#!/usr/bin/env bash
#
# dirty-disk-test.sh — install the ISO onto a disk that is not blank.
#
# Every VM install this repo has ever done started from a fresh qcow2, and a
# fresh qcow2 is the one thing real hardware never is. That gap is not
# academic: the first bare-metal attempt failed twice on it, and destroyed the
# disk's partition table on the way past.
#
# What it failed on was btrfs. btrfs-progs ships a udev rule that runs
# `btrfs device scan` on every device carrying a btrfs signature, so the live
# medium registers the target with the kernel while booting. A registered
# device is held, and a held device refuses the exclusive open that wipefs and
# mkfs both need — with nothing mounted, nothing in lsblk's tree and nothing in
# /sys/class/block/*/holders to see. See disk_release in
# files/iso/overlay/root/lib/disk.sh.
#
# Reproducing that costs nothing, which is the point of this script. mkfs works
# on a plain file, so a disk shaped like the machine that failed — GPT, a 1G
# ESP, the rest btrfs — can be built with no root and no loop device, and qemu
# will boot it as an ordinary disk. Run this after any change to disk.sh:
# nothing else here can fail the way real hardware does.
#
#   files/dev/dirty-disk-test.sh          build the disk, boot the installer
#   files/dev/dirty-disk-test.sh verify   boot what got installed, and probe it
#   files/dev/dirty-disk-test.sh clean    throw the disk away
#
# It needs an ISO in the repo root (./manuserver.sh build_iso), qemu, and
# btrfs-progs, dosfstools and util-linux for the three mkfs calls.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="${HERE%/files/dev}"
readonly WORK="$HERE/.dirty"
readonly DISK="$WORK/dirty.qcow2"
readonly NVRAM="$WORK/OVMF_VARS.fd"

# Its own everything: disk, NVRAM, forwarded port and monitor. The real VM may
# well be running, and this must not compete with it for 8080 or 2222 or reach
# its disk by any path.
readonly HTTP_PORT=8081
readonly MONITOR=/tmp/manuserver-dirty.sock   # short: a unix socket path cannot exceed ~108 bytes
readonly PIDFILE="$WORK/qemu.pid"

# Sector offsets of the layout below, needed twice: once to write the
# filesystems in, once to read them back out.
readonly ESP_START=2048        # 1 MiB in, the conventional first-LBA
readonly ESP_SECTORS=2097152   # 1 GiB
readonly ROOT_START=2099200

say() { printf '==> %s\n' "$*"; }
die() { printf 'dirty-disk-test: %s\n' "$*" >&2; exit 1; }

newest_iso() {
  { find "$ROOT" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null || true; } |
    sort -rn | head -n1 | cut -d' ' -f2-
}

find_firmware() {
  local f
  for f in "$@"; do [[ -r $f ]] && { printf '%s' "$f"; return 0; }; done
  return 1
}

ovmf_code() {
  find_firmware \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/OVMF/OVMF_CODE.fd
}

ovmf_vars() {
  find_firmware \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
    /usr/share/OVMF/OVMF_VARS.fd
}

# --- building the disk -------------------------------------------------------

build_disk() {
  local esp="$WORK/esp.img" root="$WORK/root.img" raw="$WORK/target.img"

  for tool in sfdisk mkfs.btrfs mkfs.fat qemu-img; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
  done

  install -d "$WORK"
  rm -f "$DISK" "$esp" "$root" "$raw"

  say "laying out a disk that looks like a machine somebody already used"
  truncate -s 8G "$raw"
  sfdisk --quiet "$raw" >/dev/null <<PARTS
label: gpt
size=${ESP_SECTORS}, type=uefi, name=ESP
type=linux, name=root
PARTS

  # Each filesystem is made in a file of its own and then placed at the offset
  # its partition starts at. Formatting inside the image directly would mean a
  # loop device, and a loop device would mean root — which this test does not
  # need and should not ask for.
  truncate -s 1G "$esp"
  mkfs.fat -F32 -n ESP "$esp" >/dev/null

  truncate -s 7G "$root"
  # The label is a joke with a purpose: it is what the machine that failed was
  # about to be replaced with, and seeing it survive is how you know the test
  # did not silently start from a blank disk.
  mkfs.btrfs -f -L archlab "$root" >/dev/null 2>&1

  dd if="$esp"  of="$raw" bs=512 seek="$ESP_START"  conv=notrunc status=none
  dd if="$root" of="$raw" bs=512 seek="$ROOT_START" conv=notrunc status=none
  rm -f "$esp" "$root"

  qemu-img convert -f raw -O qcow2 "$raw" "$DISK"
  rm -f "$raw"

  say "built $DISK"
  describe_disk
}

# What the root partition actually holds, read straight out of the image. This
# is the measurement the whole test turns on: btrfs before, ext4 after.
describe_disk() {
  local raw="$WORK/read.img" desc
  qemu-img convert -O raw "$DISK" "$raw"
  desc=$(dd if="$raw" bs=512 skip="$ROOT_START" count=200 status=none | file -)
  rm -f "$raw"

  printf '    root partition: %s\n' "${desc#/dev/stdin: }"
}

# --- running it --------------------------------------------------------------

install_from_iso() {
  local iso code vars
  iso=$(newest_iso)
  [[ -n $iso ]] || die "no ISO in $ROOT — build one: ./manuserver.sh build_iso"
  code=$(ovmf_code) || die "OVMF firmware not found"
  vars=$(ovmf_vars) || die "OVMF vars not found"

  install -m 644 "$vars" "$NVRAM"

  say "booting $(basename "$iso") against it"
  printf '    watch for:  > releasing /dev/vda from its previous install\n'
  printf '    that line only prints when the hold was found. Getting past\n'
  printf '    "clearing filesystem signatures" is the whole test.\n\n'

  qemu-system-x86_64 \
    -machine q35,accel="$(accel)" -cpu "$(cpu)" -smp 2 -m 4G \
    -drive "if=pflash,format=raw,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,file=$NVRAM" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display gtk \
    -drive "media=cdrom,readonly=on,file=$iso" \
    -boot order=d,menu=on \
    -no-reboot

  say "installer exited"
  describe_disk
  printf '\n    ext4 "manuserver" above means the disk was released and installed.\n'
  printf '    btrfs "archlab" means it was not, and nothing was destroyed.\n'
  printf '\n    then: %s verify\n' "${BASH_SOURCE[0]}"
}

accel() { [[ -r /dev/kvm && -w /dev/kvm ]] && printf 'kvm' || printf 'tcg'; }
cpu()   { [[ -r /dev/kvm && -w /dev/kvm ]] && printf 'host' || printf 'max'; }

# Boot what was installed, with no ISO attached, and ask it the same questions
# the clean-room run asked. A disk that formats is not the same as a disk that
# boots, and this is the cheap way to tell them apart.
verify_install() {
  local code
  [[ -f $DISK ]] || die "no disk yet — run this with no arguments first"
  code=$(ovmf_code) || die "OVMF firmware not found"
  [[ -f $NVRAM ]] || install -m 644 "$(ovmf_vars)" "$NVRAM"

  rm -f "$MONITOR"
  say "booting the installed system on port $HTTP_PORT"
  qemu-system-x86_64 \
    -machine q35,accel="$(accel)" -cpu "$(cpu)" -smp 2 -m 4G \
    -drive "if=pflash,format=raw,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,file=$NVRAM" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$HTTP_PORT-:80" \
    -device virtio-net-pci,netdev=net0 \
    -display none -daemonize \
    -pidfile "$PIDFILE" \
    -monitor "unix:$MONITOR,server,nowait"

  local base="http://localhost:$HTTP_PORT" i code_out
  for i in $(seq 1 40); do
    code_out=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$base/" 2>/dev/null || true)
    [[ $code_out == 200 ]] && break
    sleep 3
  done

  printf '\n'
  probe "$base/"        200 'front page'
  # /new renders a feed, which reads user_reputation — so a 200 here is proof
  # that db-setup.sh built the role, the database and the schema at boot.
  probe "$base/new"     200 'feed (proves the database was built at boot)'
  probe "$base/index.php" 404 'only the router executes'
  probe "$base/nope"    404 'unknown paths'

  printf '\n'
  if curl -sSI --max-time 8 "$base/fonts/geomini-latin.woff2?cb=$RANDOM" 2>/dev/null |
       grep -qi 'max-age=31536000'; then
    printf '  ok    fonts cached for a year\n'
  else
    printf '  FAIL  fonts are not cached for a year\n'
  fi

  stop_vm
}

probe() {
  local url=$1 want=$2 label=$3 got
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)
  if [[ $got == "$want" ]]; then
    printf '  ok    %-48s %s\n' "$label" "$got"
  else
    printf '  FAIL  %-48s %s (wanted %s)\n' "$label" "$got" "$want"
  fi
}

stop_vm() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || return 0

  command -v socat >/dev/null &&
    printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$MONITOR" >/dev/null 2>&1 || true

  local waited=0
  while ((waited < 30)) && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
  rm -f "$PIDFILE" "$MONITOR"
  printf '\n'
  say "test machine stopped"
}

case "${1:-run}" in
  run)    build_disk; install_from_iso ;;
  # Building the disk is the half of this that can be checked without a
  # keyboard, so it is worth being able to run on its own.
  build)  build_disk ;;
  verify) verify_install ;;
  clean)  stop_vm; rm -rf "$WORK"; say "removed $WORK" ;;
  *)      die "unknown command: $1 (try: run, build, verify, clean)" ;;
esac

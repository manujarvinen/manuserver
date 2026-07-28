#!/usr/bin/env bash
#
# run-manuserver-in-vm.sh — install manuserver into a VM, then run it like a
# server.
#
#   ./run-manuserver-in-vm.sh install    fresh disk, boot the ISO, install
#   ./run-manuserver-in-vm.sh            start the server in the background
#   ./run-manuserver-in-vm.sh stop       ask it to shut down cleanly
#   ./run-manuserver-in-vm.sh status     is it up, and on which ports
#   ./run-manuserver-in-vm.sh ssh [user] open a shell on it
#   ./run-manuserver-in-vm.sh console    boot it in a window, to watch it boot
#
# Starting and stopping the VM *is* starting and stopping the server: the
# installed system autologins on tty1 and brings its services up on boot, so
# there is nothing to log into first.
#
# Forwards host 8080 -> 80 and 2222 -> 22. Everything is UEFI; the installer
# refuses to run under BIOS, so a BIOS test would test nothing.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly OUT="$HERE/out"
readonly VM="$HERE/build/vm"
readonly DISK="$VM/manuserver.qcow2"
readonly NVRAM="$VM/OVMF_VARS.fd"
readonly PIDFILE="$VM/qemu.pid"
readonly MONITOR="$VM/monitor.sock"
readonly DISK_SIZE=20G
readonly SSH_PORT=2222
readonly HTTP_PORT=8080

die() { printf 'run-manuserver-in-vm.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

# shellcheck source=lib/host-tools.sh
source "$HERE/lib/host-tools.sh"

# --- tooling ---------------------------------------------------------------
#
# All of this is resolved on demand. `status`, `stop` and `ssh` have no use for
# firmware images or an accelerator, and should keep working on a machine where
# the build tooling was never installed.

OVMF_CODE=''
OVMF_VARS=''
ACCEL=''
CPU=''

# The packaged path for OVMF has moved between edk2 releases; probe for it
# rather than hardcoding one.
find_firmware() {
  local f
  for f in "$@"; do [[ -r $f ]] && { printf '%s' "$f"; return 0; }; done
  return 1
}

ensure_firmware() {
  [[ -n $OVMF_CODE ]] && return 0

  OVMF_CODE=$(find_firmware \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd) || die "OVMF firmware not found — run ./build_manuserver_iso.sh first"

  OVMF_VARS=$(find_firmware \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS.fd) || die "OVMF vars not found — run ./build_manuserver_iso.sh first"
}

# KVM needs membership of the kvm group. Without it the VM still runs, just
# slowly, which beats refusing to start.
ensure_accel() {
  [[ -n $ACCEL ]] && return 0
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=kvm
    CPU=host
  else
    say "no access to /dev/kvm — using software emulation (slow)."
    say "for the fast path: sudo usermod -aG kvm \$USER, then log out and in."
    ACCEL=tcg
    CPU=max
  fi
}

ensure_vm() {
  host_tools_ensure qemu-system-x86_64 qemu-img socat
  ensure_firmware
  ensure_accel
}

# --- state -----------------------------------------------------------------

vm_pid() {
  [[ -r $PIDFILE ]] || return 1
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

vm_running() { vm_pid >/dev/null; }

require_disk() {
  [[ -f $DISK ]] || die "nothing installed yet — run: $0 install"
}

# A fresh NVRAM copy per VM: the system OVMF_VARS is read-only and shared, and
# UEFI needs somewhere writable to keep its boot entries.
reset_nvram() {
  install -d "$VM"
  install -m 644 "$OVMF_VARS" "$NVRAM"
}

base_args() {
  printf '%s\n' \
    -machine "q35,accel=$ACCEL" \
    -cpu "$CPU" \
    -smp 2 \
    -m 4G \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$NVRAM" \
    -drive "if=virtio,format=qcow2,file=$DISK" \
    -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp::$HTTP_PORT-:80" \
    -device "virtio-net-pci,netdev=net0"
}

# Newest ISO in out/, or nothing. The `|| true` is load-bearing: under
# `pipefail`, a missing out/ makes find fail, which would abort the script
# through `set -e` before the caller can print something useful.
newest_iso() {
  { find "$OUT" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null || true; } |
    sort -rn | head -n1 | cut -d' ' -f2-
}

# --- verbs -----------------------------------------------------------------

cmd_install() {
  local iso
  iso=$(newest_iso)
  [[ -n $iso ]] || die "no ISO in $OUT — run: ./build_manuserver_iso.sh"

  ! vm_running || die "the VM is running — stop it first: $0 stop"
  ensure_vm

  # A fresh disk every time. A half-finished install left lying around is a
  # confusing thing to debug on the next run.
  install -d "$VM"
  rm -f "$DISK"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
  reset_nvram

  say "booting $(basename "$iso") — the installer starts on its own"
  local -a args=()
  mapfile -t args < <(base_args)
  qemu-system-x86_64 "${args[@]}" \
    -display gtk \
    -drive "media=cdrom,readonly=on,file=$iso" \
    -boot "order=d,menu=on"

  say "installer VM exited. start the installed server with: $0"
  offer_iso_cleanup "$iso"
}

# The ISO is about a gigabyte and, once it has been installed into the VM, only
# earns its keep if you plan to reinstall or write a USB stick. Ask rather than
# assume either way -- and default to keeping it, since rebuilding costs twenty
# minutes and deleting costs nothing to undo but time.
offer_iso_cleanup() {
  local iso=$1 size reply
  [[ -f $iso ]] || return 0
  [[ -t 0 ]] || return 0   # non-interactive: never delete behind someone's back

  size=$(du -h "$iso" | cut -f1)
  printf '\n'
  read -rp "Delete the ISO ($size) now that it is installed? [y/N] " reply
  case ${reply,,} in
    y|yes)
      rm -f "$iso"
      say "removed $(basename "$iso") — rebuild with ./build_manuserver_iso.sh"
      ;;
    *)
      say "kept $iso"
      ;;
  esac
}

cmd_start() {
  require_disk
  if vm_running; then
    say "already running (pid $(vm_pid))"
    return 0
  fi

  ensure_vm
  [[ -f $NVRAM ]] || reset_nvram
  rm -f "$MONITOR"

  local -a args=()
  mapfile -t args < <(base_args)
  # -daemonize backgrounds it; the monitor socket is how `stop` reaches the
  # guest's power button.
  qemu-system-x86_64 "${args[@]}" \
    -display none \
    -daemonize \
    -pidfile "$PIDFILE" \
    -monitor "unix:$MONITOR,server,nowait"

  say "manuserver is booting (pid $(vm_pid))"
  printf '    ssh    ssh -p %s <user>@localhost   (or: %s ssh)\n' "$SSH_PORT" "$0"
  printf '    http   http://localhost:%s\n' "$HTTP_PORT"
  printf '    stop   %s stop\n' "$0"
}

cmd_stop() {
  vm_running || { say "not running"; return 0; }

  local pid
  pid=$(vm_pid)
  host_tools_ensure socat

  # system_powerdown is an ACPI power-button press: the guest shuts services
  # down in order. Killing qemu instead is the equivalent of pulling the plug
  # on a live database.
  say "asking manuserver to shut down"
  printf 'system_powerdown\n' | socat - "UNIX-CONNECT:$MONITOR" >/dev/null 2>&1 ||
    die "could not reach the VM monitor at $MONITOR"

  local waited=0
  while ((waited < 60)) && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    die "still up after ${waited}s — it may be mid-boot. Force it with: kill $pid"
  fi

  rm -f "$PIDFILE" "$MONITOR"
  say "stopped cleanly after ${waited}s"
}

cmd_status() {
  if vm_running; then
    say "running (pid $(vm_pid))"
    printf '    ssh    localhost:%s\n    http   localhost:%s\n' "$SSH_PORT" "$HTTP_PORT"
  else
    say "not running"
    [[ -f $DISK ]] || printf '    no disk installed yet — run: %s install\n' "$0"
  fi
}

cmd_ssh() {
  vm_running || die "not running — start it with: $0"
  local user=${1:-$USER}
  # A rebuilt VM reuses the port with a different host key, which otherwise
  # trips the known_hosts warning every single time.
  exec ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$user@localhost"
}

cmd_console() {
  require_disk
  ! vm_running || die "already running in the background — stop it first: $0 stop"
  ensure_vm
  [[ -f $NVRAM ]] || reset_nvram
  local -a args=()
  mapfile -t args < <(base_args)
  exec qemu-system-x86_64 "${args[@]}" -display gtk
}

case "${1:-start}" in
  install) cmd_install ;;
  start|up) cmd_start ;;
  stop|down) cmd_stop ;;
  status) cmd_status ;;
  ssh) shift; cmd_ssh "$@" ;;
  console) cmd_console ;;
  -h|--help|help)
    # The header comment is the help text; print it up to the first line that
    # isn't a comment, so the two can never drift apart.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
    ;;
  *) die "unknown command: $1 (try: $0 --help)" ;;
esac

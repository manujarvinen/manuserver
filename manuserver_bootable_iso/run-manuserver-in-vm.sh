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
#   ./run-manuserver-in-vm.sh backup     save the database to backups/
#   ./run-manuserver-in-vm.sh restore    put a saved database back
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
readonly BACKUPS="$HERE/backups"

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

# Installing erases the VM's disk. That is harmless the first time and
# destructive every time after, because the database lives on that disk and
# this is the only copy of it. So: never wipe an existing machine without
# being told to, twice.
confirm_wipe() {
  local reply size
  size=$(du -h "$DISK" 2>/dev/null | cut -f1)

  printf '\n'
  printf 'There is already a manuserver installed in this VM (%s).\n' "${size:-unknown size}"
  printf 'Installing again ERASES it, including the database and anything\n'
  printf 'else on it. There is no undo.\n\n'

  if [[ ! -t 0 ]]; then
    die "refusing to erase it without a confirmation. Use: $0 install --wipe"
  fi

  read -rp "Type ERASE to confirm, anything else to cancel: " reply
  [[ $reply == ERASE ]] || die "cancelled — nothing was touched"
}

cmd_install() {
  local iso wipe=0

  # `--wipe` is for when you already know, and for scripts. It skips the
  # question, nothing else.
  [[ ${1:-} == --wipe || ${1:-} == -f ]] && wipe=1

  iso=$(newest_iso)
  [[ -n $iso ]] || die "no ISO in $OUT — run: ./build_manuserver_iso.sh"

  ! vm_running || die "the VM is running — stop it first: $0 stop"

  if [[ -f $DISK ]] && ((!wipe)); then
    confirm_wipe
  fi

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

  # -no-reboot is what keeps this from looping. The ISO is still in the virtual
  # drive when the installer reboots at the end, and the firmware would boot it
  # again and run the installer a second time. Exiting on the reboot ends the
  # install session instead, and every later start runs without the ISO
  # attached at all.
  qemu-system-x86_64 "${args[@]}" \
    -display gtk \
    -drive "media=cdrom,readonly=on,file=$iso" \
    -boot "order=d,menu=on" \
    -no-reboot

  say "install finished. start the server with: $0"
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

# A rebuilt VM reuses the port with a different host key, which otherwise trips
# the known_hosts warning every single time.
ssh_opts() {
  printf '%s\n' \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR
}

cmd_ssh() {
  vm_running || die "not running — start it with: $0"
  local user=${1:-$USER}
  local -a opts=()
  mapfile -t opts < <(ssh_opts)
  exec ssh "${opts[@]}" "$user@localhost"
}

# vm_run <tty|notty> <user> <command...>
#
# `tty` allocates a terminal, which sudo needs in order to ask for a password.
# Anything whose output we capture must use `notty`, because a terminal turns
# every newline into CRLF and would quietly corrupt a database dump.
vm_run() {
  local mode=$1 user=$2; shift 2
  local -a opts=()
  mapfile -t opts < <(ssh_opts)
  [[ $mode == tty ]] && opts+=(-t)
  # shellcheck disable=SC2029  # paths are meant to expand here; anything that
  # must run on the server is escaped by the caller
  ssh "${opts[@]}" "$user@localhost" "$@"
}

# --- backup and restore ----------------------------------------------------
#
# The database lives inside the VM, on a single disk image. These two verbs
# exist so that is not the only copy of it.

readonly REMOTE_TMP=/tmp/manuserver-db.sql

require_postgres() {
  local user=$1
  vm_run notty "$user" 'command -v pg_dumpall >/dev/null 2>&1' ||
    die "Postgres is not installed on the server yet.
     That happens in server/deploy/provision.sh, which is still a placeholder."
}

newest_backup() {
  { find "$BACKUPS" -maxdepth 1 -name '*.sql' -printf '%T@ %p\n' 2>/dev/null || true; } |
    sort -rn | head -n1 | cut -d' ' -f2-
}

cmd_backup() {
  local user=${1:-$USER} stamp file

  vm_running || die "not running — start it with: $0"
  require_postgres "$user"

  install -d "$BACKUPS"
  stamp=$(date +%Y-%m-%d-%H%M)
  file="$BACKUPS/manuserver-$stamp.sql"

  # Dump on the server first, then fetch it. Doing both in one step would mean
  # capturing output from a terminal session, which mangles the file.
  say "asking the server for a copy of the database"
  vm_run tty "$user" \
    "sudo -u postgres pg_dumpall --clean > $REMOTE_TMP && sudo chown \$(id -un) $REMOTE_TMP" ||
    die "the server could not make a copy — see the message above"

  vm_run notty "$user" "cat $REMOTE_TMP" >"$file" || {
    rm -f "$file"
    die "could not fetch the copy from the server"
  }
  vm_run notty "$user" "rm -f $REMOTE_TMP" || true

  [[ -s $file ]] || { rm -f "$file"; die "the copy came back empty — nothing saved"; }

  say "saved $file ($(du -h "$file" | cut -f1))"
}

cmd_restore() {
  local file=${1:-} user=${2:-$USER} reply

  vm_running || die "not running — start it with: $0"

  if [[ -z $file ]]; then
    file=$(newest_backup)
    [[ -n $file ]] || die "no backups in $BACKUPS — make one with: $0 backup"
    say "using the newest backup: $(basename "$file")"
  fi
  [[ -r $file ]] || die "cannot read $file"

  require_postgres "$user"

  # Restoring replaces what is on the server. Same rule as installing: ask
  # first, and default to not doing it.
  printf '\n'
  printf 'This REPLACES the database on the server with:\n  %s\n' "$file"
  printf 'Anything currently in it is lost.\n\n'
  [[ -t 0 ]] || die "refusing to restore without a confirmation"
  read -rp "Continue? [y/N] " reply
  case ${reply,,} in y|yes) ;; *) die "cancelled — the server was not touched" ;; esac

  say "sending the backup to the server"
  vm_run notty "$user" "cat > $REMOTE_TMP" <"$file" || die "could not send the file"

  say "restoring"
  vm_run tty "$user" "sudo -u postgres psql -q -f $REMOTE_TMP" ||
    die "the restore reported a problem — see the message above"
  vm_run notty "$user" "rm -f $REMOTE_TMP" || true

  say "restored from $(basename "$file")"
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
  install) shift; cmd_install "$@" ;;
  start|up) cmd_start ;;
  stop|down) cmd_stop ;;
  status) cmd_status ;;
  ssh) shift; cmd_ssh "$@" ;;
  backup) shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  console) cmd_console ;;
  -h|--help|help)
    # The header comment is the help text; print it up to the first line that
    # isn't a comment, so the two can never drift apart.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
    ;;
  *) die "unknown command: $1 (try: $0 --help)" ;;
esac

#!/usr/bin/env bash
#
# manuserver — install it into a VM, then run it like a server.
#
# (In the checkout this file is run-manuserver-in-vm.sh. The header doubles as
# --help, so it is written in terms of the installed name.)
#
# After `install-command` this is `manuserver` on your PATH, and every line
# below works from any directory:
#
#   manuserver install          fresh disk, boot the ISO, install
#   manuserver install-command  put `manuserver` on your PATH
#   manuserver                  start the server in the background
#   manuserver stop             ask it to shut down cleanly
#   manuserver status           is it up, and on which ports
#   manuserver ssh [user]       open a shell on it
#   manuserver tunnel           put the site on the public internet
#   manuserver backup           save the database
#   manuserver restore          put a saved database back
#   manuserver console          boot it in a window, to watch it boot
#
# The VM, its backups and the installed command all live under
# ~/.local/share/manuserver, never in the checkout — so the clone can be moved
# or deleted afterwards without taking the server with it. Only `install`
# needs the checkout, because only it needs an ISO.
#
# Starting and stopping the VM *is* starting and stopping the server: the
# installed system autologins on tty1 and brings its services up on boot, so
# there is nothing to log into first.
#
# Forwards host 8080 -> 80 and 2222 -> 22. Everything is UEFI; the installer
# refuses to run under BIOS, so a BIOS test would test nothing.

set -euo pipefail

# readlink -f so that HERE is where the script really lives, not where the
# symlink to it does. `install-command` puts a copy in the data directory and
# links it onto PATH, and the copy still has to find its own lib/.
SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
HERE="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd)"
readonly SELF_PATH HERE

# How to refer to this command in messages. `manuserver` once it is on PATH,
# ./run-manuserver-in-vm.sh when run out of the checkout.
SELF="${0##*/}"
[[ $SELF == manuserver ]] || SELF="./$SELF"
readonly SELF

# Two places this runs from: the git checkout, and the copy in the data
# directory. Only the checkout has ISOs to install from and a repo to delete.
if [[ -f $HERE/build_manuserver_iso.sh ]]; then
  IN_REPO=1
  REPO_ROOT="$(cd -- "$HERE/.." && pwd)"
else
  IN_REPO=0
  REPO_ROOT=''
fi
readonly IN_REPO REPO_ROOT

# The VM lives in the user's data directory, deliberately not in the checkout.
# A clone sitting in ~/Downloads may be moved, renamed or deleted, and none of
# that should take an installed server and its database with it.
#
# Not /opt or /var/lib: those are root-owned, and this VM is started by you,
# runs as you, and uses your kvm group membership. Putting it there would mean
# sudo for every start, stop and backup, to no benefit.
readonly DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/manuserver"
readonly VM="$DATA_HOME/vm"
readonly CLI_DIR="$DATA_HOME/bin"

# Backups are the exception, and go somewhere you can actually see them.
# ~/.local/share is right for state you never touch by hand; a database dump is
# the opposite — the entire point of one is dragging it onto a USB stick.
#
# xdg-user-dir answers "$HOME" when the machine has no user-dirs configuration,
# which would drop .sql files loose in the home directory. Hence the guard.
BACKUPS="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
[[ -n $BACKUPS && $BACKUPS != "$HOME" ]] || BACKUPS="$HOME/Downloads"
readonly BACKUPS

readonly OUT="$HERE/out"
readonly DISK="$VM/manuserver.qcow2"
readonly NVRAM="$VM/OVMF_VARS.fd"
readonly PIDFILE="$VM/qemu.pid"
readonly MONITOR="$VM/monitor.sock"
readonly DISK_SIZE=20G
readonly SSH_PORT=2222
readonly HTTP_PORT=8080

# What the forwarded ports listen on.
#
# QEMU's hostfwd takes the host address before the port, and leaving it empty
# — as this did — binds to 0.0.0.0. That put the VM's sshd in front of the
# whole local network: any device on the wifi could reach it on 2222 and guess
# passwords at it, unrated and unlogged. Nobody asked for that, and ssh here is
# always from this machine.
readonly SSH_BIND=127.0.0.1

# The site is the one thing you might genuinely want to open on your phone, so
# this is a knob rather than a constant. It still defaults to closed:
#
#   MANUSERVER_HTTP_BIND=0.0.0.0 manuserver
#
# The public route is the Cloudflare tunnel, which needs none of this.
readonly HTTP_BIND="${MANUSERVER_HTTP_BIND:-127.0.0.1}"

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
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
  [[ -f $DISK ]] || die "nothing installed yet — run: $SELF install"
}

# Earlier versions kept the VM inside the checkout, at build/vm. Move it out on
# first run, so upgrading does not look like a lost server.
migrate_from_checkout() {
  local old_vm="$HERE/build/vm" pid old

  # Backups have lived in the checkout, and briefly in the data directory.
  # Move the dumps themselves rather than the directory, since the destination
  # is now a folder full of other things.
  for old in "$HERE/backups" "$DATA_HOME/backups"; do
    [[ -d $old ]] || continue

    if compgen -G "$old/manuserver-*.sql" >/dev/null; then
      install -d "$BACKUPS"
      mv -- "$old"/manuserver-*.sql "$BACKUPS"/
      say "moved your database backups to $BACKUPS"
    fi

    rmdir -- "$old" 2>/dev/null || true
  done

  ((IN_REPO)) || return 0

  [[ -f $old_vm/manuserver.qcow2 ]] || return 0
  [[ -f $DISK ]] && return 0

  # Started by an older copy of this script, whose pidfile we no longer read.
  if [[ -r $old_vm/qemu.pid ]]; then
    pid=$(cat "$old_vm/qemu.pid" 2>/dev/null || true)
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      die "the VM is running from its old location inside the checkout.
     Shut it down and run this again:  kill $pid"
    fi
  fi

  say "moving the VM out of the checkout into $VM"
  install -d "$DATA_HOME"
  mv -- "$old_vm" "$VM"
  rmdir -- "$HERE/build" 2>/dev/null || true
  say "the checkout can now be moved or deleted without losing the server"
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
    -netdev "user,id=net0,hostfwd=tcp:$SSH_BIND:$SSH_PORT-:22,hostfwd=tcp:$HTTP_BIND:$HTTP_PORT-:80" \
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
    die "refusing to erase it without a confirmation. Use: $SELF install --wipe"
  fi

  read -rp "Type ERASE to confirm, anything else to cancel: " reply
  [[ $reply == ERASE ]] || die "cancelled — nothing was touched"
}

# --- putting the command on PATH -------------------------------------------
#
# A copy, not a symlink into the checkout. The whole point is that the checkout
# can be deleted afterwards, and a symlink into a deleted directory is worse
# than no command at all — it exists, and it fails.
#
# The copy takes lib/ with it, which is why HERE is resolved through readlink.
cmd_install_command() {
  ((IN_REPO)) || die "this is already the installed copy"

  local bindir="$HOME/.local/bin" link="$HOME/.local/bin/manuserver"

  install -d "$CLI_DIR/lib" "$bindir"
  install -m 755 "$HERE/run-manuserver-in-vm.sh" "$CLI_DIR/manuserver"
  install -m 644 "$HERE/lib/host-tools.sh" "$CLI_DIR/lib/host-tools.sh"
  ln -sfn -- "$CLI_DIR/manuserver" "$link"

  say "installed $link"

  case ":$PATH:" in
    *":$bindir:"*)
      say "run it from anywhere now:  manuserver"
      ;;
    *)
      printf '\n'
      say "$bindir is not on your PATH. Add this line to ~/.bashrc or ~/.zshrc:"
      printf '\n    export PATH="$HOME/.local/bin:$PATH"\n\n'
      ;;
  esac
}

offer_install_command() {
  ((IN_REPO)) || return 0
  [[ -t 0 ]] || return 0
  [[ -x $CLI_DIR/manuserver ]] && return 0

  local reply
  printf '\n'
  read -rp "Install the 'manuserver' command, so you can run it from anywhere? [Y/n] " reply

  case ${reply,,} in
    n|no) say "skipped — do it later with: $SELF install-command"; return 0 ;;
  esac

  cmd_install_command
}

# Offered only once the command is installed and the VM is out of the tree,
# because until both are true this checkout is the only way to reach the
# server.
offer_repo_cleanup() {
  ((IN_REPO)) || return 0
  [[ -t 0 ]] || return 0
  [[ -x $CLI_DIR/manuserver ]] || return 0

  local reply keep=''

  # Deleting a checkout with work in it cannot be undone from here, so this
  # refuses rather than asks.
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null) ]]; then
      keep='it has uncommitted changes'
    elif [[ -n $(git -C "$REPO_ROOT" log --branches --not --remotes --oneline 2>/dev/null) ]]; then
      keep='it has commits that were never pushed'
    fi
  else
    keep='it is not a git checkout, so there is nothing to clone it back from'
  fi

  printf '\n'

  if [[ -n $keep ]]; then
    say "keeping $REPO_ROOT — $keep"
    return 0
  fi

  printf 'The command is installed and the VM lives in\n'
  printf '  %s\n' "$DATA_HOME"
  printf 'so the checkout is no longer needed to run the server. Deleting it\n'
  printf 'also removes any ISOs left in it. Everything is on GitHub.\n\n'
  read -rp "Delete $REPO_ROOT ? [y/N] " reply

  case ${reply,,} in
    y|yes) ;;
    *) say "kept $REPO_ROOT"; return 0 ;;
  esac

  printf '\n'
  say "deleting $REPO_ROOT"
  printf '\nStart the server with:  manuserver\n\n'

  # exec, from outside the tree. Bash reads a script incrementally as it runs,
  # so deleting this file while it is still being interpreted is a real way to
  # corrupt the rest of the run. Replacing the shell means it is never read
  # again, and cd / means the working directory is not being deleted either.
  cd /
  exec rm -rf -- "$REPO_ROOT"
}

cmd_install() {
  local iso wipe=0

  ((IN_REPO)) || die "installing needs the checkout and an ISO to install from.
     Clone it again and build one:
       git clone https://github.com/manujarvinen/manuserver.git
       cd manuserver/manuserver_bootable_iso && ./build_manuserver_iso.sh"

  # `--wipe` is for when you already know, and for scripts. It skips the
  # question, nothing else.
  [[ ${1:-} == --wipe || ${1:-} == -f ]] && wipe=1

  iso=$(newest_iso)
  [[ -n $iso ]] || die "no ISO in $OUT — run: ./build_manuserver_iso.sh"

  ! vm_running || die "the VM is running — stop it first: $SELF stop"

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

  say "install finished"
  offer_iso_cleanup "$iso"
  offer_install_command
  offer_repo_cleanup

  printf '\n'
  say "start the server with: $SELF"
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
  printf '    ssh    ssh -p %s <user>@localhost   (or: %s ssh)\n' "$SSH_PORT" "$SELF"
  printf '    http   http://localhost:%s\n' "$HTTP_PORT"
  printf '    stop   %s stop\n' "$SELF"
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
    printf '    ssh    %s:%s\n    http   http://%s:%s\n' \
      "$SSH_BIND" "$SSH_PORT" "$HTTP_BIND" "$HTTP_PORT"

    # Worth saying out loud, since it is the difference between "only this
    # machine" and "anyone on the wifi".
    [[ $HTTP_BIND == 0.0.0.0 ]] &&
      printf '           reachable from the local network (MANUSERVER_HTTP_BIND)\n'
  else
    say "not running"
    [[ -f $DISK ]] || printf '    no disk installed yet — run: %s install\n' "$SELF"
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
  vm_running || die "not running — start it with: $SELF"
  local user=${1:-$USER}
  local -a opts=()
  mapfile -t opts < <(ssh_opts)
  exec ssh "${opts[@]}" "$user@localhost"
}

# Putting the server on the internet means pasting a ~200-character Cloudflare
# token, and QEMU has no clipboard into a guest console — typing it by hand on
# the VM's own screen is not a real option. So this is deliberately an ssh
# session in *your* terminal, where paste works the way it always does.
#
# The token goes straight from your clipboard into the prompt on the server.
# This script never receives it, never passes it as an argument, and cannot
# leave it in the host's shell history or process list.
cmd_tunnel() {
  vm_running || die "not running — start it with: $SELF"

  local action=on user=$USER

  case ${1:-} in
    on|off|status) action=$1; shift ;;
  esac

  [[ -n ${1:-} ]] && user=$1

  local -a opts=()
  mapfile -t opts < <(ssh_opts)
  opts+=(-t)

  exec ssh "${opts[@]}" "$user@localhost" "sudo manuserver-tunnel $action"
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
    die "Postgres is not installed on the server.
     It is installed by server/deploy/provision.sh during the install. If this
     machine was installed before that script existed, bring it up to date:
       $SELF ssh $user
       cd /srv/manuserver && sudo git pull && sudo bash server/deploy/provision.sh"
}

# manuserver-*.sql, not *.sql. Backups share a directory with everything else
# you have ever downloaded, and restoring somebody else's stray dump over this
# database would be a memorable way to lose an evening.
newest_backup() {
  { find "$BACKUPS" -maxdepth 1 -name 'manuserver-*.sql' -printf '%T@ %p\n' 2>/dev/null || true; } |
    sort -rn | head -n1 | cut -d' ' -f2-
}

cmd_backup() {
  local user=${1:-$USER} stamp file

  vm_running || die "not running — start it with: $SELF"
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

  vm_running || die "not running — start it with: $SELF"

  if [[ -z $file ]]; then
    file=$(newest_backup)
    [[ -n $file ]] || die "no backups in $BACKUPS — make one with: $SELF backup"
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
  ! vm_running || die "already running in the background — stop it first: $SELF stop"
  ensure_vm
  [[ -f $NVRAM ]] || reset_nvram
  local -a args=()
  mapfile -t args < <(base_args)
  exec qemu-system-x86_64 "${args[@]}" -display gtk
}

# A no-op unless this is an old checkout whose VM still sits inside it.
migrate_from_checkout

case "${1:-start}" in
  install) shift; cmd_install "$@" ;;
  install-command) cmd_install_command ;;
  start|up) cmd_start ;;
  stop|down) cmd_stop ;;
  status) cmd_status ;;
  ssh) shift; cmd_ssh "$@" ;;
  tunnel) shift; cmd_tunnel "$@" ;;
  backup) shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  console) cmd_console ;;
  -h|--help|help)
    # The header comment is the help text; print it up to the first line that
    # isn't a comment, so the two can never drift apart.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SELF_PATH"
    ;;
  *) die "unknown command: $1 (try: $SELF --help)" ;;
esac

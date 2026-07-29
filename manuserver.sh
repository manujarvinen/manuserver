#!/usr/bin/env bash
#
# manuserver — build it, install it, run it. One script, one directory.
#
#   ./manuserver.sh build_iso        build the installer ISO   (~20 min, sudo)
#   ./manuserver.sh vm_install       install that ISO into a VM  (erases it)
#   ./manuserver.sh vm_start         start the server in the background
#   ./manuserver.sh vm_stop          ask it to shut down cleanly
#   ./manuserver.sh vm_status        is it up, and on which ports
#   ./manuserver.sh vm_console       boot it in a window, to watch it boot
#   ./manuserver.sh ssh [user]       open a shell on it
#   ./manuserver.sh tunnel [on|off|status]   put the site on the internet
#   ./manuserver.sh backup           save the database to ~/Downloads
#   ./manuserver.sh restore [file]   put a saved database back
#   ./manuserver.sh site_dev         run the website here, without the VM
#   ./manuserver.sh site_seed        fill the local database with test accounts
#   ./manuserver.sh install_command  put `manuserver` on your PATH
#
# With no argument it starts the server, because that is the thing you do most.
#
# After install_command this is `manuserver`, and every line above works from
# any directory. The VM lives in ~/.local/share/manuserver and backups go to
# ~/Downloads, so the checkout can be moved or deleted without taking the
# server with it — only build_iso, vm_install and site_dev need it back.
#
# Everything this script drives is in files/:
#
#   files/lib/      the parts of this command
#   files/iso/      the installer ISO: build inputs and the TUI installer
#   files/site/     the website itself — public_html, app, database schema
#   files/deploy/   what runs on the server after it is installed
#   files/dev/      helpers for running the site here instead of on the VM
#   files/promo/    the page describing this project, hosted elsewhere
#
# Forwards 8080 -> 80 and 2222 -> 22, both bound to this machine. Everything is
# UEFI; the installer refuses to run under BIOS, so a BIOS test would test
# nothing.

set -euo pipefail

# readlink -f so this works through the symlink install_command puts on PATH:
# the copy in the data directory has to find its own files/lib, not the one in
# whatever checkout happens to be lying around.
SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
ROOT="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd)"
readonly SELF_PATH ROOT

# shellcheck source=files/lib/common.sh
source "$ROOT/files/lib/common.sh"
# shellcheck source=files/lib/host-tools.sh
source "$LIB/host-tools.sh"
# shellcheck source=files/lib/vm.sh
source "$LIB/vm.sh"

# Only the checkout has sources to build an ISO from or a site to serve. The
# installed copy loads neither, and needs_checkout explains the absence.
if ((IN_REPO)); then
  # shellcheck source=files/lib/iso.sh
  source "$LIB/iso.sh"
  # shellcheck source=files/lib/site.sh
  source "$LIB/site.sh"
fi

# A no-op unless this is an old checkout whose VM still sits inside it.
migrate_from_checkout

case "${1:-vm_start}" in
  build_iso)        needs_checkout build_iso; shift; cmd_build_iso "$@" ;;
  vm_install)       shift; cmd_vm_install "$@" ;;
  vm_start)         cmd_vm_start ;;
  vm_stop)          cmd_vm_stop ;;
  vm_status)        cmd_vm_status ;;
  vm_console)       cmd_vm_console ;;
  ssh)              shift; cmd_ssh "$@" ;;
  tunnel)           shift; cmd_tunnel "$@" ;;
  backup)           shift; cmd_backup "$@" ;;
  restore)          shift; cmd_restore "$@" ;;
  site_dev)         needs_checkout site_dev; shift; cmd_site_dev "$@" ;;
  site_seed)        needs_checkout site_seed; cmd_site_seed ;;
  site_reset)       needs_checkout site_reset; cmd_site_reset ;;
  install_command)  cmd_install_command ;;
  -h|--help|help)
    # The header comment is the help text; print it up to the first line that
    # isn't a comment, so the two can never drift apart.
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SELF_PATH"
    ;;
  *) die "unknown command: $1 (try: $SELF --help)" ;;
esac

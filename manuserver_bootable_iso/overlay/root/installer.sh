#!/usr/bin/env bash
#
# manuserver installer — entry point and flow control.
#
# Runs on tty1 of the live ISO. Every step is a full-screen redraw with one
# question on it; the individual steps live in lib/.

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

readonly HERE=/root
readonly LOGO_FILE="$HERE/manuserver_logo.txt"

# Cloned onto the target at the end of a successful install. HTTPS, not SSH:
# the freshly installed machine has no key and no known_hosts.
readonly REPO_URL='https://github.com/manujarvinen/manuserver.git'

# shellcheck source=lib/ui.sh
source "$HERE/lib/ui.sh"
# shellcheck source=lib/network.sh
source "$HERE/lib/network.sh"
# shellcheck source=lib/disk.sh
source "$HERE/lib/disk.sh"
# shellcheck source=lib/install.sh
source "$HERE/lib/install.sh"

# --- preflight -------------------------------------------------------------

preflight() {
  if ((EUID != 0)); then
    printf 'The installer must run as root.\n' >&2
    exit 1
  fi

  # systemd-boot is the only loader here and it is UEFI-only. Bail now with
  # something readable rather than at bootctl, two hundred packages later.
  if [[ ! -d /sys/firmware/efi ]]; then
    printf 'This machine booted in BIOS/legacy mode.\n' >&2
    printf 'manuserver installs UEFI-only. Enable UEFI boot in firmware and retry.\n' >&2
    exit 1
  fi
}

# --- steps -----------------------------------------------------------------

# Answers land in globals, not on stdout: these functions draw, and a command
# substitution around them would swallow the screen. See ui_input.
USERNAME=''
PASSWORD=''

ask_username() {
  while :; do
    ui_screen
    ui_body "Let's setup your user account..."
    ui_blank
    ui_input "Username" 0

    # Same rule useradd enforces, checked here so the failure is a sentence
    # instead of a chroot error at the very end of the install.
    if [[ $UI_RESULT =~ ^[a-z_][a-z0-9_-]{1,31}$ ]]; then
      USERNAME=$UI_RESULT
      return 0
    fi

    ui_blank
    ui_body "Not a valid username: start with a lowercase letter or underscore,"
    ui_body "then 1-31 more of lowercase letters, digits, underscore or dash."
    ui_blank
    ui_pause "press enter to try again"
  done
}

ask_password() {
  local first
  while :; do
    ui_screen
    ui_body "Set the password for this account."
    ui_body "It is also the sudo password — root itself will be locked."
    ui_blank
    ui_input "Password" 1
    first=$UI_RESULT

    ui_screen
    ui_body "Once more, to be sure."
    ui_blank
    ui_input "Confirm" 1

    if [[ $first == "$UI_RESULT" ]]; then
      PASSWORD=$first
      return 0
    fi

    ui_screen
    ui_body "Those didn't match."
    ui_blank
    ui_pause "press enter to try again"
  done
}

do_install() {
  local username=$1 password=$2

  ui_screen
  ui_body "Installing manuserver on $DISK..."
  ui_blank

  disk_partition
  disk_format
  disk_mount

  install_detect_ucode
  install_base

  # Credentials the live environment needed to get online are carried into the
  # target so it rejoins the same network unattended on first boot.
  if [[ -n ${NET_SSID:-} && -n ${NET_PSK:-} ]]; then
    ui_step "saving wireless credentials"
    net_persist_psk /mnt "$NET_SSID" "$NET_PSK"
  fi

  install_configure "$username"
  install_bootloader
  install_account "$username" "$password"
  install_repo "$REPO_URL"

  ui_run "unmounting" umount -R /mnt
}

finish_screen() {
  local username=$1
  ui_screen
  ui_body "manuserver is installed."
  ui_blank
  ui_line "$S_ACCENT" "  host      $TARGET_HOSTNAME"
  ui_line "$S_ACCENT" "  user      $username (wheel, sudo)"
  ui_line "$S_ACCENT" "  root      locked"
  ui_line "$S_ACCENT" "  disk      $DISK"
  ui_line "$S_ACCENT" "  ssh       enabled on first boot"
  ui_blank
  ui_body "Remove the install medium before the machine comes back up."
  ui_blank
  ui_hint "enter reboot"
  read -r _ 2>/dev/null || true
  systemctl reboot
}

# --- main ------------------------------------------------------------------

main() {
  preflight

  : >"$UI_LOG"
  ui_init "$LOGO_FILE"
  trap ui_cleanup EXIT

  net_setup
  ask_username
  ask_password

  disk_setup
  do_install "$USERNAME" "$PASSWORD"
  finish_screen "$USERNAME"
}

main "$@"

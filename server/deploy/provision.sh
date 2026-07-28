#!/usr/bin/env bash
#
# provision.sh — placeholder. Proves the install chain reaches this file.
#
# The installer runs this at the very end of an install, under `arch-chroot`,
# as root, on the freshly installed system. Today it installs nothing; it just
# leaves proof that it ran. Replace the body with the real server setup
# (Postgres, PHP, nginx) when that exists — the ISO does not need rebuilding
# for that, which is the whole point of this hook.
#
# Two rules for whatever replaces this:
#
#   1. There is no running init inside arch-chroot. `systemctl enable` works,
#      `systemctl start` does not. Anything needing a live service has to defer
#      to a first-boot one-shot unit.
#   2. It must be safe to run again. A reinstall runs it from scratch, but a
#      half-finished run should not wedge the next one.

set -euo pipefail

# Empty in real use. Tests point it at a temp directory so this script can be
# run without writing to the machine it is running on.
: "${PROVISION_ROOT:=}"

readonly MARKER='manuserver provisioning begins here'
readonly LOG="$PROVISION_ROOT/var/log/manuserver-provision.log"
readonly MOTD="$PROVISION_ROOT/etc/motd"
readonly GREETING="$PROVISION_ROOT/etc/profile.d/manuserver-provision.sh"

# Goes to the installer's log on the live system, visible on the failure screen
# if anything below breaks.
printf '=== %s ===\n' "$MARKER"

install -d "$(dirname "$LOG")" "$(dirname "$MOTD")" "$(dirname "$GREETING")"

{
  printf '%s\n' "$MARKER"
  printf 'when:  %s\n' "$(date -Iseconds)"
  printf 'host:  %s\n' "$(cat "$PROVISION_ROOT/etc/hostname" 2>/dev/null || echo unknown)"
  printf 'user:  %s\n' "$(id -un)"
  printf 'where: %s\n' "$0"
} >"$LOG"

# The installed system autologins on tty1, so the motd is the first thing on
# screen after boot. That makes "did provisioning run?" answerable at a glance,
# without logging in or reading a file.
cat >"$MOTD" <<EOF

  $MARKER

  Nothing is installed on this server yet. This message means the installer
  cloned the repo and ran server/deploy/provision.sh successfully.

  Details: /var/log/manuserver-provision.log
  Replace: server/deploy/provision.sh in the manuserver repo

EOF

# Belt and braces. Whether /etc/motd is displayed at all depends on PAM being
# configured for it, and this message is the only thing that says the install
# chain worked -- it should not hinge on that. A profile.d snippet prints on
# every login shell regardless, which on this machine means the autologin
# console shows it the moment the system boots.
cat >"$GREETING" <<EOF
# shellcheck shell=sh
# Placeholder from server/deploy/provision.sh. Delete this when the real
# server setup replaces it.
printf '\n  %s\n\n' '$MARKER'
EOF
chmod 644 "$GREETING"

printf 'wrote %s, %s and %s\n' "$LOG" "$MOTD" "$GREETING"

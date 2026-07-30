# shellcheck shell=bash
#
# common.sh — what every verb needs: where things live, and how to complain.
#
# Sourced by manuserver.sh, which has already worked out ROOT and SELF_PATH.

# How to refer to this command in messages: `manuserver` once it is on PATH,
# ./manuserver.sh when run out of the checkout.
SELF="${0##*/}"
[[ $SELF == manuserver ]] || SELF="./$SELF"
readonly SELF

readonly LIB="$ROOT/files/lib"

# Two places this runs from: the checkout, and the copy install_command leaves
# in the data directory. The copy takes files/lib and nothing else, so the
# absence of files/iso is what tells it which one it is.
if [[ -d $ROOT/files/iso ]]; then
  IN_REPO=1
else
  IN_REPO=0
fi
readonly IN_REPO

# --- where things live ------------------------------------------------------

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
# the opposite, since the entire point of one is dragging it onto a USB stick.
#
# xdg-user-dir answers "$HOME" when the machine has no user-dirs configuration,
# which would drop .sql files loose in the home directory. Hence the guard.
BACKUPS="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
[[ -n $BACKUPS && $BACKUPS != "$HOME" ]] || BACKUPS="$HOME/Downloads"
readonly BACKUPS

# The finished ISO lands in the repo root, next to manuserver.sh — the one
# place you are already looking, and an easy drag onto a USB stick. The build's
# scratch space stays out of sight in files/iso/build.
readonly ISO_OUT="$ROOT"
readonly ISO_DIR="$ROOT/files/iso"

readonly SITE_SRC="$ROOT/files/site"
readonly DEPLOY_SRC="$ROOT/files/deploy"

readonly DISK="$VM/manuserver.qcow2"
readonly NVRAM="$VM/OVMF_VARS.fd"
readonly PIDFILE="$VM/qemu.pid"
readonly MONITOR="$VM/monitor.sock"
readonly DISK_SIZE=20G

readonly SSH_PORT=2222
readonly HTTP_PORT=8080

# The key `manuserver ssh` offers, and the only one it offers — see ssh_opts.
# Its own key, not a reused one: this server is not GitHub and should not be
# reachable by the thing that is. Missing is fine; ssh asks for a password
# instead. Override to use a key you already have.
readonly SSH_KEY="${MANUSERVER_SSH_KEY:-$HOME/.ssh/id_ed25519_manuserver}"

# What the forwarded ports listen on.
#
# QEMU's hostfwd takes the host address before the port, and leaving it empty
# binds to 0.0.0.0. That put the VM's sshd in front of the whole local network:
# any device on the wifi could reach it and guess passwords at it, unrated and
# unlogged. Nobody asked for that, and ssh here is always from this machine.
readonly SSH_BIND=127.0.0.1

# The site is the one thing you might genuinely want to open on your phone, so
# this is a knob rather than a constant. It still defaults to closed:
#
#   MANUSERVER_HTTP_BIND=0.0.0.0 manuserver
#
# The public route is the Cloudflare tunnel, which needs none of this.
readonly HTTP_BIND="${MANUSERVER_HTTP_BIND:-127.0.0.1}"

# --- talking to the user ----------------------------------------------------

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

# Building an ISO and running the site need sources that the installed copy
# does not carry. Refuse with the way out rather than a missing-file error.
needs_checkout() {
  ((IN_REPO)) && return 0

  die "\`$1\` needs the manuserver checkout, and this copy is not part of one.
     git clone https://github.com/manujarvinen/manuserver.git
     cd manuserver && ./manuserver.sh $1"
}

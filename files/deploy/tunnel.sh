#!/usr/bin/env bash
#
# tunnel.sh — put this server on the public internet, or take it off again.
#
# Installed by provision.sh as /usr/local/bin/manuserver-tunnel, as a symlink
# back into the repo, so `git pull` updates the command.
#
#   sudo manuserver-tunnel          ask for a token and turn the tunnel on
#   sudo manuserver-tunnel status   is it up, and what is it serving
#   sudo manuserver-tunnel off      take it off the internet, forget the token
#
# Why a tunnel at all: the normal way to publish a home server is forwarding a
# port on the router, which needs access to the router and a stable address.
# A tunnel needs neither. The server makes an outgoing connection to
# Cloudflare, and public visitors are passed back down it. Nothing has to be
# opened on your side, and nothing on this machine listens to the internet.
#
# The token is the whole configuration. It names one tunnel on Cloudflare's
# side, and which hostname reaches which local port is decided there, in the
# dashboard — not here. That is why this script asks for one thing and nothing
# else.

set -euo pipefail

readonly CONF_DIR=/etc/manuserver
readonly ENV_FILE="$CONF_DIR/tunnel.env"
readonly SERVICE=manuserver-tunnel.service

say()  { printf 'manuserver-tunnel: %s\n' "$*"; }
die()  { printf 'manuserver-tunnel: %s\n' "$*" >&2; exit 1; }

need_root() {
  ((EUID == 0)) || die "run this with sudo"
}

# --- status -----------------------------------------------------------------

cmd_status() {
  if [[ ! -f $ENV_FILE ]]; then
    say "off — no token set. turn it on with: sudo manuserver-tunnel"
    return
  fi

  if systemctl is-active --quiet "$SERVICE"; then
    say "up"
  else
    say "a token is set but the tunnel is not running"
  fi

  printf '\n'
  systemctl status --no-pager --lines=8 "$SERVICE" || true
  printf '\nthe public address is whatever hostname you attached to this tunnel\n'
  printf 'in the cloudflare dashboard, under Networks -> Tunnels & Mesh -> your tunnel.\n'
  printf 'a connected tunnel with no route has no address at all.\n'
}

# --- off ---------------------------------------------------------------------

cmd_off() {
  need_root

  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"

  say "off — the token is deleted and the tunnel is stopped"
  say "the site is still running locally; only the public route is gone"
}

# --- on ----------------------------------------------------------------------

# People paste the whole install command from Cloudflare's screen, because
# that is what the screen offers. Take the token out of it rather than
# rejecting it.
#
# Cloudflare shows it in two shapes depending on which panel you copy from:
#
#   cloudflared service install eyJhIjoi...
#   cloudflared tunnel --no-autoupdate run --token eyJhIjoi...
#
# In both, the token is the last thing on the line. Cutting at the marker has
# to happen before any whitespace is touched, because the spaces are the only
# thing separating the command from its argument.
extract_token() {
  local input=$1

  if [[ $input == *--token* ]]; then
    input=${input##*--token}
  elif [[ $input == *"service install"* ]]; then
    input=${input##*service install}
  fi

  # Now that nothing but the token is left, collapse every space, tab and
  # newline in it. A token copied out of an email or a note is often wrapped
  # across lines, and rejoining it is the whole point of doing this.
  printf '%s' "${input//[$'\t\r\n ']/}"
}

cmd_on() {
  need_root

  command -v cloudflared >/dev/null ||
    die "cloudflared is not installed — run files/deploy/provision.sh first"

  [[ -f /etc/systemd/system/$SERVICE ]] ||
    die "$SERVICE is missing — run files/deploy/provision.sh first"

  cat <<'INTRO'

  Paste the tunnel token from Cloudflare.

  Networks -> Tunnels & Mesh -> your tunnel. It shows an install command with
  a long string starting "eyJhIjoi" in it. That is the token; pasting the whole
  command is fine too.

  Afterwards, give the tunnel an address: Networks -> Tunnels & Mesh -> your
  tunnel -> Published application routes. Service type HTTP, URL localhost:80.
  Not Networks -> Routes in the menu, which is a different thing for private
  networks. Without a route the tunnel connects and serves nothing.

  Nothing is shown as you paste. Press enter when done.

INTRO

  local raw token
  # -s so a token does not end up on screen, in a scrollback buffer, or in a
  # screenshot. It never reaches the command line either, so it stays out of
  # shell history and out of `ps`.
  #
  # `|| true`: read still fills raw correctly when input ends without a
  # trailing newline, but returns non-zero anyway because that counts as EOF
  # mid-read. A token file someone typed by hand often has no final newline,
  # and set -e turns that into this script exiting right here with no output
  # at all -- which looks exactly like the command silently doing nothing.
  read -rsp '  token: ' raw || true
  printf '\n\n'

  token=$(extract_token "$raw")

  [[ -n $token ]] || die "nothing pasted"

  # Cloudflare tokens are base64. This catches a truncated paste, which is the
  # common failure and otherwise shows up much later as a tunnel that will not
  # authenticate.
  [[ $token =~ ^[A-Za-z0-9_=-]{40,}$ ]] ||
    die "that does not look like a tunnel token — expected a long base64 string"

  # Best-effort sanity check. A real token is base64 of a JSON object, so it
  # always begins "eyJ" and always decodes to something with a "t" field in
  # it. Warnings rather than refusals: a change to Cloudflare's format should
  # not be able to lock you out of your own server.
  if [[ $token != eyJ* ]] || ! base64 -d <<<"$token" 2>/dev/null | grep -q '"t"'; then
    say "warning: that does not decode like a tunnel token usually does."
    say "         continuing anyway — if the tunnel fails to start, this is why."
  fi

  install -d -m 755 "$CONF_DIR"

  # 600 root, and written with a umask so it is never briefly readable.
  ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" >"$ENV_FILE" )
  chmod 600 "$ENV_FILE"

  systemctl daemon-reload
  systemctl enable --now "$SERVICE"

  printf '\n'
  say "tunnel started"

  # It takes a few seconds to register with Cloudflare, and reporting success
  # before that is how you get told everything is fine when it is not.
  sleep 5

  if systemctl is-active --quiet "$SERVICE"; then
    say "up — visitors reach this server at the hostname you set in the dashboard"
    printf '\n  check on it with:  sudo manuserver-tunnel status\n'
    printf '  take it down with: sudo manuserver-tunnel off\n\n'
  else
    printf '\n'
    say "it did not stay up. the log usually says why:"
    printf '\n'
    journalctl -u "$SERVICE" --no-pager --lines=15 || true
    exit 1
  fi
}

case "${1:-on}" in
  on|'')      cmd_on ;;
  status)     cmd_status ;;
  off|stop)   cmd_off ;;
  -h|--help)  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0" ;;
  *)          die "unknown command: $1 (try: on, status, off)" ;;
esac

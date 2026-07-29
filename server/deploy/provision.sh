#!/usr/bin/env bash
#
# provision.sh — turns the bare Arch system the ISO just installed into the
# server that runs Tastehopping.
#
# The installer runs this at the very end of an install, under `arch-chroot`,
# as root, on the freshly installed system. It is the reason the ISO can stop
# changing: everything below iterates with a push and a reinstall.
#
# Two rules, both of which shape what is here:
#
#   1. There is no running init inside arch-chroot. `systemctl enable` works,
#      `systemctl start` does not. Anything needing a live service defers to
#      manuserver-db.service, the one-shot below.
#   2. It must be safe to run again. Every write here is an overwrite or a
#      create-if-missing, and nothing is generated twice.
#
# There are no passwords anywhere in this file, and none on the machine it
# builds. The site reaches Postgres over a unix socket, authenticated by which
# OS user opened it — see the pg_ident map in db-setup.sh. A credential that
# does not exist cannot be leaked, committed, or left in a backup.

set -euo pipefail

# Empty in real use. Point it at a directory to render every config file
# somewhere harmless and skip pacman, initdb and systemctl — enough to read
# what an install would produce without installing anything.
: "${PROVISION_ROOT:=}"

# cloudflared is in `extra`, not the AUR, so publishing this server to the
# internet needs no build tools and no AUR helper on a machine that has
# neither. It is installed here but does nothing until someone runs
# `manuserver-tunnel` and gives it a token.
readonly PACKAGES=(nginx php php-fpm php-pgsql postgresql cloudflared)

readonly SITE_DIR=/srv/manuserver
readonly DOC_ROOT="$SITE_DIR/public_html"
readonly PGDATA=/var/lib/postgres/data
readonly SESSION_DIR=/var/lib/php/sessions
readonly LOG="$PROVISION_ROOT/var/log/manuserver-provision.log"

# In test mode, describe the step instead of taking it.
if [[ -n $PROVISION_ROOT ]]; then
  run() { printf '  would run: %s\n' "$*"; }
else
  run() { "$@"; }
fi

step() { printf '=== %s ===\n' "$*"; }

write() {
  local path="$PROVISION_ROOT$1"
  install -d "$(dirname "$path")"
  cat >"$path"
  printf '  wrote %s\n' "$1"
}

# --- packages --------------------------------------------------------------

step 'installing nginx, php and postgres'

# --needed makes a second run a no-op rather than a reinstall.
#
# -Syu, not -Sy. During an install the difference is nothing — pacstrap pulled
# these mirrors minutes ago, so there is nothing to upgrade. But this script is
# also the way the server is provisioned by hand months later, and there `-Sy`
# is the classic Arch partial-upgrade footgun: a fresh package index against
# stale installed packages, linked against libraries that are no longer there.
run pacman -Syu --needed --noconfirm "${PACKAGES[@]}"

# --- php -------------------------------------------------------------------
#
# Arch ships the postgres driver as a shared object that nothing loads until
# it is asked for. A drop-in in conf.d rather than an edit to php.ini, so a
# package upgrade replacing php.ini cannot quietly undo it.

step 'configuring php'

write /etc/php/conf.d/manuserver.ini <<'INI'
; Written by server/deploy/provision.sh. Edits here are lost on reprovision.

; The only reason php-pgsql is installed.
extension=pdo_pgsql

; Nothing good comes of announcing the version in every response header.
expose_php = Off

; Errors go to the journal, never to the browser. A stack trace on a public
; page is a map of the filesystem.
display_errors = Off
display_startup_errors = Off
log_errors = On

; Sessions outlive a php-fpm restart here, which matters more than usual: the
; only alternative to a live session is digging out the account key again.
session.save_path = "/var/lib/php/sessions"
session.gc_maxlifetime = 31536000
session.cookie_lifetime = 31536000
session.use_strict_mode = 1

; A form post carries a link and a title. Anything larger is not one of ours.
post_max_size = 256K
upload_max_filesize = 0
file_uploads = Off
INI

run install -d -o http -g http -m 700 "$SESSION_DIR"

# --- nginx -----------------------------------------------------------------

step 'configuring nginx'

write /etc/nginx/nginx.conf <<NGINX
# Written by server/deploy/provision.sh. Edits here are lost on reprovision.

user http;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    keepalive_timeout 65;
    client_max_body_size 256k;

    # Deliberately off. This server exists to hold things people saved without
    # saying who they are, and an access log is a list of who visited, from
    # where, and when — the exact record the site promises not to keep. Turn
    # it on while debugging if you need it, and turn it back off.
    access_log off;
    error_log  /var/log/nginx/error.log warn;

    server_tokens off;

    server {
        listen      80 default_server;
        listen [::]:80 default_server;
        server_name _;

        root  $DOC_ROOT;
        index index.php;

        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;
        add_header Referrer-Policy no-referrer always;

        # Every address that is not a file on disk is the front controller's
        # problem. This one line is the entire router.
        location / {
            try_files \$uri /index.php\$is_args\$args;
        }

        location ~ \.php\$ {
            # index.php is the only program in the document root. Anything
            # else ending in .php that ever lands there is a mistake or an
            # attack, and either way it is a 404 rather than something run.
            try_files \$uri =404;

            include      fastcgi.conf;
            fastcgi_pass unix:/run/php-fpm/php-fpm.sock;
            fastcgi_read_timeout 30s;
        }

        location = /favicon.ico {
            log_not_found off;
        }

        # Dotfiles, including anything a stray .git would put here.
        location ~ /\. {
            deny all;
        }
    }
}
NGINX

# --- postgres --------------------------------------------------------------
#
# initdb only writes files, so it is one of the few real actions that works
# inside a chroot with no init. Doing it here rather than at first boot means
# postgresql.service comes up cleanly the very first time instead of failing
# once and being repaired afterwards.
#
# C.UTF-8 rather than the system locale: it is built into glibc and needs no
# locale-gen to have run first, which removes an ordering dependency on the
# rest of the install.

step 'creating the postgres cluster'

if [[ -n $PROVISION_ROOT ]]; then
  printf '  would run: initdb --pgdata=%s\n' "$PGDATA"
elif [[ -f $PGDATA/PG_VERSION ]]; then
  printf '  cluster already exists at %s\n' "$PGDATA"
else
  install -d -o postgres -g postgres -m 700 "$PGDATA"
  su postgres -c "initdb --pgdata='$PGDATA' --encoding=UTF8 --locale=C.UTF-8 \
    --auth-local=peer --auth-host=scram-sha-256" >/dev/null
  printf '  created %s\n' "$PGDATA"
fi

# --- the first-boot one-shot ------------------------------------------------
#
# Creating a role, creating a database and applying a schema all need a
# running Postgres, which does not exist in here. This unit does that work on
# every boot instead. It is ordered after postgresql.service, it is idempotent,
# and it lives in the repo — so fixing it later is a push, a `git pull` on the
# server and `systemctl start manuserver-db`, with no reinstall.

step 'installing the database setup unit'

write /etc/systemd/system/manuserver-db.service <<UNIT
[Unit]
Description=manuserver database setup
Documentation=file://$SITE_DIR/server/deploy/db-setup.sh
Wants=postgresql.service
After=postgresql.service
ConditionPathExists=$SITE_DIR/server/deploy/db-setup.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SITE_DIR/server/deploy/db-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

# --- ssh ---------------------------------------------------------------------
#
# The ISO enables sshd with Arch's defaults, which on a real home server means
# password authentication facing the whole local network with no rate limit.
# In a VM the forwards are bound to 127.0.0.1 so this matters less, but the
# same repo provisions both.
#
# Passwords stay on, deliberately. Turning them off here would lock you out of
# a machine that has no key on it yet — the last line of the file below is how
# you switch, once you have one.

step 'hardening ssh'

write /etc/ssh/sshd_config.d/10-manuserver.conf <<'SSHD'
# Written by server/deploy/provision.sh. Edits here are lost on reprovision.

# Six guesses per connection is the default. Reconnecting is free either way,
# so this is not a rate limit — it just makes each attempt cost more setup.
MaxAuthTries 3

# An unauthenticated connection has 2 minutes by default to become an
# authenticated one. It does not need that long.
LoginGraceTime 20

# Root is already locked by the installer. This is the second lock.
PermitRootLogin no

# Nothing here has a display, and nothing needs a tunnel through this host.
X11Forwarding no
AllowAgentForwarding no

# Once you have copied a key over — ssh-copy-id yourname@the-server — password
# logins can go away entirely:
#
#   echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/20-no-passwords.conf
#   sudo systemctl restart sshd
#
# Do it in that order, and keep this session open until a new one works.
SSHD

# --- the public tunnel -------------------------------------------------------
#
# Installed ready and switched off. The unit below is enabled unconditionally,
# but ConditionPathExists means it does nothing at all until a token file
# exists — so provisioning never puts this machine on the internet by
# accident, and turning it on later is one command with no reprovisioning.
#
# The token is read from the environment rather than passed as an argument.
# cloudflared takes TUNNEL_TOKEN from the environment for exactly this reason:
# an argument would sit in `ps` output for every user on the machine to read.

step 'installing the tunnel'

write /etc/systemd/system/manuserver-tunnel.service <<'UNIT'
[Unit]
Description=manuserver public tunnel (cloudflare)
Documentation=man:cloudflared(1)
After=network-online.target nginx.service
Wants=network-online.target

# No token, no tunnel. This is what makes "enabled" safe.
ConditionPathExists=/etc/manuserver/tunnel.env

[Service]
Type=simple
EnvironmentFile=/etc/manuserver/tunnel.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

# cloudflared wants somewhere to put its cache. StateDirectory gives it one
# that survives ProtectSystem=strict.
StateDirectory=cloudflared
Environment=HOME=/var/lib/cloudflared

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
UNIT

# A symlink rather than a copy, so `git pull` updates the command along with
# everything else.
run ln -sfn "$SITE_DIR/server/deploy/tunnel.sh" /usr/local/bin/manuserver-tunnel

# --- services ---------------------------------------------------------------

step 'enabling services'

run systemctl enable nginx.service php-fpm.service postgresql.service \
  manuserver-db.service manuserver-tunnel.service

# --- the console message ----------------------------------------------------
#
# The installed system autologins on tty1, so this is the first thing on
# screen after boot. It is how "did this work?" gets answered at a glance.

step 'writing the console message'

# Both of these are what the placeholder left behind. A static file cannot say
# what this machine's address is or whether the tunnel is up, and those are the
# two things worth knowing at a glance.
rm -f "$PROVISION_ROOT/etc/profile.d/manuserver-provision.sh" "$PROVISION_ROOT/etc/motd"

# On a home server with no keyboard attached this is the screen you walk over
# and read: it tells you where the machine is on the network, which is what
# you need in order to ssh in and set the tunnel up from a machine that can
# paste.
write /etc/profile.d/manuserver.sh <<'SH'
# shellcheck shell=sh
# Written by server/deploy/provision.sh. Edits here are lost on reprovision.
#
# Printed by every login shell, which on this machine means the autologin
# console shows it the moment the system finishes booting.

printf '\n  manuserver — tastehopping\n\n'

_ms_address=$(ip -4 -brief address show scope global 2>/dev/null |
  awk '{ print $3 }' | cut -d/ -f1 | head -n 1)

[ -n "$_ms_address" ] && printf '  on this network:   http://%s/\n' "$_ms_address"
printf '  from the vm host:  http://localhost:8080/\n'

if [ -f /etc/manuserver/tunnel.env ]; then
  if systemctl is-active --quiet manuserver-tunnel.service 2>/dev/null; then
    printf '  on the internet:   up\n'
  else
    printf '  on the internet:   token set, but the tunnel is not running\n'
  fi
else
  printf '  on the internet:   off — turn it on with: sudo manuserver-tunnel\n'
fi

printf '\n  systemctl status nginx php-fpm postgresql manuserver-db\n\n'

unset _ms_address
SH

chmod 644 "$PROVISION_ROOT/etc/profile.d/manuserver.sh"

install -d "$(dirname "$LOG")"
{
  printf 'manuserver provisioning\n'
  printf 'when:     %s\n' "$(date -Iseconds)"
  printf 'host:     %s\n' "$(cat "$PROVISION_ROOT/etc/hostname" 2>/dev/null || echo unknown)"
  printf 'packages: %s\n' "${PACKAGES[*]}"
  printf 'docroot:  %s\n' "$DOC_ROOT"
  printf 'cluster:  %s\n' "$PGDATA"
} >"$LOG"

step 'done — the database is set up on first boot by manuserver-db.service'

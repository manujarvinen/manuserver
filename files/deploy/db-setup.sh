#!/usr/bin/env bash
#
# db-setup.sh — run at every boot by manuserver-db.service.
#
# provision.sh cannot do any of this: creating a role, creating a database and
# applying a schema all need a Postgres that is actually running, and there is
# no init inside arch-chroot. So this is the other half of provisioning, and
# the half that can be fixed without reinstalling — it lives in the repo, so
# `git pull && systemctl restart manuserver-db` is the whole edit loop.
#
# It runs on every boot rather than once, because everything it does is
# idempotent and because that makes it a repair as well as a setup: delete the
# database by accident and the next boot builds it again, empty.

set -euo pipefail

readonly SITE_DIR=/srv/manuserver
readonly SCHEMA="$SITE_DIR/files/site/db/schema.sql"
readonly PGDATA=/var/lib/postgres/data
readonly DB_NAME=tastehopping
readonly DB_ROLE=tastehopping

say() { printf 'manuserver-db: %s\n' "$*"; }
die() { printf 'manuserver-db: %s\n' "$*" >&2; exit 1; }

# psql as the cluster superuser. SQL arrives on stdin so that nothing has to
# survive a trip through two layers of shell quoting.
as_postgres() {
  su postgres -s /bin/bash -c "$*"
}

superuser_sql() {
  as_postgres 'psql --no-psqlrc --quiet --no-align --tuples-only --file=-'
}

# --- 1. the cluster ---------------------------------------------------------
#
# provision.sh normally created this during the install. Doing it again here
# is the recovery path for a cluster that was never created or was wiped.

if [[ ! -f $PGDATA/PG_VERSION ]]; then
  say "no cluster at $PGDATA — creating one"
  install -d -o postgres -g postgres -m 700 "$PGDATA"
  as_postgres "initdb --pgdata='$PGDATA' --encoding=UTF8 --locale=C.UTF-8 \
    --auth-local=peer --auth-host=scram-sha-256" >/dev/null
fi

# --- 2. who may connect as what ---------------------------------------------
#
# This is where the site's database credentials would be, if it had any.
#
# php-fpm runs as the OS user `http`. The ident map below says that `http`
# connecting over the local socket *is* the `tastehopping` role — no password
# is sent, because none exists to send. There is nothing in the document root,
# in the repo, or in any backup that would let someone else connect.
#
# Both files are rewritten every boot, so an edit made by hand is temporary by
# design. Change them here.

cat >"$PGDATA/pg_hba.conf" <<'HBA'
# Written by files/deploy/db-setup.sh on every boot. Edits are lost.
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# The superuser, for backups and maintenance.
local   all             postgres                                peer

# The site. `http` (php-fpm) and `root` (this script) map to the app role.
local   tastehopping    tastehopping                            peer map=manuserver

# Everyone else is themselves or nobody.
local   all             all                                     peer

# Postgres listens on localhost only, and no role has a password, so these two
# lines authenticate nobody. They are here so that adding a password to a role
# is all it takes to open a TCP path deliberately.
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
HBA

cat >"$PGDATA/pg_ident.conf" <<'IDENT'
# Written by files/deploy/db-setup.sh on every boot. Edits are lost.
#
# MAPNAME     SYSTEM-USERNAME   PG-USERNAME
manuserver    http              tastehopping
manuserver    root              tastehopping
IDENT

chown postgres:postgres "$PGDATA/pg_hba.conf" "$PGDATA/pg_ident.conf"
chmod 600 "$PGDATA/pg_hba.conf" "$PGDATA/pg_ident.conf"

# --- 3. a running server ----------------------------------------------------

if systemctl is-active --quiet postgresql.service; then
  systemctl reload postgresql.service
else
  # First boot after a repair above, or postgresql failed for its own reasons.
  systemctl start postgresql.service
fi

for _ in $(seq 30); do
  as_postgres 'pg_isready --quiet' && break
  sleep 1
done

as_postgres 'pg_isready --quiet' || die "postgres did not come up — journalctl -u postgresql"

# --- 4. the role and the database -------------------------------------------

if [[ $(printf "SELECT 1 FROM pg_roles WHERE rolname = '%s'\n" "$DB_ROLE" | superuser_sql) != 1 ]]; then
  say "creating the $DB_ROLE role"
  # No password and no ability to make more roles or databases. Everything it
  # needs, it gets by owning the one database below.
  printf "CREATE ROLE %s WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE\n" "$DB_ROLE" | superuser_sql
fi

if [[ $(printf "SELECT 1 FROM pg_database WHERE datname = '%s'\n" "$DB_NAME" | superuser_sql) != 1 ]]; then
  say "creating the $DB_NAME database"
  as_postgres "createdb --owner='$DB_ROLE' '$DB_NAME'"
fi

# --- 5. the schema -----------------------------------------------------------
#
# Applied as the app role, not as the superuser, so every table ends up owned
# by the role that has to use it. schema.sql is written to be safe to reapply,
# which is what makes "run this every boot" a reasonable thing to do.

[[ -f $SCHEMA ]] || die "no schema at $SCHEMA"

psql --username="$DB_ROLE" --dbname="$DB_NAME" \
     --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --file="$SCHEMA" >/dev/null

say "$DB_NAME is ready"

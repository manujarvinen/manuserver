#!/usr/bin/env bash
#
# run-local.sh — the whole site on this machine, without the VM.
#
#   ./run-local.sh          start Postgres and the site on http://localhost:8000
#   ./run-local.sh seed     fill an empty database with something to look at
#   ./run-local.sh reset    throw the database away and start it again empty
#   ./run-local.sh stop     stop the database (the site stops with Ctrl-C)
#
# The cluster it creates lives in server/dev/.cluster and belongs to whoever
# runs this. It listens on a unix socket inside that directory and on no TCP
# port at all, so it cannot collide with a Postgres the machine already runs,
# and nothing outside this checkout can reach it.
#
# This is a development convenience. What runs on the actual server is set up
# by server/deploy/provision.sh, which shares only the schema file with this.

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO="$(cd "$HERE/../.." && pwd)"
readonly CLUSTER="$HERE/.cluster"
readonly SOCKET="$CLUSTER/socket"
readonly PGLOG="$CLUSTER/postgres.log"
readonly SCHEMA="$REPO/server/db/schema.sql"
readonly DB_NAME=tastehopping

PORT="${PORT:-8000}"

say() { printf '\033[1;35m::\033[0m %s\n' "$*"; }
die() { printf 'run-local.sh: %s\n' "$*" >&2; exit 1; }

# Extra flags PHP needs to reach Postgres, worked out by check_tools.
PHP_FLAGS=()

check_tools() {
  command -v initdb  >/dev/null || die "postgres is missing — sudo pacman -S postgresql"
  command -v php     >/dev/null || die "php is missing — sudo pacman -S php"

  if php -m | grep -qx pdo_pgsql; then
    return
  fi

  # Arch ships php-pgsql as a shared object but leaves the extension line
  # commented out in php.ini, and uncommenting it needs root. Loading it for
  # this one process gets the same result without asking for a password and
  # without changing how PHP behaves for anything else on the machine.
  #
  # On the server there is no such dance: provision.sh writes a conf.d
  # drop-in, because php-fpm is not invoked from a script we control.
  local module_dir
  module_dir=$(php -r 'echo ini_get("extension_dir");')

  [[ -f "$module_dir/pdo_pgsql.so" ]] ||
    die "php cannot talk to postgres — sudo pacman -S php-pgsql"

  PHP_FLAGS=(-d extension=pdo_pgsql)

  php "${PHP_FLAGS[@]}" -m | grep -qx pdo_pgsql ||
    die "$module_dir/pdo_pgsql.so is there but will not load — try: php -d extension=pdo_pgsql -m"
}

# initdb makes the invoking user the cluster superuser, and the default local
# authentication is trust. Both are fine for a socket nobody else can see, and
# both are why this needs no password anywhere.
ensure_cluster() {
  [[ -f $CLUSTER/data/PG_VERSION ]] && return

  say "creating a postgres cluster in $CLUSTER"
  mkdir -p "$CLUSTER" "$SOCKET"
  initdb --pgdata="$CLUSTER/data" --encoding=UTF8 --locale=C.UTF-8 >/dev/null
}

db_running() {
  pg_ctl --pgdata="$CLUSTER/data" status >/dev/null 2>&1
}

start_db() {
  db_running && return

  say "starting postgres"
  # -h '' turns off TCP entirely; -k puts the socket where only we look.
  pg_ctl --pgdata="$CLUSTER/data" --log="$PGLOG" \
    --options="-k '$SOCKET' -h ''" --wait start >/dev/null ||
    die "postgres would not start — see $PGLOG"
}

stop_db() {
  db_running || return 0
  say "stopping postgres"
  pg_ctl --pgdata="$CLUSTER/data" --mode=fast --wait stop >/dev/null
}

psql_db() {
  psql --host="$SOCKET" --dbname="$DB_NAME" --quiet --no-psqlrc "$@"
}

ensure_database() {
  if ! psql --host="$SOCKET" --dbname=postgres --tuples-only --no-align \
       --command="SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    say "creating the $DB_NAME database"
    createdb --host="$SOCKET" "$DB_NAME"
  fi

  # The schema is written to be safe to reapply, so this runs every time and
  # picks up any change since the last run.
  psql_db --set=ON_ERROR_STOP=1 --file="$SCHEMA" >/dev/null
}

# Exported for both the site and seed.php. An empty password is correct here:
# trust authentication on a private socket has nothing to check.
export_env() {
  export DB_HOST="$SOCKET"
  export DB_USER="$(id --user --name)"
  export DB_PASSWORD=""

  # No assignment: DB_NAME is already a readonly constant above, and
  # re-assigning one is an error even when the value is identical. This just
  # marks it for export.
  export DB_NAME
}

cmd_serve() {
  check_tools
  ensure_cluster
  start_db
  ensure_database
  export_env

  trap stop_db EXIT

  say "http://localhost:$PORT"
  say "database: $DB_NAME on $SOCKET"
  printf '\n'

  # -t sets the document root to exactly what nginx serves; router.php is the
  # stand-in for nginx's try_files, and does nothing else.
  php "${PHP_FLAGS[@]}" -S "localhost:$PORT" -t "$REPO/public_html" "$HERE/router.php"
}

cmd_seed() {
  check_tools
  ensure_cluster
  start_db
  ensure_database
  export_env

  php "${PHP_FLAGS[@]}" "$HERE/seed.php"
}

cmd_reset() {
  check_tools
  ensure_cluster
  start_db

  read -rp "throw away the local $DB_NAME database? [y/N] " answer
  [[ ${answer,,} == y ]] || die "left alone"

  dropdb --host="$SOCKET" --if-exists "$DB_NAME"
  ensure_database
  say "empty again"
}

case "${1:-serve}" in
  serve) cmd_serve ;;
  seed)  cmd_seed ;;
  reset) cmd_reset ;;
  stop)  stop_db ;;
  *)     die "unknown command: $1 (try: serve, seed, reset, stop)" ;;
esac

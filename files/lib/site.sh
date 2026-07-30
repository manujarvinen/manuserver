# shellcheck shell=bash
#
# site.sh — the whole website on this machine, without the VM.
#
# The cluster it creates lives in files/dev/.cluster and belongs to whoever
# runs it. It listens on a unix socket inside that directory and on no TCP port
# at all, so it cannot collide with a Postgres the machine already runs, and
# nothing outside this checkout can reach it.
#
# This is a development convenience. What runs on the actual server is set up
# by files/deploy/provision.sh, which shares only the schema file with this.
#
# Sourced by manuserver.sh. Defines functions and runs nothing.

readonly DEV_DIR="$ROOT/files/dev"
readonly CLUSTER="$DEV_DIR/.cluster"
readonly SOCKET="$CLUSTER/socket"
readonly PGLOG="$CLUSTER/postgres.log"
readonly SCHEMA="$SITE_SRC/db/schema.sql"
readonly DEV_DB=tastehopping

# Extra flags PHP needs to reach Postgres, worked out by site_check_tools.
PHP_FLAGS=()

site_check_tools() {
  command -v initdb >/dev/null || die "postgres is missing — sudo pacman -S postgresql"
  command -v php    >/dev/null || die "php is missing — sudo pacman -S php"

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
site_ensure_cluster() {
  [[ -f $CLUSTER/data/PG_VERSION ]] && return

  say "creating a postgres cluster in $CLUSTER"
  mkdir -p "$CLUSTER" "$SOCKET"
  initdb --pgdata="$CLUSTER/data" --encoding=UTF8 --locale=C.UTF-8 >/dev/null
}

site_db_running() {
  pg_ctl --pgdata="$CLUSTER/data" status >/dev/null 2>&1
}

site_start_db() {
  site_db_running && return

  say "starting postgres"
  # -h '' turns off TCP entirely; -k puts the socket where only we look.
  pg_ctl --pgdata="$CLUSTER/data" --log="$PGLOG" \
    --options="-k '$SOCKET' -h ''" --wait start >/dev/null ||
    die "postgres would not start — see $PGLOG"
}

site_stop_db() {
  site_db_running || return 0
  say "stopping postgres"
  pg_ctl --pgdata="$CLUSTER/data" --mode=fast --wait stop >/dev/null
}

site_ensure_database() {
  if ! psql --host="$SOCKET" --dbname=postgres --tuples-only --no-align \
       --command="SELECT 1 FROM pg_database WHERE datname = '$DEV_DB'" | grep -q 1; then
    say "creating the $DEV_DB database"
    createdb --host="$SOCKET" "$DEV_DB"
  fi

  # The schema is written to be safe to reapply, so this runs every time and
  # picks up any change since the last run.
  psql --host="$SOCKET" --dbname="$DEV_DB" --quiet --no-psqlrc \
    --set=ON_ERROR_STOP=1 --file="$SCHEMA" >/dev/null
}

# Used by both the site and seed.php. An empty password is correct here: trust
# authentication on a private socket has nothing to check.
site_export_env() {
  export DB_HOST="$SOCKET"
  export DB_NAME="$DEV_DB"
  DB_USER="$(id --user --name)"
  export DB_USER
  export DB_PASSWORD=""
}

site_up() {
  site_check_tools
  site_ensure_cluster
  site_start_db
  site_ensure_database
  site_export_env
}

cmd_site_dev() {
  local port="${PORT:-8000}"

  site_up
  trap site_stop_db EXIT

  say "http://localhost:$port"
  say "database: $DEV_DB on $SOCKET"
  printf '\n'

  # -t sets the document root to exactly what nginx serves; router.php is the
  # stand-in for nginx's try_files, and does nothing else.
  php "${PHP_FLAGS[@]}" -S "localhost:$port" -t "$SITE_SRC/public_html" "$DEV_DIR/router.php"
}

cmd_site_seed() {
  site_up
  php "${PHP_FLAGS[@]}" "$DEV_DIR/seed.php"
}

cmd_site_reset() {
  local answer

  site_check_tools
  site_ensure_cluster
  site_start_db

  read -rp "throw away the local $DEV_DB database? [y/N] " answer
  [[ ${answer,,} == y ]] || die "left alone"

  dropdb --host="$SOCKET" --if-exists "$DEV_DB"
  site_ensure_database
  say "empty again"
}

# --- the wordmark ----------------------------------------------------------
#
# files/deploy/offline-worker.js carries an inlined copy of the path data in
# files/promo/manuserver.svg. It has to: the Worker answers when Cloudflare
# cannot reach the origin, so it cannot fetch an asset from the site it is
# standing in for. One file, no requests, or it is not an offline page.
#
# That makes it a copy, and copies drift. This re-derives it from the SVG, so
# keeping the two together is a command you run before deploying the Worker
# rather than something you notice months later on the one page nobody sees.

readonly WORDMARK_SVG="$ROOT/files/promo/manuserver.svg"
readonly WORDMARK_COPY="$ROOT/files/deploy/offline-worker.js"

# The first `d="…"` attribute in the file. Anchored on a preceding space so it
# cannot match the `d="` inside Inkscape's `id="path1"`.
wordmark_path() {
  awk '
    match($0, /(^|[[:space:]])d="[^"]*"/) {
      seg = substr($0, RSTART, RLENGTH)
      print substr(seg, index(seg, "d=\"") + 3, length(seg) - index(seg, "d=\"") - 3)
      exit
    }
  ' "$1"
}

cmd_wordmark() {
  local source_d copy_d tmp

  [[ -r $WORDMARK_SVG ]]  || die "not found: $WORDMARK_SVG"
  [[ -r $WORDMARK_COPY ]] || die "not found: $WORDMARK_COPY"

  source_d=$(wordmark_path "$WORDMARK_SVG")
  [[ -n $source_d ]] || die "no path data in $WORDMARK_SVG"

  copy_d=$(wordmark_path "$WORDMARK_COPY")
  [[ -n $copy_d ]] || die "no inlined path data in $WORDMARK_COPY"

  if [[ $source_d == "$copy_d" ]]; then
    say "the wordmark in the offline page matches files/promo/manuserver.svg"
    return
  fi

  # Substituted through an awk variable, not a sed replacement: the path data
  # is a thousand characters of slashes and commas and would need escaping.
  tmp=$(mktemp)
  awk -v new="$source_d" '
    !done && match($0, /(^|[[:space:]])d="[^"]*"/) {
      seg = substr($0, RSTART, RLENGTH)
      at  = index(seg, "d=\"")
      print substr($0, 1, RSTART - 1) substr(seg, 1, at - 1) "d=\"" new "\"" \
            substr($0, RSTART + RLENGTH)
      done = 1
      next
    }
    { print }
  ' "$WORDMARK_COPY" >"$tmp" || { rm -f "$tmp"; die "could not rewrite $WORDMARK_COPY"; }

  cat "$tmp" >"$WORDMARK_COPY"
  rm -f "$tmp"
  say "updated the wordmark in $(basename "$WORDMARK_COPY") — redeploy the Worker"
}

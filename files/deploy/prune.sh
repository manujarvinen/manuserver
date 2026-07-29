#!/usr/bin/env bash
#
# prune.sh — delete accounts nobody has used for three months.
#
# Run once a day by manuserver-prune.timer. The timer is Persistent, so a
# machine that was switched off for a week catches up on the next boot rather
# than silently skipping.
#
# What "used" means is decided by touch_activity() in files/site/app/auth.php,
# which stamps last_seen on any request from a signed-in account, at most once
# a day. It deliberately does not mean "logged in": a session cookie lasts a
# year, so a regular visitor may never log in twice.
#
# Deleting a user cascades — their saved videos go too, along with the likes
# other people put on them. That is the intended reading of a disposable
# service, and it is the reason the site says so plainly before you join. There
# is no email here, so nobody can be warned first; saying it up front is the
# only honest version of this feature.
#
# It also keeps the name pool from filling up. Names are ~1.6 million
# combinations and are only freed by deletion, so without this a long enough
# run of signups would eventually leave none.

set -euo pipefail

# Change it here and in the two places that promise it to people: the join page
# in files/site/app/views/join.php, and the promo page.
readonly TTL='3 months'

readonly DB=tastehopping

# root maps to the tastehopping role over the local socket, via the pg_ident
# entry db-setup.sh writes. No password is involved, here or anywhere.
count=$(psql --username="$DB" --dbname="$DB" \
             --no-psqlrc --quiet --tuples-only --no-align \
             --set=ON_ERROR_STOP=1 <<SQL
WITH gone AS (
    DELETE FROM users
     WHERE last_seen < now() - interval '$TTL'
 RETURNING 1
)
SELECT count(*) FROM gone;
SQL
)

printf 'manuserver-prune: removed %s account(s) unused for %s\n' "${count:-0}" "$TTL"

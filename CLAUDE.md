# How manuserver is put together

Context for anyone — human or otherwise — changing this repo. The user-facing
instructions are in [INSTALL.md](INSTALL.md); this is the reasoning behind them
and the rules that break quietly if you don't know them.

## The loop

The ISO installs a bare Arch system. At the very end of the install it clones
*this repo* to `/srv/manuserver` on the machine it just built, and does one
thing:

> if `files/deploy/provision.sh` exists in the clone, run it under
> `arch-chroot`. If it doesn't, skip silently.

That script installs nginx, PHP, Postgres and cloudflared and points them at the
clone. So the ISO knows nothing about what the server becomes, which is the
whole design: **change the server and the same ISO, unrebuilt, installs the new
one.** Building an ISO takes twenty minutes and testing one takes a reinstall,
so the ISO is meant to stop changing. Everything downstream of the clone
iterates with a push and a reinstall — or on a running machine, with a pull:

```sh
cd /srv/manuserver && sudo git pull
sudo systemctl restart manuserver-db   # only if the schema changed
```

## Rules that break quietly

**The installer clones from GitHub, not from your working copy.** Changes under
`files/deploy/` do nothing until they are pushed. This is the single most common
way to waste a reinstall.

**`arch-chroot` has no running init.** `provision.sh` can `systemctl enable` but
never `start`. Anything needing a live service — creating the database role, the
database, the tables — belongs in `files/deploy/db-setup.sh`, which
`manuserver-db.service` runs at every boot.

**`provision.sh` must be safe to run again**, and `db-setup.sh` and
`schema.sql` actually do run again, on every single boot. Every statement in
`schema.sql` is `IF NOT EXISTS` or `OR REPLACE`. Never put a destructive
statement in it.

**Some paths are baked into the installed system.** Moving `files/site/` or
`files/deploy/` means updating all of: the nginx docroot and the systemd unit in
`provision.sh`, the schema path in `db-setup.sh`, the tunnel symlink, and the
hook in `files/iso/overlay/root/lib/install.sh`. The installed machine only ever
knows `/srv/manuserver`.

**`ISO_OUT` is the repo root.** The build runs as root, so anything that chowns
its output must name files individually — a recursive chown there would rewrite
ownership of the whole checkout, `.git` included.

## The command

`manuserver.sh` at the root is the only entry point. It sources `files/lib/`:

| | |
|---|---|
| `common.sh` | paths, `say`/`die`, and whether we are in a checkout |
| `host-tools.sh` | installs missing host packages |
| `vm.sh` | `vm_*`, `ssh`, `tunnel`, `backup`, `restore`, `install_command` |
| `iso.sh` | `build_iso` — checkout only |
| `site.sh` | `site_dev`, `site_seed` — checkout only |

`install_command` **copies** the script and `files/lib/` into
`~/.local/share/manuserver/bin/` and symlinks `~/.local/bin/manuserver` at the
copy. A copy, not a symlink into the checkout, because the checkout is meant to
be deletable afterwards — a symlink into a deleted directory is worse than no
command, since it exists and fails. The copy detects it is a copy by the absence
of `files/iso/`.

Host-side state lives outside the checkout: the VM in
`~/.local/share/manuserver/vm`, backups in `~/Downloads` — visible, because the
point of a backup is copying it somewhere safe.

## The site

Plain PHP against Postgres. No framework, no Composer, nothing to install.

`files/site/public_html/` holds **only what a browser may request**. The
application, its queries and its settings are in `files/site/app/`, one level
above the document root, where no URL reaches them. nginx executes `index.php`
and nothing else; any other `.php` in the docroot is a 404.

Design decisions that are load-bearing, not incidental:

- **The site works with JavaScript off.** Every control is a real form posting
  to a real URL. `app.js` intercepts four of them for in-place updates and falls
  back to a normal submit on any error. Do not add a control that only works
  with the script.
- **No third-party requests. None.** No webfonts, no CDN, no analytics. The one
  outbound call anywhere is to YouTube's oEmbed endpoint when someone saves a
  link. This is why there is no CAPTCHA.
- **nginx keeps no access log**, deliberately: it is a list of who visited, from
  where and when, on a site that promises not to keep one.
- **There is no database password.** php-fpm runs as `http`, and a `pg_ident`
  map makes `http` the `tastehopping` role over a unix socket. Postgres accepts
  nothing from the network. A credential that does not exist cannot leak.
- **An account is a name and a key.** 32 bytes from the CSPRNG, of which only
  `sha256()` is stored — so the key is shown on exactly one screen and is
  unrecoverable by design. Plain SHA-256 rather than a slow KDF is correct here:
  256 bits of uniform randomness has no dictionary to attack.
- **Reputation is a percentile**, not a raw score, over accounts that have saved
  something. A raw score sits near zero for everyone on a young site and the
  slider selects nothing across its whole range.
- **Voting, repping and reporting need an account that has saved a video.**
  Accounts are free, and votes and reports are denominated in accounts. This
  makes empty ones worthless rather than making accounts hard to create, so
  there is no bot detection to bypass. Enforced in SQL, not just in the routes.

## The offline page

`files/deploy/offline-worker.js` is a Cloudflare Worker, not part of the server.
It sits on a route for the public hostname, passes everything through, and only
answers itself when Cloudflare cannot reach the tunnel — because the machine is
switched off, which for a home server is ordinary rather than an outage.

It lives in the repo rather than in a dashboard text box for the same reason
the nginx config lives in `provision.sh`: anything visitors see should be
reviewable and in git. Deploying it is manual, and documented in INSTALL.md.

It intercepts only 502, 504 and 520-530 — the codes that mean Cloudflare could
not reach the origin. A 500 from PHP passes through untouched, because that
means the server answered and the site is broken, which is a different thing
and should look like one.

The wordmark is inlined, copied from `files/promo/manuserver.svg`. If that file
changes, this copy does not follow.

## Running it here

```sh
./manuserver.sh site_dev      # http://localhost:8000
./manuserver.sh site_seed     # accounts and saves to look at
```

Builds a throwaway Postgres cluster in `files/dev/.cluster` on a unix socket
inside that directory and no TCP port, so it cannot collide with anything else.
Needs `postgresql` and `php-pgsql`; Arch ships the latter with the extension
disabled, so `site.sh` loads it per-invocation rather than asking for root.
`site_seed` prints the key of every account it invents, so you can sign in as
any of them.

`provision.sh` runs standalone for inspection — point `PROVISION_ROOT` at a temp
directory and it renders every config file there and skips pacman, initdb and
systemctl.

## Style

Bash is `set -euo pipefail` and shellcheck-clean. PHP is `declare(strict_types=1)`,
prepared statements with `ATTR_EMULATE_PREPARES => false`, `htmlspecialchars` on
every output, a CSRF token on every POST.

Comment the *why*, not the *what* — especially where something looks arbitrary
until it breaks. The partition suffix rule, `iw` versus `iwctl`, `-Syu` versus
`-Sy`, the socket-not-password decision, and the percentile reputation are all
things that read as odd choices and are not.

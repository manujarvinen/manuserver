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
one.** A rebuild is 5–20 minutes depending on the machine and how fast its
pacman mirror is — most of it is pacstrap — so the cost of touching the ISO is
not the build. It is that the only way to test one is a full reinstall, which
means changes under `files/iso/` are the slowest thing in this repo to verify.

The disk half of that has a shortcut. `files/dev/dirty-disk-test.sh` builds a
disk image that is *not* blank — GPT, an ESP and a btrfs root, which is what
real hardware looks like and what a fresh qcow2 never does — and boots the ISO
against it. Run it after any change to `disk.sh`. The first bare-metal attempt
failed on exactly that difference, and no other test in this repo can.
Everything downstream of the clone iterates with a push and a reinstall — or on
a running machine, with a pull:

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
| `site.sh` | `site_dev`, `site_seed`, `wordmark` — checkout only |

`install_command` **copies** the script and `files/lib/` into
`~/.local/share/manuserver/bin/` and symlinks `~/.local/bin/manuserver` at the
copy. A copy, not a symlink into the checkout, because the checkout is meant to
be deletable afterwards — a symlink into a deleted directory is worse than no
command, since it exists and fails. The copy detects it is a copy by the absence
of `files/iso/`.

Host-side state lives outside the checkout: the VM in
`~/.local/share/manuserver/vm`, backups in `~/Downloads` — visible, because the
point of a backup is copying it somewhere safe.

`backup`, `restore`, `ssh` and `tunnel` take the **server's** username and
default to `$USER`, the one on the machine you are typing on. Nothing remembers
what the server calls you. So the documents tell people to choose a *different*
username at install time, and that advice is about more than the argument: the
password prompt that appears partway through a backup is the server's `sudo`,
asked from your terminal, and with matching usernames there is nothing in it to
say so. Anything added here that prompts across the connection inherits the same
problem.

Taking that advice makes the *default* wrong, which is the trade. `$USER` is
then an account the server does not have, sshd asks for a password anyway, and
no answer can be right — the correct local password included. `cmd_tunnel`
therefore does two things worth copying into anything else that logs in:
`announce_remote_login` names the account and whose passwords are coming
*before* the first prompt, and it does not `exec ssh`, so exit 255 can be
turned into "there is probably no such account, pass the name" instead of
`Permission denied (publickey,password)`, which reads as a key problem and is
not one.

`ssh_opts` pins `SSH_KEY` (`~/.ssh/id_ed25519_manuserver`, or
`MANUSERVER_SSH_KEY`) with `IdentitiesOnly`. Left to itself ssh walks its
default names and offers whatever it finds, which on a machine keeping several
identities apart presents one of them to a server with no business seeing it.
`~/.ssh/config` cannot express the same rule: `Match` has no `port` attribute,
and `Host localhost` would capture every other local connection. If the key is
absent, ssh asks for a password — the behaviour from before it existed.

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
- **The tunnel token is the only secret anywhere**, and it lives in
  `/etc/manuserver/tunnel.env` on the server, root-only. It is never an
  argument, so it cannot reach a shell history or a process list, and
  `pg_dumpall` does not touch `/etc`, so it is not in backups either. It *is*
  part of the disk: the VM's `.qcow2` carries it, and so would any full-disk
  image. Anything added here that needs a secret should aim for the same
  shape — or better, for not needing one, as the database does.
- **An account is a name and a key.** 32 bytes from the CSPRNG, of which only
  `sha256()` is stored — so the key is shown on exactly one screen and is
  unrecoverable by design. Plain SHA-256 rather than a slow KDF is correct here:
  256 bits of uniform randomness has no dictionary to attack.
- **Reputation is a percentile**, not a raw score, over accounts that have saved
  something. A raw score sits near zero for everyone on a young site and the
  slider selects nothing across its whole range.
- **The slider is a floor, not a window.** 0 is everyone, 1000 is only the top,
  and the default is 0 because the default has to hide nobody. It used to pick
  a band either side of the handle, backed by a floor of the five nearest
  accounts so the band could never come back empty — and that floor is what
  made it wrong. Until an account has been liked its score is 0, so on a young
  site *every* account sits at reputation 0, none of them fall in a band around
  500, and the tie-break served the five oldest. A newcomer's first save was
  invisible wherever the slider went. Removing the floor without changing the
  semantics is not the fix either: measured on a young site, band-only left 91
  of 101 slider positions empty. A percentile can always give an ordering; on a
  degenerate scale it cannot name a neighbourhood.
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

`node files/dev/offline-worker-test.mjs` checks exactly that, and is worth
running before any deploy: this is the one file in the repo that can take the
site down while the server is up. It needs no dependencies and asserts the
boundaries either side of the 520-530 band.

The wordmark is inlined, copied from `files/promo/manuserver.svg`, because a
page that answers when the origin is unreachable cannot fetch an asset from it.
The copy does not follow the original by itself — `./manuserver.sh wordmark`
re-derives it, and INSTALL.md puts that step before deploying the Worker, which
is the only moment the copy actually ships.

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

## Picking this up on a machine that has never seen it

This file says how the thing is built. **[TODO.md](TODO.md) says where it
currently stands** — what has been tested, what has not, and what was decided
and why. Read it second; it is the only record of state, because the machine
this was developed on is expected to be wiped.

A fresh clone is enough. Nothing else survives a wipe and nothing else needs to:

- **The VM does not come with you.** It lives in `~/.local/share/manuserver`,
  not the checkout. On a new machine there is no server until `build_iso` and
  `vm_install` make one. `install_command` likewise: a clone has no
  `manuserver` on PATH until you run it.
- **Backups do not come with you either** — `~/Downloads`, outside the repo, on
  purpose. Restoring one onto a freshly installed server is
  `manuserver restore <file>`, or on bare metal
  `sudo -u postgres psql -f backup.sql`.
- **The Cloudflare tunnel and the offline Worker live at Cloudflare**, not
  here. The Worker survives any number of wipes. The tunnel token does not —
  it is only ever on the server, and `manuserver-tunnel off` deletes it. Take a
  new one from the dashboard.

What has to be installed, and nothing does until you need it:

| To run | You need |
|---|---|
| `build_iso` | Arch, and about 15 GB free. It installs archiso and qemu itself. |
| `site_dev`, `site_seed` | `postgresql` and `php-pgsql` |
| `files/dev/offline-worker-test.mjs` | node 22 or newer |
| `files/dev/dirty-disk-test.sh` | qemu, `btrfs-progs`, `dosfstools`, and an ISO in the repo root |

**One thing a clone will not tell you.** This repo's own remote was
`git@github-manujarvinen:manujarvinen/manuserver.git` — an alias defined in one
person's `~/.ssh/config`, not anything GitHub knows about. A fresh clone from
the https URL will fetch fine and fail to push with an authentication error
that looks like a permissions problem and is not. Set up whichever remote and
key you actually have.

## Style

Bash is `set -euo pipefail` and shellcheck-clean. PHP is `declare(strict_types=1)`,
prepared statements with `ATTR_EMULATE_PREPARES => false`, `htmlspecialchars` on
every output, a CSRF token on every POST.

Comment the *why*, not the *what* — especially where something looks arbitrary
until it breaks. The partition suffix rule, `iw` versus `iwctl`, `-Syu` versus
`-Sy`, the socket-not-password decision, and the percentile reputation are all
things that read as odd choices and are not.

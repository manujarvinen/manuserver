# What is still unfinished

Written 2026-07-30, after the first end-to-end run. **tastehopping.com is live**
— the VM serves it through a Cloudflare tunnel, on the apex and on `www`, with
a valid certificate. Everything below is what has *not* been done or *not* been
tested.

## 1. Four one-line jobs, none of them done

In this order. The first is the only one with a consequence today; the rest
make the next hour cheaper.

```sh
manuserver ssh mj
systemctl status manuserver-prune.timer     # expect: active (waiting)
```

**The account pruner is still unconfirmed.** It cannot be seen from outside the
machine, and until the timer is installed accounts are never deleted — while
the three-month rule is stated on the join page, on `/what` and on the promo
page. The site is either keeping that promise or it is not, and nobody has
looked.

```sh
ssh-copy-id -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mj@localhost
```

Stops `ssh` asking for a password, so the check above and every backup is one
prompt instead of two. The `sudo` prompt stays — see §3.

```sh
cd /path/to/manuserver && ./manuserver.sh install_command
```

**The installed `manuserver` is out of date.** `restore` and `wordmark` were
changed in the checkout on 2026-07-30 and host-side changes do not travel by
themselves. Must be run from inside the clone; from anywhere else there is no
`./manuserver.sh`.

```sh
git push
```

Not urgent — the commit is host-side and docs, so nothing on the server is
waiting for it. It matters before any *new* install, because the installer
clones from GitHub.

### Already done

Re-provisioned and rebooted 2026-07-30. The nginx side landed: the font comes
back with `max-age=31536000`. Check it from outside with a cache-buster, or you
are reading Cloudflare's four-hour copy of the old header rather than the
server, which is what made it look like the change had not taken:

```sh
curl -sI "https://tastehopping.com/fonts/geomini-latin.woff2?cb=$RANDOM" | grep -i cache
```

## 2. Things that have never been tested

**The ISO.** `files/iso/overlay/root/installer.sh` gained an 8-character
minimum password that has never been built into an ISO or run — the installed
VM predates it. `./manuserver.sh build_iso` (~20 min). Nothing else in the
installer changed, so this is the only untested part of it.

**A clean-room install.** The original plan — clone fresh into another
directory, build, install — was never carried out. It is the only thing that
exercises the whole chain: clone → `build_iso` → `vm_install` → clone on the
target → `provision.sh` → first boot → site up. Every part has worked
individually; the sequence has not been run start to finish from nothing.

Push before starting one, or it tests the previous commit: both clones come
from GitHub, the fresh checkout and the one the installer makes on the target.

**Bare metal.** No install onto a physical machine has happened. The USB
instructions (Caligula) and the *Running it in 64-bit PC* sections of both
documents are written from the code, not from having done it. The `ssh` and
`sudo -u postgres` commands there are the same ones the VM path runs remotely,
so they should hold, but nobody has checked.

**The offline Worker.** `files/deploy/offline-worker.js` is written and its
status rules were walked through by hand against eleven codes, but *no test for
that lives in the repo* — there is no test file and nothing inline, so nothing
re-checks the rules if they change. It has never been deployed to Cloudflare
and has never seen a real outage.

Run `./manuserver.sh wordmark` first, then the deploy steps in INSTALL.md under
*A page for when the server is off*. Test with `manuserver vm_stop`, then load
the site.

Deploying it is the one item here that can break a working site: it is code in
front of the origin, on a route matching every URL. If the site ever misbehaves
in a way the server cannot explain, remove the route before looking anywhere
else.

## 3. Known, small, deliberate

- **`REPORT_THRESHOLD` is 3** (`files/site/app/bootstrap.php`). Three accounts
  can permanently hide any post, and reports are one-way with no undo. Now that
  voting requires having saved a video this is much more expensive to abuse
  than it was, but three is still a low number.
- **`sudo` on the server asks for a password**, so a backup costs a prompt even
  once the `ssh` key in §1 is copied. That one should stay — it is what stops
  anyone at an unlocked terminal reading the database off the machine.

Two entries that used to live here are now fixed rather than tolerated:
`restore` reads a bare word that is not a file as a username, so
`manuserver restore mj` works; and `./manuserver.sh wordmark` re-derives the
offline page's inlined logo from `files/promo/manuserver.svg` instead of
leaving the two to drift. Both are in the checkout only until `install_command`
is run — see §1.

## 4. Worth knowing before changing anything

- **Two kinds of change, two ways to deploy, and neither follows the other.**
  Host-side (`manuserver.sh`, `files/lib/`) needs
  `./manuserver.sh install_command` run from the checkout. Server-side
  (`files/site/`, `files/deploy/`) needs `git pull` on the VM. Nothing warns
  you when the one you did was the wrong one — this has already cost an hour
  once.
- **The installer clones from GitHub**, so unpushed changes under
  `files/deploy/` have no effect on a new install.
- **Reputation reads `new`** until ten accounts have each saved something. With
  the accounts made so far it is under that, so `new` is correct, not a fault.
- **Cloudflare caches `.css` and `.js` for four hours.** Asset URLs now carry a
  modification-time stamp so this no longer bites, but a *new* kind of static
  file added to the docroot would need the same treatment.
- **`files/dev/.cluster`** holds a local Postgres full of invented test data.
  Gitignored and disposable — `./manuserver.sh site_reset` empties it.

The reasoning behind the design, and the rules that break quietly, are in
[CLAUDE.md](CLAUDE.md).

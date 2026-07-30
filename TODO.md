# What is still unfinished

Written 2026-07-30, after the first end-to-end run. **tastehopping.com is live**
— the VM serves it through a Cloudflare tunnel, on the apex and on `www`, with
a valid certificate. Everything below is what has *not* been done or *not* been
tested.

## 1. Re-run provisioning on the server — done, mostly verified

Re-provisioned and rebooted 2026-07-30. The nginx side landed: the font comes
back with `max-age=31536000`.

Check it from outside with a cache-buster, or you are reading Cloudflare's
four-hour copy of the old header rather than the server:

```sh
curl -sI "https://tastehopping.com/fonts/geomini-latin.woff2?cb=$RANDOM" | grep -i cache
```

**Still unconfirmed:** the account pruner, which cannot be seen from outside.
Until the timer is installed accounts are never deleted, and the three-month
rule is stated on the join page, on `/what` and on the promo page. One command
on the server settles it:

```sh
manuserver ssh mj
systemctl status manuserver-prune.timer     # expect: active (waiting)
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

**Bare metal.** No install onto a physical machine has happened. The USB
instructions (Caligula) and the *Running it in 64-bit PC* sections of both
documents are written from the code, not from having done it. The `ssh` and
`sudo -u postgres` commands there are the same ones the VM path runs remotely,
so they should hold, but nobody has checked.

**The offline Worker.** `files/deploy/offline-worker.js` is written, its status
rules are unit-tested against eleven codes and the page validates, but it has
never been deployed to Cloudflare and has never seen a real outage. Deploy
steps are in INSTALL.md under *A page for when the server is off*. Test with
`manuserver vm_stop`, then load the site.

## 3. Known, small, deliberate

- **`REPORT_THRESHOLD` is 3** (`files/site/app/bootstrap.php`). Three accounts
  can permanently hide any post, and reports are one-way with no undo. Now that
  voting requires having saved a video this is much more expensive to abuse
  than it was, but three is still a low number.
- **SSH still asks for a password.** A backup costs two prompts, `ssh` then
  `sudo`. Removing the first is one command, run once:
  ```sh
  ssh-copy-id -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mj@localhost
  ```
  The `sudo` prompt should stay — it is what stops anyone at an unlocked
  terminal reading the database off the machine.

Two entries that used to live here are now fixed rather than tolerated:
`restore` reads a bare word that is not a file as a username, so
`manuserver restore mj` works; and `./manuserver.sh wordmark` re-derives the
offline page's inlined logo from `files/promo/manuserver.svg` instead of
leaving the two to drift.

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

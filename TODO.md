# What is still unfinished

Written 2026-07-30, after the first end-to-end run. **tastehopping.com is live**
— the VM serves it through a Cloudflare tunnel, on the apex and on `www`, with
a valid certificate. Everything below is what has *not* been done or *not* been
tested.

## 1. Nothing outstanding here

Everything in this section is done, and so is the clean-room install in §2.
What is left is bare metal and the offline Worker.

### Done, 2026-07-30

**Provisioning re-run.** The nginx side landed: the font comes back with
`max-age=31536000`. Check it from outside with a cache-buster, or you are
reading Cloudflare's four-hour copy of the old header rather than the server,
which is what made it look like the change had not taken:

```sh
curl -sI "https://tastehopping.com/fonts/geomini-latin.woff2?cb=$RANDOM" | grep -i cache
```

**The account pruner is confirmed.** `manuserver-prune.timer` is
`active (waiting)` and fires daily. The three-month rule on the join page, on
`/what` and on the promo page is being kept.

**The VM has its own ssh key.** It previously authorised a *GitHub* key, from a
`ssh-copy-id` that installed whichever key it found first. `authorized_keys`
now holds one key, `~/.ssh/id_ed25519_manuserver`, which exists for this and
nothing else; the GitHub key no longer authenticates. `ssh_opts` pins it with
`IdentitiesOnly`, so `manuserver` offers that key or a password and never walks
the rest of `~/.ssh`. `MANUSERVER_SSH_KEY` overrides the path.

This cannot live in `~/.ssh/config`: `Match` has no `port` attribute, so a rule
cannot be scoped to the forwarded port, and `Host localhost` would capture
every other local connection.

**`install_command` re-run and everything pushed.** The installed copy now has
the `restore` fix, `wordmark`, and the key pinning.

### One thing to know about usernames

`backup`, `restore`, `ssh` and `tunnel` all take the **server's** username and
default to the one on *your* machine. They match here, so the bare commands
work. On a server installed under a different name they do not, and the failure
reads as `Permission denied (publickey,password)` — which looks like a key
problem and is not. Pass the name: `manuserver backup johnson`.

**Matching them is the worse trade, though.** Every password these commands ask
for is the server's, asked from your own terminal. When both machines call you
the same thing the prompt is identical either way and there is nothing to tell
you which one wants the password — and the natural guess is the local one. The
convenience of a bare `manuserver backup` costs a doubt every single time.
INSTALL.md, README.md and the promo page now say to pick a different name at
install time, and the installer says it too. This VM predates that and shares
its username with the machine it is administered from — the case worth not
repeating, and worth fixing whenever it is next reinstalled.

## 2. Things that have never been tested

**The clean-room install was run on 2026-07-30 and it worked, start to
finish.** Fresh clone from GitHub into `/home/mj/manuserver-cleanroom-src`,
`build_iso` there, `vm_install` into a second VM under
`XDG_DATA_HOME=/home/mj/manuserver-cleanroom`, username `johnson`. So the whole
chain — clone → `build_iso` → `vm_install` → clone on the target →
`provision.sh` → first boot → site up — is no longer theory.

Confirmed on that machine, on its **first** boot, with nothing done by hand:

- nginx serving, PHP rendering, Postgres answering — the page comes back with
  its title and a session cookie, which means `db-setup.sh` built the role, the
  database and the schema at boot.
- `/fonts/` returns `max-age=31536000`. This is the rule that was *missing* on
  the live server and needed a manual re-provision, so it is the one that most
  needed proving.
- `/index.php` returns 404 — only the router executes.
- `manuserver-prune.timer` is `active (waiting)`. On the live server this had to
  be taken on trust for a day.
- `manuserver-tunnel.service` is loaded and enabled but `inactive (dead)`,
  which is right: off until it is given a token.
- The installer's username screen and the 8-character password minimum both
  behaved, and the shell prompt reads `johnson@manuserver` — which is the whole
  argument for two different usernames, visible in one line.

Two notes for whoever runs the next one:

- **Answer `n` to "Install the `manuserver` command".** It follows
  `XDG_DATA_HOME`, so accepting repoints `~/.local/bin/manuserver` at the
  clean-room copy and breaks the command for the real server. Saying no also
  suppresses the delete-the-clone offer, deliberately — `vm.sh:231` will not
  offer to delete the only thing that can still reach the new VM.
- **Push first**, or it tests the previous commit: both clones come from
  GitHub, the fresh checkout and the one the installer makes on the target.

The `hostname` binary is not installed on the built machine — nothing in this
repo calls it, `/etc/hostname` is set, and the prompt proves it. Noted only so
nobody reads its absence as a fault.

**Bare metal.** No install onto a physical machine has happened. The USB
instructions (Caligula) and the *Running it in 64-bit PC* sections of both
documents are written from the code, not from having done it. The `ssh` and
`sudo -u postgres` commands there are the same ones the VM path runs remotely,
so they should hold, but nobody has checked.

The clean-room run narrows what is left here. The installer, `provision.sh`,
`db-setup.sh` and first boot are all now proven on a machine built from
nothing; what bare metal adds is real firmware, a real disk and real wifi —
the parts a VM cannot stand in for.

**The offline Worker.** `files/deploy/offline-worker.js` is written and its
status rules were walked through by hand against eleven codes, but *no test for
that lives in the repo* — there is no test file and nothing inline, so nothing
re-checks the rules if they change. It has never been deployed to Cloudflare
and has never seen a real outage.

Run `./manuserver.sh wordmark` first, then the deploy steps in INSTALL.md under
*A page for when the server is off*. Test with `manuserver stop`, then load
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
- **`sudo` on the server asks for a password**, so a backup still costs one
  prompt now that the `ssh` half is a key. That one should stay — it is what
  stops anyone at an unlocked terminal reading the database off the machine.

Two entries that used to live here are now fixed rather than tolerated:
`restore` reads a bare word that is not a file as a username, so
`manuserver restore admin` works; and `./manuserver.sh wordmark` re-derives the
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

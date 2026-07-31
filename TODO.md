# What is still unfinished

## 0. Where this stands, 2026-07-31

**The development machine was wiped and rebuilt from scratch, and everything
survived that a fresh clone is supposed to survive.** This is the wipe §2
planned for, and it did not go the way the plan describes: the bare-metal
install of *this* repo failed on the disk (see *Bare metal*, §2), and rather
than stay down, the machine was reinstalled with something else —
`github.com/gearnoodle/archlab` — at 03:01. **So the target hardware is now in
use by another system, and the bare-metal test is blocked** on freeing it
again or finding a second machine.

The wipe took the VM and the live server on it, the `manuserver` command, the
Cloudflare tunnel token and anything in `~/Downloads`. All expected, and the
whole point of §2's list. **The route back was exactly the documented one**,
run the same morning from a fresh clone:

    ./manuserver.sh build_iso     # 1.5G ISO, with the disk fix baked in
    ./manuserver.sh vm_install
    ./manuserver.sh install_command

**Verified on that VM's first boot, with nothing done by hand:** the front
page returns 200 with a session cookie; `/new` returns 200, which is the one
that matters, since rendering a feed reads `user_reputation` and so proves
`db-setup.sh` built the role, the database and the schema at boot;
`/fonts/*.woff2` comes back with `max-age=31536000`; `/index.php` and a
made-up path both 404, so only the router executes.

**What is still missing is the tunnel.** The token only ever lived on the old
server, so the site has no origin until a new one is taken from the Cloudflare
dashboard and given to `manuserver tunnel`.

**Whether any database backup left the machine before the wipe is unknown.**
`~/Downloads` was empty afterwards. If none did, the posts that were on the
old server are gone, and the rebuilt one starts empty — which is survivable
and worth knowing rather than discovering later.

**The offline Worker covered the whole outage, unprompted.** Through the wipe
and the rebuild, tastehopping.com answered with `<title>tastehopping — back
shortly</title>` rather than a Cloudflare 1033. That is the first *real*
outage it has taken — not a planned maintenance window, and not one anybody
set up to watch it — which was one of the two things §2 listed as still
unseen. It works.

## 1. Nothing outstanding here

Everything in this section was done on 2026-07-30, on the server that no
longer exists. It is kept because it is what a rebuilt one should look like.
**The one thing left is an install onto a physical machine** — the one thing a
VM cannot stand in for. It has now been attempted, it failed on the disk, and
the cause is fixed but unproven; see *Bare metal* in §2.

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

**Bare metal, attempted 2026-07-31. It got as far as the disk and stopped
there.** The target's disk carried an ordinary Arch install with a btrfs root
— the same setup as the development machine. Two runs, two failures, both on
the same cause:

1. `wipefs: /dev/nvme0n1: probing initialization failed: Device or resource
   busy`, reported under *clearing filesystem signatures*.
2. On the second run, `/dev/nvme0n1p2 is apparently in use by the system; will
   not make a filesystem here!`, under *formatting root*.

**The cause was btrfs, not LVM.** btrfs-progs ships a udev rule that runs
`btrfs device scan` on every device carrying a btrfs signature, and the live
medium runs it on the target disk during boot. A registered device is held by
the kernel module, so it refuses the exclusive open that `wipefs` and `mkfs`
both need. Nothing is mounted, nothing appears in `lsblk`'s tree, and
`/sys/class/block/*/holders` is empty — the disk simply will not be written
to. Opening a whole disk exclusively also fails when one partition is held,
which is why the first message names `/dev/nvme0n1` for a problem one level
down.

This is worth being clear about because the obvious diagnosis is wrong. The
recovery that worked at the time ran `dmsetup remove ArchinstallVg-root`
first, and that command did nothing: the machine has no LVM, no `lvm2`
installed and an empty `/dev/mapper`. What actually cleared the disk were the
`wipefs -a` and `sgdisk --zap-all` that followed, by which point the failed
run had already destroyed enough state to release it.

**The order of operations made the first failure destructive.**
`disk_partition` ran `sgdisk --zap-all` *before* `wipefs`, so the partition
table was gone by the time the step that actually fails on a busy disk
reported it. The disk lost its contents and gained no install. That order is
now reversed: `wipefs` is the first thing that touches the disk, so a disk
this installer cannot have is a disk it has not modified.

**Fixed, and still not proven where it counts.** The rebuilt ISO installs
cleanly into a VM, so the change does not break the ordinary path — but a
fresh qcow2 has no btrfs signature to register, so `disk_release` finds
nothing and returns immediately. Only a disk somebody has used before
exercises it. `disk_release` in
`files/iso/overlay/root/lib/disk.sh` now unmounts and `swapoff`s everything on
the target, deactivates volume groups with `vgchange`, stops leftover md
arrays and dm mappings, and hands every btrfs member back with `btrfs device
scan --forget`. `files/lib/iso.sh` puts `btrfs-progs`, `lvm2` and `mdadm` on
the medium so those tools exist. **None of it reaches an install until the ISO
is rebuilt** — `disk.sh` is baked into the medium, so pushing alone does
nothing, and `iso.sh` is host-side and needs `install_command`.

**What the attempt did prove:** `disk_part_suffix` gets NVMe right. Both
failures name `/dev/nvme0n1p2`, which is the `p` branch that had never once
run and was the most likely thing to break. The error path also works — both
failures came back through `ui_fatal_log` with the real cause in the tail of
the log, on screen, rather than as a hang or a stack trace.

**Also found, while testing the helpers against real hardware:** `lsblk`
reports `/dev/zram0` as `type == disk`, so `disk_candidates` was offering a
compressed-RAM swap device in the disk menu next to the real one. Picking it
would waste an install on something that does not survive a reboot. Now
filtered along with `ram*`, `loop*` and `fd*`.

**The attempt was abandoned rather than retried.** After the manual wipe the
machine was given a different system entirely, to get something running that
evening. That is the honest reason bare metal is still open, and it is a fair
one: an installer that eats a disk and installs nothing is not something to
spend a third attempt on at five in the morning.

Still untested on bare metal: everything after the disk. The USB instructions
(Caligula) and the *Running it in 64-bit PC* sections of both documents are
written from the code, not from having done it. Wifi has still never run —
every install so far used the cable path.

### The plan: wipe this machine and install onto it

The machine this was all developed on — hostname `arch`, a Micro Computer (HK)
Tech mini PC — is itself the bare-metal target. It is going to be wiped for
Omarchy 4.0 eventually, so an install onto it costs nothing that is not already
being thrown away.

**It is also the machine the VM runs on.** Wiping it destroys the live server,
which is fine and intended, but it means four things have to leave the disk
first. In this order:

1. **A fresh database backup, copied off the machine.** `manuserver backup`,
   then put the `.sql` on a USB stick. A backup sitting on the disk you are
   about to erase is not a backup. Check the age of what is already in
   `~/Downloads` — the one there on 2026-07-30 was four hours stale within an
   evening, holding 5 posts when the site was serving 8.
2. **The ISO, written to USB.** Building one needs an Arch host, and after the
   wipe this *is* the only Arch host. Wipe first and there is nothing left to
   build the installer with.
3. **The Cloudflare tunnel token — not saved, just known about.** It lives only
   on the machine and `manuserver-tunnel off` deletes it. Get a fresh one from
   the Cloudflare dashboard afterwards; there is no file to rescue.
4. **Everything pushed.** GitHub is the only copy that survives.

The site is down for the whole wipe and reinstall, and that is now survivable:
the offline Worker was deployed hours before this plan existed, so visitors get
the resting-machine page rather than a Cloudflare error.

**What this actually tests**, in rough order of how likely it is to be the
thing that breaks:

- **~~`disk_part_suffix` on NVMe~~ — confirmed working, 2026-07-31.** The `p`
  branch produced `/dev/nvme0n1p2` correctly on the attempt above.
- **Whether the disk actually lets go.** This is what replaced the item above
  as the likely thing to break, and it already has once. See *Bare metal*.
- **The disk menu, with a footgun.** One disk is shown rather than asked about;
  with the USB stick attached there are two, so the menu runs for the first
  time. `disk_candidates` filters on `type == disk`, and **a USB stick is type
  disk** — the stick you booted from appears in the list. Pick by the size and
  model that `disk_describe` prints, never by position. `zram0` used to show up
  here too and no longer does.
- **Wifi.** `iw`/`iwd` scanning has never run; every install used the cable
  path. Use ethernet for the first attempt so a disk problem and a wifi problem
  cannot be mistaken for each other, then test wifi on a second run.
- **`linux-firmware` mattering.** Installed all along, irrelevant in a VM.
- **Firmware settings.** UEFI on, Secure Boot off. The installer refuses BIOS
  outright rather than installing something that will not boot.

**Afterwards there is no host side.** No `manuserver` command, no `site_dev`,
no `build_iso` except by cloning onto the server and building there. Restoring
the backup is Postgres directly: `sudo -u postgres psql -f backup.sql`.

**The offline Worker.** `files/deploy/offline-worker.js` now has a test —
`node files/dev/offline-worker-test.mjs`, 43 assertions, no dependencies. It
imports the Worker unmodified, stubs global fetch as the origin and asks what a
visitor would get: all thirteen unreachable codes become the offline page, and
200, 301, 404, 418, 500, 501, 503, 505, 519, 531 and 599 pass through with the
origin's own body. 519 and 531 are there on purpose — they sit either side of
the 520-530 band and catch an off-by-one.

**It is deployed and it works, 2026-07-30.** Routed on the apex and on `www`,
tested against a server that was actually switched off: visitors got the
offline page instead of Cloudflare's 1033. With the server back up, the apex
and `www` both return 200 and `/nope` still returns the origin's own 404 — so
it is passing through and intercepting only what it should.

That closes the last thing this repo could test on its own. **Turning the
server off is no longer a thing to avoid**: a maintenance window now looks like
a page that says the machine is resting, which is what it always should have
looked like. The clean-room install earlier the same day took the site down
with nothing in front of it; the next one will not.

**One of those has now happened.** The wipe in §0 took the origin away for
good with nobody watching, and the Worker answered — see §0. What it still has
not seen is a Cloudflare-side failure rather than an origin-side one.

**It is code in front of a working system.** If the site ever misbehaves in a
way the server cannot explain, remove the route before looking anywhere else.
Run `node files/dev/offline-worker-test.mjs` and `./manuserver.sh wordmark`
before redeploying it.

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

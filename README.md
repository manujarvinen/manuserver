# manuserver

A small Arch Linux server, the installer that puts it on a machine, and the
website it runs. One script drives all three.

The loop reads oddly until you see it: the ISO installs the system, and at the
end of the install the system clones *this repo* to `/srv/manuserver` and
provisions itself from it. So the machine carries a copy of the thing that
installed it, and updating the server is a `git pull` on the server.

## From zero to a running server

Step-by-step instructions in plain English are in [INSTALL.md](INSTALL.md).
The short version:

```sh
git clone https://github.com/manujarvinen/manuserver.git
cd manuserver

./manuserver.sh build_iso     # -> ./manuserver-*.iso   (~20 min)
./manuserver.sh vm_install    # install that ISO into a VM
```

`build_iso` installs whatever the machine is missing (archiso, QEMU, UEFI
firmware) and elevates itself, so there is no setup step before it. The ISO
lands in the repo root, next to `manuserver.sh`, where it is easy to find and
easy to `dd` onto a USB stick.

The install boots the ISO in a window; answer the installer's four questions —
network, username, password, disk. It then offers to delete the ISO, put a
`manuserver` command on your PATH, and delete the clone.

After that the VM is the server, and runs like one — from any directory:

```sh
manuserver              # start it (backgrounded, no window)
manuserver vm_stop      # shut it down cleanly
manuserver vm_status    # check on it
manuserver ssh mj       # shell on it, or http://localhost:8080
manuserver tunnel       # put it on the public internet
manuserver backup       # database -> ~/Downloads, restore puts it back
manuserver site_dev     # run the website here instead, no VM involved
```

`manuserver.sh --help` lists the lot.

The VM and the command itself live in `~/.local/share/manuserver`, never in the
checkout — so the clone can be moved or deleted without taking the server with
it. Only `build_iso`, `vm_install` and `site_dev` need the clone back, because
only they need its sources. An older checkout with its VM still inside migrates
itself on the next command.

Database backups go to `~/Downloads` instead, on the grounds that the whole
point of one is copying it somewhere safe, and a hidden directory is a poor
place to keep something you are meant to notice.

`vm_install` erases the VM and everything on it, so it asks you to type `ERASE`
first. Take a backup before you do.

It autologins on the console and starts its services at boot, so there is no
login step between powering it on and the server being up. Details, including
how to turn that off, are in
[the ISO notes](files/iso/README.md).

## The site it runs: tastehopping

The server exists to host one thing — an anonymous place to keep the YouTube
videos other people found worth keeping, and to vote on them.

There are no accounts in the usual sense. Joining is one button. The server
invents a name for you — `pal-ori`, `tul-fon`, that shape — and hands you one
long key. **The key is the account.** No email, no password, no profile, and
nothing that says who you are. The database stores only a SHA-256 of the key,
so the server cannot show it to you twice and cannot send it back to you if it
is lost. Lose it and that account is simply gone; make a new one.

Reputation is a position rather than a score: 0 to 1000, by where you stand
against everyone else. The slider under each feed picks which part of that
range you want to hear from, which is the point of the whole site — not "what
is popular", but "what do people whose taste sits *here* keep".

The site itself is plain PHP against Postgres, no framework and no
dependencies to install. Every button is a real form that works with
JavaScript switched off; the script only makes the clicks instant.

## The loop

The ISO is the slow part: building one takes half an hour, testing it takes a
reinstall. So it is designed to stop changing. The last step of an install
clones this repo and then does one thing:

> if `files/deploy/provision.sh` exists in the clone, run it under
> `arch-chroot`. If it doesn't, skip silently.

That script installs nginx, PHP and Postgres and points them at this repo. The
ISO itself knows nothing about any of it — change the server and the *same
ISO*, unchanged and unrebuilt, installs the new one.

Because the installer clones from GitHub rather than from your working copy,
**changes to `provision.sh` only take effect once they are pushed.**

`arch-chroot` has no running init, so `provision.sh` can `systemctl enable` but
never `start`. Everything needing a live service — creating the database role,
the database and the tables — is in `files/deploy/db-setup.sh`, which
`manuserver-db.service` runs at every boot. That half can be fixed without
reinstalling anything:

```sh
cd /srv/manuserver && sudo git pull
sudo systemctl restart manuserver-db
```

## Developing the site without the VM

```sh
./manuserver.sh site_dev      # http://localhost:8000
./manuserver.sh site_seed     # accounts and saves to look at
```

It builds a throwaway Postgres cluster in `files/dev/.cluster`, listening on
a unix socket inside that directory and on no TCP port, so it cannot collide
with anything else on the machine. Needs `postgresql` and `php-pgsql`
installed; it says so if they are missing. `seed` prints the key for every
account it invents, so you can sign in as any of them.

## What gets installed

The ISO installs deliberately little: `base linux linux-firmware <ucode> sudo
iwd iw openssh git`, UEFI + systemd-boot, and
`systemd-networkd`/`systemd-resolved`/`iwd` for networking. Root is locked;
administration goes through `sudo` via the `wheel` group, so there is one
account, one password and one audit trail. The install ISO is the rescue path
if sudoers ever gets mangled.

`provision.sh` then adds `nginx php php-fpm php-pgsql postgresql` and nothing
else.

There is no database password on the machine, because there is no database
password. php-fpm runs as the `http` user and reaches Postgres over a unix
socket, where a `pg_ident` map says that `http` *is* the `tastehopping` role.
A credential that does not exist cannot leak into a repo, a log or a backup.

## Layout

One script at the root, and everything it drives under `files/`:

```
manuserver.sh              the only command — build_iso, vm_install, ssh, ...
files/lib/                 the parts it is made of
files/iso/                 ISO build inputs + the TUI installer (overlay/)
files/site/public_html/    document root — front controller, CSS, JS
files/site/app/            the site: routing, queries, auth, views
files/site/db/schema.sql   the whole database
files/deploy/              provision.sh, db-setup.sh, tunnel.sh — run on the machine
files/dev/                 helpers for running the site here instead of on the VM
files/promo/               a page describing this project, hosted elsewhere
files/references/          design references — logo, colours, screen layouts
files/work-files/          source files for the visuals (Krita)
```

`files/site/public_html/` holds only what a browser is allowed to ask for.
Everything else lives in `files/site/app/`, one directory up from the document
root, where no URL reaches it.

Two websites, which is confusing until you see the split: `files/promo/`
describes the project and is uploaded wherever you like. `files/site/` is the
thing running *on* the server, talking to the database — nginx points at it
from `/srv/manuserver/files/site/public_html`.

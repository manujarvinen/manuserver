# manuserver

A small Arch Linux server, and the installer that puts it on a machine.

This repo is both halves of that, which reads oddly until you see the loop:

- **`manuserver_bootable_iso/`** — builds a custom Arch install ISO. Run one
  script and you get a bootable `.iso`. See
  [its README](manuserver_bootable_iso/README.md).
- **the repository root** — the server itself. At the end of an install, the
  ISO clones *this repo* to `/srv/manuserver` on the machine it just built.

So the ISO installs the system, and the system carries a copy of the thing that
installed it.

## From zero to a running server

Step-by-step instructions in plain English are in [INSTALL.md](INSTALL.md).
The short version:

```sh
git clone git@github.com:manujarvinen/manuserver.git
cd manuserver/manuserver_bootable_iso

./build_manuserver_iso.sh            # -> out/manuserver-*.iso  (~20 min)
./run-manuserver-in-vm.sh install    # install that ISO into a VM
```

The build script installs whatever the machine is missing (archiso, QEMU, UEFI
firmware), so there is no setup step before it. The install boots the ISO in a
window; answer the installer's four questions — network, username, password,
disk.

After that the VM is the server, and runs like one:

```sh
./run-manuserver-in-vm.sh            # start it (backgrounded, no window)
./run-manuserver-in-vm.sh stop       # shut it down cleanly
./run-manuserver-in-vm.sh status     # check on it
./run-manuserver-in-vm.sh ssh mj     # shell on it, or http://localhost:8080
./run-manuserver-in-vm.sh backup     # database -> backups/, restore puts it back
```

`install` erases the VM and everything on it, so it asks you to type `ERASE`
first. Take a backup before you do.

It autologins on the console and starts its services at boot, so there is no
login step between powering it on and the server being up. Details, including
how to turn that off, are in
[the ISO README](manuserver_bootable_iso/README.md).

## The loop

The ISO is the slow part: building one takes half an hour, testing it takes a
reinstall. So it is designed to stop changing almost immediately. The last step
of an install clones this repo and then does one thing:

> if `server/deploy/provision.sh` exists in the clone, run it under
> `arch-chroot`. If it doesn't, skip silently.

Today that file is a **placeholder**: it installs nothing and only leaves proof
that it ran, so the chain from ISO to clone to provisioning can be tested
before there is a server to provision. Replace its body with the real setup and
the same ISO — unchanged, unrebuilt — installs the full server. Everything
downstream of the clone iterates with a push and a reinstall.

Because the installer clones from GitHub rather than from your working copy,
**changes to `provision.sh` only take effect once they are pushed.**

A note for whoever writes the real one: `arch-chroot` has no running init, so it
can `systemctl enable` but never `start`. Anything that needs a live service has
to defer to a first-boot one-shot unit.

## What gets installed

Deliberately minimal: `base linux linux-firmware <ucode> sudo iwd iw openssh
git`, UEFI + systemd-boot, `systemd-networkd`/`systemd-resolved`/`iwd` for
networking. Root is locked; administration goes through `sudo` via the `wheel`
group, so there is one account, one password and one audit trail. The install
ISO is the rescue path if sudoers ever gets mangled.

Postgres, PHP and nginx come later, via `provision.sh`.

## Layout

```
manuserver_bootable_iso/   ISO build scripts + the TUI installer
references/                design references — logo, colours, screen layouts
work-files/                source files for the visuals (Krita)
```

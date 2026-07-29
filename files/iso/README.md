# The install ISO

Notes on what is in here. How to *use* it is in
[INSTALL.md](../../INSTALL.md) — `./manuserver.sh build_iso`, then
`./manuserver.sh vm_install`.

## What the installer does

It asks four things and infers the rest:

1. **Network** — uses wired automatically if a cable is live; otherwise scans
   and offers an SSID list. Verifies real connectivity, not just an address.
2. **Username** — validated against the rule `useradd` enforces.
3. **Password** — twice, masked, at least 8 characters, with a `ctrl-r` reveal
   toggle. The reveal is not decoration: the keymap is hardcoded `us`, and a
   layout mismatch produces a *consistent* wrong password that the
   double-entry check cannot catch.
4. **Disk** — auto-selected when there is only one, then a destructive
   confirmation that defaults to *No*.

Then it partitions (1 GB ESP + root), pacstraps, configures, installs
systemd-boot, creates the account, locks root, and clones this repo to
`/srv/manuserver` on the target.

Fixed without asking: keymap `us`, hostname `manuserver`, timezone `UTC`,
locale `en_US.UTF-8`, UEFI + systemd-boot, `systemd-networkd` + `iwd`.

### Autologin

The installed system logs the user in automatically on tty1, so starting the
machine is the same thing as starting the server. The trade-off is worth
saying out loud: **anyone at the console gets that user's shell, and through
`wheel`, sudo.** Physical access is the trust boundary. SSH is unaffected and
still asks for the password. To turn it off:

```sh
sudo rm -r /etc/systemd/system/getty@tty1.service.d
```

## Layout

```
overlay/root/         copied verbatim into the ISO's airootfs
  .zprofile           autostarts the installer on tty1 only
  installer.sh        flow control, one screen per question
  lib/ui.sh           palette, drawing, input widgets
  lib/network.sh      wired detection, wifi scan and connect
  lib/disk.sh         enumeration, confirmation, partitioning
  lib/install.sh      pacstrap, chroot config, bootloader, repo hook
manuserver_logo.txt   block-ASCII logo, baked into the medium at build time
build/                generated scratch space, not in git
```

The build itself is `files/lib/iso.sh`, driven by `./manuserver.sh build_iso`.
It takes archiso's stock `releng` profile, drops `overlay/` onto its airootfs,
renames the medium, and runs mkarchiso. The finished ISO lands in the repo
root.

The logo comes from `files/iso/manuserver_logo.txt` and is copied into
the ISO at build time. It has to be: the installer runs from the live medium
long before the repo exists on the machine.

## Debugging a failing install

- The installer runs on **tty1 only**. `Alt+F2` gives a plain root shell on the
  live ISO while it is running.
- Everything long-running is logged to `/tmp/manuserver-install.log` on the
  live system; the failure screen shows its last lines.
- Rerun by hand with `bash /root/installer.sh`.

## Changing the ISO

Try not to. The ISO is the slow part of the loop, and the repo hook at the end
of `lib/install.sh` exists so it doesn't have to change: everything the server
becomes is decided by `files/deploy/provision.sh`, which the *same ISO* runs
from a fresh clone at the end of every install. Iterate there with a push and a
reinstall, not here with a rebuild.

The installer clones from GitHub, so edits have to be pushed before an install
will see them.

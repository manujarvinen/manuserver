# manuserver install ISO

A custom Arch Linux ISO whose only job is to install a minimal Arch system
with a styled TUI installer. No desktop, no NetworkManager, no GRUB.

## The whole thing, start to finish

Two commands, from this directory:

```sh
./build_manuserver_iso.sh            # 1. build the ISO -> out/  (~20 min)
./run-manuserver-in-vm.sh install    # 2. install it into a VM
```

Then the VM *is* the server — start and stop it like one:

```sh
./run-manuserver-in-vm.sh            # start it in the background
./run-manuserver-in-vm.sh status     # up? on which ports?
./run-manuserver-in-vm.sh ssh mj     # get a shell on it
./run-manuserver-in-vm.sh stop       # ask it to shut down cleanly
```

There is no login step: the installed system autologins on tty1 and starts its
services at boot, so powering the VM on is all it takes.

### 1. `./build_manuserver_iso.sh`

Elevates itself with `sudo`, installs anything missing — `archiso`,
`qemu-desktop`, `edk2-ovmf`, `socat`, and your `kvm` group membership — then
overlays the installer onto archiso's stock `releng` profile and runs
`mkarchiso`. There is no separate setup step; this is the first command you
run on a new machine.

Expect 15–30 minutes and about 12 GB free (the finished ISO is roughly 1 GB;
the rest is the work tree, deleted afterwards).

```sh
KEEP_WORK=1 ./build_manuserver_iso.sh    # keep build/work/ to inspect it
```

If it had to add you to the `kvm` group, log out and back in before step 2 —
otherwise the VM falls back to software emulation, which works but is slow.

**Not on Arch?** Build in a container — the script prints this exact command
if it can't find `pacman`:

```sh
podman run --rm --privileged -v "$PWD/..":/repo archlinux \
  bash -c 'pacman -Sy --noconfirm archiso &&
           /repo/manuserver_bootable_iso/build_manuserver_iso.sh'
```

### 2. `./run-manuserver-in-vm.sh install`

Creates a fresh 20 GB virtual disk and boots the ISO in a window; the installer
starts on its own. Answer its four questions and it reboots into the installed
system. Everything is UEFI — the installer refuses to run under BIOS, so a BIOS
test would test nothing.

When the installer VM exits it offers to delete the ISO, which has done its job
by then and is a gigabyte. It defaults to keeping it — say `y` only if you
won't be reinstalling or writing a USB stick, since getting it back means
another twenty-minute build.

`./run-manuserver-in-vm.sh console` boots the installed system in a window
instead of the background, for when it won't come up and you need to watch it
try.

The one thing QEMU cannot exercise is the wifi picker: there is no virtual
wireless device. Test that on real hardware.

## Write it to a USB stick

```sh
lsblk                                   # identify the stick — get this wrong
                                        # and you erase the wrong disk
sudo dd bs=4M status=progress oflag=sync if=out/manuserver-*.iso of=/dev/sdX
```

Boot it with UEFI enabled and Secure Boot off (the ISO is unsigned).

## What the installer does

It asks four things and infers the rest:

1. **Network** — uses wired automatically if a cable is live; otherwise scans
   and offers an SSID list. Verifies real connectivity, not just an address.
2. **Username** — validated against the rule `useradd` enforces.
3. **Password** — twice, masked, with a `ctrl-r` reveal toggle.
4. **Disk** — auto-selected when there is only one, then a destructive
   confirmation that defaults to *No*.

Then it partitions (1 GB ESP + root), pacstraps, configures, installs
systemd-boot, creates the account, locks root, and clones this repo to
`/srv/manuserver` on the target.

Fixed without asking: keymap `us`, hostname `manu-server`, timezone `UTC`,
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
build_manuserver_iso.sh    builds the ISO        -> out/*.iso
run-manuserver-in-vm.sh    installs it into a VM, then runs that VM as a server
lib/host-tools.sh          host package list, shared by the two scripts above
overlay/root/         copied verbatim into the ISO's airootfs
  .zprofile           autostarts the installer on tty1 only
  installer.sh        flow control, one screen per question
  lib/ui.sh           palette, drawing, input widgets
  lib/network.sh      wired detection, wifi scan and connect
  lib/disk.sh         enumeration, confirmation, partitioning
  lib/install.sh      pacstrap, chroot config, bootloader, repo hook
build/, out/          generated, not in git
```

The logo comes from `../references/manuserver_logo.txt` and is copied into the
ISO at build time. It has to be: the installer runs from the live medium long
before the repo exists on the machine.

## Debugging a failing install

- The installer runs on **tty1 only**. `Alt+F2` gives a plain root shell on the
  live ISO while it is running.
- Everything long-running is logged to `/tmp/manuserver-install.log` on the
  live system; the failure screen shows its last lines.
- Rerun by hand with `bash /root/installer.sh`.

## Changing the ISO

Try not to. The ISO is the slow part of the loop, and the repo hook at the end
of `lib/install.sh` exists so it doesn't have to change: fill in
`server/deploy/provision.sh` in this repo and the *same ISO* installs the full
server. Iterate there with a push and a reinstall, not here with a rebuild.

That file currently holds a placeholder that installs nothing and only records
that it ran — enough to verify the chain works. Note that the installer clones
from GitHub, so edits to it have to be pushed before an install will see them.

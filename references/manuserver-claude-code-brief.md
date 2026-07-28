# Claude Code brief — `manuserver` install ISO

Build a custom Arch Linux ISO whose only job is to install a minimal Arch
system with a hand-written, visually styled TUI installer.

**Scope for this pass: the ISO and the installer only.** The server
application (Postgres, PHP, nginx) comes later — but wire in the hook for it
now, as described under *Repo hook*.

---

## Repo layout to produce

```
manuserver/
├── README.md
├── ref/                              # already in repo, read but don't modify
│   ├── manuserver_logo.txt           # block-ASCII logo
│   ├── visuals_manuserver.png        # colour + layout reference
│   ├── ref_username.png              # text-input screen reference
│   └── ref_wipe_disk.png             # confirm/toggle screen reference
└── iso/
    ├── build.sh                      # builds the .iso
    ├── run-vm.sh                     # boots it in QEMU
    └── overlay/root/
        ├── .zprofile                 # autostarts installer on tty1
        ├── installer.sh              # entry point / flow control
        └── lib/
            ├── ui.sh                 # drawing, palette, prompts, widgets
            ├── network.sh            # wired detect, wifi scan/connect
            ├── disk.sh               # detect, confirm, partition, format
            └── install.sh            # pacstrap, chroot config, bootloader
```

Look at the three PNGs in `ref/` before writing any UI code. They are the
spec for layout and colour.

---

## Decisions already made — do not revisit

**Root is locked.** `passwd -l root`. Administration goes through `sudo` via
the `wheel` group. One account, one password, one audit trail. The install ISO
is the rescue path if sudoers ever gets mangled.

**UEFI only**, systemd-boot as the loader. Bail out early with a clear message
if `/sys/firmware/efi` is absent. systemd-boot ships inside systemd, so it
costs no package — do not use GRUB.

**Networking is systemd-networkd + systemd-resolved + iwd.** No NetworkManager
— it's a large dependency tree for capability this box won't use.

**Preselected, never asked:** keymap `us`, hostname `manu-server`, timezone
`UTC`, locale `en_US.UTF-8`.

### Package set

Keep it genuinely minimal. Target:

```
base linux linux-firmware <ucode> sudo iwd iw openssh git
```

- `<ucode>` is `intel-ucode` or `amd-ucode`, chosen by reading `vendor_id`
  from `/proc/cpuinfo`. Add the matching `initrd` line to the boot entry —
  and only that one, since a boot entry referencing a missing initrd fails.
- `iw` is there purely because its scan output is machine-readable, unlike
  `iwctl`'s. See *WiFi* below.
- Put `linux-firmware` in a constant at the top of `install.sh` with a
  comment noting it's ~500MB and can be swapped for a vendor package
  (`linux-firmware-intel`, `-realtek`, `-atheros`) once the target hardware
  is known.

---

## Installer flow

Every step is a full-screen redraw: clear, logo, content. One question per
screen, as in the Omarchy references.

### 1. Network

Detect in this order and **do not ask anything you don't have to**:

1. **Wired carrier present** → done, say so briefly, move on. Test by reading
   `/sys/class/net/*/carrier` for interfaces that are neither `lo` nor
   wireless. Then wait for DHCP and verify real connectivity.
2. **No wired, wireless device exists** → run the SSID picker below.
3. **Neither** → fail with a clear message.

Verify connectivity properly — a link with no route out must count as
failure. Poll something small over HTTPS with a timeout, don't just check
that an IP was assigned.

#### WiFi picker (our own, not `nmtui`)

- `systemctl start iwd`, then `iw dev <iface> scan` — **parse `iw`, not
  `iwctl`**. `iwctl` output carries ANSI colour, column padding and an
  asterisk signal bar designed for human eyes; it's brittle across versions.
  `iw` emits parseable records. Pull SSID and signal strength, sort by
  strength, deduplicate.
- Present a numbered list. Include a final entry for **manual SSID entry**,
  so hidden networks work.
- Prompt for the passphrase, then connect with
  `iwctl --passphrase "$PASS" station <iface> connect "$SSID"`.
- A wrong passphrase fails *asynchronously* and iwd's error text is
  unhelpful. Wrap in a retry loop with a connectivity check and a plain
  "couldn't join that network — try again" message.
- Persist the credentials into the installed system so it rejoins on first
  boot: write an iwd PSK file to
  `/var/lib/iwd/<SSID>.psk` on the target, mode 600.

**This is the one component untestable in QEMU** — there is no virtual
wireless device. Build it last, and structure it so the wired path is
completely independent of it.

### 2. Username

Text input, styled per `ref_username.png`. Validate against
`^[a-z_][a-z0-9_-]{1,31}$` and re-prompt with a visible reason on failure.

### 3. Password

Entered twice, masked. Re-prompt on mismatch.

**Add a reveal toggle** (Ctrl-R, advertised in the hint line). This is not
decoration — the keymap is hardcoded `us`, and if this ever runs on a
Spanish keyboard, every symbol key is displaced. A layout mismatch produces
a *consistent* wrong password, so the double-entry check won't catch it, and
the result is a locked-out machine with no way to discover why. The reveal
toggle is the only thing that makes that visible.

### 4. Disk

- Enumerate with `lsblk -dpno NAME,TYPE`, keep type `disk`.
- **Exactly one disk → select it automatically**, just display which. This
  covers the VM and most laptops.
- More than one → numbered list with size and model.
- Then the destructive confirmation, styled exactly like
  `ref_wipe_disk.png`: two toggle buttons, `←`/`→` to move, `enter` to
  submit, `y`/`n` as direct shortcuts, default on **No**.

### 5. Install

Progress display while it works. Steps:

- Partition GPT: 1GB ESP (`ef00`), remainder root (`8304`).
  **Partition suffix**: `nvme0n1` → `nvme0n1p1`, but `vda` → `vda1`. Append
  `p` only for `nvme`/`mmcblk`/`loop` device names.
- `mkfs.fat -F32` on ESP, `mkfs.ext4` on root, mount at `/mnt` and
  `/mnt/boot`.
- `pacstrap -K`, then `genfstab -U`.
- Chroot config: locale, keymap, hostname, `/etc/hosts`, timezone,
  `hwclock --systohc`, wheel sudoers drop-in, enable
  `systemd-networkd systemd-resolved iwd sshd`, plus a DHCP `.network` unit
  for wired.
- `bootctl install` and a loader entry using `root=UUID=...` (read with
  `blkid -s UUID -o value`, not the partition path).
- User creation: `useradd -m -G wheel`, then **pipe the password into
  `chpasswd` from outside the chroot**. It must never be written to a file,
  not even a temporary one. Then `passwd -l root`.

### 6. Done

Summary screen, then reboot on keypress.

---

## Repo hook — wire it now, use it later

At the end of a successful install:

1. `git clone` `$REPO_URL` (a constant at the top of `installer.sh`) into
   `/srv/manuserver` on the target.
2. If the network is down, fall back to a copy baked into the ISO — have
   `build.sh` clone the repo into the airootfs at build time. This gives
   offline installs and fresh code from the same artifact.
3. **If `server/deploy/provision.sh` exists in the clone, run it under
   `arch-chroot`. If it doesn't, skip silently.**

Point 3 is the whole design: today's ISO installs bare Arch and stops. The
*same ISO*, unchanged, will install the full server the moment a provision
script is committed. The ISO should stop changing almost immediately — it's
the slow part of the loop, and everything downstream of the clone can be
iterated with a push and a reinstall.

Note for whoever writes `provision.sh` later: `arch-chroot` has no running
init, so it can `systemctl enable` but never `start`. Anything needing a live
service must defer to a first-boot one-shot unit.

---

## Visual specification

### Palette

The Linux framebuffer console **cannot do truecolor**. Get exact colours by
remapping the 16-colour palette at startup with OSC escapes —
`printf '\e]P%X%s' <index> <rrggbb>` (six hex digits, no `#`) — then use
ordinary SGR codes throughout. Reset the palette with `\e]R` on exit.

Sampled from `visuals_manuserver.png`; treat as a starting point and tune
against the image:

| Role | Index | Hex |
|---|---|---|
| background | 0 | `2E1522` |
| logo | 1 | `8F0B45` |
| body text | 5 | `A81558` |
| label / accent (bold) | 13 | `E81E80` |
| input text | 15 | `F2C8DC` |
| hint text (dim) | 8 | `7A1040` |
| cursor block | 9 | `FF2E95` |

Because index 0 becomes the maroon, a plain screen clear paints the whole
background correctly — no need to fill manually.

Hide the real cursor (`tput civis`, restore with `tput cnorm` on exit) and
draw the block cursor yourself as a reverse-video space in the cursor colour.

### Layout

Follow `ref_username.png` and `ref_wipe_disk.png`:

- Logo at top with a blank line beneath.
- Content block indented, left-aligned — **not** centred.
- Body line stating what's happening ("Let's setup your user account...").
- Prompt line: bold accent label, `>`, a space, then input and block cursor.
- Hint line in dim text at the bottom of the block listing the available
  keys, `•`-separated (`enter submit`, `↔ toggle • enter submit • y ... • n ...`).
- Toggle buttons render as reverse-video when selected, dim when not.

### Logo and the small-terminal fallback

Read `manuserver_logo.txt` at runtime. **Do not hardcode its dimensions** —
strip leading and trailing blank lines, then measure: width is the longest
line, height is the line count. It's currently ~100 columns by 7 rows.

If `tput cols` is less than the measured width plus margin, **or** `tput
lines` leaves too little room for the content below, fall back to rendering
the plain string `MANUSERVER` in the logo colour instead.

Expect this to fire: a default 80×25 VGA text console is narrower than the
logo, so the fallback path is a normal case, not an edge case. Make sure it
looks deliberate.

**The logo file must be copied into the ISO by `build.sh`** — into
`overlay/root/` or alongside the installer. The installer runs from the live
ISO long before any repo is cloned, so it cannot read `ref/` from the clone.
Getting this wrong produces an installer that works when tested by hand and
shows nothing on a real boot.

Console font: verify the default archiso font renders `▄ █ ▀` and `▸ ↔ •`.
If not, `setfont` to one that does before drawing anything.

---

## Build and test scripts

**`build.sh`** — copy `/usr/share/archiso/configs/releng` to a work dir,
overlay `overlay/` onto its `airootfs`, patch `profiledef.sh` for the ISO
name/label/publisher, run `mkarchiso`, output to `iso/out/`. Requires root;
`chown` the output back to `$SUDO_USER` afterwards.

Have `.zprofile` invoke the installer as `bash /root/installer.sh` rather
than executing it directly — that sidesteps needing the exec bit to survive
the `file_permissions` array in `profiledef.sh`. Only launch on `/dev/tty1`,
so Alt+F2 still gives a plain debugging shell, and drop to a shell with a
rerun hint if the installer exits non-zero.

**`run-vm.sh`** — `install` argument creates a fresh qcow2 and boots the ISO;
no argument boots the installed disk. Needs OVMF pflash drives (`edk2-ovmf`),
`-enable-kvm`, virtio disk and net, and host-forwards `8080→80` and
`2222→22`. Copy `OVMF_VARS` to a local writable NVRAM file rather than using
the read-only system one.

---

## Style

Bash, `set -euo pipefail`, shellcheck-clean. Comment the *why*, not the
*what* — especially around the palette remapping, the `iw`-versus-`iwctl`
choice, the partition suffix rule, and the logo-baking requirement, since
each of those looks arbitrary until it breaks.

No dependency on anything outside the archiso live environment.

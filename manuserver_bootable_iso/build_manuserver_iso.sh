#!/usr/bin/env bash
#
# build_manuserver_iso.sh — produce the manuserver install ISO.
#
#   ./build_manuserver_iso.sh              build, output to ./out/
#   KEEP_WORK=1 ./build_manuserver_iso.sh  keep the (large) work directory
#
# No setup step comes before this. It installs the build and VM tooling if the
# machine doesn't have it, and elevates itself with sudo.
#
# Takes archiso's stock `releng` profile, drops our installer on top of its
# airootfs, renames the medium, and runs mkarchiso. Nothing about the profile
# itself is customised beyond the overlay and the identifying strings: the
# less this diverges from releng, the less it breaks when archiso moves.
#
# The ISO deliberately carries no copy of the manuserver repo. It is an
# installer, the same way the official Arch medium is; the repo is cloned over
# the network at the end of an install.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$HERE")"
readonly HERE REPO_ROOT
readonly PROFILE="$HERE/build/profile"
readonly WORK="$HERE/build/work"
readonly OUT="$HERE/out"
readonly RELENG=/usr/share/archiso/configs/releng
readonly LOGO="$REPO_ROOT/references/manuserver_logo.txt"

# 11 characters is the hard limit for a FAT volume label, and archiso uses
# iso_label as exactly that. Longer values fail late, inside mkfs.fat.
ISO_LABEL="MSRV_$(date +%Y%m)"
readonly ISO_LABEL

die() { printf 'build_manuserver_iso.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

# shellcheck source=lib/host-tools.sh
source "$HERE/lib/host-tools.sh"

# --- preflight -------------------------------------------------------------

# mkarchiso needs root for the loop mounts and for owning files in the
# airootfs. Rather than failing with "run me under sudo", just do it -- this
# is meant to be the first command anyone runs.
if ((EUID != 0)); then
  command -v sudo >/dev/null || die "must run as root, and sudo is not installed"
  say "elevating with sudo"
  exec sudo --preserve-env=KEEP_WORK -- "$HERE/build_manuserver_iso.sh" "$@"
fi

# The ISO can only be assembled on an Arch host (or an Arch container/chroot):
# mkarchiso pacstraps the live system with the host's pacman.
command -v pacman >/dev/null ||
  die "this needs an Arch Linux host — pacman was not found.
     On another distro, build inside an Arch container:
       podman run --rm --privileged -v \"$REPO_ROOT\":/repo archlinux \\
         bash -c 'pacman -Sy --noconfirm archiso &&
                  /repo/manuserver_bootable_iso/build_manuserver_iso.sh'"

# Installs the VM tooling too, not just archiso: doing it here means the next
# step -- installing this ISO into a VM -- has nothing left to set up.
host_tools_ensure mkarchiso qemu-system-x86_64 socat

[[ -d $RELENG ]] || die "archiso is installed but $RELENG is missing"
[[ -r $LOGO ]] || die "logo not found at $LOGO — is the repo complete?"

# mkarchiso needs room for the work tree plus the ISO. Running out halfway
# through wastes twenty minutes and leaves a confusing pacstrap error.
avail=$(df -BG --output=avail "$HERE" | tail -n1 | tr -dc '0-9')
if [[ -n $avail ]] && ((avail < 12)); then
  die "only ${avail}G free on $HERE — the build needs about 12G"
fi

# --- assemble the profile --------------------------------------------------

say "copying the releng profile"
rm -rf "$PROFILE"
install -d "$(dirname "$PROFILE")"
cp -a "$RELENG" "$PROFILE"

say "overlaying the installer"
cp -a "$HERE/overlay/." "$PROFILE/airootfs/"

# The installer runs from the live medium long before any repo exists on the
# machine, so it cannot read the logo out of a clone. It has to be baked in
# here or the real boot shows a blank header while hand-testing looks fine.
say "baking in the logo"
install -m 644 "$LOGO" "$PROFILE/airootfs/root/manuserver_logo.txt"

# releng's package list is not a contract -- it has gained and lost packages
# between releases. Naming what the installer actually calls means a future
# releng that drops `iw` produces a broken wifi picker at install time rather
# than here, where it is cheap to notice.
say "adding the installer's own tools to the medium"
for pkg in iwd iw curl gptfdisk dosfstools e2fsprogs arch-install-scripts git terminus-font; do
  grep -qxF "$pkg" "$PROFILE/packages.x86_64" || printf '%s\n' "$pkg" >>"$PROFILE/packages.x86_64"
done

say "renaming the medium"
sed -i \
  -e 's|^iso_name=.*|iso_name="manuserver"|' \
  -e "s|^iso_label=.*|iso_label=\"$ISO_LABEL\"|" \
  -e 's|^iso_publisher=.*|iso_publisher="manujarvinen <https://github.com/manujarvinen/manuserver>"|' \
  -e 's|^iso_application=.*|iso_application="manuserver install medium"|' \
  "$PROFILE/profiledef.sh"

# --- build -----------------------------------------------------------------

say "running mkarchiso (this takes a while and wants a few GB)"
install -d "$OUT"
rm -rf "$WORK"
mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

if [[ ${KEEP_WORK:-0} != 1 ]]; then
  say "cleaning up the work directory"
  rm -rf "$WORK"
fi

# mkarchiso runs as root, so without this the ISO lands owned by root in the
# user's own tree.
if [[ -n ${SUDO_USER:-} ]]; then
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$OUT" "$HERE/build" 2>/dev/null || true
fi

iso=$({ find "$OUT" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' || true; } |
      sort -rn | head -n1 | cut -d' ' -f2-)
[[ -n $iso ]] || die "mkarchiso reported success but no ISO landed in $OUT"

say "done: $iso"

cat <<EOF

Next:
  install it into a VM   ./run-manuserver-in-vm.sh install
  then run the server    ./run-manuserver-in-vm.sh
                         ./run-manuserver-in-vm.sh stop
  or write it to a USB   lsblk                # identify the stick first
                         sudo dd bs=4M status=progress oflag=sync \\
                              if=$iso of=/dev/sdX
EOF

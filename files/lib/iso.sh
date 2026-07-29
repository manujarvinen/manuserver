# shellcheck shell=bash
#
# iso.sh — produce the manuserver install ISO.
#
# Takes archiso's stock `releng` profile, drops our installer on top of its
# airootfs, renames the medium, and runs mkarchiso. Nothing about the profile
# itself is customised beyond the overlay and the identifying strings: the
# less this diverges from releng, the less it breaks when archiso moves.
#
# The ISO deliberately carries no copy of the manuserver repo. It is an
# installer, the same way the official Arch medium is; the repo is cloned over
# the network at the end of an install.
#
# Sourced by manuserver.sh. Defines functions and runs nothing.

readonly RELENG=/usr/share/archiso/configs/releng

cmd_build_iso() {
  local profile="$ISO_DIR/build/profile"
  local work="$ISO_DIR/build/work"
  local logo="$ROOT/files/references/manuserver_logo.txt"
  local iso_label avail pkg iso

  # 11 characters is the hard limit for a FAT volume label, and archiso uses
  # iso_label as exactly that. Longer values fail late, inside mkfs.fat.
  iso_label="MSRV_$(date +%Y%m)"

  # --- preflight ------------------------------------------------------------

  # mkarchiso needs root for the loop mounts and for owning files in the
  # airootfs. Rather than failing with "run me under sudo", just do it — this
  # is meant to be the first command anyone runs.
  if ((EUID != 0)); then
    command -v sudo >/dev/null || die "must run as root, and sudo is not installed"
    say "elevating with sudo"
    exec sudo --preserve-env=KEEP_WORK -- "$SELF_PATH" build_iso "$@"
  fi

  # The ISO can only be assembled on an Arch host (or an Arch container/chroot):
  # mkarchiso pacstraps the live system with the host's pacman.
  command -v pacman >/dev/null ||
    die "this needs an Arch Linux host — pacman was not found.
     On another distro, build inside an Arch container:
       podman run --rm --privileged -v \"$ROOT\":/repo archlinux \\
         bash -c 'pacman -Sy --noconfirm archiso && /repo/manuserver.sh build_iso'"

  # Installs the VM tooling too, not just archiso: doing it here means the next
  # step — installing this ISO into a VM — has nothing left to set up.
  host_tools_ensure mkarchiso qemu-system-x86_64 socat

  [[ -d $RELENG ]] || die "archiso is installed but $RELENG is missing"
  [[ -r $logo ]] || die "logo not found at $logo — is the checkout complete?"

  # mkarchiso needs room for the work tree plus the ISO. Running out halfway
  # through wastes twenty minutes and leaves a confusing pacstrap error.
  avail=$(df -BG --output=avail "$ISO_DIR" | tail -n1 | tr -dc '0-9')
  if [[ -n $avail ]] && ((avail < 12)); then
    die "only ${avail}G free on $ISO_DIR — the build needs about 12G"
  fi

  # --- assemble the profile -------------------------------------------------

  say "copying the releng profile"
  rm -rf "$profile"
  install -d "$(dirname "$profile")"
  cp -a "$RELENG" "$profile"

  say "overlaying the installer"
  cp -a "$ISO_DIR/overlay/." "$profile/airootfs/"

  # The installer runs from the live medium long before any repo exists on the
  # machine, so it cannot read the logo out of a clone. It has to be baked in
  # here or the real boot shows a blank header while hand-testing looks fine.
  say "baking in the logo"
  install -m 644 "$logo" "$profile/airootfs/root/manuserver_logo.txt"

  # releng's package list is not a contract — it has gained and lost packages
  # between releases. Naming what the installer actually calls means a future
  # releng that drops `iw` produces a broken wifi picker at install time rather
  # than here, where it is cheap to notice.
  say "adding the installer's own tools to the medium"
  # kbd matters more than it looks: the installer uses psfgettable to find out
  # which glyphs the console font actually has, and setfont to switch to one
  # that can draw the logo.
  for pkg in iwd iw curl gptfdisk dosfstools e2fsprogs arch-install-scripts git kbd; do
    grep -qxF "$pkg" "$profile/packages.x86_64" || printf '%s\n' "$pkg" >>"$profile/packages.x86_64"
  done

  say "renaming the medium"
  sed -i \
    -e 's|^iso_name=.*|iso_name="manuserver"|' \
    -e "s|^iso_label=.*|iso_label=\"$iso_label\"|" \
    -e 's|^iso_publisher=.*|iso_publisher="manujarvinen <https://github.com/manujarvinen/manuserver>"|' \
    -e 's|^iso_application=.*|iso_application="manuserver install medium"|' \
    "$profile/profiledef.sh"

  # --- build ----------------------------------------------------------------

  say "running mkarchiso (this takes a while and wants a few GB)"
  rm -rf "$work"
  mkarchiso -v -w "$work" -o "$ISO_OUT" "$profile"

  if [[ ${KEEP_WORK:-0} != 1 ]]; then
    say "cleaning up the work directory"
    rm -rf "$work"
  fi

  iso=$(newest_iso)
  [[ -n $iso ]] || die "mkarchiso reported success but no ISO landed in $ISO_OUT"

  # mkarchiso runs as root, so without this the ISO lands owned by root in the
  # user's own tree.
  #
  # Named files only. ISO_OUT is now the repo root, and a recursive chown there
  # would rewrite ownership of the entire checkout — including .git — as a side
  # effect of building.
  if [[ -n ${SUDO_USER:-} ]]; then
    chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$iso" 2>/dev/null || true
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$ISO_DIR/build" 2>/dev/null || true
  fi

  say "done: $iso"

  cat <<EOF

Next:
  install it into a VM   ./manuserver.sh vm_install
  then run the server    ./manuserver.sh
                         ./manuserver.sh vm_stop
  or write it to a USB   caligula burn -z none $iso
                         (pacman -S caligula; it lists the disks and you pick
                          one, so there is no device path to mistype)
EOF
}

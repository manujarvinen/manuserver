# shellcheck shell=bash
#
# host-tools.sh — what this machine needs installed to build the ISO and run
# the VM, and how to get it.
#
# Not a script you run. It is sourced by files/lib/iso.sh and files/lib/vm.sh,
# both of which install what they are missing when
# they are missing it. The list lives here, in one place, so the two callers
# cannot drift apart.

# archiso        builds the ISO (pulls in arch-install-scripts, squashfs-tools,
#                libisoburn, mtools)
# qemu-desktop   runs the VM
# edk2-ovmf      UEFI firmware for it -- the installer is UEFI-only, so a
#                BIOS-booted VM would test nothing
# socat          talks to QEMU's monitor socket, which is how the `stop` verb
#                asks the guest to shut down cleanly instead of pulling the
#                power
# git            clones the manuserver repo; already present if you got this
#                far, but named so the list is complete
readonly HOST_PACKAGES=(archiso qemu-desktop edk2-ovmf socat git)

ht_say() { printf '\n==> %s\n' "$*"; }
ht_note() { printf '    %s\n' "$*"; }
ht_die() { printf 'host-tools: %s\n' "$*" >&2; exit 1; }

# pacman needs root; the group check below needs to know the real user. Elevate
# only around the commands that require it.
ht_as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    command -v sudo >/dev/null || ht_die "not root and sudo is not installed"
    sudo "$@"
  fi
}

# host_tools_ensure <command...> — if any of the named commands is absent,
# install the whole package set. Installing all of it rather than only the
# missing piece means building the ISO also sets up the VM, and the run script
# never stops to install something mid-flow.
host_tools_ensure() {
  local c missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null || missing=1
  done
  ((missing)) || return 0

  command -v pacman >/dev/null || ht_die \
    "this needs an Arch Linux host — pacman was not found (the README has the
     container route for other distros)"

  local -a want=()
  local pkg
  for pkg in "${HOST_PACKAGES[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || want+=("$pkg")
  done

  if ((${#want[@]})); then
    ht_say "installing build and VM tooling: ${want[*]}"
    ht_as_root pacman -Sy --needed --noconfirm "${want[@]}" ||
      ht_die "package installation failed — try: sudo pacman -S ${want[*]}"
  fi

  host_kvm_setup
}

# Without kvm group membership the VM still runs, just under software
# emulation, which turns a five-minute install into a very long one.
host_kvm_setup() {
  local user=${SUDO_USER:-${USER:-root}}

  if [[ ! -e /dev/kvm ]]; then
    ht_say "no /dev/kvm on this machine"
    ht_note "virtualisation is unsupported or disabled in firmware; the VM"
    ht_note "will use software emulation instead — slow, but correct."
    return 0
  fi

  if [[ -r /dev/kvm && -w /dev/kvm ]] || [[ $user == root ]]; then
    return 0
  fi

  if ! id -nG "$user" 2>/dev/null | grep -qw kvm; then
    ht_say "adding $user to the kvm group"
    ht_as_root usermod -aG kvm "$user" || return 0
  fi

  ht_note "the kvm group is not active in this shell yet — log out and back in"
  ht_note "(or run: newgrp kvm). Until then the VM falls back to software"
  ht_note "emulation, which works but is slow."
}

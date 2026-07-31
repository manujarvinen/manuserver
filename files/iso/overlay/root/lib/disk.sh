# shellcheck shell=bash
#
# disk.sh — pick a target disk, get destructive consent, lay down the layout.

DISK=''        # whole-disk device, e.g. /dev/vda
PART_ESP=''    # e.g. /dev/vda1
PART_ROOT=''   # e.g. /dev/vda2

# Kernel naming splits two ways: sd*/vd* append the partition number directly
# (vda -> vda1), while namespaced devices need a `p` separator
# (nvme0n1 -> nvme0n1p1). Getting this wrong produces device paths that do not
# exist and a mkfs that fails several steps later.
disk_part_suffix() {
  case ${1##*/} in
    nvme*|mmcblk*|loop*) printf 'p' ;;
    *)                   printf '' ;;
  esac
}

disk_set() {
  DISK=$1
  local sep
  sep=$(disk_part_suffix "$DISK")
  PART_ESP="${DISK}${sep}1"
  PART_ROOT="${DISK}${sep}2"
}

# Whole disks only — partitions, CD-ROMs and the live medium's loop devices
# are not install targets.
#
# `type == disk` is necessary and not sufficient. lsblk calls zram a disk, so a
# machine with compressed swap offers a 4G RAM device in the menu next to the
# real one, and picking it wastes an install on something that does not survive
# a reboot. Everything excluded here is memory-backed and belongs to the
# running system rather than to the machine.
disk_candidates() {
  local name type
  while read -r name type; do
    case ${name##*/} in
      zram*|ram*|loop*|fd*) continue ;;
    esac
    if [[ $type == disk ]]; then printf '%s\n' "$name"; fi
  done < <(lsblk -dpno NAME,TYPE)
}

disk_describe() {
  local dev=$1 size model
  size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
  model=$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')
  printf '%-14s %8s  %s' "$dev" "$size" "${model:-unknown model}"
}

# One disk is the normal case (the VM, most laptops) and asking about it is a
# question with one answer. Show it, don't ask it.
disk_choose() {
  local -a disks=() labels=()
  local dev

  while read -r dev; do disks+=("$dev"); done < <(disk_candidates)

  if ((${#disks[@]} == 0)); then
    ui_fatal "No disks were detected." \
             "This installer needs a writable disk to install onto."
  fi

  if ((${#disks[@]} == 1)); then
    disk_set "${disks[0]}"
    ui_screen
    ui_body "Let's select where to install manuserver..."
    ui_blank
    ui_body "One disk found: $(disk_describe "$DISK")"
    ui_blank
    sleep 2
    return 0
  fi

  for dev in "${disks[@]}"; do labels+=("$(disk_describe "$dev")"); done

  ui_screen
  ui_body "Let's select where to install manuserver..."
  ui_blank
  ui_menu "Disk" "${labels[@]}"
  disk_set "${disks[$((UI_RESULT - 1))]}"
}

# The point of no return. Defaults to No.
disk_confirm() {
  ui_screen
  ui_body "Let's select where to install manuserver..."
  ui_body "Everything will be overwritten. There is no recovery possible."
  ui_blank
  ui_line "$S_ACCENT" "Confirm overwriting $DISK"
  # Spell out which disk this actually is. On a machine with more than one, the
  # device name alone is not enough to tell them apart, and this is the last
  # screen before the data is gone.
  ui_line "$S_BODY" "  $(disk_describe "$DISK")"
  ui_blank
  if ui_confirm "Yes, format disk" "No, change it"; then
    return 0
  fi
  return 1
}

# --- letting go of a disk the machine is still holding -----------------------
#
# A fresh qcow2 has nothing on it, so the VM never once needed any of this.
# Real hardware arrives with the last install still on the disk, and the live
# medium's udev does not merely see it — it *claims* it, before the installer
# has drawn its first screen.
#
# A claimed device is busy, and the tools say so a long way from where it went
# wrong:
#
#   wipefs: /dev/nvme0n1: probing initialization failed: Device or resource busy
#   /dev/nvme0n1p2 is apparently in use by the system; will not make a filesystem here!
#
# Both come from the same thing: the kernel refuses an exclusive open, which is
# what wipefs and mkfs both need. Opening a whole disk exclusively also fails
# when only one of its partitions is held, which is why the first message names
# the disk for a problem that lives one level down.
#
# There are two ways a disk gets claimed, and only one of them is the obvious
# one:
#
#   Stacked devices. An LVM volume group, an md array or a LUKS container gets
#   activated on sight, putting a device-mapper node on top of the partition.
#   This is the case everyone writes about, and it is visible in lsblk.
#
#   btrfs registration. btrfs-progs ships a udev rule that runs `btrfs device
#   scan` on every device carrying a btrfs signature. That registers it with
#   the kernel module, which then holds it — with nothing mounted, nothing in
#   lsblk's tree, and nothing in /sys/class/block/*/holders to see. The disk
#   simply refuses to be written to. This is what a plain Arch install with a
#   btrfs root looks like to this installer, which is to say: the ordinary
#   case on real hardware, and the one that actually bit.
#
# None of what follows is tidiness. It is the difference between installing
# onto a disk somebody used before and not.

# The kernel's own name for a device — dm-0 rather than
# /dev/mapper/ArchinstallVg-root — which is the only form /sys is indexed by.
disk_kernel_name() {
  local path
  path=$(readlink -f -- "$1" 2>/dev/null) || return 1
  [[ -n $path ]] || return 1
  printf '%s' "${path##*/}"
}

# Everything the kernel has stacked on $DISK, deepest first. lsblk lists a
# parent before its children, so reversing it puts the filesystem ahead of the
# volume it sits in — which is the order things have to be taken apart in.
disk_stack() {
  local -a stack=()
  local dev
  while read -r dev; do stack=("$dev" "${stack[@]}"); done \
    < <(lsblk -nrpo NAME "$DISK" 2>/dev/null || true)
  ((${#stack[@]})) && printf '%s\n' "${stack[@]}"
  return 0
}

# Volume groups with a foot on this disk. vgchange rather than picking the
# mappings off one by one: a group can span several disks, and its own tool is
# the only thing that knows that.
disk_volume_groups() {
  command -v pvs >/dev/null || return 0
  local dev
  while read -r dev; do
    pvs --noheadings -o vg_name "$dev" 2>/dev/null || true
  done < <(disk_stack) | tr -d ' ' | grep -v '^$' | sort -u
  return 0
}

# Devices on this disk carrying a btrfs signature — which, on a live medium
# that has udev, means devices the kernel has registered and is holding.
#
# Detected by signature rather than by asking btrfs what it has registered:
# `btrfs filesystem show` scans on its own and cannot be made to answer the
# narrower question. Over-broad in one harmless direction — an unregistered
# btrfs is un-registered again, which is a no-op.
disk_btrfs_members() {
  local dev fstype
  while read -r dev fstype; do
    if [[ $fstype == btrfs ]]; then printf '%s\n' "$dev"; fi
  done < <(lsblk -nrpo NAME,FSTYPE "$DISK" 2>/dev/null || true)
  return 0
}

# Everything that would refuse an exclusive open, or is about to be released so
# that it stops. Bare partitions do not count — they are going to be
# overwritten and hold nothing open.
disk_holders() {
  local dev name
  while read -r dev; do
    name=$(disk_kernel_name "$dev") || continue
    if [[ -d /sys/class/block/$name/dm || -d /sys/class/block/$name/md ]]; then
      printf '%s\n' "$dev"
    elif findmnt -nro TARGET --source "$dev" >/dev/null 2>&1; then
      printf '%s\n' "$dev"
    fi
  done < <(disk_stack)

  disk_btrfs_members
  return 0
}

disk_release() {
  local dev name vg

  # A disk with nothing on it: no mounts, nothing stacked, no btrfs to hand
  # back. That is a blank disk and every install into the VM, which is why none
  # of this was ever needed there.
  [[ -n $(disk_holders) ]] || return 0

  ui_step "releasing $DISK from its previous install"

  for dev in $(disk_stack); do
    swapoff "$dev" >>"$UI_LOG" 2>&1 || true
    # -A unmounts every mountpoint this device has, not just the first one.
    umount -A -q "$dev" >>"$UI_LOG" 2>&1 || true
  done

  for vg in $(disk_volume_groups); do
    vgchange -an "$vg" >>"$UI_LOG" 2>&1 || true
  done

  # Re-read the stack: deactivating the groups above has already removed most
  # of what was in it. What can be left is an md array, a LUKS mapping, or a
  # group whose metadata is too damaged for vgchange to own up to it — so this
  # pass goes by what the kernel says is there rather than by what made it.
  for dev in $(disk_stack); do
    name=$(disk_kernel_name "$dev") || continue
    if [[ -d /sys/class/block/$name/md ]]; then
      mdadm --stop "$dev" >>"$UI_LOG" 2>&1 || true
    elif [[ -d /sys/class/block/$name/dm ]]; then
      dmsetup remove --retry "$dev" >>"$UI_LOG" 2>&1 || true
    fi
  done

  # Hand every btrfs member back. `scan --forget` is the counterpart to the
  # scan udev did on our behalf: it drops the device from the kernel's registry
  # and, with it, the hold that makes wipefs and mkfs fail. Nothing in lsblk
  # ever showed this, so there is nothing to check afterwards either — which is
  # why it is done unconditionally rather than in response to a symptom.
  if command -v btrfs >/dev/null; then
    for dev in $(disk_btrfs_members); do
      btrfs device scan --forget "$dev" >>"$UI_LOG" 2>&1 || true
    done
  fi

  udevadm settle >/dev/null 2>&1 || true
}

disk_partition() {
  disk_release

  # Signatures come off the partitions before the table that names them does.
  # Wiping only the whole disk leaves a btrfs, LVM or md signature sitting at
  # the same offset inside the new layout, and udev claims it again the moment
  # partprobe announces the partitions — putting back exactly the hold
  # disk_release just removed, in time to block mkfs.
  local part
  for part in $(disk_stack); do
    [[ $part == "$DISK" ]] && continue
    wipefs -a "$part" >>"$UI_LOG" 2>&1 || true
  done

  # Signatures before the partition table, and this order is the whole point.
  #
  # It used to be sgdisk first. wipefs is the step that fails on a disk
  # something still holds, so failing in that order meant the GPT was already
  # destroyed by the time the installer found out it could not continue —
  # the disk's contents gone *and* nothing installed. Reversed, a disk this
  # installer cannot have is a disk it has not touched.
  if ! wipefs -a "$DISK" >>"$UI_LOG" 2>&1; then
    ui_fatal "$DISK is in use by this machine and cannot be written to." \
             "" \
             "Nothing has been changed on it — this check runs before anything" \
             "is erased." \
             "" \
             "Something claimed the disk after the installer released it, or" \
             "held it in a way the release did not cover. From the shell" \
             "below:" \
             "" \
             "  lsblk $DISK                       # what is on it" \
             "  btrfs device scan --forget        # release btrfs members" \
             "  vgchange -an                      # deactivate volume groups" \
             "  wipefs -a $DISK                   # should now succeed" \
             "  bash /root/installer.sh"
  fi
  ui_step "cleared filesystem signatures"

  ui_run "wiping $DISK" sgdisk --zap-all "$DISK"
  ui_run "creating GPT layout" sgdisk \
    -n 1:0:+1G -t 1:ef00 -c 1:ESP \
    -n 2:0:0   -t 2:8304 -c 2:root \
    "$DISK"
  ui_run "settling devices" partprobe "$DISK"
  udevadm settle >/dev/null 2>&1 || true

  # partprobe can report success and still leave the kernel on the old table if
  # anything reopened the disk behind us. Saying so here names the disk; the
  # same problem discovered by mkfs names a path that does not exist.
  for part in "$PART_ESP" "$PART_ROOT"; do
    [[ -b $part ]] && continue
    ui_fatal "The new partitions did not appear on $DISK." \
             "" \
             "Expected $part, and the kernel does not have it. The partition" \
             "table was written, so this is usually something reopening the" \
             "disk. Reboot from this medium and install again."
  done
}

disk_format() {
  ui_run "formatting ESP" mkfs.fat -F32 -n ESP "$PART_ESP"
  ui_run "formatting root" mkfs.ext4 -F -L manuserver "$PART_ROOT"
}

disk_mount() {
  ui_run "mounting root" mount "$PART_ROOT" /mnt
  ui_run "mounting ESP" mount --mkdir "$PART_ESP" /mnt/boot
}

# Wrapper for the whole phase; loops back to selection if consent is refused.
disk_setup() {
  while :; do
    disk_choose
    disk_confirm && break
  done
}

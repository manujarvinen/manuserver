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
disk_candidates() {
  local name type
  while read -r name type; do
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
  ui_blank
  if ui_confirm "Yes, format disk" "No, change it"; then
    return 0
  fi
  return 1
}

disk_partition() {
  ui_run "wiping $DISK" sgdisk --zap-all "$DISK"
  ui_run "clearing filesystem signatures" wipefs -a "$DISK"
  ui_run "creating GPT layout" sgdisk \
    -n 1:0:+1G -t 1:ef00 -c 1:ESP \
    -n 2:0:0   -t 2:8304 -c 2:root \
    "$DISK"
  ui_run "settling devices" partprobe "$DISK"
  udevadm settle >/dev/null 2>&1 || true
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

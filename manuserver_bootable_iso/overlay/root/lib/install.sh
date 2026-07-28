# shellcheck shell=bash
#
# install.sh — pacstrap, chroot configuration, bootloader, user, repo hook.

# Deliberately small. Every package here earns its place:
#   iwd     wireless, without NetworkManager's dependency tree
#   iw      only for its machine-readable scan output (see network.sh)
#   openssh how this box is administered once the installer is gone
#   git     needed by the repo hook at the end of this file
#
# linux-firmware is ~500MB of blobs for hardware this machine mostly does not
# have. Once the target hardware is known, swap it for the vendor split
# package — linux-firmware-intel, linux-firmware-realtek, linux-firmware-atheros
# — and reclaim most of that.
readonly FIRMWARE_PKG='linux-firmware'
readonly BASE_PACKAGES=(base linux "$FIRMWARE_PKG" sudo iwd iw openssh git)

readonly TARGET_HOSTNAME='manu-server'
readonly TARGET_LOCALE='en_US.UTF-8'
readonly TARGET_KEYMAP='us'
readonly TARGET_TIMEZONE='UTC'

UCODE=''   # intel-ucode | amd-ucode

# A boot entry that names an initrd which was never installed fails to boot,
# so the ucode package and the loader entry have to agree. Both are derived
# from this one read.
install_detect_ucode() {
  case $(grep -m1 '^vendor_id' /proc/cpuinfo | awk '{print $3}') in
    GenuineIntel) UCODE='intel-ucode' ;;
    AuthenticAMD) UCODE='amd-ucode' ;;
    *)            UCODE='' ;;
  esac
}

install_base() {
  local -a pkgs=("${BASE_PACKAGES[@]}")
  if [[ -n $UCODE ]]; then pkgs+=("$UCODE"); fi

  ui_run "installing base system (this takes a while)" pacstrap -K /mnt "${pkgs[@]}"
  ui_step "writing fstab"
  genfstab -U /mnt >>/mnt/etc/fstab 2>>"$UI_LOG" || ui_fatal_log "writing fstab"
}

install_configure() {
  local username=$1

  ui_step "configuring the system"
  arch-chroot /mnt /bin/bash -s -- \
    "$username" "$TARGET_HOSTNAME" "$TARGET_LOCALE" "$TARGET_KEYMAP" "$TARGET_TIMEZONE" \
    >>"$UI_LOG" 2>&1 <<'CHROOT' || ui_fatal_log "configuring the system"
set -euo pipefail
username=$1 hostname=$2 locale=$3 keymap=$4 timezone=$5

ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc

sed -i "s/^#\\(${locale} UTF-8\\)/\\1/" /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$locale" >/etc/locale.conf
printf 'KEYMAP=%s\n' "$keymap" >/etc/vconsole.conf

printf '%s\n' "$hostname" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${hostname}.localdomain	${hostname}
EOF

# Administration goes through sudo; root itself is locked further down. A
# drop-in rather than an edit to /etc/sudoers so a package update never
# prompts about a modified file.
printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c -f /etc/sudoers.d/10-wheel

# networkd handles addressing for both wired and wireless; iwd is left to do
# only authentication, which is its default when EnableNetworkConfiguration
# is unset.
cat >/etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

cat >/etc/systemd/network/25-wireless.network <<'EOF'
[Match]
Name=wl*

[Network]
DHCP=yes
EOF

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

systemctl enable systemd-networkd systemd-resolved iwd sshd

useradd -m -G wheel -s /bin/bash "$username"

# Autologin on the console. This machine is meant to be powered on and be a
# server -- starting the VM should be all it takes, with no login step in
# between. The trade-off is real and worth stating: anyone at the console (or
# at the VM window) gets this user's shell, and via wheel, sudo. Physical
# access is the trust boundary. SSH is unaffected and still asks for the
# password.
install -d /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${username} --noclear %I \$TERM
EOF
CHROOT
}

install_bootloader() {
  local uuid

  ui_run "installing systemd-boot" arch-chroot /mnt bootctl install

  # The partition path is not stable across boots (device enumeration order,
  # added disks); the filesystem UUID is.
  uuid=$(blkid -s UUID -o value "$PART_ROOT")
  [[ -n $uuid ]] || ui_fatal_log "reading root UUID"

  ui_step "writing boot entry"
  {
    printf 'default manuserver.conf\ntimeout 3\nconsole-mode max\neditor no\n' \
      >/mnt/boot/loader/loader.conf

    printf 'title   manuserver\nlinux   /vmlinuz-linux\n' >/mnt/boot/loader/entries/manuserver.conf
    if [[ -n $UCODE ]]; then
      printf 'initrd  /%s.img\n' "$UCODE" >>/mnt/boot/loader/entries/manuserver.conf
    fi
    printf 'initrd  /initramfs-linux.img\noptions root=UUID=%s rw\n' "$uuid" \
      >>/mnt/boot/loader/entries/manuserver.conf
  } 2>>"$UI_LOG" || ui_fatal_log "writing boot entry"
}

# The password reaches chpasswd through a pipe and nothing else. It is never
# an argument (visible in ps), never a heredoc (bash may back one with a temp
# file), and never written to the log.
install_account() {
  local username=$1 password=$2

  ui_step "setting the password"
  if ! printf '%s:%s\n' "$username" "$password" | arch-chroot /mnt chpasswd 2>>"$UI_LOG"; then
    ui_fatal_log "setting the password"
  fi

  # One account, one password, one audit trail. The install ISO is the rescue
  # path if the sudoers drop-in above ever gets mangled.
  ui_run "locking the root account" arch-chroot /mnt passwd -l root
}

# --- repo hook -------------------------------------------------------------
#
# This is the part that makes the ISO stop changing. The ISO installs bare
# Arch and stops. The moment server/deploy/provision.sh is committed to the
# repo, the *same ISO* installs the full server — no rebuild. Everything
# downstream of this clone iterates with a push and a reinstall.
install_repo() {
  local repo_url=$1
  local target=/mnt/srv/manuserver

  install -d -m 755 /mnt/srv

  # The ISO carries no copy of the repo — same as the official Arch ISO, it is
  # an installer and nothing else. A failed clone is therefore not fatal: the
  # base system is complete and installable without it, and the repo can be
  # cloned by hand after first boot.
  ui_step "fetching the manuserver repo"
  if ! git clone --depth 1 "$repo_url" "$target" >>"$UI_LOG" 2>&1; then
    ui_step "repo unavailable — skipping (the base system is still complete)"
    return 0
  fi

  # arch-chroot has no running init, so provision.sh can `systemctl enable`
  # but never `start`. Anything needing a live service must defer to a
  # first-boot one-shot unit.
  if [[ -x $target/server/deploy/provision.sh || -f $target/server/deploy/provision.sh ]]; then
    ui_run "provisioning the server" arch-chroot /mnt bash /srv/manuserver/server/deploy/provision.sh
  fi
}

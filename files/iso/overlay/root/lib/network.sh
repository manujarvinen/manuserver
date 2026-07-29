# shellcheck shell=bash
#
# network.sh — get the live environment online with as few questions as
# possible, then persist whatever was needed so the installed system comes
# back up on its own.
#
# Nothing below is exercised by the QEMU test loop except the wired path;
# there is no virtual wireless device. The wired path therefore never calls
# into the wifi code, and the wifi code is the last thing to touch.

readonly NET_PROBE_URL="https://archlinux.org/"
readonly NET_DHCP_TIMEOUT=20

# A link with no route out is not connectivity. Poll something small over
# HTTPS instead of trusting that an address was assigned.
net_online() {
  curl -sf --max-time 5 -o /dev/null "$NET_PROBE_URL"
}

net_wait_online() {
  local waited=0
  while ((waited < NET_DHCP_TIMEOUT)); do
    net_online && return 0
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

net_is_wireless() { [[ -d /sys/class/net/$1/wireless ]]; }

# First wired interface reporting a carrier, if any.
net_wired_iface() {
  local path iface
  for path in /sys/class/net/*; do
    iface=${path##*/}
    [[ $iface == lo ]] && continue
    net_is_wireless "$iface" && continue
    [[ -r $path/carrier ]] || continue
    # Reading carrier on a down interface errors; bring it up first.
    ip link set "$iface" up 2>/dev/null || true
    if [[ $(cat "$path/carrier" 2>/dev/null || echo 0) == 1 ]]; then
      printf '%s' "$iface"
      return 0
    fi
  done
  return 1
}

net_wireless_iface() {
  local path iface
  for path in /sys/class/net/*; do
    iface=${path##*/}
    if net_is_wireless "$iface"; then
      printf '%s' "$iface"
      return 0
    fi
  done
  return 1
}

# --- wifi ------------------------------------------------------------------

# Scan and emit "<signal>\t<ssid>" records, strongest first, deduplicated.
#
# The parsing target is `iw`, never `iwctl`. iwctl formats for human eyes:
# ANSI colour, column padding, and a signal bar drawn with asterisks whose
# width has changed between releases. `iw` emits stable, field-per-line
# records.
net_wifi_scan() {
  local iface=$1 out

  # iwd holds the device, so a fresh `iw scan` usually returns EBUSY. Ask iwd
  # to do the scanning and read its results back through `iw scan dump`, which
  # reads the cache and works while iwd is connected.
  if ! out=$(iw dev "$iface" scan 2>/dev/null); then
    iwctl station "$iface" scan >/dev/null 2>&1 || true
    sleep 3
    out=$(iw dev "$iface" scan dump 2>/dev/null) || return 1
  fi

  printf '%s\n' "$out" | awk '
    /^BSS /                  { sig = ""; ssid = "" }
    /^[ \t]*signal:/         { sig = $2 + 0 }
    /^[ \t]*SSID:/           {
      $1 = ""; sub(/^[ \t]+/, "")
      if (length($0) > 0) print sig "\t" $0
    }
  ' | sort -rn | awk -F'\t' '!seen[$2]++'
}

# iwd names its config files after the SSID, hex-encoding anything that is not
# plain alphanumeric as "=<hex>.psk".
net_iwd_filename() {
  local ssid=$1
  if [[ $ssid =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s.psk' "$ssid"
  else
    printf '=%s.psk' "$(printf '%s' "$ssid" | od -An -tx1 | tr -d ' \n')"
  fi
}

# Persist credentials into the *target* system so it rejoins on first boot.
net_persist_psk() {
  local root=$1 ssid=$2 pass=$3
  local dir="$root/var/lib/iwd" file
  install -d -m 700 "$dir"
  file="$dir/$(net_iwd_filename "$ssid")"
  umask 077
  printf '[Security]\nPassphrase=%s\n' "$pass" >"$file"
  chmod 600 "$file"
}

# Interactive SSID picker. Sets NET_SSID / NET_PSK on success so the caller
# can persist them after the target root is mounted.
# shellcheck disable=SC2034  # both are read by installer.sh
NET_SSID=''
NET_PSK=''

net_wifi_connect() {
  local iface=$1
  local -a ssids=() labels=()
  local sig ssid pass

  systemctl start iwd >/dev/null 2>&1 || true
  ip link set "$iface" up 2>/dev/null || true
  sleep 1

  ui_screen
  ui_body "No wired connection. Scanning for networks..."
  ui_blank

  while IFS=$'\t' read -r sig ssid; do
    [[ -z $ssid ]] && continue
    ssids+=("$ssid")
    labels+=("$(printf '%-32s %s dBm' "$ssid" "$sig")")
  done < <(net_wifi_scan "$iface")

  ssids+=('')
  labels+=("enter a network name manually (hidden network)")

  while :; do
    ui_screen
    ui_body "Let's get this machine online..."
    ui_blank
    ui_menu "Network" "${labels[@]}"

    NET_SSID=${ssids[$((UI_RESULT - 1))]}
    if [[ -z $NET_SSID ]]; then
      ui_screen
      ui_body "Enter the network name exactly as it is broadcast."
      ui_blank
      ui_input "SSID" 0
      NET_SSID=$UI_RESULT
    fi

    ui_screen
    ui_body "Joining $NET_SSID..."
    ui_blank
    ui_input "Passphrase" 1
    pass=$UI_RESULT

    ui_screen
    ui_body "Connecting to $NET_SSID..."
    ui_blank

    # A wrong passphrase fails asynchronously and iwd's own error text does
    # not say so. Treat "no connectivity shortly after connecting" as the
    # real signal and say something a human can act on.
    iwctl --passphrase "$pass" station "$iface" connect "$NET_SSID" >/dev/null 2>&1 || true
    if net_wait_online; then
      # shellcheck disable=SC2034  # read by installer.sh once /mnt exists
      NET_PSK=$pass
      return 0
    fi

    ui_body "Couldn't join that network — check the passphrase and try again."
    ui_blank
    ui_pause
  done
}

# --- entry point -----------------------------------------------------------

# Bring the live environment online. Asks nothing when it doesn't have to.
net_setup() {
  local iface

  systemctl start systemd-networkd systemd-resolved >/dev/null 2>&1 || true

  if iface=$(net_wired_iface); then
    ui_screen
    ui_body "Wired connection found on $iface. Getting an address..."
    ui_blank
    if net_wait_online; then
      ui_body "Online."
      sleep 1
      return 0
    fi
    ui_body "$iface has a link but no route out. Falling back to wireless..."
    sleep 2
  fi

  if iface=$(net_wireless_iface); then
    net_wifi_connect "$iface"
    return 0
  fi

  ui_fatal \
    "No network interface with a usable connection was found." \
    "Plug in an ethernet cable, or use hardware with a wireless card," \
    "and start the installer again."
}

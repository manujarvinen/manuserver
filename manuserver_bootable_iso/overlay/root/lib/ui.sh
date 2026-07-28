# shellcheck shell=bash
#
# ui.sh — palette, screen drawing and input widgets.
#
# Everything here targets the Linux framebuffer console, which is what the
# installer actually runs on. That constrains the design in two ways worth
# knowing before changing anything:
#
#   1. No truecolor. The console honours only the 16 palette slots, so the
#      brand colours are installed by *redefining* those slots (see
#      ui_palette_init) and then addressed with ordinary SGR codes.
#   2. Fixed 80x25 by default. The logo is wider than that, so the fallback
#      path in ui_logo_load is the common case, not an edge case.

# --- palette ---------------------------------------------------------------
#
# Slot indices chosen so that slot 0 (the background) is the maroon: a plain
# screen clear then paints the whole terminal correctly and no manual fill is
# ever needed. Hex values sampled from references/visuals_manuserver.png.

readonly PAL_BG=2E1522     # 0  background
readonly PAL_LOGO=8F0B45   # 1  logo
readonly PAL_BODY=A81558   # 5  body text
readonly PAL_ACCENT=E81E80 # 13 labels / accents (bold)
readonly PAL_INPUT=F2C8DC  # 15 text the user typed
readonly PAL_HINT=7A1040   # 8  key hints
readonly PAL_CURSOR=FF2E95 # 9  block cursor

# SGR sequences for the slots above. Bright slots (8-15) use the 90/100 range.
readonly S_RESET=$'\e[0m'
readonly S_LOGO=$'\e[31m'
readonly S_BODY=$'\e[35m'
readonly S_ACCENT=$'\e[1;95m'
readonly S_INPUT=$'\e[97m'
readonly S_HINT=$'\e[90m'
readonly S_CURSOR=$'\e[101m'  # slot 9 as a background -> solid block
readonly S_SEL=$'\e[1;95;7m'  # selected toggle: reverse video, accent

# --- layout state ----------------------------------------------------------

UI_COLS=80        # terminal width
UI_LINES=25       # terminal height
UI_PAD=2          # left indent of the content block
UI_ROW=0          # next free content row (0-indexed)
UI_TOP=1          # first row the logo is drawn on

declare -a UI_LOGO_LINES=()
UI_LOGO_W=0
UI_LOGO_H=0

# Widgets hand their answer back here rather than on stdout. See ui_input.
UI_RESULT=''

# --- lifecycle -------------------------------------------------------------

ui_init() {
  ui_quiet_kernel
  ui_palette_init
  ui_font_check
  tput civis 2>/dev/null || true
  stty -echo 2>/dev/null || true
  ui_measure
  ui_logo_load "${1:-}"
}

# Undo everything ui_init changed. Registered as an EXIT trap by the caller so
# that a crash never leaves the console pink and cursorless.
ui_cleanup() {
  ui_restore_kernel
  printf '\e]R'                      # restore the default palette
  printf '%s' "$S_RESET"
  stty echo 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}

# The kernel writes straight to the console, on top of whatever is drawn
# there. Formatting a disk is enough to trigger it -- ext4 probing alone prints
# a line mid-install -- and the result is a screen with kernel noise stamped
# through the middle of it. Messages still go to dmesg and to the install log;
# they just stop painting over the UI.
UI_PRINTK_SAVED=''

ui_quiet_kernel() {
  [[ -w /proc/sys/kernel/printk ]] || return 0
  UI_PRINTK_SAVED=$(cut -f1 /proc/sys/kernel/printk 2>/dev/null || true)
  printf '1\n' >/proc/sys/kernel/printk 2>/dev/null || true
  return 0
}

ui_restore_kernel() {
  [[ -n $UI_PRINTK_SAVED && -w /proc/sys/kernel/printk ]] || return 0
  printf '%s\n' "$UI_PRINTK_SAVED" >/proc/sys/kernel/printk 2>/dev/null || true
  return 0
}

ui_palette_init() {
  local i=0 hex
  for hex in "$PAL_BG" "$PAL_LOGO" "" "" "" "$PAL_BODY" "" "" \
             "$PAL_HINT" "$PAL_CURSOR" "" "" "" "$PAL_ACCENT" "" "$PAL_INPUT"; do
    if [[ -n $hex ]]; then printf '\e]P%X%s' "$i" "$hex"; fi
    i=$((i + 1))
  done
  printf '\e[2J\e[H'   # repaint so slot 0 becomes the visible background
}

# Glyphs used in the chrome. Nothing here is assumed: a console font that
# lacks a glyph draws a blank or a tofu box in the middle of a word, and the
# logo is made of glyphs too, so guessing wrong wrecks the whole screen.
#
# ▸ (U+25B8) is in none of the stock console fonts, so the step marker is
# plain ASCII and stays that way.
UI_G_STEP='>'
UI_G_SEP='-'
UI_G_TOGGLE='<->'
UI_BLOCKS_OK=1        # can the console draw the logo's ▀ ▄ █ ?

readonly UI_FONTDIR=/usr/share/kbd/consolefonts

# Path of the console font in use, if it can be worked out. Failing means the
# kernel's built-in font is active, which is default8x16 and does carry the
# block elements.
ui_font_file() {
  local name='' f
  [[ -r /etc/vconsole.conf ]] &&
    name=$(sed -n 's/^[[:space:]]*FONT=//p' /etc/vconsole.conf | tr -d '"' | head -n1)
  [[ -n $name ]] || return 1

  for f in "$UI_FONTDIR/$name".psfu.gz "$UI_FONTDIR/$name".psf.gz \
           "$UI_FONTDIR/$name".psfu "$UI_FONTDIR/$name".psf; do
    if [[ -r $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# A font file's own unicode table. This is the only honest way to find out
# what the console can draw -- the driver offers no way to ask.
ui_font_table() { zcat -f "$1" 2>/dev/null | psfgettable - 2>/dev/null; }

ui_font_has() {
  local table=$1 cp
  shift
  for cp in "$@"; do
    grep -qi "U+$cp" <<<"$table" || return 1
  done
  return 0
}

ui_font_check() {
  local table='' file cand ctable

  # No way to check: keep the ASCII chrome, and trust the blocks, since every
  # stock font carries them -- including the kernel's built-in one.
  command -v psfgettable >/dev/null || return 0

  if file=$(ui_font_file); then
    table=$(ui_font_table "$file")
  else
    table=$(ui_font_table "$UI_FONTDIR/default8x16.psfu.gz")
  fi

  # If the active font cannot draw the logo, find one that can rather than
  # painting a wall of tofu across the top of every screen.
  if ! ui_font_has "$table" 2580 2584 2588; then
    for cand in default8x16 eurlatgr lat9w-16 cp850-8x16; do
      [[ -r $UI_FONTDIR/$cand.psfu.gz ]] || continue
      ctable=$(ui_font_table "$UI_FONTDIR/$cand.psfu.gz")
      if ui_font_has "$ctable" 2580 2584 2588 && setfont "$cand" 2>/dev/null; then
        table=$ctable
        break
      fi
    done
  fi

  if ! ui_font_has "$table" 2580 2584 2588; then UI_BLOCKS_OK=0; fi
  if ui_font_has "$table" 2022; then UI_G_SEP='•'; fi
  if ui_font_has "$table" 2194; then UI_G_TOGGLE='↔'; fi
  return 0
}

ui_measure() {
  UI_COLS=$(tput cols 2>/dev/null || echo 80)
  UI_LINES=$(tput lines 2>/dev/null || echo 25)
}

# Load the block-ASCII logo, trimming blank leading/trailing lines and
# measuring what is left. Dimensions are never hardcoded: the art is expected
# to be re-exported at other sizes.
ui_logo_load() {
  local file=$1 line
  UI_LOGO_LINES=()

  if [[ -n $file && -r $file ]]; then
    local -a raw=()
    while IFS= read -r line || [[ -n $line ]]; do raw+=("$line"); done <"$file"

    local first=0 last=$((${#raw[@]} - 1))
    while ((first <= last)) && [[ -z ${raw[first]//[[:space:]]/} ]]; do first=$((first + 1)); done
    while ((last >= first)) && [[ -z ${raw[last]//[[:space:]]/} ]]; do last=$((last - 1)); done

    local i trimmed
    for ((i = first; i <= last; i++)); do
      trimmed=${raw[i]}
      trimmed=${trimmed%"${trimmed##*[![:space:]]}"}   # strip trailing padding
      UI_LOGO_LINES+=("$trimmed")
      if ((${#trimmed} > UI_LOGO_W)); then UI_LOGO_W=${#trimmed}; fi
    done
  fi

  UI_LOGO_H=${#UI_LOGO_LINES[@]}

  # Too narrow, too short to leave room for the content below, or a console
  # font that cannot draw block elements? Then the wordmark is rendered as
  # plain text instead. Deliberate, not a degraded accident -- the default
  # 80x25 VGA console is narrower than the art, so this is the ordinary path
  # on real hardware.
  if ((UI_LOGO_H == 0)) ||
     ((!UI_BLOCKS_OK)) ||
     ((UI_LOGO_W + 4 > UI_COLS)) ||
     ((UI_LOGO_H + 10 > UI_LINES)); then
    UI_LOGO_LINES=("MANUSERVER")
    UI_LOGO_H=1
    UI_LOGO_W=10
    # Centring ten characters would push the whole content block into the
    # middle of the screen and leave sentences no room. Hug the left instead,
    # which is also what the reference confirm screen does.
    UI_PAD=4
  else
    # The content block lines up with the logo's left edge. The art is wide,
    # so this indent stays small.
    UI_PAD=$(((UI_COLS - UI_LOGO_W) / 2))
    if ((UI_PAD < 2)); then UI_PAD=2; fi
  fi

  return 0
}

# --- primitives ------------------------------------------------------------

ui_at() { printf '\e[%d;%dH' "$(($1 + 1))" "$(($2 + 1))"; }
ui_clear_line() { printf '\e[K'; }

# Draw a fresh screen: clear, logo, blank line. Content starts at UI_ROW.
ui_screen() {
  printf '\e[2J'
  local i
  for ((i = 0; i < UI_LOGO_H; i++)); do
    ui_at $((UI_TOP + i)) "$UI_PAD"
    printf '%s%s%s' "$S_LOGO" "${UI_LOGO_LINES[i]}" "$S_RESET"
  done
  UI_ROW=$((UI_TOP + UI_LOGO_H + 1))
}

# ui_line <sgr> <text...> — one content line at the current row.
ui_line() {
  local sgr=$1; shift
  ui_at "$UI_ROW" "$UI_PAD"
  ui_clear_line
  printf '%s%s%s' "$sgr" "$*" "$S_RESET"
  UI_ROW=$((UI_ROW + 1))
}

ui_body() { ui_line "$S_BODY" "$@"; }
ui_hint() { ui_line "$S_HINT" "$@"; }
ui_blank() { UI_ROW=$((UI_ROW + 1)); }

# A step marker used by the progress screen.
ui_step() {
  ui_at "$UI_ROW" "$UI_PAD"
  ui_clear_line
  printf '%s%s %s%s%s' "$S_ACCENT" "$UI_G_STEP" "$S_BODY" "$*" "$S_RESET"
  UI_ROW=$((UI_ROW + 1))
  # The progress screen is the one place output can outgrow the console.
  if ((UI_ROW >= UI_LINES - 1)); then
    ui_screen
    ui_body "installing..."
    ui_blank
  fi
}

ui_fatal() {
  ui_screen
  ui_line "$S_ACCENT" "Cannot continue."
  ui_blank
  local line
  for line in "$@"; do ui_body "$line"; done
  ui_blank
  ui_hint "press enter to drop to a shell"
  read -r _ 2>/dev/null || true
  exit 1
}

# Everything long-running is logged rather than printed: command output would
# shred the layout, and when something breaks the tail of the log is far more
# useful than whatever scrolled past.
UI_LOG=/tmp/manuserver-install.log

ui_run() {
  local label=$1; shift
  ui_step "$label"
  if ! "$@" >>"$UI_LOG" 2>&1; then
    ui_fatal_log "$label"
  fi
}

ui_fatal_log() {
  ui_screen
  ui_line "$S_ACCENT" "Failed: $1"
  ui_blank
  ui_body "Last lines of $UI_LOG —"
  local line width=$((UI_COLS - UI_PAD - 1))
  while IFS= read -r line; do ui_body "${line:0:$width}"; done < <(tail -n 8 "$UI_LOG" 2>/dev/null)
  ui_blank
  ui_hint "press enter to drop to a shell"
  read -r _ 2>/dev/null || true
  exit 1
}

ui_pause() {
  ui_hint "${1:-press enter to continue}"
  read -r _ 2>/dev/null || true
}

# --- keyboard --------------------------------------------------------------

# Read one keypress, resolving arrow escape sequences to plain names. Echoes
# one of: a literal character, "" (enter), "left", "right", "up", "down",
# "backspace", "reveal" (Ctrl-R), "esc".
ui_key() {
  local c rest
  # End of input is its own answer, never a stand-in for enter. Treating it as
  # enter meant a closed stdin could confirm a disk wipe on its own.
  IFS= read -rsn1 c 2>/dev/null || { printf 'eof\n'; return 0; }
  case $c in
    '')      printf '\n' ;;                       # enter
    $'\177'|$'\b') printf 'backspace\n' ;;
    $'\022') printf 'reveal\n' ;;                 # Ctrl-R
    $'\e')
      # Arrow keys arrive as ESC [ X. Nothing follows a bare ESC, so the
      # short timeout is what tells the two apart.
      IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=''
      case $rest in
        '[C') printf 'right\n' ;;
        '[D') printf 'left\n' ;;
        '[A') printf 'up\n' ;;
        '[B') printf 'down\n' ;;
        *)    printf 'esc\n' ;;
      esac
      ;;
    *) printf '%s\n' "$c" ;;
  esac
}

# --- widgets ---------------------------------------------------------------

# ui_input <label> <mask:0|1> — prompt on one line, hint below, block cursor
# drawn by hand. The answer lands in UI_RESULT.
#
# Widgets never return values on stdout, because stdout is the screen: a
# `x=$(ui_input ...)` would capture every escape sequence the widget draws
# with, leaving the console blank and x full of terminal codes.
#
# The reveal toggle is not a nicety. The keymap is hardcoded to `us`; on a
# keyboard with any other layout every symbol key is displaced, and because
# the mistake is *consistent* the confirm-twice check still passes. The user
# then owns a machine with a password they cannot type. Showing the text is
# the only way that becomes visible.
ui_input() {
  local label=$1 mask=${2:-0}
  local value='' reveal=0 key
  local row=$UI_ROW
  local hint

  if ((mask)); then
    hint="enter submit $UI_G_SEP ctrl-r reveal"
  else
    hint="enter submit"
  fi

  ui_at $((row + 1)) "$UI_PAD"
  printf '%s%s%s' "$S_HINT" "$hint" "$S_RESET"

  while :; do
    local shown=$value
    if ((mask && !reveal)); then
      shown=$(printf '%*s' "${#value}" '' | tr ' ' '*')
    fi

    ui_at "$row" "$UI_PAD"
    ui_clear_line
    printf '%s%s>%s %s%s%s %s' \
      "$S_ACCENT" "$label" "$S_RESET" \
      "$S_INPUT" "$shown" "$S_CURSOR" "$S_RESET"

    key=$(ui_key)
    case $key in
      '')          [[ -n $value ]] && break ;;
      backspace)   value=${value%?} ;;
      reveal)      ((mask)) && reveal=$((1 - reveal)) ;;
      left|right|up|down|esc) ;;
      # Nothing left to read. On a console this cannot happen; if it somehow
      # does, stop with a message rather than spinning on a dead stream.
      eof)         ui_fatal "The installer lost its keyboard input." \
                            "Rerun it with: bash /root/installer.sh" ;;
      *)           value+=$key ;;
    esac
  done

  UI_ROW=$((row + 2))
  UI_RESULT=$value
}

# ui_menu <label> <item...> — numbered list; the 1-based index chosen lands in
# UI_RESULT. Multi-digit entries are supported because a wifi scan can easily
# turn up more than nine networks.
ui_menu() {
  local label=$1; shift
  local -a items=("$@")
  local i

  for i in "${!items[@]}"; do
    ui_line "$S_BODY" "$(printf '%s%2d)%s %s' "$S_ACCENT" $((i + 1)) "$S_BODY" "${items[i]}")"
  done
  ui_blank

  while :; do
    ui_input "$label" 0
    if [[ $UI_RESULT =~ ^[0-9]+$ ]] && ((UI_RESULT >= 1 && UI_RESULT <= ${#items[@]})); then
      return 0
    fi
    UI_ROW=$((UI_ROW - 2))
  done
}

# ui_confirm <yes-label> <no-label> — two toggle buttons, styled after
# references/ref_wipe_disk.png. Defaults to No; returns 0 for yes, 1 for no.
#
# y and n move the selection, they do not submit. The only thing this is used
# for is erasing a disk, and a single mistyped key should never be enough to
# do that -- confirming always takes two deliberate presses.
ui_confirm() {
  local yes=$1 no=$2
  local sel=1   # 0 = yes, 1 = no
  local row=$UI_ROW key

  ui_at $((row + 2)) "$UI_PAD"
  printf '%s%s toggle %s y/n select %s enter confirm%s' \
    "$S_HINT" "$UI_G_TOGGLE" "$UI_G_SEP" "$UI_G_SEP" "$S_RESET"

  while :; do
    ui_at "$row" "$UI_PAD"
    ui_clear_line
    if ((sel == 0)); then
      printf '%s %s %s   %s %s %s' "$S_SEL" "$yes" "$S_RESET" "$S_HINT" "$no" "$S_RESET"
    else
      printf '%s %s %s   %s %s %s' "$S_HINT" "$yes" "$S_RESET" "$S_SEL" "$no" "$S_RESET"
    fi

    key=$(ui_key)
    case $key in
      left|right) sel=$((1 - sel)) ;;
      y|Y) sel=0 ;;
      n|N) sel=1 ;;
      eof) sel=1; break ;;   # no input left: answer no, never yes
      '')  break ;;
    esac
  done

  UI_ROW=$((row + 3))
  return "$sel"
}

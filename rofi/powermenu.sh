#!/usr/bin/env bash

# ─────────────────────────────────────────────────────────────────
#  Rofi Power Menu + Spotlight Launcher  (i3 / Arch Linux)
#
#  - Selecting a power action executes it immediately
#  - Typing anything launches the spotlight script with that query
#  - Escape / no input does nothing
# ─────────────────────────────────────────────────────────────────

# Path to your spotlight script
SPOTLIGHT="${SPOTLIGHT_SCRIPT:-$HOME/.config/rofi/scripts/spotlight.py}"

# Power options (Nerd Font icons — swap for plain text if needed)
lock="  Lock"
logout="  Logout"
restart="  Restart"
poweroff="  Poweroff"

options="$lock\n$logout\n$restart\n$poweroff"

# ── Launch rofi ──────────────────────────────────────────────────
# -format 'i\ns' gives us both the index AND the raw typed string.
# If the user picks an item  → index is 0-3, string is the label.
# If the user types freely   → index is -1, string is what they typed.
# We allow custom input (-no-custom removed) so free typing works.
read -r idx_raw chosen_raw < <(
	echo -e "$options" | rofi \
		-dmenu \
		-i \
		-p "⏻" \
		-mesg "$(cat /proc/sys/kernel/hostname)  •  $(uptime -p)" \
		-theme-str 'window { width: 520px; border-radius: 14px; }' \
		-theme-str 'listview { lines: 4; columns: 1; }' \
		-theme-str 'element  { padding: 10px 18px; border-radius: 8px; }' \
		-format 'i\ns' \
		2>/dev/null
)

# rofi exits non-zero on Escape; bail out cleanly
[ $? -ne 0 ] && exit 0

idx="${idx_raw:-$chosen_raw}" # when format='i\ns', first line is index
typed="${chosen_raw}"         # second line is the raw string

# ── Decision logic ───────────────────────────────────────────────
case "$idx" in
0) # Lock
	i3lock --color=1e1e2e
	exit 0
	;;
1) # Logout
	i3-msg exit
	exit 0
	;;
2) # Restart
	systemctl reboot
	exit 0
	;;
3) # Poweroff
	systemctl poweroff
	exit 0
	;;
esac

# ── If we reach here the user typed something freely ─────────────
query="$(echo "$typed" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# If the query matches a power label exactly, treat it as a selection
case "$query" in
*"Lock")
	i3lock --color=1e1e2e
	exit 0
	;;
*"Logout")
	i3-msg exit
	exit 0
	;;
*"Restart")
	systemctl reboot
	exit 0
	;;
*"Poweroff")
	systemctl poweroff
	exit 0
	;;
esac

# Hand off to spotlight with the typed query pre-filled
if [ -x "$SPOTLIGHT" ]; then
	rofi \
		-modi "spotlight:python3 $SPOTLIGHT" \
		-show spotlight \
		-filter "$query" \
		-theme-str 'window { width: 640px; border-radius: 14px; }' \
		-theme-str 'listview { lines: 10; columns: 1; }' \
		-theme-str 'element  { padding: 10px 18px; border-radius: 8px; }'
else
	# Spotlight not found — fall back to plain rofi drun
	notify-send "powermenu" "spotlight.py not found at $SPOTLIGHT" 2>/dev/null
	rofi -show drun -filter "$query"
fi

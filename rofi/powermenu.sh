#!/usr/bin/env bash
set -euo pipefail

LOG="${XDG_CACHE_HOME:-$HOME/.cache}/rofi-powermenu.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "---- $(date) ----"
echo "ENV: DISPLAY=${DISPLAY:-} XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} PATH=$PATH"

LOCK_CMD="${LOCK_CMD:-$HOME/.config/i3lock/lock.sh}"

rofi_cmd() {
	command -v rofi >/dev/null 2>&1 || {
		echo "ERROR: rofi not found"
		exit 1
	}
	rofi -dmenu -i -p "Power" -theme-str 'window { width: 20em; }'
}

options=$'Lock\nLogout\nSuspend\nHibernate\nReboot\nShutdown'
choice="$(printf "%s\n" "$options" | rofi_cmd || true)"
choice="${choice//$'\r'/}" # strip CR if any
echo "CHOICE=<$choice>"

[[ -z "$choice" ]] && {
	echo "No choice selected, exiting."
	exit 0
}

run_cmd() {
	echo "RUN: $*"
	"$@" || {
		echo "FAILED: $* (exit=$?)"
		return 1
	}
}

do_suspend() {
	[[ -x "$LOCK_CMD" ]] && run_cmd "$LOCK_CMD" || echo "Lock script missing/not executable: $LOCK_CMD"
	if command -v loginctl >/dev/null 2>&1; then
		run_cmd loginctl suspend
	else
		run_cmd systemctl suspend
	fi
}

do_hibernate() {
	[[ -x "$LOCK_CMD" ]] && run_cmd "$LOCK_CMD" || echo "Lock script missing/not executable: $LOCK_CMD"
	if command -v loginctl >/dev/null 2>&1; then
		run_cmd loginctl hibernate
	else
		run_cmd systemctl hibernate
	fi
}

case "$choice" in
Lock)
	if [[ -x "$LOCK_CMD" ]]; then
		run_cmd "$LOCK_CMD"
	else
		echo "Lock script not executable: $LOCK_CMD"
		run_cmd i3lock
	fi
	;;
Logout)
	run_cmd i3-msg exit
	;;
Suspend)
	do_suspend
	;;
Hibernate)
	do_hibernate
	;;
Reboot)
	if command -v loginctl >/dev/null 2>&1; then
		run_cmd loginctl reboot
	else
		run_cmd systemctl reboot
	fi
	;;
Shutdown)
	if command -v loginctl >/dev/null 2>&1; then
		run_cmd loginctl poweroff
	else
		run_cmd systemctl poweroff
	fi
	;;
*)
	echo "Unknown choice: $choice"
	;;
esac

#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rofi-spotlight"
APPS_CACHE="$CACHE_DIR/apps.cache"
RECENT_CACHE="$CACHE_DIR/recent.cache"
mkdir -p "$CACHE_DIR"

log() {
	printf "[%s] %s\n" "$(date '+%F %T')" "$*" >>"$CACHE_DIR/debug.log"
}

has() { command -v "$1" >/dev/null 2>&1; }

sanitize_exec() {
	sed -E 's/%[fFuUdDnNickvm]//g; s/[[:space:]]+/ /g; s/[[:space:]]+$//'
}

# ---------------- APPS CACHE ----------------

build_apps_cache() {
	log "build_apps_cache"
	: >"$APPS_CACHE"

	for d in /usr/share/applications "$HOME/.local/share/applications"; do
		[[ -d "$d" ]] || continue
		for f in "$d"/*.desktop; do
			[[ -f "$f" ]] || continue

			grep -q '^NoDisplay=true' "$f" && continue

			name=$(grep -m1 '^Name=' "$f" | cut -d= -f2- || true)
			exec=$(grep -m1 '^Exec=' "$f" | cut -d= -f2- | sanitize_exec || true)
			icon=$(grep -m1 '^Icon=' "$f" | cut -d= -f2- || true)

			[[ -n "$name" && -n "$exec" ]] || continue

			id="app:$(basename "$f")"

			printf "%s  [app]\0icon\x1f%s\0info\x1fAPP|%s|%s\n" \
				"$name" "${icon:-application-x-executable}" "$id" "$exec" \
				>>"$APPS_CACHE"
		done
	done
}

# ---------------- RECENT CACHE ----------------

build_recent_cache() {
	log "build_recent_cache"
	: >"$RECENT_CACHE"

	xbel="$HOME/.local/share/recently-used.xbel"
	[[ -f "$xbel" ]] || return

	grep -o 'href="file://[^"]*"' "$xbel" |
		sed 's/^href="file:\/\///; s/"$//' |
		head -n 200 |
		while IFS= read -r p; do
			p="${p//%20/ }"
			[[ -e "$p" ]] || continue
			name="${p##*/}"
			id="file:$p"

			printf "%s  [file]\0icon\x1ffolder\0info\x1fFILE|%s|%s\n" \
				"$name" "$id" "$p" >>"$RECENT_CACHE"
		done
}

ensure_caches() {
	[[ -f "$APPS_CACHE" ]] || build_apps_cache
	[[ -f "$RECENT_CACHE" ]] || build_recent_cache
}

# ---------------- CALCULATOR ----------------

looks_like_math() {
	[[ "$1" =~ ^[0-9\ \+\*\/\.\(\)\-]+$ ]]
}

emit_calc() {
	local q="$1"
	looks_like_math "$q" || return
	res=$(awk "BEGIN{print ($q)}" 2>/dev/null || true)
	[[ -n "$res" ]] || return
	printf "= %s (copy)\0icon\x1faccessories-calculator\0info\x1fCALC|calc:$q|$res\n" "$res"
}

# ---------------- FILE SEARCH (lazy plocate) ----------------

emit_plocate() {
	local q="$1"
	[[ ${#q} -ge 3 ]] || return
	has plocate || return

	plocate -i --limit 60 -- "$q" 2>/dev/null |
		while IFS= read -r p; do
			[[ -n "$p" ]] || continue
			name="${p##*/}"
			id="file:$p"
			printf "%s  [file]\0icon\x1ffolder\0info\x1fFILE|%s|%s\n" \
				"$name" "$id" "$p"
		done
}

# ---------------- WEB FALLBACK ----------------

emit_web() {
	local q="$1"
	[[ -n "$q" ]] || return
	printf "Search web: %s\0icon\x1fweb-browser\0info\x1fWEB|web:%s|%s\n" "$q" "$q" "$q"
}

# ---------------- EXECUTION ----------------

execute_selection() {
	local q="$1"
	local info="${ROFI_INFO:-}"

	log "ROFI_RETV=$ROFI_RETV raw='$q' info='$info'"

	if [[ -z "$info" ]]; then
		log "spawn_sh: $q"
		nohup sh -lc "$q" >/dev/null 2>&1 &
		exit 0
	fi

	IFS='|' read -r type id payload <<<"$info"

	case "$type" in
	APP)
		log "launch app: $payload"
		nohup sh -lc "$payload" >/dev/null 2>&1 &
		;;
	FILE)
		log "open file: $payload"
		nohup xdg-open "$payload" >/dev/null 2>&1 &
		;;
	CALC)
		printf "%s" "$payload" | xclip -selection clipboard 2>/dev/null || true
		;;
	WEB)
		url=$(
			python - "$payload" <<PY
import urllib.parse,sys
print("https://duckduckgo.com/?q="+urllib.parse.quote(sys.argv[1]))
PY
		)
		nohup xdg-open "$url" >/dev/null 2>&1 &
		;;
	esac

	exit 0
}

# ---------------- MAIN ----------------

q="${1:-}"

if [[ "${ROFI_RETV:-0}" != "0" ]]; then
	execute_selection "$q"
fi

ensure_caches

emit_calc "$q"
cat "$APPS_CACHE"
cat "$RECENT_CACHE"
emit_plocate "$q"
emit_web "$q"

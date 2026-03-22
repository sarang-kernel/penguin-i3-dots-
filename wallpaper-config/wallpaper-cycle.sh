#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/Pictures/wallpapers"
DAY_DIR="$BASE_DIR/day"
NIGHT_DIR="$BASE_DIR/night"

CACHE_DIR="$HOME/.cache/wallpaper-cycle"
LOG_FILE="$CACHE_DIR/wallpaper_cycle.log"

CURRENT_WP_CACHE="$HOME/.cache/current_wallpaper"

DAY_LIST="$CACHE_DIR/wallpapers_day.list"
NIGHT_LIST="$CACHE_DIR/wallpapers_night.list"
ALL_LIST="$CACHE_DIR/wallpapers_all.list"

DAY_INDEX_FILE="$CACHE_DIR/index_day"
NIGHT_INDEX_FILE="$CACHE_DIR/index_night"
ALL_INDEX_FILE="$CACHE_DIR/index_all"

DAY_HASH_FILE="$CACHE_DIR/hash_day"
NIGHT_HASH_FILE="$CACHE_DIR/hash_night"
ALL_HASH_FILE="$CACHE_DIR/hash_all"

DAY_START=7
NIGHT_START=19

log() { echo "[$(date '+%F %T')] $*" >>"$LOG_FILE"; }

get_mode() {
	local hour
	hour=$(date +"%H")
	if ((hour >= DAY_START && hour < NIGHT_START)); then
		echo "day"
	else
		echo "night"
	fi
}

update_list_if_changed() {
	local dir="$1" list="$2" hash="$3"
	[[ ! -d "$dir" ]] && return

	local current_hash
	current_hash=$(find "$dir" -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.jpeg" \) \
		-printf '%P\n' | sort | sha256sum | awk '{print $1}')

	if [[ ! -f "$hash" || "$current_hash" != "$(cat "$hash")" ]]; then
		log "Updating wallpaper list for $dir"
		find "$dir" -type f \( -iname "*.jpg" -o -iname "*.png" -o -iname "*.jpeg" \) >"$list"
		echo "$current_hash" >"$hash"
	fi
}

apply_next() {
	local wallpapers=("$@")
	local count=${#wallpapers[@]}
	[[ $count -eq 0 ]] && exit 1

	local index=0
	[[ -f "$INDEX_FILE" ]] && index=$(<"$INDEX_FILE")

	local next=$(((index + 1) % count))
	local wp="${wallpapers[$next]}"

	log "Applying [$next]: $wp"
	feh --no-fehbg --bg-scale "$wp"

	# Cache it for lockscreen
	echo "$wp" >"$CURRENT_WP_CACHE"

	echo "$next" >"$INDEX_FILE"
}

mkdir -p "$CACHE_DIR"

MODE=$(get_mode)

if [[ -d "$DAY_DIR" && -d "$NIGHT_DIR" ]]; then
	if [[ "$MODE" == "day" ]]; then
		WALLPAPER_DIR="$DAY_DIR"
		LIST_FILE="$DAY_LIST"
		INDEX_FILE="$DAY_INDEX_FILE"
		HASH_FILE="$DAY_HASH_FILE"
	else
		WALLPAPER_DIR="$NIGHT_DIR"
		LIST_FILE="$NIGHT_LIST"
		INDEX_FILE="$NIGHT_INDEX_FILE"
		HASH_FILE="$NIGHT_HASH_FILE"
	fi
else
	WALLPAPER_DIR="$BASE_DIR"
	LIST_FILE="$ALL_LIST"
	INDEX_FILE="$ALL_INDEX_FILE"
	HASH_FILE="$ALL_HASH_FILE"
fi

update_list_if_changed "$WALLPAPER_DIR" "$LIST_FILE" "$HASH_FILE"
mapfile -t WALLPAPERS <"$LIST_FILE"

apply_next "${WALLPAPERS[@]}"

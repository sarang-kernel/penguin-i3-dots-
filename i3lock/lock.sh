#!/usr/bin/env bash

# Extract current feh wallpaper path
WALLPAPER="$(grep -oE "'[^']+'" "$HOME/.fehbg" | tail -n1 | tr -d "'")"

# Fallback to solid color if not found
if [ -f "$WALLPAPER" ]; then
	exec i3lock -i "$WALLPAPER"
else
	exec i3lock -c 111111
fi

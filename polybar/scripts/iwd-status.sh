#!/bin/bash
# ~/.config/polybar/scripts/iwd-status.sh

IFACE="wlan0"

# Get connection state
CONNECTED=$(iwctl station "$IFACE" show | awk '/State/ {print $2}')
SSID=$(iwctl station "$IFACE" show | awk '/Connected network/ {print $3}')

# Output
if [[ "$CONNECTED" == "connected" && -n "$SSID" ]]; then
	echo " $SSID"
else
	echo "睊 Disconnected"
fi

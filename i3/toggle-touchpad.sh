#!/bin/sh
ID=$(xinput list | grep -i touchpad | grep -o 'id=[0-9]*' | cut -d= -f2)
STATE=$(xinput list-props "$ID" | grep 'Device Enabled' | awk '{print $4}')

if [ "$STATE" -eq 1 ]; then
	xinput disable "$ID"
else
	xinput enable "$ID"
fi

#!/bin/bash

WHITE=0xffcad3f5
BLUE=0xff8aadf4
GREY=0xff939ab7

BLUETOOTH_POWER=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -i "State:" | head -1 | awk '{print $2}')
CONNECTED_DEVICES=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -c "Connected: Yes")

if [ "$BLUETOOTH_POWER" = "Off" ] || [ -z "$BLUETOOTH_POWER" ]; then
    ICON="󰂲"; COLOR=$GREY; LABEL=""
elif [ "$CONNECTED_DEVICES" -gt 0 ]; then
    ICON="󰂱"; COLOR=$BLUE; LABEL="$CONNECTED_DEVICES"
else
    ICON=""; COLOR=$WHITE; LABEL=""
fi

sketchybar --set $NAME icon="$ICON" icon.color=$COLOR label="$LABEL" label.color=$COLOR

#!/bin/bash

# Colors
WHITE=0xffcad3f5
GREEN=0xffa6da95
YELLOW=0xffeed49f
RED=0xffed8796

# Get battery info
BATTERY_INFO=$(pmset -g batt)
PERCENTAGE=$(echo "$BATTERY_INFO" | grep -Eo '[0-9]+%' | tr -d '%')
CHARGING=$(echo "$BATTERY_INFO" | grep 'AC Power')

# Set icon based on battery level and charging status
if [ -n "$CHARGING" ]; then
  ICON="󰂄"
  COLOR=$GREEN
elif [ "$PERCENTAGE" -gt 80 ]; then
  ICON="󰁹"
  COLOR=$WHITE
elif [ "$PERCENTAGE" -gt 60 ]; then
  ICON="󰂁"
  COLOR=$WHITE
elif [ "$PERCENTAGE" -gt 40 ]; then
  ICON="󰂀"
  COLOR=$WHITE
elif [ "$PERCENTAGE" -gt 20 ]; then
  ICON="󰁿"
  COLOR=$YELLOW
else
  ICON="󰁾"
  COLOR=$RED
fi

sketchybar --set $NAME \
  icon="$ICON" \
  icon.color=$COLOR \
  label="${PERCENTAGE}%" \
  label.color=$COLOR
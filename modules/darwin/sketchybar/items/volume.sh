#!/bin/bash

# Get volume
VOLUME=$(osascript -e 'output volume of (get volume settings)')
MUTED=$(osascript -e 'output muted of (get volume settings)')

# Set icon based on volume level
if [ "$MUTED" = "true" ]; then
  ICON="󰝟"
elif [ "$VOLUME" -eq 0 ]; then
  ICON="󰝟"
elif [ "$VOLUME" -lt 30 ]; then
  ICON="󰕿"
elif [ "$VOLUME" -lt 70 ]; then
  ICON="󰖀"
else
  ICON="󰕾"
fi

sketchybar --set $NAME \
  icon="$ICON" \
  label="${VOLUME}%"
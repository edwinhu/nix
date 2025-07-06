#!/bin/bash

# Get the current front app
FRONT_APP=$(aerospace list-windows --focused --format "%{app-name}")

# If no app is focused, try to get the frontmost app
if [ -z "$FRONT_APP" ]; then
  FRONT_APP="Finder"
fi

sketchybar --set $NAME label="$FRONT_APP"
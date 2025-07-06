#!/bin/bash

# Toggle mute
osascript -e 'set volume output muted not (output muted of (get volume settings))'

# Update the volume display
sketchybar --trigger volume_change
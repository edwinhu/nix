#!/bin/bash

# Colors
WHITE=0xffcad3f5
BLACK=0xff181926
TRANSPARENT=0x00000000

# Get the space ID from the script argument
SPACE_ID=$1

# Check if this space is currently focused
# FOCUSED_WORKSPACE is passed as an environment variable from the aerospace event
# If not available (e.g., during initial load), query aerospace
if [ -z "$FOCUSED_WORKSPACE" ]; then
  FOCUSED_WORKSPACE=$(aerospace list-workspaces --focused)
fi

if [ "$SPACE_ID" = "$FOCUSED_WORKSPACE" ]; then
  sketchybar --set space.$SPACE_ID \
    icon.color=$BLACK \
    background.color=$WHITE \
    background.border_color=$BLACK \
    background.drawing=on
else
  sketchybar --set space.$SPACE_ID \
    icon.color=$WHITE \
    background.color=$TRANSPARENT \
    background.border_color=$TRANSPARENT \
    background.drawing=off
fi
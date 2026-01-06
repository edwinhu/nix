#!/bin/bash

# Colors
WHITE=0xffcad3f5
BLACK=0xff181926
TRANSPARENT=0x00000000

# Persistent workspaces (always visible)
PERSISTENT="1 2 3 4 5"

# Get the space ID from the script argument
SPACE_ID=$1

# Check if this space is currently focused
if [ -z "$FOCUSED_WORKSPACE" ]; then
  FOCUSED_WORKSPACE=$(aerospace list-workspaces --focused)
fi

# Only show persistent workspaces (1-5)
if echo "$PERSISTENT" | grep -qw "$SPACE_ID"; then
  SHOULD_DRAW="on"
else
  SHOULD_DRAW="off"
fi

# Apply styling based on focus state
if [ "$SPACE_ID" = "$FOCUSED_WORKSPACE" ]; then
  sketchybar --set space.$SPACE_ID \
    drawing=$SHOULD_DRAW \
    icon.color=$BLACK \
    background.color=$WHITE \
    background.border_color=$BLACK \
    background.drawing=on
else
  sketchybar --set space.$SPACE_ID \
    drawing=$SHOULD_DRAW \
    icon.color=$WHITE \
    background.color=$TRANSPARENT \
    background.border_color=$TRANSPARENT \
    background.drawing=off
fi

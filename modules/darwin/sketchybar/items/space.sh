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

# Check visibility conditions
IS_PERSISTENT=$(echo "$PERSISTENT" | grep -qw "$SPACE_ID" && echo "yes")
HAS_WINDOWS=$(aerospace list-windows --workspace "$SPACE_ID" 2>/dev/null | grep -c .)
IS_FOCUSED=$([ "$SPACE_ID" = "$FOCUSED_WORKSPACE" ] && echo "yes")

# Determine if workspace should be visible
# Show if: persistent OR focused OR has windows
if [ -n "$IS_PERSISTENT" ] || [ -n "$IS_FOCUSED" ] || [ "$HAS_WINDOWS" -gt 0 ]; then
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

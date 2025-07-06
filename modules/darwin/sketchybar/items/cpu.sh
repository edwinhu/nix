#!/bin/bash

# Colors
WHITE=0xffcad3f5
YELLOW=0xffeed49f
RED=0xffed8796

# Get CPU usage
CPU_USAGE=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s}')

# Set color based on usage
if [ "$CPU_USAGE" -gt 80 ]; then
  COLOR=$RED
elif [ "$CPU_USAGE" -gt 50 ]; then
  COLOR=$YELLOW
else
  COLOR=$WHITE
fi

sketchybar --set $NAME \
  label="${CPU_USAGE}%" \
  label.color=$COLOR \
  icon.color=$COLOR
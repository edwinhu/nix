#!/bin/bash

# Colors
WHITE=0xffcad3f5
YELLOW=0xffeed49f
RED=0xffed8796

# Get CPU usage (average across cores)
CORES=$(sysctl -n hw.ncpu)
CPU_TOTAL=$(ps -A -o %cpu | awk '{s+=$1} END {print s}')
CPU_USAGE=$(echo "$CPU_TOTAL $CORES" | awk '{printf "%.0f", $1/$2}')

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
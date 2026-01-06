#!/bin/bash

# Power-aware configuration helper
# Sets update frequencies based on power source (battery vs AC power)

# Check if we're on battery or AC power
BATTERY_INFO=$(pmset -g batt)
ON_AC=$(echo "$BATTERY_INFO" | grep -q 'AC Power' && echo "yes")

# Define update frequencies
if [ -z "$ON_AC" ]; then
    # On battery - reduced polling for power saving
    CALENDAR_FREQ=60
    NETWORK_FREQ=60
    VOLUME_FREQ=10
    BATTERY_FREQ=60
else
    # On AC power - normal polling
    CALENDAR_FREQ=30
    NETWORK_FREQ=2
    VOLUME_FREQ=1
    BATTERY_FREQ=60
fi

# Update sketchybar items with appropriate frequencies
sketchybar --set calendar update_freq=$CALENDAR_FREQ
sketchybar --set wifi update_freq=$NETWORK_FREQ
sketchybar --set volume update_freq=$VOLUME_FREQ
sketchybar --set battery update_freq=$BATTERY_FREQ

# Log the current power state for debugging
echo "$(date): Power state - $([ -n "$ON_AC" ] && echo "AC Power" || echo "Battery") - Calendar: ${CALENDAR_FREQ}s, Network: ${NETWORK_FREQ}s, Volume: ${VOLUME_FREQ}s" >> /tmp/sketchybar_power_log
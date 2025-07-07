#!/bin/bash

# Colors
WHITE=0xffcad3f5
GREEN=0xffa6da95
RED=0xffed8796
BLUE=0xff8aadf4
YELLOW=0xffeed49f
ORANGE=0xfff5a97f

# Function to format bytes to human readable with fixed width
format_bytes() {
  local bytes=$1
  if [ $bytes -lt 1024 ]; then
    printf "%4dB" $bytes
  elif [ $bytes -lt 1048576 ]; then
    printf "%4dK" $((bytes / 1024))
  elif [ $bytes -lt 1073741824 ]; then
    printf "%4dM" $((bytes / 1048576))
  else
    printf "%4dG" $((bytes / 1073741824))
  fi
}

# Get network statistics
# Store previous values in tmp files
STATS_DIR="/tmp/sketchybar_network_stats"
mkdir -p "$STATS_DIR"

# Determine active interface
ACTIVE_INTERFACE=""
ETHERNET_FOUND=false

# Check for ethernet connection first
for interface in en8 en7 en6 en5 en4; do
  INTERFACE_INFO=$(ifconfig $interface 2>/dev/null)
  if [[ "$INTERFACE_INFO" =~ "status: active" ]] && [[ "$INTERFACE_INFO" =~ "inet " ]]; then
    ETHERNET_FOUND=true
    ACTIVE_INTERFACE=$interface
    ICON="󰈀"  # Ethernet icon
    ICON_COLOR=$BLUE
    break
  fi
done

# If no ethernet, check WiFi
if [ -z "$ACTIVE_INTERFACE" ]; then
  WIFI_INTERFACE="en0"
  WIFI_INFO=$(ifconfig $WIFI_INTERFACE 2>/dev/null)
  
  if [[ "$WIFI_INFO" =~ "status: active" ]]; then
    ACTIVE_INTERFACE=$WIFI_INTERFACE
    ICON="󰤨"
    ICON_COLOR=$GREEN
  else
    # No network connection
    ICON="󰤭"
    ICON_COLOR=$RED
    LABEL="↓    0B ↑    0B"
    
    sketchybar --set $NAME \
      icon="$ICON" \
      icon.color=$ICON_COLOR \
      label="$LABEL" \
      label.color=$RED
    exit 0
  fi
fi

# Get current network stats
if [ -n "$ACTIVE_INTERFACE" ]; then
  # Get bytes in/out from netstat
  NETSTAT_OUTPUT=$(netstat -I $ACTIVE_INTERFACE -b | tail -1)
  CURRENT_IN=$(echo "$NETSTAT_OUTPUT" | awk '{print $7}')
  CURRENT_OUT=$(echo "$NETSTAT_OUTPUT" | awk '{print $10}')
  CURRENT_TIME=$(date +%s)
  
  # Read previous values
  PREV_FILE="$STATS_DIR/${ACTIVE_INTERFACE}_stats"
  if [ -f "$PREV_FILE" ]; then
    source "$PREV_FILE"
  else
    PREV_IN=$CURRENT_IN
    PREV_OUT=$CURRENT_OUT
    PREV_TIME=$CURRENT_TIME
  fi
  
  # Calculate speed (bytes per second)
  TIME_DIFF=$((CURRENT_TIME - PREV_TIME))
  if [ $TIME_DIFF -gt 0 ]; then
    DOWN_SPEED=$(( (CURRENT_IN - PREV_IN) / TIME_DIFF ))
    UP_SPEED=$(( (CURRENT_OUT - PREV_OUT) / TIME_DIFF ))
  else
    DOWN_SPEED=0
    UP_SPEED=0
  fi
  
  # Ensure non-negative speeds
  [ $DOWN_SPEED -lt 0 ] && DOWN_SPEED=0
  [ $UP_SPEED -lt 0 ] && UP_SPEED=0
  
  # Format speeds
  DOWN_TEXT=$(format_bytes $DOWN_SPEED)
  UP_TEXT=$(format_bytes $UP_SPEED)
  
  # Set arrow colors based on activity
  if [ $DOWN_SPEED -gt 1048576 ]; then  # > 1MB/s
    DOWN_COLOR=$GREEN
  elif [ $DOWN_SPEED -gt 102400 ]; then  # > 100KB/s
    DOWN_COLOR=$YELLOW
  elif [ $DOWN_SPEED -gt 0 ]; then
    DOWN_COLOR=$ORANGE
  else
    DOWN_COLOR=$WHITE
  fi
  
  if [ $UP_SPEED -gt 1048576 ]; then  # > 1MB/s
    UP_COLOR=$GREEN
  elif [ $UP_SPEED -gt 102400 ]; then  # > 100KB/s
    UP_COLOR=$YELLOW
  elif [ $UP_SPEED -gt 0 ]; then
    UP_COLOR=$ORANGE
  else
    UP_COLOR=$WHITE
  fi
  
  # Create label with colored arrows
  LABEL="↓ ${DOWN_TEXT} ↑ ${UP_TEXT}"
  
  # Save current values for next iteration
  cat > "$PREV_FILE" << EOF
PREV_IN=$CURRENT_IN
PREV_OUT=$CURRENT_OUT
PREV_TIME=$CURRENT_TIME
EOF
  
  sketchybar --set $NAME \
    icon="$ICON" \
    icon.color=$ICON_COLOR \
    label="$LABEL" \
    label.color=$WHITE
fi
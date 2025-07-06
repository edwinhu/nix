#!/bin/bash

# Colors
WHITE=0xffcad3f5
GREEN=0xffa6da95
RED=0xffed8796
BLUE=0xff8aadf4

# Check for ethernet connection first
# Check common ethernet interfaces (including USB LAN adapters)
ETHERNET_FOUND=false
for interface in en8 en7 en6 en5 en4; do
  ETHERNET_INFO=$(ifconfig $interface 2>/dev/null)
  if [[ "$ETHERNET_INFO" =~ "status: active" ]] && [[ "$ETHERNET_INFO" =~ "inet " ]]; then
    ETHERNET_FOUND=true
    break
  fi
done

if [ "$ETHERNET_FOUND" = true ]; then
  # Ethernet is connected
  ICON="󰈀"  # Ethernet icon
  COLOR=$BLUE
  LABEL="Ethernet"
else
  # Check WiFi status using networksetup instead of deprecated airport command
  WIFI_INTERFACE="en0"
  WIFI_INFO=$(ifconfig $WIFI_INTERFACE 2>/dev/null)
  
  if [[ "$WIFI_INFO" =~ "status: active" ]]; then
    # WiFi is connected, get SSID
    SSID=$(networksetup -getairportnetwork $WIFI_INTERFACE 2>/dev/null | sed 's/Current Wi-Fi Network: //')
    
    if [ -n "$SSID" ] && [ "$SSID" != "" ] && [[ ! "$SSID" =~ "not associated" ]]; then
      ICON="󰤨"
      COLOR=$GREEN
      LABEL="$SSID"
    else
      # WiFi active but not connected to network
      ICON="󰤭"
      COLOR=$RED
      LABEL="No Network"
    fi
  else
    # No network connection
    ICON="󰤭"
    COLOR=$RED
    LABEL="Disconnected"
  fi
fi

sketchybar --set $NAME \
  icon="$ICON" \
  icon.color=$COLOR \
  label="$LABEL" \
  label.color=$WHITE
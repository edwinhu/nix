#!/usr/bin/env bash

# Update loop for time-based sketchybar items
# This script runs in the background and triggers routine events

while true; do
  # Trigger routine event
  sketchybar --trigger routine
  
  # Sleep for 30 seconds
  sleep 30
done
#!/bin/bash

# Get current date and time in local timezone
DATE=$(TZ="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')" date +'%a %b %d %I:%M %p')

sketchybar --set $NAME label="$DATE"
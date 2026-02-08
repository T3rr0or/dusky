#!/bin/bash

# Get the current resolution of the main monitor (DP-1)
CURRENT_RES=$(hyprctl monitors | grep -A 1 "^Monitor DP-1" | grep -oP '\d+x\d+' | head -1)

if [ "$CURRENT_RES" = "3440x1440" ]; then
    # Switch to 2560x1440@240Hz
    hyprctl keyword monitor DP-1,2560x1440@240,auto,1
    echo "Switched to 2560x1440@240Hz"
else
    # Switch to 3440x1440@240Hz
    hyprctl keyword monitor DP-1,3440x1440@240,auto,1
    echo "Switched to 3440x1440@240Hz"
fi

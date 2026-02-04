#!/bin/bash
# Get public IP
public_ip=$(curl -s --connect-timeout 60 ifconfig.me)

# Output for Waybar (plain text)
echo -e "IP: $public_ip"

#!/bin/bash
BAT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "?")
TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
WIFI=$(iwgetid -r 2>/dev/null || echo "off")
FAN=$(cat /sys/class/hwmon/hwmon3/fan1_input 2>/dev/null || echo "?")
ICON="🔋"; [ "$BAT" -lt 20 ] 2>/dev/null && ICON="🪫"
echo "$ICON$BAT% 🌡${TEMP}°C 🌀${FAN} 📶$WIFI"

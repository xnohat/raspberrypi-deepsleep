#!/bin/bash
LOG=/var/log/battery-drain.log
echo "=== logger start $(date '+%F %T') ===" >> $LOG
while true; do
    echo "$(date '+%F %T') capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null) charge_uah=$(cat /sys/class/power_supply/battery/charge_now 2>/dev/null) mv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) state=$([ -f /tmp/pi-deepsleep-state ] && echo SLEEP || echo AWAKE)" >> $LOG
    sleep 60
done

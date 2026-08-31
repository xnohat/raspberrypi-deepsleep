#!/bin/bash
# pipower-apply.sh — privileged helper for Pi Power GUI (called via sudo).
# Narrow, validated operations only. Never trust raw input.

set -e
CONFIG_TXT="/boot/firmware/config.txt"
SLEEP_SH="/usr/local/bin/powerbtn-deepsleep.sh"
DAEMON_PY="/usr/local/bin/powerbtn-daemon.py"
LOG="/var/log/pi-deepsleep.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - UI: $1" >> "$LOG"; }

fan_hwmon() {
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "pwmfan" ] && { echo "$h"; return; }
    done
    return 1
}

seed_cooling() {
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    st=0
    [ "$t" -ge 55000 ] && st=1
    [ "$t" -ge 65000 ] && st=2
    [ "$t" -ge 72000 ] && st=3
    [ "$t" -ge 78000 ] && st=4
    echo "$st" > /sys/class/thermal/cooling_device0/cur_state 2>/dev/null || true
}

case "$1" in
fan-test)
    # fan-test <pwm 0-255> <seconds 1-30>: spin briefly then back to auto
    pwm="$2"; secs="$3"
    [[ "$pwm" =~ ^[0-9]+$ ]] && [ "$pwm" -le 255 ] || { echo "bad pwm"; exit 1; }
    [[ "$secs" =~ ^[0-9]+$ ]] && [ "$secs" -ge 1 ] && [ "$secs" -le 30 ] || { echo "bad secs"; exit 1; }
    fh=$(fan_hwmon) || { echo "no fan"; exit 1; }
    echo 1 > "$fh/pwm1_enable"
    echo "$pwm" > "$fh/pwm1"
    sleep "$secs"
    rpm=$(cat "$fh/fan1_input")
    echo 2 > "$fh/pwm1_enable"
    seed_cooling
    log "fan-test pwm=$pwm rpm=$rpm"
    echo "pwm=$pwm rpm=$rpm"
    ;;
fan-manual)
    # fan-manual <pwm 0-255>: hold fixed speed until fan-auto
    pwm="$2"
    [[ "$pwm" =~ ^[0-9]+$ ]] && [ "$pwm" -le 255 ] || { echo "bad pwm"; exit 1; }
    fh=$(fan_hwmon) || { echo "no fan"; exit 1; }
    echo 1 > "$fh/pwm1_enable"
    echo "$pwm" > "$fh/pwm1"
    log "fan-manual pwm=$pwm"
    sleep 1
    echo "manual pwm=$pwm rpm=$(cat "$fh/fan1_input")"
    ;;
fan-auto)
    # return fan to kernel thermal control
    fh=$(fan_hwmon) || { echo "no fan"; exit 1; }
    echo 2 > "$fh/pwm1_enable"
    seed_cooling
    log "fan-auto restored"
    echo "auto"
    ;;
fan-save)
    # fan-save t0 s0 h0 t1 s1 h1 t2 s2 h2 t3 s3 h3  (temps mC, increasing)
    shift
    [ $# -eq 12 ] || { echo "need 12 args"; exit 1; }
    args=("$@")
    last=0
    for i in 0 3 6 9; do
        t="${args[$i]}"; s="${args[$((i+1))]}"; h="${args[$((i+2))]}"
        [[ "$t" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { echo "bad arg"; exit 1; }
        [ "$t" -ge 30000 ] && [ "$t" -le 90000 ] || { echo "temp out of range"; exit 1; }
        [ "$s" -le 255 ] || { echo "speed out of range"; exit 1; }
        [ "$h" -ge 1000 ] && [ "$h" -le 15000 ] || { echo "hyst out of range"; exit 1; }
        [ "$t" -gt "$last" ] || { echo "temps must increase"; exit 1; }
        last="$t"
    done
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak.ui.$(date +%Y%m%d_%H%M%S)"
    ls -t "$CONFIG_TXT".bak.ui.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    for i in 0 1 2 3; do
        t="${args[$((i*3))]}"; s="${args[$((i*3+1))]}"; h="${args[$((i*3+2))]}"
        sed -i "s/^dtparam=fan_temp${i}=.*/dtparam=fan_temp${i}=${t}/" "$CONFIG_TXT"
        sed -i "s/^dtparam=fan_temp${i}_speed=.*/dtparam=fan_temp${i}_speed=${s}/" "$CONFIG_TXT"
        sed -i "s/^dtparam=fan_temp${i}_hyst=.*/dtparam=fan_temp${i}_hyst=${h}/" "$CONFIG_TXT"
    done
    log "fan-save curve updated (reboot needed)"
    echo "saved (reboot needed)"
    ;;
config-set)
    # config-set KEY VALUE [KEY VALUE...]
    shift
    while [ $# -ge 2 ]; do
        k="$1"; v="$2"; shift 2
        case "$k" in
        WIFI_OFF|FAN_OFF|KEEP_AGENT|PANEL_OFF|SD_OFF)
            [[ "$v" =~ ^[01]$ ]] || { echo "bad $k"; exit 1; }
            sed -i "s/^${k}=[01]/${k}=${v}/" "$SLEEP_SH" ;;
        WATCHDOG_TEMP)
            [[ "$v" =~ ^[0-9]{5,6}$ ]] && [ "$v" -ge 50000 ] && [ "$v" -le 90000 ] || { echo "bad $k"; exit 1; }
            sed -i "s/^WATCHDOG_TEMP=[0-9]*/WATCHDOG_TEMP=${v}/" "$SLEEP_SH" ;;
        LONG_MS)
            [[ "$v" =~ ^[0-9]{3,5}$ ]] && [ "$v" -ge 500 ] && [ "$v" -le 10000 ] || { echo "bad $k"; exit 1; }
            sed -i "s/^LONG_MS = [0-9]*/LONG_MS = ${v}/" "$DAEMON_PY"
            systemctl restart powerbtn-daemon ;;
        *) echo "unknown key $k"; exit 1 ;;
        esac
        log "config-set $k=$v"
    done
    echo "applied"
    ;;
action)
    case "$2" in
    sleep)    log "UI action: sleep";    nohup /usr/local/bin/powerbtn-deepsleep.sh >/dev/null 2>&1 & echo "sleeping" ;;
    fastboot) log "UI action: fastboot"; nohup /usr/local/bin/fastboot-save.sh >/dev/null 2>&1 & echo "fastboot" ;;
    reboot)   log "UI action: reboot";   shutdown -r +0 ;;
    *) echo "unknown action"; exit 1 ;;
    esac
    ;;
*)
    echo "usage: fan-test|fan-manual|fan-auto|fan-save|config-set|action"; exit 1 ;;
esac

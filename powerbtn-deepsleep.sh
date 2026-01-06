#!/bin/bash
# powerbtn-deepsleep.sh - Raspberry Pi Deep Sleep Power Button Handler
# Toggles between normal state and aggressive power saving mode on key 116 press
# Usage: Place in /usr/local/bin/ and trigger via ACPI event

# Don't use set -e as we want to continue even if some commands fail

STATE_FILE="/tmp/pi-deepsleep-state"
LOG_FILE="/var/log/pi-deepsleep.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Aggressive power saving - enter deep sleep
enter_deep_sleep() {
    log "Entering deep sleep mode..."

    # Save current state
    echo "sleeping" > "$STATE_FILE"

    # Block radios via rfkill (more reliable than stopping services)
    rfkill block bluetooth 2>/dev/null || true
    rfkill block wifi 2>/dev/null || true
    log "Radios blocked (bluetooth + wifi)"

    # Stop non-essential services
    systemctl stop avahi-daemon.service 2>/dev/null || true
    systemctl stop triggerhappy.service 2>/dev/null || true
    log "Services stopped"

    # Disable HDMI output (Pi5 uses KMS - requires root, may fail in some setups)
    {
        for card in /sys/class/drm/card*-HDMI-*/enabled; do
            [ -f "$card" ] && echo "disabled" > "$card"
        done
    } 2>/dev/null || true
    log "HDMI disabled"

    # Disable USB power (saves ~100-500mA depending on devices)
    for bus in /sys/bus/usb/devices/usb*/power/control; do
        [ -f "$bus" ] && echo "auto" > "$bus" 2>/dev/null || true
    done

    # Set CPU to powersave governor
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo "powersave" > "$cpu" 2>/dev/null || true
    done
    log "CPU set to powersave"

    # Set ACT LED to slow heartbeat (visual sleep indicator)
    echo heartbeat > /sys/class/leds/ACT/trigger 2>/dev/null || true
    # Disable PWR LED
    echo 0 > /sys/class/leds/PWR/brightness 2>/dev/null || true
    echo none > /sys/class/leds/PWR/trigger 2>/dev/null || true
    log "LEDs: ACT=heartbeat, PWR=off"

    # Sync filesystems
    sync

    log "Deep sleep mode active"
}

# Exit deep sleep - restore normal operation
exit_deep_sleep() {
    log "Exiting deep sleep mode..."

    # Clear state
    rm -f "$STATE_FILE"

    # Unblock radios via rfkill
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock bluetooth 2>/dev/null || true
    log "Radios unblocked"

    # Re-enable HDMI (Pi5 uses KMS)
    {
        for card in /sys/class/drm/card*-HDMI-*/enabled; do
            [ -f "$card" ] && echo "enabled" > "$card"
        done
    } 2>/dev/null || true

    # Restore USB power
    for bus in /sys/bus/usb/devices/usb*/power/control; do
        [ -f "$bus" ] && echo "on" > "$bus" 2>/dev/null || true
    done

    # Set CPU to ondemand governor
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo "ondemand" > "$cpu" 2>/dev/null || true
    done
    log "CPU set to ondemand"

    # Re-enable LEDs
    echo mmc0 > /sys/class/leds/ACT/trigger 2>/dev/null || true
    echo default-on > /sys/class/leds/PWR/trigger 2>/dev/null || true

    # Restart essential services
    systemctl start avahi-daemon.service 2>/dev/null || true
    systemctl start triggerhappy.service 2>/dev/null || true

    log "Normal operation restored"
}

# Main logic - toggle between states
main() {
    if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "sleeping" ]; then
        exit_deep_sleep
    else
        enter_deep_sleep
    fi
}

main "$@"

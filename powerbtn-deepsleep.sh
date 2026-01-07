#!/bin/bash
# powerbtn-deepsleep.sh - Raspberry Pi Deep Sleep Power Button Handler
# Toggles between normal state and aggressive power saving mode on key 116 press
# Usage: Place in /usr/local/bin/ and trigger via ACPI event

# Don't use set -e as we want to continue even if some commands fail

STATE_FILE="/tmp/pi-deepsleep-state"
STOPPED_PIDS_FILE="/tmp/pi-deepsleep-stopped-pids"
LOG_FILE="/var/log/pi-deepsleep.log"

# Processes that must NEVER be stopped (regex patterns)
# Kernel threads, init, systemd core, display, input handlers, this script
EXCLUDE_PATTERNS="^(systemd|init|kthreadd|kworker|rcu_|migration|watchdog|ksoftirqd|cpuhp|idle_inject)"
EXCLUDE_PATTERNS+="|^(Xorg|Xwayland|weston|labwc|openbox|lxsession|lxpanel|pcmanfm)"
EXCLUDE_PATTERNS+="|^(acpid|dbus|polkit|login|getty|agetty|sshd|ssh-agent)"
EXCLUDE_PATTERNS+="|^(irq/|i2c-|spi-|mmc-|usb-|input-|hid-)"
EXCLUDE_PATTERNS+="|^(bash|sh|dash|zsh)$"
EXCLUDE_PATTERNS+="|powerbtn-deepsleep"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Freeze non-essential user processes with SIGSTOP
freeze_processes() {
    log "Freezing non-essential processes..."
    local count=0
    local skipped_tty=0
    > "$STOPPED_PIDS_FILE"  # Clear file

    # Get all user processes (not kernel threads) with TTY info
    while read -r pid tty comm; do
        # Skip kernel threads (PPID 2 or comm in brackets)
        [[ "$comm" == \[*\] ]] && continue

        # Skip if matches exclude patterns
        echo "$comm" | grep -qE "$EXCLUDE_PATTERNS" && continue

        # Skip PID 1, 2 and our own process tree
        [[ "$pid" -le 2 ]] && continue
        [[ "$pid" -eq $$ ]] && continue
        [[ "$pid" -eq $PPID ]] && continue

        # Skip processes with a controlling terminal (interactive processes)
        # These can't resume properly due to job control (SIGTTIN/SIGTTOU)
        if [[ "$tty" != "?" ]]; then
            ((skipped_tty++))
            continue
        fi

        # Send SIGSTOP and record if successful
        if kill -STOP "$pid" 2>/dev/null; then
            echo "$pid" >> "$STOPPED_PIDS_FILE"
            ((count++))
        fi
    done < <(ps -eo pid=,tty=,comm= --no-headers 2>/dev/null)

    log "Frozen $count processes (skipped $skipped_tty with tty)"
}

# Resume frozen processes with SIGCONT
thaw_processes() {
    log "Thawing frozen processes..."
    local count=0

    if [ -f "$STOPPED_PIDS_FILE" ]; then
        while read -r pid; do
            if kill -CONT "$pid" 2>/dev/null; then
                ((count++))
            fi
        done < "$STOPPED_PIDS_FILE"
        rm -f "$STOPPED_PIDS_FILE"
    fi

    log "Thawed $count processes"
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

    # Freeze non-essential processes (last step - most aggressive)
    freeze_processes

    log "Deep sleep mode active"
}

# Exit deep sleep - restore normal operation
exit_deep_sleep() {
    log "Exiting deep sleep mode..."

    # Thaw processes first (restore them before anything else)
    thaw_processes

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

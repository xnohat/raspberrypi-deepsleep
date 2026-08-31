#!/bin/bash
# powerbtn-deepsleep.sh - Raspberry Pi Deep Sleep Power Button Handler
# Toggles between normal state and aggressive power saving mode on key 116 press
# Usage: Place in /usr/local/bin/ and trigger via ACPI event

# Don't use set -e as we want to continue even if some commands fail

STATE_FILE="/tmp/pi-deepsleep-state"
STOPPED_PIDS_FILE="/tmp/pi-deepsleep-stopped-pids"
SAVED_STATE_FILE="/tmp/pi-deepsleep-saved"
WATCHDOG_PID_FILE="/tmp/pi-deepsleep-watchdog-pid"
LOG_FILE="/var/log/pi-deepsleep.log"

# ── Config ───────────────────────────────────────────────────────
WIFI_OFF=1            # 1 = block wifi in sleep (kills remote chat/ssh; wake only via button)
PANEL_OFF=1           # 1 = disable DPI scanout in sleep (~1W! backlight button alone does NOT
                      #     stop SoC scanout/HVS). Wake restores. Recover if flicker: screen btn/SW3.
KEEP_AGENT=1          # 1 = don't freeze AICoworker gateway (chat keeps working in sleep, can wake remotely)
FAN_OFF=1             # 1 = stop fan in sleep (thermal watchdog below still protects)
SD_OFF=1              # 1 = power off SD-card slot in sleep (~120mW; only safe when NOT booting from SD)
WATCHDOG_TEMP=70000   # millidegC: watchdog re-enables fan above this
WATCHDOG_INTERVAL=30  # seconds between watchdog temp checks
# Stopped in sleep; only services that were ACTIVE before sleep are restarted
# on wake (state saved to SAVED_STATE_FILE).
HEAVY_SERVICES="ollama.service waydroid-container.service docker.service docker.socket containerd.service tailscaled.service lxc-monitord.service lxcfs.service snapd.service snapd.socket cups.service cups.socket cups-browsed.service ModemManager.service accounts-daemon.service power-profiles-daemon.service switcheroo-control.service"
DISPLAY_USER=pi
DISPLAY_OUTPUT="DPI-1"
TOUCH_I2C_DEV="13-0048"
TOUCH_DRIVER="/sys/bus/i2c/drivers/edt_ft5x06"
SD_MMC_DEV="1000fff000.mmc"   # SD-card slot controller (mmc0). NOT the wifi SDIO (1001100000.mmc)!
# ─────────────────────────────────────────────────────────────────

# Processes that must NEVER be stopped (regex patterns)
# Kernel threads, init, systemd core, display, input handlers, this script
EXCLUDE_PATTERNS="^(systemd|init|kthreadd|kworker|rcu_|migration|watchdog|ksoftirqd|cpuhp|idle_inject)"
EXCLUDE_PATTERNS+="|^(Xorg|Xwayland|weston|labwc|openbox|lxsession|lxpanel|pcmanfm)"
# UI-critical helpers: freezing these hangs input/compositor (polkit agent modal grab!)
EXCLUDE_PATTERNS+="|polkit|^(wf-panel|pipewire|wireplumber|seatd|squeekboard|kanshi|swayidle|wlopm|xdg-desktop)"
EXCLUDE_PATTERNS+="|^(acpid|dbus|polkit|login|getty|agetty|sshd|ssh-agent)"
EXCLUDE_PATTERNS+="|^(irq/|i2c-|spi-|mmc-|usb-|input-|hid-)"
EXCLUDE_PATTERNS+="|^(bash|sh|dash|zsh)$"
# NOTE: ps comm truncates to 15 chars ("deepsleep-watch"), match prefixes
EXCLUDE_PATTERNS+="|powerbtn-deepsl|powerbtn-daemon|deepsleep-|battery-log"
# Never freeze 'sleep' children: the watchdog/logger loops block on `sleep N`;
# freezing that child freezes the whole loop (watchdog dead = no fan safety!)
EXCLUDE_PATTERNS+="|^sleep$"
# Keep the AI agent gateway alive so the machine stays reachable in sleep.
# BUT: if wifi is off, the agent is unreachable anyway — keeping its heavy
# Electron/chromium stack awake would burn ~1A for nothing. So the agent is
# only kept alive when it can actually be reached (KEEP_AGENT=1 AND wifi on).
if [ "$KEEP_AGENT" = "1" ] && [ "$WIFI_OFF" != "1" ]; then
    EXCLUDE_PATTERNS+="|openclaw|aicoworker|crawbot"
    AGENT_KEPT=1
else
    AGENT_KEPT=0
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

fan_hwmon_dir() {
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "pwmfan" ] && { echo "$h"; return 0; }
    done
    return 1
}

# Seed cooling state for current temp (interrupt-driven zone won't re-evaluate
# until the next trip crossing, so after manual pwm changes the fan can stay
# stuck off between trips)
seed_cooling_state() {
    local t st
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    st=0
    [ "$t" -ge 55000 ] && st=1
    [ "$t" -ge 65000 ] && st=2
    [ "$t" -ge 72000 ] && st=3
    [ "$t" -ge 78000 ] && st=4
    echo "$st" > /sys/class/thermal/cooling_device0/cur_state 2>/dev/null
}

# Fail-safe: on any unexpected exit while entering/being in sleep, give the
# fan back to the kernel and seed a sane state.
restore_fan_failsafe() {
    local fh
    fh=$(fan_hwmon_dir) || return 0
    echo 2 > "$fh/pwm1_enable" 2>/dev/null
    seed_cooling_state
}
trap restore_fan_failsafe TERM INT

# Freeze non-essential user processes with SIGSTOP
freeze_processes() {
    log "Freezing non-essential processes... (agent kept alive: ${AGENT_KEPT:-0})"
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

# Turn the DPI panel off/on via the compositor (wlr-randr under labwc/wayland)
panel_off() {
    local rtdir uid
    uid=$(id -u "$DISPLAY_USER" 2>/dev/null) || return 0
    rtdir="/run/user/$uid"
    timeout 10 sudo -u "$DISPLAY_USER" WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$rtdir" \
        wlr-randr --output "$DISPLAY_OUTPUT" --off 2>/dev/null || true
    log "Panel $DISPLAY_OUTPUT off"
}

panel_on() {
    local rtdir uid
    uid=$(id -u "$DISPLAY_USER" 2>/dev/null) || return 0
    rtdir="/run/user/$uid"
    timeout 10 sudo -u "$DISPLAY_USER" WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="$rtdir" \
        wlr-randr --output "$DISPLAY_OUTPUT" --on 2>/dev/null || true
    log "Panel $DISPLAY_OUTPUT on"
}

# SD-card slot power off (~120mW measured via PMIC). Safe ONLY because this
# device boots from NVMe — the SD card is just removable media. Unmounts any
# mounted partitions first; unbind cuts vcc-sd regulator power to the slot.
sd_off() {
    [ "$SD_OFF" = "1" ] || return 0
    # never touch it if root/boot lives on the SD card
    case "$(findmnt -n -o SOURCE / 2>/dev/null)$(findmnt -n -o SOURCE /boot/firmware 2>/dev/null)" in
        *mmcblk*) log "SD off skipped: system boots from SD"; return 0 ;;
    esac
    local drv
    for d in /sys/bus/platform/drivers/*/"$SD_MMC_DEV"; do
        [ -e "$d" ] && drv=$(dirname "$d") && break
    done
    [ -n "$drv" ] || { log "SD host driver not found"; return 0; }
    # unmount any mounted partitions of mmcblk0
    local m
    for m in $(lsblk -n -o MOUNTPOINTS /dev/mmcblk0 2>/dev/null | grep -v '^$'); do
        umount "$m" 2>/dev/null && echo "sd_mount=$m" >> "$SAVED_STATE_FILE"
    done
    if echo "$SD_MMC_DEV" > "$drv/unbind" 2>/dev/null; then
        echo "sd_drv=$drv" >> "$SAVED_STATE_FILE"
        log "SD-card slot powered off (unbound $SD_MMC_DEV)"
    fi
}

sd_restore() {
    local drv
    drv=$(grep "^sd_drv=" "$SAVED_STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ -n "$drv" ] || return 0
    echo "$SD_MMC_DEV" > "$drv/bind" 2>/dev/null && log "SD-card slot rebound"
    # remount is left to udisks/user (removable media semantics)
}

# Fan control: off in sleep + background thermal watchdog as safety net
fan_off_with_watchdog() {
    [ "$FAN_OFF" = "1" ] || return 0
    local fh
    fh=$(fan_hwmon_dir) || { log "Fan hwmon not found"; return 0; }

    echo "fan_enable=$(cat "$fh/pwm1_enable" 2>/dev/null)" >> "$SAVED_STATE_FILE"
    echo 1 > "$fh/pwm1_enable" 2>/dev/null
    echo 0 > "$fh/pwm1" 2>/dev/null
    log "Fan stopped (manual pwm=0)"

    # Thermal watchdog: if SoC gets hot while sleeping, give the fan back to the kernel.
    # Run under systemd (own scope, root) so the freeze pass can NEVER stop it.
    cat > /tmp/deepsleep-watchdog.sh <<WDEOF
#!/bin/bash
FH="$fh"; SF="$STATE_FILE"; LOGF="$LOG_FILE"
while [ -f "\$SF" ]; do
    t=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    if [ "\$t" -gt $WATCHDOG_TEMP ]; then
        echo 2 > "\$FH/pwm1_enable" 2>/dev/null
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - WATCHDOG: temp \${t} > $WATCHDOG_TEMP, fan re-enabled (auto)" >> "\$LOGF"
        exit 0
    fi
    sleep $WATCHDOG_INTERVAL
done
WDEOF
    chmod +x /tmp/deepsleep-watchdog.sh
    systemd-run --unit=deepsleep-watchdog --collect --quiet /tmp/deepsleep-watchdog.sh 2>/dev/null
    sleep 0.5
    if systemctl is-active deepsleep-watchdog.service >/dev/null 2>&1; then
        log "Thermal watchdog started (systemd unit deepsleep-watchdog, threshold ${WATCHDOG_TEMP}mC)"
    else
        # Fail-safe: watchdog not RUNNING -> no fan-off allowed
        echo 2 > "$fh/pwm1_enable" 2>/dev/null
        seed_cooling_state
        log "WARNING: watchdog not active — fan left in auto mode"
    fi
}

fan_restore() {
    local fh
    fh=$(fan_hwmon_dir) || return 0
    systemctl stop deepsleep-watchdog.service 2>/dev/null
    rm -f "$WATCHDOG_PID_FILE"
    # Give fan back to kernel thermal governor
    echo 2 > "$fh/pwm1_enable" 2>/dev/null
    seed_cooling_state
    log "Fan restored to auto thermal control (cooling state seeded)"
}

# Aggressive power saving - enter deep sleep
enter_deep_sleep() {
    log "Entering deep sleep mode..."

    # Save current state
    echo "sleeping" > "$STATE_FILE"
    > "$SAVED_STATE_FILE"

    # Disable DPI scanout: the hardware screen button only cuts BACKLIGHT;
    # SoC keeps burning ~1W on scanout (HVS + pixel clock + compositor render).
    # Measured 31/8: total 4.3W -> 3.3W with scanout off. Flicker risk on
    # wake after very long off is accepted (recover: screen button / SW3).
    if [ "$PANEL_OFF" = "1" ]; then panel_off; fi

    # Unbind touch controller (no input needed while sleeping)
    if [ -e "$TOUCH_DRIVER/$TOUCH_I2C_DEV" ]; then
        echo "$TOUCH_I2C_DEV" > "$TOUCH_DRIVER/unbind" 2>/dev/null && log "Touch unbound"
    fi

    # Block radios via rfkill (wifi optional: keeping it preserves remote chat/ssh)
    rfkill block bluetooth 2>/dev/null || true
    if [ "$WIFI_OFF" = "1" ]; then
        rfkill block wifi 2>/dev/null || true
        log "Radios blocked (bluetooth + wifi)"
    else
        log "Bluetooth blocked (wifi kept for remote access)"
    fi

    # Stop heavy + non-essential services (record which were active so wake
    # only restarts those — never starts something the user had disabled)
    active_svcs=""
    for svc in $HEAVY_SERVICES avahi-daemon.service triggerhappy.service; do
        if systemctl is-active "$svc" >/dev/null 2>&1; then
            active_svcs="$active_svcs $svc"
        fi
    done
    echo "services=$active_svcs" >> "$SAVED_STATE_FILE"
    for svc in $active_svcs; do
        systemctl stop "$svc" 2>/dev/null || true
    done
    log "Services stopped:$active_svcs"

    # Kill x86-emulated processes (qemu binfmt: open-webui supervisord stack).
    # Emulation burns power even idle; supervisord under docker/systemd will
    # be restarted by its parent service on wake.
    pkill -f "qemu-binfmt" 2>/dev/null || true
    log "qemu-emulated processes killed"

    # Disable HDMI output (harmless if none connected)
    {
        for card in /sys/class/drm/card*-HDMI-*/enabled; do
            [ -f "$card" ] && echo "disabled" > "$card"
        done
    } 2>/dev/null || true

    # USB autosuspend (saves ~100-500mA depending on devices)
    for bus in /sys/bus/usb/devices/usb*/power/control; do
        [ -f "$bus" ] && echo "auto" > "$bus" 2>/dev/null || true
    done

    # NVMe/PCIe runtime power management
    for dev in /sys/bus/pci/devices/*/power/control /sys/class/nvme/nvme*/device/power/control; do
        [ -f "$dev" ] && echo "auto" > "$dev" 2>/dev/null || true
    done
    log "USB + PCIe/NVMe runtime PM enabled"

    # Power off SD-card slot (~120mW, boots from NVMe so SD is just media)
    sd_off

    # NOTE: do NOT offline CPU cores — on CM5 PSCI CPU_ON fails (-22) and
    # cores stay dead until reboot. Use governor + freq cap instead.
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo "powersave" > "$cpu" 2>/dev/null || true
    done
    # Cap max frequency to minimum available (restored on wake)
    minfreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null)
    if [ -n "$minfreq" ]; then
        echo "maxfreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)" >> "$SAVED_STATE_FILE"
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
            [ -f "$cpu" ] && echo "$minfreq" > "$cpu" 2>/dev/null || true
        done
    fi
    log "CPU set to powersave + freq capped to ${minfreq}"

    # Stop the fan + start thermal watchdog
    fan_off_with_watchdog

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

    # Re-enable DPI scanout
    if [ "$PANEL_OFF" = "1" ]; then panel_on; fi

    # Clear state (also stops the watchdog loop condition)
    rm -f "$STATE_FILE"

    # Fan back to kernel auto control
    fan_restore

    # Restore CPU max frequency
    maxfreq=$(grep "^maxfreq=" "$SAVED_STATE_FILE" 2>/dev/null | cut -d= -f2)
    [ -z "$maxfreq" ] && maxfreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    if [ -n "$maxfreq" ]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
            [ -f "$cpu" ] && echo "$maxfreq" > "$cpu" 2>/dev/null || true
        done
    fi
    log "CPU max freq restored to ${maxfreq}"

    # Unblock radios via rfkill
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock bluetooth 2>/dev/null || true
    log "Radios unblocked"

    # Re-enable HDMI
    {
        for card in /sys/class/drm/card*-HDMI-*/enabled; do
            [ -f "$card" ] && echo "enabled" > "$card"
        done
    } 2>/dev/null || true

    # Restore USB power
    for bus in /sys/bus/usb/devices/usb*/power/control; do
        [ -f "$bus" ] && echo "on" > "$bus" 2>/dev/null || true
    done

    # Restore NVMe/PCIe power
    for dev in /sys/bus/pci/devices/*/power/control /sys/class/nvme/nvme*/device/power/control; do
        [ -f "$dev" ] && echo "on" > "$dev" 2>/dev/null || true
    done

    # Re-power the SD-card slot
    sd_restore

    # Set CPU to ondemand governor
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo "ondemand" > "$cpu" 2>/dev/null || true
    done
    log "CPU set to ondemand"

    # Rebind touch controller
    if [ -d "$TOUCH_DRIVER" ] && [ ! -e "$TOUCH_DRIVER/$TOUCH_I2C_DEV" ]; then
        echo "$TOUCH_I2C_DEV" > "$TOUCH_DRIVER/bind" 2>/dev/null && log "Touch rebound"
    fi

    # Re-enable LEDs
    echo mmc0 > /sys/class/leds/ACT/trigger 2>/dev/null || true
    echo default-on > /sys/class/leds/PWR/trigger 2>/dev/null || true

    # Restart only the services that were active before sleep
    restore_svcs=$(grep "^services=" "$SAVED_STATE_FILE" 2>/dev/null | cut -d= -f2-)
    for svc in $restore_svcs; do
        systemctl start "$svc" 2>/dev/null || true
    done
    log "Services restarted:${restore_svcs:- (none)}"

    rm -f "$SAVED_STATE_FILE"
    log "Normal operation restored"
}

# Main logic - toggle between states
# flock: serialize + debounce so double button events can't race two toggles
main() {
    exec 9>/tmp/pi-deepsleep.lock
    if ! flock -n 9; then
        log "Another toggle already running - ignoring this press"
        exit 0
    fi
    # Debounce: ignore presses within 3s of the last accepted one
    now=$(date +%s)
    last=$(cat /tmp/pi-deepsleep-lastpress 2>/dev/null || echo 0)
    if [ $((now - last)) -lt 3 ]; then
        log "Debounce: press within 3s of previous - ignored"
        exit 0
    fi
    echo "$now" > /tmp/pi-deepsleep-lastpress

    if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "sleeping" ]; then
        exit_deep_sleep
    else
        enter_deep_sleep
    fi
}

main "$@"

#!/bin/bash
# doctor.sh — verify Pi Deep Sleep + Fastboot + PiTerm installation health.
# Exit 0 = all good; exit 1 = problems found.

TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
FAIL=0

ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; FAIL=1; }

echo "── dependencies ──"
for c in tmux foot acpid wl-copy; do
    command -v "$c" >/dev/null && ok "$c" || bad "$c missing"
done
python3 -c "import evdev" 2>/dev/null && ok "python3-evdev" || bad "python3-evdev missing"

echo "── scripts ──"
for f in powerbtn-deepsleep.sh fastboot-save.sh fastboot-restore.sh tmux-state.py powerbtn-daemon.py fastboot; do
    [ -x "/usr/local/bin/$f" ] && ok "/usr/local/bin/$f" || bad "/usr/local/bin/$f missing"
done

echo "── power button ──"
systemctl is-active powerbtn-daemon >/dev/null 2>&1 && ok "powerbtn-daemon active" || bad "powerbtn-daemon NOT active"
ACTIVE_HANDLERS=$(ls /etc/acpi/events/ 2>/dev/null | grep -vc disabled || true)
[ "$ACTIVE_HANDLERS" = "0" ] && ok "no legacy acpid handlers" || bad "$ACTIVE_HANDLERS legacy acpid handler(s) still active"
if [ -f /usr/bin/pwrkey ]; then
    grep -q "exit 0" /usr/bin/pwrkey && ok "pwrkey no-op" || bad "pwrkey still active"
fi
grep -q "^HandlePowerKey=ignore" /etc/systemd/logind.conf && ok "logind ignores power key" || bad "logind HandlePowerKey not ignore"

echo "── sudoers ──"
[ -f /etc/sudoers.d/pi-deepsleep ] && visudo -c -f /etc/sudoers.d/pi-deepsleep >/dev/null 2>&1 \
    && ok "sudoers rules valid" || bad "sudoers rules missing/invalid"

echo "── piterm ──"
[ -f "$TARGET_HOME/.config/foot/foot.ini" ] && ok "foot.ini" || bad "foot.ini missing"
[ -f "$TARGET_HOME/.tmux.conf" ] && ok ".tmux.conf" || bad ".tmux.conf missing"
[ -x "$TARGET_HOME/.local/bin/piterm-attach" ] && ok "piterm-attach" || bad "piterm-attach missing"
[ -f "$TARGET_HOME/.local/share/applications/piterm.desktop" ] && ok "piterm.desktop" || bad "piterm.desktop missing"

echo "── pi power gui ──"
[ -x /usr/local/bin/pipower-gui.py ] && ok "pipower-gui.py" || bad "pipower-gui.py missing"
[ -x /usr/local/bin/pipower-apply.sh ] && ok "pipower-apply.sh" || bad "pipower-apply.sh missing"
[ -f /etc/sudoers.d/pi-power-ui ] && ok "sudoers pi-power-ui" || bad "sudoers pi-power-ui missing"
systemctl is-active battery-logger >/dev/null 2>&1 && ok "battery-logger active" || bad "battery-logger NOT active"
python3 -c "import tkinter" 2>/dev/null && ok "python3-tk" || bad "python3-tk missing"

echo "── fastboot hooks ──"
grep -q "fastboot-restore" "$TARGET_HOME/.config/labwc/autostart" 2>/dev/null \
    && ok "labwc autostart hook" || bad "labwc autostart hook missing"
[ -f /var/log/pi-deepsleep.log ] && ok "log file" || bad "log file missing"

echo ""
if [ "$FAIL" = "0" ]; then
    echo "DOCTOR: all checks passed ✓"
else
    echo "DOCTOR: PROBLEMS FOUND ✗ (see above)"
fi
exit $FAIL

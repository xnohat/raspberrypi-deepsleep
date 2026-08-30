#!/bin/bash
# install.sh — Pi Deep Sleep + Fastboot + PiTerm installer (idempotent)
# Run with: sudo ./install.sh
#
# Installs three integrated features for HackberryPi CM5 (and similar):
#   1. DEEP SLEEP  — short power-button press toggles aggressive power saving
#   2. FASTBOOT    — 2s power-button hold saves the session (tmux windows,
#                    running commands, chromium tabs, file manager) then
#                    shuts down cleanly; everything is reconstructed on boot
#   3. PITERM      — foot + tmux terminal with grouped multi-window views,
#                    status bar (battery/temp/fan/wifi) and mouse context menu
#
# Note: fastboot is session RECONSTRUCTION (relaunch/prefill of commands),
# not process-memory hibernation (the Pi cannot hibernate).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-pi}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

echo "=== Pi Deep Sleep + Fastboot + PiTerm Installer ==="
echo "user=$TARGET_USER home=$TARGET_HOME"

if [ "$EUID" -ne 0 ]; then
    echo "Error: run as root (sudo ./install.sh)"
    exit 1
fi

as_user() { sudo -u "$TARGET_USER" "$@"; }

# ── 1. Dependencies ──────────────────────────────────────────────
echo "[1/8] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq acpid iw tmux foot python3-evdev wl-clipboard wayland-utils

# ── 2. Core scripts ──────────────────────────────────────────────
echo "[2/8] Installing scripts to /usr/local/bin..."
install -m 755 "$SCRIPT_DIR/powerbtn-deepsleep.sh" /usr/local/bin/
install -m 755 "$SCRIPT_DIR/fastboot-save.sh"      /usr/local/bin/
install -m 755 "$SCRIPT_DIR/fastboot-restore.sh"   /usr/local/bin/
install -m 755 "$SCRIPT_DIR/tmux-state.py"         /usr/local/bin/
install -m 755 "$SCRIPT_DIR/powerbtn-daemon.py"    /usr/local/bin/
# convenience command: `fastboot` saves session + shuts down
cat > /usr/local/bin/fastboot << 'EOF'
#!/bin/sh
exec sudo -n /usr/local/bin/fastboot-save.sh
EOF
chmod 755 /usr/local/bin/fastboot
# battery logger (optional measurement helper)
[ -f "$SCRIPT_DIR/battery-logger.sh" ] && install -m 755 "$SCRIPT_DIR/battery-logger.sh" /usr/local/bin/ || true

# ── 3. Sudoers (button daemon runs as root; user command needs no pass) ──
echo "[3/8] Sudoers rules..."
cat > /etc/sudoers.d/pi-deepsleep << EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/powerbtn-deepsleep.sh
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/fastboot-save.sh
EOF
chmod 440 /etc/sudoers.d/pi-deepsleep
visudo -c -f /etc/sudoers.d/pi-deepsleep >/dev/null

# ── 4. Power button daemon (replaces ALL other handlers) ─────────
echo "[4/8] Power button daemon..."
install -m 644 "$SCRIPT_DIR/powerbtn-daemon.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now powerbtn-daemon.service
# retire every legacy handler: acpid events + desktop pwrkey + logind
for f in /etc/acpi/events/powerbtn-custom /etc/acpi/events/powerbtn-acpi-support /etc/acpi/events/powerbtn; do
    [ -f "$f" ] && mv "$f" "$f.disabled"
done
systemctl restart acpid 2>/dev/null || true
PWRKEY_BIN="/usr/bin/pwrkey"
if [ -f "$PWRKEY_BIN" ]; then
    [ -f "${PWRKEY_BIN}.bak" ] || cp "$PWRKEY_BIN" "${PWRKEY_BIN}.bak"
    cat > "$PWRKEY_BIN" << 'EOF'
#!/bin/sh
# Power button handled EXCLUSIVELY by powerbtn-daemon (evdev grab).
exit 0
EOF
    chmod +x "$PWRKEY_BIN"
fi
PWRKEY_DESKTOP="/etc/xdg/autostart/pwrkey.desktop"
[ -f "$PWRKEY_DESKTOP" ] && mv "$PWRKEY_DESKTOP" "${PWRKEY_DESKTOP}.disabled"
LOGIND_CONF="/etc/systemd/logind.conf"
if grep -q "^HandlePowerKey=" "$LOGIND_CONF"; then
    sed -i 's/^HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF"
else
    sed -i 's/^#HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF" || echo "HandlePowerKey=ignore" >> "$LOGIND_CONF"
fi
systemctl kill -s HUP systemd-logind 2>/dev/null || true

# ── 5. PiTerm (foot + tmux) ──────────────────────────────────────
echo "[5/8] PiTerm..."
install -d -o "$TARGET_USER" -g "$TARGET_USER" \
    "$TARGET_HOME/.config/foot" "$TARGET_HOME/.local/bin" \
    "$TARGET_HOME/.local/share/applications"
# backup existing user configs once (never clobber user edits silently)
for f in "$TARGET_HOME/.config/foot/foot.ini" "$TARGET_HOME/.tmux.conf"; do
    [ -f "$f" ] && [ ! -f "$f.pre-piterm" ] && cp "$f" "$f.pre-piterm"
done
install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/terminal/foot.ini"       "$TARGET_HOME/.config/foot/foot.ini"
install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/terminal/tmux.conf"      "$TARGET_HOME/.tmux.conf"
install -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/terminal/tmux-status.sh" "$TARGET_HOME/.tmux-status.sh"
install -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/terminal/piterm-attach"  "$TARGET_HOME/.local/bin/piterm-attach"
install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$SCRIPT_DIR/terminal/piterm.desktop" "$TARGET_HOME/.local/share/applications/piterm.desktop"
as_user update-desktop-database "$TARGET_HOME/.local/share/applications" 2>/dev/null || true

# ── 6. Labwc hooks: restore-on-boot + PiTerm maximize rule ───────
echo "[6/8] Labwc autostart + window rule..."
LABWC_DIR="$TARGET_HOME/.config/labwc"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$LABWC_DIR"
AUTOSTART="$LABWC_DIR/autostart"
touch "$AUTOSTART"; chown "$TARGET_USER:$TARGET_USER" "$AUTOSTART"
grep -q "fastboot-restore" "$AUTOSTART" || echo "/usr/local/bin/fastboot-restore.sh &" >> "$AUTOSTART"
RC="$LABWC_DIR/rc.xml"
if [ -f "$RC" ] && ! grep -q 'identifier="piterm"' "$RC"; then
    python3 - "$RC" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
rule = '''  <windowRules>
    <windowRule identifier="piterm" serverDecoration="yes">
      <action name="Maximize"/>
    </windowRule>
  </windowRules>
'''
if '</openbox_config>' in s and '<windowRules>' not in s:
    s = s.replace('</openbox_config>', rule + '</openbox_config>')
    open(p, 'w').write(s)
PYEOF
fi

# ── 7. Log file ──────────────────────────────────────────────────
echo "[7/8] Log file..."
touch /var/log/pi-deepsleep.log
chmod 644 /var/log/pi-deepsleep.log

# ── 8. Doctor ────────────────────────────────────────────────────
echo "[8/8] Verifying installation..."
bash "$SCRIPT_DIR/doctor.sh" || true

echo ""
echo "=== Installation Complete ==="
echo "Power button:  short press        = deep sleep toggle"
echo "               hold 2s (release)  = fastboot: save session + shutdown"
echo "Command:       fastboot           = same as 2s hold"
echo "PiTerm:        app menu / taskbar = terminal with session persistence"
echo "Log:           /var/log/pi-deepsleep.log"
echo "Uninstall:     sudo ./uninstall.sh"

#!/bin/bash
# Install the patched wf-panel-pi battery plugin (shows % inside the battery +
# a charging bolt derived from the MAX17048 CRATE register).
# Backs up the stock plugin once, installs the prebuilt .so, restarts the panel.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/lib/aarch64-linux-gnu/wf-panel-pi/libbatt.so"

if [ ! -f "$HERE/libbatt.so" ]; then echo "libbatt.so missing in $HERE"; exit 1; fi
if [ "$EUID" -ne 0 ]; then echo "run with sudo"; exit 1; fi

# one-time backup of the untouched stock plugin
[ -f "$DEST.orig" ] || cp "$DEST" "$DEST.orig"
install -m 644 "$HERE/libbatt.so" "$DEST"
echo "installed patched libbatt.so (stock backed up at $DEST.orig)"

# make sure the panel actually shows the battery widget
INI="$(getent passwd "${SUDO_USER:-pi}" | cut -d: -f6)/.config/wf-panel-pi.ini"
if [ -f "$INI" ] && ! grep -q 'widgets_right=.*batt' "$INI"; then
    sed -i 's/\(widgets_right=.*\)clock /\1clock batt /' "$INI" || true
fi

# restart the panel for the user session
U="${SUDO_USER:-pi}"; UID_="$(id -u "$U")"
sudo -u "$U" WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR="/run/user/$UID_" \
    pkill -TERM wf-panel-pi 2>/dev/null || true
echo "done — battery widget now shows the % and a charging bolt."

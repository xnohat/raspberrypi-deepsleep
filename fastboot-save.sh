#!/bin/bash
# fastboot-save.sh — save session state to disk, then clean shutdown (0mA).
# Restore happens on next boot via fastboot-restore.sh (labwc autostart).
# Saves: tmux sessions (layout+cwd+running cmds), chromium tabs (native
# session restore), pcmanfm/Thunar open folder windows, GUI app list.

STATE_DIR="/home/pi/.fastboot-state"
LOG="/var/log/pi-deepsleep.log"
USERNAME=pi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - FASTBOOT: $1" >> "$LOG"; }

as_user() { sudo -u "$USERNAME" "$@"; }

mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR"/*
log "Saving session state..."

# ── 1. tmux: dump every session/window/pane (layout, cwd, running command) ──
if as_user tmux list-sessions >/dev/null 2>&1; then
    as_user tmux list-panes -a -F '#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_path}|#{pane_current_command}|#{window_layout}' \
        > "$STATE_DIR/tmux-panes.txt" 2>/dev/null
    # scrollback of each pane (last 2000 lines) for context
    mkdir -p "$STATE_DIR/tmux-scrollback"
    while IFS='|' read -r sess win wname pane cwd cmd layout; do
        as_user tmux capture-pane -t "${sess}:${win}.${pane}" -p -S -2000 \
            > "$STATE_DIR/tmux-scrollback/${sess}_${win}_${pane}.txt" 2>/dev/null
    done < "$STATE_DIR/tmux-panes.txt"
    log "tmux: $(wc -l < "$STATE_DIR/tmux-panes.txt") panes saved"
fi

# ── 2. Chromium: enable native session restore, then close cleanly ──
CHROME_RUNNING=0
if pgrep -u "$USERNAME" -f "chromium" >/dev/null 2>&1; then
    CHROME_RUNNING=1
    echo "chromium" >> "$STATE_DIR/apps.txt"
    # ask chromium to exit gracefully (SIGTERM lets it mark clean exit)
    pkill -u "$USERNAME" -TERM -f "chromium" 2>/dev/null
    for i in $(seq 1 20); do
        pgrep -u "$USERNAME" -f "chromium" >/dev/null || break
        sleep 0.5
    done
    log "chromium closed gracefully"
fi
# force restore_on_startup=1 (restore last session) + clean exit flags.
# Only edit AFTER chromium fully exited; atomic write via temp file + backup.
PREF="/home/pi/.config/chromium/Default/Preferences"
if [ -f "$PREF" ]; then
    if pgrep -u "$USERNAME" -f "chromium" >/dev/null 2>&1; then
        log "WARNING: chromium still running - skipping Preferences edit (native session files will still restore)"
    else
        as_user python3 - "$PREF" << 'PYEOF'
import json, sys, os, shutil
p = sys.argv[1]
shutil.copy2(p, p + '.fastboot-bak')
with open(p) as f: d = json.load(f)
d.setdefault('session', {})['restore_on_startup'] = 1
d.setdefault('profile', {})['exit_type'] = 'Normal'
d['profile']['exited_cleanly'] = True
tmp = p + '.tmp'
with open(tmp, 'w') as f: json.dump(d, f)
os.replace(tmp, p)
PYEOF
        chown "$USERNAME:$USERNAME" "$PREF" "$PREF.fastboot-bak" 2>/dev/null
        log "chromium restore_on_startup=1 set (atomic, backup kept)"
    fi
fi

# ── 3. File managers: save cwd of each open window process ──
for fm in pcmanfm thunar; do
    for pid in $(pgrep -u "$USERNAME" -x "$fm" 2>/dev/null); do
        # skip the desktop-mode pcmanfm (it has --desktop in cmdline)
        if grep -q -- "--desktop" "/proc/$pid/cmdline" 2>/dev/null; then continue; fi
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
        [ -n "$cwd" ] && echo "$fm|$cwd" >> "$STATE_DIR/filemgr.txt"
    done
done
[ -f "$STATE_DIR/filemgr.txt" ] && log "file managers: $(wc -l < "$STATE_DIR/filemgr.txt") windows saved"

# ── 4. Was a terminal window open? ──
if pgrep -u "$USERNAME" -x lxterminal >/dev/null 2>&1; then
    echo "lxterminal" >> "$STATE_DIR/apps.txt"
fi

# ── 5. Arm the restore-on-boot marker ──
touch "$STATE_DIR/restore-pending"
chown -R "$USERNAME:$USERNAME" "$STATE_DIR"
sync
log "State saved. Shutting down..."

shutdown -h now

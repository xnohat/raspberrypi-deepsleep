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

# Transactional save: build in .new, atomically swap in only when complete.
# Previous good state is kept at .previous (never lose the last snapshot).
NEW_DIR="${STATE_DIR}.new"
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
SAVE_OK=1
log "Saving session state..."

# ── 1. tmux: dump every session/window/pane (layout, cwd, running command) ──
if as_user tmux list-sessions >/dev/null 2>&1; then
    # pane_pid = the pane's shell; its child = the actual running command.
    # Capture the child's FULL cmdline (args included) so restore can re-run it.
    as_user tmux list-panes -a -F '#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_path}|#{pane_current_command}|#{pane_pid}' 2>/dev/null \
    | while IFS='|' read -r sess win wname pane cwd cmd panepid; do
        fullcmd=""
        child=$(pgrep -P "$panepid" 2>/dev/null | head -1)
        if [ -n "$child" ]; then
            fullcmd=$(tr '\0' ' ' < "/proc/$child/cmdline" 2>/dev/null | sed 's/ $//')
        fi
        echo "${sess}|${win}|${wname}|${pane}|${cwd}|${cmd}|${fullcmd}"
    done > "$NEW_DIR/tmux-panes.txt"
    # scrollback of each pane (last 2000 lines) for context
    mkdir -p "$NEW_DIR/tmux-scrollback"
    while IFS='|' read -r sess win wname pane cwd cmd fullcmd; do
        as_user tmux capture-pane -t "${sess}:${win}.${pane}" -p -S -2000 \
            > "$NEW_DIR/tmux-scrollback/${sess}_${win}_${pane}.txt" 2>/dev/null
    done < "$NEW_DIR/tmux-panes.txt"
    log "tmux: $(wc -l < "$NEW_DIR/tmux-panes.txt") panes saved"
fi

# ── 2. Chromium: enable native session restore, then close cleanly ──
CHROME_RUNNING=0
if pgrep -u "$USERNAME" -f "chromium" >/dev/null 2>&1; then
    CHROME_RUNNING=1
    echo "chromium" >> "$NEW_DIR/apps.txt"
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
# pcmanfm --desktop reuses ONE process for desktop AND folder windows, so
# process-scanning can't see folder windows. Use its saved tab config +
# a window-count heuristic instead.
for fm in pcmanfm thunar; do
    for pid in $(pgrep -u "$USERNAME" -x "$fm" 2>/dev/null); do
        if grep -q -- "--desktop" "/proc/$pid/cmdline" 2>/dev/null; then continue; fi
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
        [ -n "$cwd" ] && echo "$fm|$cwd" >> "$NEW_DIR/filemgr.txt"
    done
done
[ -f "$NEW_DIR/filemgr.txt" ] && log "file managers: $(wc -l < "$NEW_DIR/filemgr.txt") windows saved"

# ── 4. Terminal windows open? (foot = PiTerm, lxterminal legacy) ──
# foot: one process per window; count real windows (exclude footclient/server)
FOOT_N=$(pgrep -u "$USERNAME" -cx foot 2>/dev/null || echo 0)
if [ "$FOOT_N" -gt 0 ]; then
    echo "foot|$FOOT_N" >> "$NEW_DIR/apps.txt"
fi
if pgrep -u "$USERNAME" -x lxterminal >/dev/null 2>&1; then
    echo "lxterminal" >> "$NEW_DIR/apps.txt"
fi

# ── 5. Validate + atomic swap + arm marker; only shutdown when save is good ──
[ -f "$NEW_DIR/tmux-panes.txt" ] || [ -f "$NEW_DIR/apps.txt" ] || {
    log "ABORT: nothing captured (no tmux manifest, no apps) — NOT shutting down"
    exit 1
}
touch "$NEW_DIR/restore-pending"
chown -R "$USERNAME:$USERNAME" "$NEW_DIR"
# keep previous good snapshot, swap new one in atomically
rm -rf "${STATE_DIR}.previous"
[ -d "$STATE_DIR" ] && mv "$STATE_DIR" "${STATE_DIR}.previous"
mv "$NEW_DIR" "$STATE_DIR"
sync
log "State saved (previous kept). Shutting down..."

shutdown -h now

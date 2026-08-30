#!/bin/bash
# fastboot-restore.sh — runs once after boot (labwc autostart) when
# fastboot-save.sh armed the restore marker. Reopens tmux sessions,
# chromium (native tab restore), file manager windows, terminal.

STATE_DIR="/home/pi/.fastboot-state"
LOG="$STATE_DIR/restore.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - FASTBOOT-RESTORE: $1" >> "$LOG" 2>/dev/null || true; }

# only run when armed (accept both markers: -attempted means a previous
# restore crashed mid-way — retry it rather than losing the session forever)
if [ -f "$STATE_DIR/restore-pending" ]; then
    mv "$STATE_DIR/restore-pending" "$STATE_DIR/restore-attempted"
elif [ ! -f "$STATE_DIR/restore-attempted" ]; then
    exit 0
fi
log "Restoring session..."

# wait for wayland compositor to be ready
for i in $(seq 1 30); do
    [ -S "${XDG_RUNTIME_DIR:-/run/user/1000}/wayland-0" ] && break
    sleep 1
done
sleep 2

# ── 1. tmux sessions: rebuild windows/panes with saved cwd, show scrollback ──
if [ -f "$STATE_DIR/tmux-panes.txt" ]; then
    prev_sess=""
    while IFS='|' read -r sess win wname pane cwd cmd layout; do
        [ -d "$cwd" ] || cwd="$HOME"
        target="${sess}:${win}"
        if ! tmux has-session -t "$sess" 2>/dev/null; then
            tmux new-session -d -s "$sess" -c "$cwd" 2>/dev/null
            tmux rename-window -t "${sess}:1" "$wname" 2>/dev/null
            prev_sess="$sess"; prev_win="1"; first_in_win=1
            continue
        fi
        if ! tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null | grep -qx "$win"; then
            tmux new-window -d -t "$target" -n "$wname" -c "$cwd" 2>/dev/null
        else
            tmux split-window -d -t "$target" -c "$cwd" 2>/dev/null
        fi
    done < "$STATE_DIR/tmux-panes.txt"
    # drop a note about old scrollback location into each restored session
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        tmux send-keys -t "$s" "echo '📋 fastboot: scrollback cũ lưu ở $STATE_DIR/tmux-scrollback/'" C-m 2>/dev/null
    done
    log "tmux sessions rebuilt"
fi

# ── 2. Terminal window (attaches to tmux automatically via lxterminal.conf) ──
if grep -qx "lxterminal" "$STATE_DIR/apps.txt" 2>/dev/null; then
    lxterminal &
    log "lxterminal reopened"
fi

# ── 3. Chromium: native session restore brings back all tabs ──
if grep -qx "chromium" "$STATE_DIR/apps.txt" 2>/dev/null; then
    chromium-browser --restore-last-session >/dev/null 2>&1 &
    log "chromium reopened with session restore"
fi

# ── 4. File manager windows at saved folders ──
if [ -f "$STATE_DIR/filemgr.txt" ]; then
    while IFS='|' read -r fm cwd; do
        [ -d "$cwd" ] || cwd="$HOME"
        case "$fm" in
            pcmanfm) pcmanfm "$cwd" >/dev/null 2>&1 & ;;
            thunar)  thunar  "$cwd" >/dev/null 2>&1 & ;;
        esac
        sleep 0.5
    done < "$STATE_DIR/filemgr.txt"
    log "file manager windows reopened"
fi

rm -f "$STATE_DIR/restore-attempted"
log "Restore complete"

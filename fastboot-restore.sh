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

# ── 1. tmux sessions: rebuild via JSON manifest (tmux-state.py) ──
# Auto-runs strictly read-only TUIs (btop/htop/top); everything else is
# prefilled shlex-quoted for the user to confirm with Enter.
if [ -f "$STATE_DIR/tmux-state.json" ]; then
    if python3 /usr/local/bin/tmux-state.py restore "$STATE_DIR/tmux-state.json" >> "$LOG" 2>&1; then
        log "tmux sessions rebuilt (JSON manifest)"
    else
        log "tmux restore PARTIAL (see above)"
    fi
elif [ -f "$STATE_DIR/tmux-panes.txt" ]; then
    # legacy fallback: layout+cwd only
    while IFS='|' read -r sess win wname pane cwd cmd _; do
        [ -d "$cwd" ] || cwd="$HOME"
        target="${sess}:${win}"
        if ! tmux has-session -t "$sess" 2>/dev/null; then
            tmux new-session -d -s "$sess" -c "$cwd" 2>/dev/null
            tmux rename-window -t "${sess}:1" "$wname" 2>/dev/null
        elif ! tmux list-windows -t "$sess" -F '#{window_index}' 2>/dev/null | grep -qx "$win"; then
            tmux new-window -d -t "$target" -n "$wname" -c "$cwd" 2>/dev/null
        else
            tmux split-window -d -t "$target" -c "$cwd" 2>/dev/null
        fi
    done < "$STATE_DIR/tmux-panes.txt"
    log "tmux sessions rebuilt (legacy manifest)"
fi

# ── 2. Terminal windows (attach to tmux automatically) ──
FOOT_LINE=$(grep "^foot|" "$STATE_DIR/apps.txt" 2>/dev/null)
if [ -n "$FOOT_LINE" ]; then
    N=${FOOT_LINE#foot|}
    # prefer view count from tmux manifest (grouped sessions = real windows)
    VJSON=$(python3 -c "import json,sys; d=json.load(open('$STATE_DIR/tmux-state.json')); print(sum(d.get('views',{}).values()) or 0)" 2>/dev/null)
    [ -n "$VJSON" ] && [ "$VJSON" -ge 1 ] 2>/dev/null && N=$VJSON
    [ "$N" -ge 1 ] 2>/dev/null || N=1
    for i in $(seq 1 "$N"); do
        foot --app-id=piterm --title=PiTerm /home/pi/.local/bin/piterm-attach >/dev/null 2>&1 &
        sleep 0.5
    done
    log "PiTerm (foot) reopened x$N"
fi
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
if [ -s "$STATE_DIR/filemgr.txt" ]; then
    while IFS='|' read -r fm cwd; do
        [ -d "$cwd" ] || cwd="$HOME"
        case "$fm" in
            pcmanfm) pcmanfm "$cwd" >/dev/null 2>&1 & ;;
            thunar)  thunar  "$cwd" >/dev/null 2>&1 & ;;
        esac
        sleep 0.5
    done < "$STATE_DIR/filemgr.txt"
    log "file manager windows reopened"
elif [ "${FILEMGR_ALWAYS:-1}" = "1" ]; then
    # pcmanfm folder windows live inside the --desktop process on wayland —
    # undetectable at save time. Compromise: always reopen one window at $HOME.
    pcmanfm "$HOME" >/dev/null 2>&1 &
    log "file manager reopened at HOME (fallback — windows not detectable)"
fi

# ── Verify apps actually came up before clearing the marker ──
sleep 3
PASS=1
if grep -q "^foot|" "$STATE_DIR/apps.txt" 2>/dev/null; then
    pgrep -x foot >/dev/null || { PASS=0; log "VERIFY FAIL: foot not running"; }
fi
if grep -qx "chromium" "$STATE_DIR/apps.txt" 2>/dev/null; then
    pgrep -f "chromium" >/dev/null || { PASS=0; log "VERIFY FAIL: chromium not running"; }
fi
if [ "$PASS" = "1" ]; then
    rm -f "$STATE_DIR/restore-attempted"
    log "Restore complete — PASS"
else
    # keep restore-attempted so next boot retries
    log "Restore PARTIAL — marker kept for retry on next boot"
fi

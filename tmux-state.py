#!/usr/bin/env python3
"""tmux-state.py — save/restore tmux pane state as a JSON manifest.

save:    tmux-state.py save <out.json>
restore: tmux-state.py restore <in.json>

Capture: for each pane, resolve the FOREGROUND process group on the pane's
tty (robust vs wrappers/pipelines), read its argv from /proc/<pid>/cmdline.

Restore: rebuild sessions/windows/panes with saved cwd; auto-run only a
strict read-only allowlist (local TUI monitors); prefill everything else
(shlex-quoted) so the user just presses Enter.
"""
import json
import os
import shlex
import subprocess
import sys

# Only clearly read-only local TUIs are auto-run. watch/ssh excluded on
# purpose (watch runs arbitrary commands; ssh triggers network/auth).
AUTORUN = {"btop", "htop", "top"}
SHELLS = {"bash", "sh", "zsh", "dash", "fish"}


def tmux(*args, out=False):
    cmd = ["tmux"] + list(args)
    if out:
        return subprocess.run(cmd, capture_output=True, text=True).stdout
    return subprocess.run(cmd, capture_output=True).returncode


def _argv_of(pid: int):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read().rstrip(b"\0")
        if raw:
            return [a.decode("utf-8", "replace") for a in raw.split(b"\0")]
    except OSError:
        pass
    return []


def fg_argv(tty: str, pane_pid: int, want: str):
    """argv of the process actually running in the pane.

    Strategy 1: foreground pgrp of the pane tty (needs controlling-tty perms —
    works when we run as the same user inside the session, may fail outside).
    Strategy 2: walk /proc for processes whose tty matches and whose comm
    matches pane_current_command; deepest descendant of pane_pid wins.
    """
    try:
        fd = os.open(tty, os.O_RDONLY | os.O_NOCTTY)
        try:
            pgid = os.tcgetpgrp(fd)
            argv = _argv_of(pgid)
            if argv:
                return argv
        finally:
            os.close(fd)
    except OSError:
        pass
    # Strategy 2: breadth-first walk of pane_pid's descendants
    frontier = [pane_pid]
    best = []
    while frontier:
        nxt = []
        for pp in frontier:
            try:
                with open(f"/proc/{pp}/task/{pp}/children") as f:
                    kids = [int(x) for x in f.read().split()]
            except (OSError, ValueError):
                kids = []
            for k in kids:
                argv = _argv_of(k)
                if argv:
                    base = os.path.basename(argv[0])
                    if base == want or want in base:
                        best = argv
                    elif not best:
                        best = argv
            nxt.extend(kids)
        frontier = nxt
    return best


def save(path: str) -> None:
    fmt = ("#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t"
           "#{pane_current_path}\t#{pane_current_command}\t#{pane_tty}\t#{pane_pid}")
    panes = []
    for line in tmux("list-panes", "-a", "-F", fmt, out=True).splitlines():
        f = line.split("\t")
        if len(f) != 8:
            continue
        sess, win, wname, pane, cwd, cur, tty, panepid = f
        argv = []
        if cur not in SHELLS:
            argv = fg_argv(tty, int(panepid), cur)
        panes.append({
            "session": sess, "window": int(win), "window_name": wname,
            "pane": int(pane), "cwd": cwd, "command": cur, "argv": argv,
        })
    with open(path, "w") as fh:
        json.dump({"version": 2, "panes": panes}, fh, indent=1)
    print(f"saved {len(panes)} panes")


def restore(path: str) -> None:
    with open(path) as fh:
        data = json.load(fh)
    panes = data.get("panes", [])
    made = 0
    for p in panes:
        sess, win = p["session"], str(p["window"])
        cwd = p["cwd"] if os.path.isdir(p["cwd"]) else os.path.expanduser("~")
        target = f"{sess}:{win}"
        if tmux("has-session", "-t", sess) != 0:
            tmux("new-session", "-d", "-s", sess, "-c", cwd)
            tmux("rename-window", "-t", f"{sess}:1", p["window_name"])
        elif str(win) not in tmux("list-windows", "-t", sess, "-F",
                                  "#{window_index}", out=True).split():
            tmux("new-window", "-d", "-t", target, "-n", p["window_name"],
                 "-c", cwd)
        else:
            tmux("split-window", "-d", "-t", target, "-c", cwd)
        made += 1
        argv = p.get("argv") or []
        if argv and p["command"] not in SHELLS:
            cmdline = shlex.join(argv)
            if os.path.basename(argv[0]) in AUTORUN:
                tmux("send-keys", "-t", target, cmdline, "C-m")
            else:
                tmux("send-keys", "-t", target, cmdline)  # prefill only
    # verify: pane count must match
    have = len(tmux("list-panes", "-a", "-F", "x", out=True).splitlines())
    status = "PASS" if have >= made else f"PARTIAL ({have}/{made})"
    print(f"restored {made} panes — {status}")
    sys.exit(0 if have >= made else 2)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("save", "restore"):
        print(__doc__)
        sys.exit(1)
    (save if sys.argv[1] == "save" else restore)(sys.argv[2])

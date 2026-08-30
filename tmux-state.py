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


def group_representatives():
    """One canonical session per group (or per standalone session).

    Returns (repr_sessions, view_counts) where view_counts maps the
    representative name -> number of grouped view sessions.
    """
    reps, views = {}, {}
    out = tmux("list-sessions", "-F",
               "#{session_name}\t#{session_group}", out=True)
    for line in out.splitlines():
        parts = line.split("\t")
        name = parts[0]
        group = parts[1] if len(parts) > 1 and parts[1] else name
        views[group] = views.get(group, 0) + 1
        # prefer the session named exactly like the group (e.g. "main")
        if group not in reps or name == group:
            reps[group] = name
    return reps, views


def save(path: str) -> None:
    reps, views = group_representatives()
    rep_set = set(reps.values())
    fmt = ("#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t"
           "#{pane_current_path}\t#{pane_current_command}\t#{pane_tty}\t#{pane_pid}")
    panes = []
    for line in tmux("list-panes", "-a", "-F", fmt, out=True).splitlines():
        f = line.split("\t")
        if len(f) != 8:
            continue
        sess, win, wname, pane, cwd, cur, tty, panepid = f
        if sess not in rep_set:
            continue        # grouped view duplicates: skip
        argv = []
        last_cmd = ""
        if cur not in SHELLS:
            argv = fg_argv(tty, int(panepid), cur)
        else:
            # idle shell: remember the LAST command typed (from scrollback
            # prompt lines like "pi@host:~ $ ls -la") so restore can prefill
            # it for the user to confirm with Enter.
            import re
            scroll = tmux("capture-pane", "-t", f"{sess}:{win}.{pane}",
                          "-p", "-S", "-200", out=True)
            for line in scroll.splitlines():
                m = re.search(r"[$#] (.+)$", line)
                if m and m.group(1).strip():
                    last_cmd = m.group(1).strip()
        panes.append({
            "session": sess, "window": int(win), "window_name": wname,
            "pane": int(pane), "cwd": cwd, "command": cur, "argv": argv,
            "last_cmd": last_cmd,
        })
    # per-view selected window: each PiTerm window returns to what it showed
    view_windows = {}
    for line in tmux("list-sessions", "-F",
                     "#{session_name}\t#{session_group}", out=True).splitlines():
        name = line.split("\t")[0]
        sel = tmux("display-message", "-t", name, "-p",
                   "#{window_index}", out=True).strip()
        if sel.isdigit():
            view_windows[name] = int(sel)
    manifest = {
        "version": 3,
        "panes": panes,
        "views": {reps[g]: n for g, n in views.items()},
        "view_windows": view_windows,
    }
    with open(path, "w") as fh:
        json.dump(manifest, fh, indent=1)
    print(f"saved {len(panes)} panes, views={manifest['views']}")


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
        elif p.get("last_cmd"):
            # idle shell: prefill its last command — user decides (Enter)
            tmux("send-keys", "-t", target, p["last_cmd"])
    # recreate grouped view sessions (each extra PiTerm window attaches one)
    view_windows = data.get("view_windows", {})
    for rep, count in data.get("views", {}).items():
        for i in range(2, count + 1):
            name = f"{rep}{i}"
            if tmux("has-session", "-t", name) != 0:
                tmux("new-session", "-d", "-t", rep, "-s", name)
    # point every view (incl. the representative) at its saved window
    for name, sel in view_windows.items():
        tmux("select-window", "-t", f"{name}:{sel}")
    # verify: pane count of representative sessions must cover manifest
    reps, _ = group_representatives()
    rep_set = set(reps.values())
    have = 0
    for line in tmux("list-panes", "-a", "-F", "#{session_name}",
                     out=True).splitlines():
        if line in rep_set:
            have += 1
    status = "PASS" if have >= made else f"PARTIAL ({have}/{made})"
    print(f"restored {made} panes — {status}")
    sys.exit(0 if have >= made else 2)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("save", "restore"):
        print(__doc__)
        sys.exit(1)
    (save if sys.argv[1] == "save" else restore)(sys.argv[2])

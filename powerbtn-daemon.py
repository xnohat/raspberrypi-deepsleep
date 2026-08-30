#!/usr/bin/env python3
"""powerbtn-daemon.py — power button press-duration dispatcher.

State machine on the dedicated pwr_button input device (KEY_POWER 116):
  value=1 (down)   : start timing; long_fired=False
  value=2 (repeat) : ignored
  value=0 (up)     : if long already fired -> ignore.
                     else if held < LONG_MS -> SHORT action.
  held past LONG_MS (checked via select timeout while still down):
                     LONG action fires IMMEDIATELY (release does nothing).

LONG fires at 2s — leaves margin before any hardware/PMIC forced power-off,
and Chromium/session save needs seconds to complete.

SHORT  -> deep sleep toggle
LONG   -> fastboot save + shutdown

A dispatch lock: while fastboot is running, ALL further button events are
ignored (until it exits — normally the machine shuts down anyway).
Short-press debounce swallows only its own bounce (1s), so a quick
wake-after-sleep press still works.

Dry-run: start with --dry-run (or env BTN_DRYRUN=1) — actions are only
logged, nothing executes. Used for automated state-machine tests.
"""
import os
import select
import subprocess
import sys
import time

import evdev

LONG_MS = 2000
SHORT_DEBOUNCE_S = 1.0
DEVICE_NAME = "pwr_button"
KEY_POWER = 116
SHORT_CMD = ["/usr/local/bin/powerbtn-deepsleep.sh"]
LONG_CMD = ["/usr/local/bin/fastboot-save.sh"]
LOG = "/var/log/pi-deepsleep.log"
DRY = "--dry-run" in sys.argv or os.environ.get("BTN_DRYRUN") == "1"


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} - BTN-DAEMON: {msg}"
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        print(line, flush=True)


def find_device() -> evdev.InputDevice:
    """Resolve device by NAME + KEY_POWER capability, every (re)start."""
    while True:
        for path in evdev.list_devices():
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            caps = dev.capabilities().get(evdev.ecodes.EV_KEY, [])
            if dev.name == DEVICE_NAME and KEY_POWER in caps:
                return dev
            dev.close()
        log(f"device '{DEVICE_NAME}' not found, retrying...")
        time.sleep(2)


def dispatch(kind: str) -> None:
    if DRY:
        log(f"DRYRUN dispatch {kind}")
        return
    cmd = LONG_CMD if kind == "LONG" else SHORT_CMD
    subprocess.Popen(cmd)


def run(dev: evdev.InputDevice) -> None:
    try:
        dev.grab()
    except OSError:
        log("WARNING: could not grab device exclusively")
    log(f"listening on {dev.path} ({dev.name}), LONG at {LONG_MS}ms held"
        + (" [DRY-RUN]" if DRY else ""))

    press_t = None
    long_fired = False
    fastboot_started = False
    ignore_until = 0.0

    while True:
        timeout = None
        if press_t is not None and not long_fired:
            timeout = max(0.0, (press_t + LONG_MS / 1000) - time.monotonic())
        r, _, _ = select.select([dev.fd], [], [], timeout)
        now = time.monotonic()

        # threshold reached while still held
        if not r:
            if press_t is not None and not long_fired:
                long_fired = True
                if fastboot_started:
                    log("LONG ignored (fastboot already running)")
                else:
                    log(f"LONG press ({LONG_MS}ms held) -> fastboot")
                    fastboot_started = not DRY
                    dispatch("LONG")
            continue

        try:
            events = list(dev.read())
        except OSError:
            log("device read error — reopening")
            raise

        for event in events:
            if event.type != evdev.ecodes.EV_KEY or event.code != KEY_POWER:
                continue
            if event.value == 2:                     # autorepeat: ignore
                continue
            if fastboot_started:
                log(f"event ignored (fastboot in progress, value={event.value})")
                continue
            if event.value == 1:                     # down
                if now < ignore_until:
                    log("down during debounce ignored")
                    continue
                press_t = now
                long_fired = False
            elif event.value == 0:                   # up
                if press_t is None or long_fired:
                    press_t = None
                    continue
                held_ms = (now - press_t) * 1000
                press_t = None
                log(f"SHORT press ({held_ms:.0f}ms) -> deep sleep toggle")
                ignore_until = now + SHORT_DEBOUNCE_S
                dispatch("SHORT")


def main() -> None:
    while True:
        dev = find_device()
        try:
            run(dev)
        except OSError:
            try:
                dev.close()
            except OSError:
                pass
            time.sleep(2)


if __name__ == "__main__":
    main()

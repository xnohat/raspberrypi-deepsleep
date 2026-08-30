#!/usr/bin/env python3
"""Automated dry-run test for powerbtn-daemon.py state machine.

Creates a virtual uinput power button, runs the daemon in dry-run mode
against it, injects press patterns, and asserts exactly the expected
dispatches appear in the log.
"""
import re
import subprocess
import sys
import time

from evdev import UInput, ecodes as e

LOG = "/var/log/pi-deepsleep.log"
DAEMON = "/home/pi/pideepsleep/powerbtn-daemon.py"


def tail_marks(since_pos):
    with open(LOG) as f:
        f.seek(since_pos)
        txt = f.read()
    return re.findall(r"DRYRUN dispatch (\w+)|LONG press|SHORT press", txt), txt


def main():
    ui = UInput({e.EV_KEY: [e.KEY_POWER]}, name="pwr_button")
    time.sleep(0.5)

    # daemon in dry-run; it will find our virtual device (same name)
    proc = subprocess.Popen(
        ["python3", DAEMON, "--dry-run"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)

    results = []

    def press(hold_s, repeats=0):
        pos = open(LOG).tell() if False else __import__("os").path.getsize(LOG)
        ui.write(e.EV_KEY, e.KEY_POWER, 1); ui.syn()
        for _ in range(repeats):
            time.sleep(0.2)
            ui.write(e.EV_KEY, e.KEY_POWER, 2); ui.syn()
        time.sleep(hold_s)
        ui.write(e.EV_KEY, e.KEY_POWER, 0); ui.syn()
        time.sleep(1.0)
        _, txt = tail_marks(pos)
        shorts = txt.count("DRYRUN dispatch SHORT")
        longs = txt.count("DRYRUN dispatch LONG")
        return shorts, longs

    # 1. quick tap -> exactly 1 SHORT, 0 LONG
    s, l = press(0.15)
    results.append(("tap 150ms", s, l, s == 1 and l == 0))
    time.sleep(1.2)  # wait out debounce

    # 2. hold 2.5s -> 0 SHORT, exactly 1 LONG (fires at 2s while held)
    s, l = press(2.5)
    results.append(("hold 2.5s", s, l, s == 0 and l == 1))
    time.sleep(1.2)

    # 3. hold 5s with autorepeat events -> still exactly 1 LONG, 0 SHORT
    s, l = press(5.0, repeats=8)
    results.append(("hold 5s +repeats", s, l, s == 0 and l == 1))
    time.sleep(1.2)

    # 4. bounce: tap then immediate tap within debounce -> only 1 SHORT
    pos = __import__("os").path.getsize(LOG)
    ui.write(e.EV_KEY, e.KEY_POWER, 1); ui.syn(); time.sleep(0.1)
    ui.write(e.EV_KEY, e.KEY_POWER, 0); ui.syn(); time.sleep(0.2)
    ui.write(e.EV_KEY, e.KEY_POWER, 1); ui.syn(); time.sleep(0.1)
    ui.write(e.EV_KEY, e.KEY_POWER, 0); ui.syn(); time.sleep(1.0)
    _, txt = tail_marks(pos)
    s, l = txt.count("DRYRUN dispatch SHORT"), txt.count("DRYRUN dispatch LONG")
    results.append(("double-tap bounce", s, l, s == 1 and l == 0))

    proc.terminate()
    ui.close()

    ok = True
    for name, s, l, passed in results:
        print(f"{'PASS' if passed else 'FAIL'}  {name}: SHORT={s} LONG={l}")
        ok = ok and passed
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

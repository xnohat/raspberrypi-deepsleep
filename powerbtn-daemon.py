#!/usr/bin/env python3
"""powerbtn-daemon.py — power button press-duration dispatcher.

Listens on the dedicated pwr_button input device (KEY_POWER, code 116):
  * short press  (< LONG_MS)  -> deep sleep toggle (powerbtn-deepsleep.sh)
  * long  press  (>= LONG_MS) -> fastboot save + shutdown (fastboot-save.sh)

Replaces the acpid event handler (which cannot distinguish press length).
Runs as a systemd service (root).
"""
import subprocess
import time

import evdev

LONG_MS = 3000          # hold threshold for fastboot
DEVICE_NAME = "pwr_button"
KEY_POWER = 116
SHORT_CMD = ["/usr/local/bin/powerbtn-deepsleep.sh"]
LONG_CMD = ["/usr/local/bin/fastboot-save.sh"]
LOG = "/var/log/pi-deepsleep.log"


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(f"{ts} - BTN-DAEMON: {msg}\n")
    except OSError:
        pass


def find_device() -> evdev.InputDevice:
    while True:
        for path in evdev.list_devices():
            dev = evdev.InputDevice(path)
            if dev.name == DEVICE_NAME:
                return dev
            dev.close()
        time.sleep(2)


def main() -> None:
    dev = find_device()
    # exclusive grab so acpid/logind never double-handle the button
    try:
        dev.grab()
    except OSError:
        log("WARNING: could not grab device exclusively")
    log(f"listening on {dev.path} ({dev.name}), long-press >= {LONG_MS}ms")

    press_t = None
    for event in dev.read_loop():
        if event.type != evdev.ecodes.EV_KEY or event.code != KEY_POWER:
            continue
        if event.value == 1:            # key down
            press_t = time.monotonic()
        elif event.value == 0 and press_t is not None:   # key up
            held_ms = (time.monotonic() - press_t) * 1000
            press_t = None
            if held_ms >= LONG_MS:
                log(f"long press ({held_ms:.0f}ms) -> fastboot save+shutdown")
                subprocess.Popen(LONG_CMD)
            else:
                log(f"short press ({held_ms:.0f}ms) -> deep sleep toggle")
                subprocess.Popen(SHORT_CMD)


if __name__ == "__main__":
    main()

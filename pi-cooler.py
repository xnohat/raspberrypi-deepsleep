#!/usr/bin/env python3
"""pi-cooler — active cooling daemon for HackberryPi CM5 (Pi Deep Sleep suite).

Why: with only a light desktop load (AI gateway + chromium) the SoC sat at
62-70°C because
  1. `ondemand` governor jumps every burst straight to 2.4GHz (hot, little gain);
  2. the pwm-fan thermal zone is interrupt-driven — between trip crossings the
     fan can stay stuck (see docs/FINDINGS.md "Gotcha");
  3. the quiet fan curve only starts at 55°C.

What it does every POLL seconds (skipped entirely while deep sleep is active):
  - governor -> schedutil (smoother, picks lower clocks for bursty loads)
  - caps scaling_max_freq by temperature with hysteresis (profile table)
  - re-seeds cooling_device0/cur_state so the fan always matches the curve
    (only when fan is in kernel auto mode, pwm1_enable=2 — never fights manual)

Profiles (/etc/pi-cooler.conf, KEY=VALUE, PROFILE=off|balanced|cool|silent):
  balanced  full speed while cool, steps down above 65°C        (default)
  cool      caps at 2.0GHz always, steeper steps, fan kicks early
  silent    keeps the fan off as long as possible by capping CPU harder
  off       daemon restores stock (ondemand, max freq) and idles
"""
import os
import sys
import time

CONF = "/etc/pi-cooler.conf"
STATUS = "/run/pi-cooler.status"
SLEEP_STATE = "/tmp/pi-deepsleep-state"
LOG = "/var/log/pi-deepsleep.log"
CPU = "/sys/devices/system/cpu"
TEMP = "/sys/class/thermal/thermal_zone0/temp"
COOL_DEV = "/sys/class/thermal/cooling_device0/cur_state"
POLL = 3
HYST = 3000  # mC

# (temp_mC_threshold, max_freq_kHz) — highest matching threshold wins
PROFILES = {
    "balanced": {"base": 2400000, "steps": [(65000, 2100000), (70000, 1800000), (76000, 1500000)],
                 "fan_shift": 0},
    "cool":     {"base": 2000000, "steps": [(60000, 1800000), (66000, 1600000), (72000, 1500000)],
                 "fan_shift": -7000},
    "silent":   {"base": 1800000, "steps": [(55000, 1600000), (60000, 1500000)],
                 "fan_shift": 3000},
}
# kernel fan trip points / speeds from config.txt (state n reached at FAN_TRIPS[n-1])
FAN_TRIPS = [55000, 65000, 72000, 78000]
FAN_SPEEDS = [0, 115, 145, 190, 255]


def load_fan_curve():
    """read fan_tempN / fan_tempN_speed from config.txt so seeding matches the GUI curve."""
    import re
    txt = rd("/boot/firmware/config.txt")
    for i in range(4):
        t = re.search(rf"^dtparam=fan_temp{i}=(\d+)", txt, re.M)
        sp = re.search(rf"^dtparam=fan_temp{i}_speed=(\d+)", txt, re.M)
        if t:
            FAN_TRIPS[i] = int(t.group(1))
        if sp:
            FAN_SPEEDS[i + 1] = int(sp.group(1))


def rd(p, d=""):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return d


def wr(p, v):
    try:
        if rd(p) != str(v):
            with open(p, "w") as f:
                f.write(str(v))
        return True
    except OSError:
        return False


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + f" - COOLER: {msg}\n")
    except OSError:
        pass


def load_profile():
    prof = "balanced"
    for line in rd(CONF).splitlines():
        if line.startswith("PROFILE="):
            prof = line.split("=", 1)[1].strip()
    return prof if prof in PROFILES or prof == "off" else "balanced"


def policies():
    return [f"{CPU}/{d}/cpufreq" for d in sorted(os.listdir(CPU))
            if d.startswith("cpu") and d[3:].isdigit() and os.path.isdir(f"{CPU}/{d}/cpufreq")]


def fan_hwmon():
    for d in sorted(os.listdir("/sys/class/hwmon")):
        if rd(f"/sys/class/hwmon/{d}/name") == "pwmfan":
            return f"/sys/class/hwmon/{d}"
    return None


def main():
    pols = policies()
    hw_max = int(rd(f"{pols[0]}/cpuinfo_max_freq", "2400000"))
    hw_min = int(rd(f"{pols[0]}/cpuinfo_min_freq", "1500000"))
    fh = fan_hwmon()
    load_fan_curve()
    level = 0          # current step index (0 = base)
    last = (None, None)
    was_sleeping = False
    log("started")
    while True:
        prof = load_profile()
        t = int(rd(TEMP, "0") or 0)

        if os.path.exists(SLEEP_STATE):
            # deep sleep owns cpufreq + fan; stay out of its way
            was_sleeping = True
            status = f"profile={prof} temp={t} state=deepsleep"
        elif prof == "off":
            if last[0] != "off":
                for p in pols:
                    wr(f"{p}/scaling_governor", "ondemand")
                    wr(f"{p}/scaling_max_freq", hw_max)
                log("profile off — stock governor restored")
            last = ("off", None)
            status = f"profile=off temp={t}"
        else:
            cfg = PROFILES[prof]
            steps = cfg["steps"]
            # hysteresis: go up immediately, come down only HYST below the trip
            while level < len(steps) and t >= steps[level][0]:
                level += 1
            while level > 0 and t < steps[level - 1][0] - HYST:
                level -= 1
            cap = cfg["base"] if level == 0 else steps[level - 1][1]
            cap = max(hw_min, min(hw_max, cap))
            for p in pols:
                wr(f"{p}/scaling_governor", "schedutil")
                wr(f"{p}/scaling_max_freq", cap)

            fan_state = "-"
            # pwm-fan: thermal framework drives pwm via cur_state. A manual
            # override (GUI fan-manual / fan-test) shows up as pwm != curve speed
            # for the current state -> leave it alone.
            cur = int(rd(COOL_DEV, "0") or 0)
            pwm = int(rd(f"{fh}/pwm1", "-1") or -1) if fh else -1
            if fh and 0 <= cur < len(FAN_SPEEDS) and pwm == FAN_SPEEDS[cur]:
                trips = [x + cfg["fan_shift"] for x in FAN_TRIPS]
                want = sum(1 for x in trips if t >= x)
                cur = int(rd(COOL_DEV, "0") or 0)
                # lower only when clearly below the trip (hysteresis), raise at once
                if want > cur or (want < cur and t < trips[cur - 1] - 5000):
                    wr(COOL_DEV, want)
                    cur = want
                fan_state = str(cur)
            if (prof, cap) != last or was_sleeping:
                log(f"profile={prof} temp={t / 1000:.1f}C cap={cap // 1000}MHz")
            last = (prof, cap)
            was_sleeping = False
            status = (f"profile={prof} temp={t} cap={cap} level={level} fan_state={fan_state} "
                      f"rpm={rd(f'{fh}/fan1_input', '0') if fh else 0}")
        wr(STATUS, status + "\n")
        time.sleep(POLL)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("pi-cooler must run as root")
    main()

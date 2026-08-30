# HackberryPi CM5 — Research Findings

> 🇻🇳 [Bản tiếng Việt: FINDINGS.vi.md](FINDINGS.vi.md)

Complete research log from the 2026-08-30/31 deep-dive session. Everything
here was measured/verified on real hardware (HackberryPi CM5, CM5 Lite,
Raspberry Pi OS Bookworm, kernel 6.12.47+rpt-rpi-v8) unless noted.

## 1. Fan control

- Fan: pwm-fan cooling device, hwmon name `pwmfan`
  (`/sys/class/hwmon/hwmonN` — N varies per boot, resolve by name!).
  Control: `pwm1_enable` (1=manual, 2=auto/thermal), `pwm1` (0-255).
- Measured fan curve: **stalls below pwm≈100-110**; pwm120=1343rpm,
  140=2503, 160=3957, 255≈9600rpm (very loud).
- Stock config drove it 40°C→pwm200, 50°C→pwm255 → full blast at idle.
- Our curve (`/boot/firmware/config.txt`): 55°C→115, 65°C→145, 72°C→190,
  78°C→255, hysteresis 5°C. Idle <50°C = fan off.
- **Gotcha**: the thermal zone is interrupt-driven — after manual pwm
  toggling, the governor won't re-evaluate until the next trip-point
  *crossing*; between trips the fan can stay stuck at 0 rpm at 68°C.
  Fix: seed `cooling_device0/cur_state` for the current temp on wake.
- CM5 throttles at ~80-85°C; full 4-core load reached only 72.7°C with our
  curve → safe.

## 2. Touch controller IRQ storm (the real heat/battery bug)

- Symptom: `irq/…-edt-ft5406` thread eating ~100% of one core 24/7;
  826 IRQs/s while untouched; SoC idling ~15°C hotter; fan always on.
- Touch: FT5406 (edt_ft5x06 driver) on **bit-banged i2c-gpio** (GPIO10/11),
  address 0x48, INT on **GPIO27** (RP1 bank: gpio-596, pinctrl-rp1 pin 27).
- Root cause: the overlay declares the interrupt LEVEL_LOW but configures
  **no bias on GPIO27**. The pin floats low → permanent level interrupt.
  i2c reads are clean (crc_errors=0), touch events are real — the chip just
  never releases the (floating) line.
- **EDGE_FALLING does NOT work**: with edge trigger, touch went completely
  dead (no edges observed). The INT line needs the pull-up.
- **Fix**: enable RP1 internal pull-up on GPIO27.
  - quick way: `gpio=27=ip,pu` in config.txt (firmware, before overlay)
  - proper way: pinctrl fragment in the overlay (`bias-pull-up`,
    `function="gpio"`, `pins="gpio27"`) + `pinctrl-0` reference on the
    touch node. Both verified on hardware: idle 0 IRQs/s, touch works.
- Upstreamed as [PR #48](https://github.com/ZitaoTech/HackberryPiCM5/pull/48).
  Community repo `CNflysky/hackberrypiq20` independently uses EDGE (0x2)
  *plus pull-up pinctrl* — the pull-up is the essential part.
- Note: `ps` shows cumulative CPU% — after fixing, the irq thread still
  shows high average from before; measure with `/proc/PID/stat` deltas.

## 3. Display panel (720×720 DPI)

- Panel: 4" 720×720 TFT, RGB666 DPI (`vc4-kms-dpi` + `drm-rp1-dpi`),
  36.832MHz pixel clock, `panel-dpi` generic driver (no init sequence).
- **Flicker bug**: software display off (`wlopm --off` / `wlr-randr --off`)
  stops the pixel clock. Short off (≤5s) is fine; long off (60s+) leaves
  the panel's TCON drifted → after re-enable the screen flickers for
  ~5 minutes. PLL relock is clean (verified in dmesg) — it's the panel.
- **The dedicated screen button is the correct way to blank the screen**:
  it's pure hardware backlight control; pixel clock keeps running → no
  flicker ever.
- Screen button functions (hardware, chip U49): **tap = backlight on/off,
  hold = cycle brightness levels**. Real backlight dimming = real battery
  savings.
- No software brightness path exists: no `/sys/class/backlight`; the
  backlight is driven by U49 (touch-key controller, label "YX-1024-LED")
  → R2 10Ω → Q3 (AO3400A MOSFET) switching DISP_LEDK; LED anode fed
  ~11.5V by MT3540 boost (U59). None of it connects to a Pi GPIO
  (schematic-verified). Software gamma dimming (labwc exposes
  `zwlr_gamma_control_manager_v1`, gammastep works) is possible but saves
  no power.
- Panel RESET (`DISP_RESET`, panel pin 6) connects **only** to button SW3
  + 10k pull-up — not to any GPIO. If the panel ever glitches, pressing
  the screen-reset button re-inits it instantly.
- A hardware mod (wire DISP_RESET → spare GPIO + `reset-gpios` overlay
  entry) would allow software panel reset / flicker-free software off.

## 4. Power measurements (MAX17048 fuel gauge, 5000mAh)

- Battery sysfs: `/sys/class/power_supply/battery/`
  (capacity %, charge_now µAh — quantized ~50mAh steps, voltage_now µV).
- Awake, screen on, active session: **~1.3-1.4A** (≈3.7h runtime).
- Fake deep sleep (services stopped, freq capped, wifi off): **~430mA**
  → ~10-12h. This is the CM5 SoC+RAM+RP1+regulators baseline; without real
  suspend the platform cannot go meaningfully lower.
- NVMe (Samsung MZAL4512HBLU): APST enabled, idles at PS3 (60mW) after
  100ms, PS4 (5mW) available — NOT a significant drain.
- Charging while awake at ~1.3A load can be a net **zero or negative**
  with a weak charger — the battery appeared stuck at 4% for 30min.
  Charge powered-off (or in fastboot shutdown) for real charging speed.

## 5. CPU hotplug is a trap

- `echo 0 > /sys/devices/system/cpu/cpuN/online` works, but re-onlining
  fails: **`psci: failed to boot CPU (-22)`** — cores stay dead until
  reboot. RPi firmware doesn't implement PSCI CPU_ON for this flow.
- Use instead: `powersave` governor + cap `scaling_max_freq` to
  `cpuinfo_min_freq` (1.5GHz→min). Idle cores in WFI at min frequency
  cost only a few mA more than offlined ones.

## 6. Hibernate is impossible (stock)

- Kernel: `/sys/power/state` is empty, no `/sys/power/disk`,
  no CONFIG_HIBERNATION. `CanHibernate` → "na".
- Even with a custom kernel, resume-from-disk on Pi is known-broken
  (firmware can't jump back into an image; VideoCore/RP1 state is not
  restorable). Community attempts have failed for years.
- Hence the **Fastboot** approach: save session state → clean shutdown →
  reconstruct on boot (chromium native session restore + tmux manifest +
  command relaunch/prefill). Honest naming: reconstruction, not resume.

## 7. Power button plumbing

- Dedicated input device `pwr_button` (KEY_POWER 116) — separate from the
  keyboard controller. Also seen on event0/2/3 (ZitaoTech Q20 keyboard).
- **Do not** let multiple handlers race: stock setup had acpid events,
  `/usr/bin/pwrkey` (desktop), AND systemd-logind all reacting. Our daemon
  takes an exclusive evdev grab and retires the rest.
- Long-press must fire **at the threshold while held** (not on release):
  holding "too long" triggers a hardware PMIC power cut (observed: machine
  died with zero button events logged) — fire early, save fast.
- polkit: running `systemctl stop` as the desktop user pops an
  authentication dialog; combined with a process-freeze pass it hangs the
  compositor. Root daemon + sudoers NOPASSWD for the two entry scripts
  solves it (no blanket polkit rules).

## 8. Freeze pass caveats (deep sleep)

- SIGSTOP-ing broadly is fragile. Never freeze: compositor stack, polkit
  agent (modal grab = UI hang), the watchdog/logger (they poll via
  `sleep` children — freezing `sleep` froze them: fan safety dead + logger
  dead), the AI gateway, dbus, or anything named like the button daemon.
- `ps -o comm` truncates to 15 chars (`deepsleep-watch`) — match prefixes.
- Run helpers via `systemd-run` (own cgroup/scope, survives the freeze
  pass, and `--collect` cleans up).

## 9. tmux multi-window architecture (PiTerm)

- Grouped sessions (`tmux new-session -t main`) share windows but keep
  per-session "current window" → each terminal window = independent view.
- **Save dedup**: `list-panes -a` reports panes once per *group member* —
  serialize only one representative session per group, plus a view count
  and each view's selected window (`view_windows`).
- Foreground command capture: `os.tcgetpgrp` on the pane tty needs
  `O_NOCTTY` and same-user perms; fall back to walking
  `/proc/<pane_pid>/task/*/children`.
- Auto-relaunch allowlist: only read-only TUIs (btop/htop/top). `watch`
  and `ssh` are excluded on purpose (arbitrary commands / network+auth
  side effects). Everything else is pre-typed, never executed.
- tmux `display-menu` needs `-O` to stay open after mouse release.

## 10. Files & references

- `docs/Schematic_HackberryPi_CM5_Q20.pdf` — official schematic
  (downloaded from ZitaoTech repo Hardware/). Key nets we mapped:
  backlight (§3), DISP_RESET, DPI signal path, i2c-gpio 10/11, INT GPIO27.
- Upstream repo: https://github.com/ZitaoTech/HackberryPiCM5
- Community DKMS overlay repo: https://github.com/CNflysky/hackberrypiq20
  (max17048 battery driver + touch overlay with pull-up)
- Our fork + prebuilt fixed overlays:
  https://github.com/xnohat/HackberryPiCM5/releases/tag/touch-fix-v1

## Open items / future work

- Deep sleep drain re-measurement after the service-stop upgrade
  (expected ~320-350mA; measurement was interrupted).
- Replace the generic SIGSTOP freeze with an explicit service allowlist
  (most fragile remaining part).
- Restore PASS check could verify per-view window mapping, not just
  process existence.
- Optional hardware mod: DISP_RESET → GPIO for software panel control.
- Propose the brightness-button documentation to ZitaoTech (undocumented
  in their README).

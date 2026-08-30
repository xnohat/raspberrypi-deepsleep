# Pi Deep Sleep + Fastboot + PiTerm

> 🇻🇳 [Bản tiếng Việt: README.vi.md](README.vi.md)

Power management and terminal suite for **HackberryPi CM5** (Raspberry Pi CM5
handheld by [ZitaoTech](https://github.com/ZitaoTech/HackberryPiCM5)) — also
adaptable to other Pi devices.

Born from one complaint — *"the fan is so loud"* — and grew into a full
power-management overhaul. See [docs/FINDINGS.md](docs/FINDINGS.md) for the
complete research log (fan curve, touch IRQ storm, panel quirks, battery
measurements, hardware schematic analysis).

## Features

### 1. Deep Sleep (short power-button press)
Aggressive fake-sleep for a platform with no real suspend:
- stops fan (with a systemd thermal watchdog: >70°C re-enables auto control)
- blocks wifi + bluetooth (`WIFI_OFF=1` default — configurable)
- stops heavy services (docker, containerd, ollama, waydroid, tailscale,
  snapd, cups, lxc, ModemManager...) and **restores only those that were
  active** on wake
- kills qemu-emulated x86 processes
- caps CPU frequency to minimum + powersave governor
  (⚠️ do NOT offline cores — CM5 PSCI CPU_ON fails with -22, cores stay dead
  until reboot)
- freezes non-essential processes (SIGSTOP) — keeps the AI gateway alive
  (`KEEP_AGENT=1`) so remote control survives sleep when wifi is kept
- press again to wake: everything restores, cooling state re-seeded

Measured: awake ~1.3A; fake sleep ~430mA (CM5 SoC+RAM+RP1 baseline — the
platform simply cannot go lower without real suspend). Battery 5000mAh →
~10-12h of fake sleep. For overnight, use **Fastboot** instead.

### 2. Fastboot (hold power button 2s)
Session save → clean shutdown (near-zero drain) → automatic reconstruction
on next boot:
- **tmux**: all sessions/windows/panes with cwd; **running commands**:
  read-only TUIs (btop/htop/top) relaunch automatically, everything else —
  including the last command of idle shells — is **pre-typed** on the prompt
  for you to confirm with Enter
- **Chromium**: native session restore (all tabs)
- **PiTerm windows**: reopened, each attached to the view it was displaying
- **file manager**: reopened (at $HOME — wayland limitation, see FINDINGS)
- transactional save (`.previous` snapshot kept), restore verified before
  the retry-marker is cleared

> This is session **reconstruction** (relaunch/prefill), not hibernation.
> The Pi kernel/firmware cannot suspend-to-disk (see FINDINGS §6).

### 3. PiTerm
`foot` (wayland-native, tiny) + `tmux` with:
- **grouped multi-window**: each terminal window is an independent view over
  a shared window pool (open a tab in one, switch to it from another)
- status bar: 🔋 battery · 🌡 temp · 🌀 fan rpm · 📶 wifi · clock
- **mouse**: drag = select (kept), right-click = context menu
  (Copy / Copy+Paste on selection; Paste / New tab / Split / Zoom / Close)
- Tokyo Night theme, sized for the 720×720 screen (btop fits)
- sessions persist through Fastboot

### 4. Power button daemon
evdev-based (`pwr_button` device, exclusive grab — replaces acpid/logind
handling):
- short press → deep sleep toggle
- **hold 2s → fastboot fires while still held** (won't race the release,
  and beats the hardware PMIC force-off window)
- autorepeat ignored, per-press debounce, dispatch lock
- state machine covered by an automated uinput test (`test-btn-daemon.py`)

## Install

```bash
git clone https://github.com/xnohat/raspberrypi-deepsleep
cd raspberrypi-deepsleep
sudo ./install.sh     # installs deps + everything, idempotent
sudo ./doctor.sh      # verify health anytime
```

Uninstall: `sudo ./uninstall.sh` (restores stock button behavior).

## Usage

| Action | Result |
|---|---|
| Power button, short press | deep sleep on/off |
| Power button, hold 2s, release | save session + shutdown |
| `fastboot` in a terminal | same as 2s hold |
| Screen button, tap | backlight on/off (hardware) |
| Screen button, **hold** | cycle brightness levels (hardware) |
| PiTerm right-click | context menu |

## Repository layout

```
install.sh / doctor.sh / uninstall.sh   installer + health check
powerbtn-daemon.py (+.service)          button press-duration dispatcher
powerbtn-deepsleep.sh                   deep sleep enter/exit
fastboot-save.sh / fastboot-restore.sh  session save / boot-time restore
tmux-state.py                           tmux manifest save/restore engine
battery-logger.sh                       per-minute battery drain logger
test-btn-daemon.py                      automated daemon state-machine test
terminal/                               PiTerm configs (foot, tmux, launcher)
docs/FINDINGS.md                        full research log of this device
docs/FINDINGS.vi.md                     research log (Vietnamese)
docs/Schematic_HackberryPi_CM5_Q20.pdf  hardware schematic (from ZitaoTech)
```

## Related upstream contribution

The touch controller IRQ storm fix (826 IRQs/s idle burning a CPU core) was
submitted upstream: [ZitaoTech/HackberryPiCM5#48](https://github.com/ZitaoTech/HackberryPiCM5/pull/48)
with prebuilt overlays in [releases](https://github.com/xnohat/HackberryPiCM5/releases/tag/touch-fix-v1).

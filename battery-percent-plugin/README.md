# Battery % + charging bolt for wf-panel-pi (HackberryPi CM5)

The stock `wf-panel-pi` battery widget (`libbatt.so`, package `wfplug-batt`)
draws a battery icon but shows **no percentage** inline — the % is only in the
hover tooltip. This is a tiny patch to that plugin's `draw_icon()` so it draws:

- the **charge percentage as a number inside the battery body** (white text with
  a dark outline, readable over both filled and empty battery), and
- a **lightning bolt** (drawn as a cairo path, not an emoji glyph) while charging,
  replacing the stock `flash.png` overlay that used to cover the whole icon.

It stays a real panel plugin, so it sits **inline with no overlap** — unlike a
layer-shell overlay, which wf-panel-pi will not reserve space for.

## Why a patched plugin (not an overlay)
`wf-panel-pi` spans the full top edge and does **not** reserve horizontal space
for third-party surfaces: the `spacing` widget did nothing and a gtk-layer-shell
exclusive zone was ignored, so any floating overlay lands on top of the cpu/clock
widgets. Patching the existing plugin is the only clean inline solution.

## Install (prebuilt)
```bash
sudo ./install.sh          # backs up the original .so, installs the patched one,
                           # restarts the panel
```
`libbatt.so.orig` is the untouched stock plugin (restore with
`sudo cp libbatt.so.orig /usr/lib/aarch64-linux-gnu/wf-panel-pi/libbatt.so`).

> ⚠️ A `wfplug-batt` package update overwrites `/usr/lib/.../libbatt.so`.
> Re-run `install.sh` after such an update.

## Rebuild from source
```bash
sudo apt-get install -y libgtkmm-3.0-dev wf-panel-pi-dev libglm-dev \
     libgtk-layer-shell-dev meson ninja-build
git clone https://github.com/raspberrypi-ui/pplug-batt
cd pplug-batt && git checkout 5246936^   # version whose struct matches the
                                         # installed wf-panel-pi headers
# apply batt-percent.patch to src/batt.c, drop the lxpanel target from
# src/meson.build (no lxpanel-pi-dev), then:
meson setup build --prefix=/usr --libdir=lib/aarch64-linux-gnu
ninja -C build
# result: build/src/libbatt.so
```
See `batt-percent.patch` for the exact `draw_icon()` change.

## Charging detection
The patch does **not** change how charging is detected — it reuses the stock
plugin's `powered` flag (the same one that used to trigger `flash.png`). The
MAX17048 fuel gauge exposes no sysfs charge status; the stock plugin derives it
from the battery sysfs. (The abandoned overlay approach read the MAX17048 CRATE
register directly — kept only in git history.)

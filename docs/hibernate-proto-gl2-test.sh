#!/bin/bash
# gl2-test.sh — 2-GPU (2D scanout + virgl render node) lossy save/restore with patched QEMU
cd /home/pi/vmproto
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
export QEMU_BIN=/home/pi/vmproto/build/qemu-10.0.2/b/qemu-system-aarch64 QEMU_GPU_ALLOW_MIGRATE=1
LOG=/home/pi/vmproto/gl2-test.log; exec > "$LOG" 2>&1
S() { ./vm.sh ssh "$@" 2>/dev/null; }
F='grep -vE "Traceback|File|json|raise|\^|return|obj, end|_default|Connection"'
shot() { sleep 2; grim -o DPI-1 "/home/pi/vmproto/$1.png" >/dev/null && python3 -c "
from PIL import Image; im=Image.open('/home/pi/vmproto/$1.png').crop((40,160,680,640)); print('$1 HOST window colors', len(set(im.resize((64,48)).getdata())))"; }
echo "=== START $(date +%T) ==="
pgrep -x qemu-system-aar | xargs -r kill; sleep 2; rm -f qmp.sock qemu.pid work.ram
RAM=4096 DISPLAY_MODE=gl2 ./vm.sh start || exit 1
for i in $(seq 1 30); do S true && break; sleep 3; done; sleep 12
S 'sudo podman start counter >/dev/null 2>&1; nohup sh -c "i=0; while :; do i=\$((i+1)); echo \$i > /tmp/tick; sleep 1; done" >/dev/null 2>&1 & sleep 2; echo "BEFORE: egl-virgl=$(/tmp/eglt) uptime=$(cut -d" " -f1 /proc/uptime) counter=$(sudo podman exec counter cat /tmp/c) tick=$(cat /tmp/tick) xorg=$(pgrep -c Xorg) guestfb=$(DISPLAY=:0 import -window root -resize 64x48 txt:- 2>/dev/null | tail -n +2 | awk "{print \$3}" | sort -u | wc -l)"'
shot gl2-before
echo "=== SAVE $(date +%T) ==="; ./vm.sh save 2>&1 | eval $F; cat vm.conf; grep -E "QEMU_EXIT|Segm" qemu.err
sleep 2; pgrep -x qemu-system-aar >/dev/null && echo "qemu alive?!" || echo "qemu gone"
echo "=== RESTORE $(date +%T) ==="; ./vm.sh restore 2>&1 | eval $F; sleep 6; grep -E "QEMU_EXIT|Segm|failed" qemu.err | head -2
S 'echo "AFTER: uptime=$(cut -d" " -f1 /proc/uptime) counter=$(sudo podman exec counter cat /tmp/c) tick=$(cat /tmp/tick) xorg=$(pgrep -c Xorg) guestfb=$(DISPLAY=:0 import -window root -resize 64x48 txt:- 2>/dev/null | tail -n +2 | awk "{print \$3}" | sort -u | wc -l)"; echo "egl-virgl after (no Xorg restart): $(timeout 10 /tmp/eglt || echo HANG/FAIL)"; sudo dmesg | tail -3'
shot gl2-after
S 'DISPLAY=:0 xdotool mousemove 100 100 2>/dev/null; DISPLAY=:0 xfce4-terminal >/dev/null 2>&1 & sleep 3; echo "opened terminal; guestfb=$(DISPLAY=:0 import -window root -resize 64x48 txt:- 2>/dev/null | tail -n +2 | awk "{print \$3}" | sort -u | wc -l)"'
shot gl2-after-interact
grep -vE "Gdk|^$" qemu.err | tail -3
echo "=== END $(date +%T) ==="

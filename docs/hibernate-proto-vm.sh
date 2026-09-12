#!/bin/bash
# vm.sh — disposable prototype: KVM guest save/restore ("guest-state hibernation")
# usage: vm.sh start [fresh]|save|restore|status|ssh <cmd>|stop|clean
# env:   RAM=2048  CPUS=4  DISPLAY_MODE=none|gtk|sdl  MULTIFD=4  DIRECTIO=on
set -u
D=/home/pi/vmproto
RAM=${RAM:-2048}; CPUS=${CPUS:-4}; DISPLAY_MODE=${DISPLAY_MODE:-none}
MULTIFD=${MULTIFD:-4}; DIRECTIO=${DIRECTIO:-on}
DISK=$D/work.qcow2; BASE=$D/debian-12-arm64.qcow2
QMP=$D/qmp.sock; PID=$D/qemu.pid; SER=$D/serial.log; RAMF=$D/work.ram
SSH="ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -i $D/id_proto -p 2222 pi@127.0.0.1"

# ONE place that builds the machine — restore must be identical to start.
qemu_cmd() {
  local extra="$1" disp extra_nogpu="${2:-}"
  case "$DISPLAY_MODE" in
    none) disp="-display none" ;;
    gtk)  disp="-display gtk,gl=off -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-tablet-pci" ;;
    sdl)  disp="-display sdl,gl=off -device virtio-gpu-pci -device virtio-keyboard-pci -device virtio-tablet-pci" ;;
    gl)   disp="-display gtk,gl=on -device pcie-root-port,id=rp0,slot=9 $( [ -z "$extra_nogpu" ] && echo -device virtio-gpu-gl-pci,id=gpu0,bus=rp0 ) -device virtio-keyboard-pci -device virtio-tablet-pci" ;;
    gl2)  disp="-display gtk,gl=on -device virtio-gpu-pci,id=gpu2d -device pcie-root-port,id=rp0,slot=9 $( [ -z "$extra_nogpu" ] && echo -device virtio-gpu-gl-pci,id=gpu0,bus=rp0 ) -device virtio-keyboard-pci -device virtio-tablet-pci" ;;
  esac
  echo qemu-system-aarch64 -name vmwork -M virt,gic-version=host -accel kvm -cpu host \
    -smp "$CPUS" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,file=$D/vars.fd \
    -drive if=none,id=hd,file=$DISK,format=qcow2,cache=writeback,discard=unmap \
    -device virtio-blk-pci,drive=hd \
    -drive if=none,id=seed,file=$D/seed.iso,format=raw,readonly=on \
    -device virtio-blk-pci,drive=seed \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
    -device virtio-balloon-pci -device virtio-rng-pci \
    -object memory-backend-ram,id=m0,size=${RAM}M -machine memory-backend=m0 \
    -serial file:$SER -qmp unix:$QMP,server,nowait -pidfile $PID \
    $disp $extra
}

# background qemu (no -daemonize: it breaks gtk display + -incoming), wait for QMP
launch() {
  rm -f "$QMP" "$PID"
  setsid bash -c "exec $(qemu_cmd "$1" "${2:-}")" > "$D/qemu.err" 2>&1 < /dev/null &
  for i in $(seq 1 100); do [ -S "$QMP" ] && return 0; sleep 0.2; done
  echo "qemu failed:"; cat "$D/qemu.err"; return 1
}

qmp() { # qmp <cmd> [json-args]
  python3 - "$QMP" "$1" "${2:-}" <<'PY'
import socket,json,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f=s.makefile('rw')
def send(c,a=None):
    m={"execute":c}
    if a: m["arguments"]=a
    s.sendall((json.dumps(m)+"\n").encode())
    while True:
        l=f.readline()
        if not l: return None
        j=json.loads(l)
        if 'return' in j or 'error' in j: return j
f.readline(); send("qmp_capabilities")
r=send(sys.argv[2], json.loads(sys.argv[3]) if sys.argv[3] else None)
print(json.dumps(r))
PY
}

set_caps() {
  qmp migrate-set-capabilities '{"capabilities":[{"capability":"multifd","state":true},{"capability":"mapped-ram","state":true}]}' >/dev/null
  qmp migrate-set-parameters "{\"multifd-channels\":$MULTIFD,\"direct-io\":$([ "$DIRECTIO" = on ] && echo true || echo false)}" >/dev/null
}
wait_migrate() {
  while :; do
    st=$(qmp query-migrate | python3 -c "import sys,json; r=json.load(sys.stdin)['return']; print(r.get('status'), r.get('error-desc',''))")
    case "$st" in completed*) return 0;; failed*) echo "MIGRATE FAILED: $st"; return 1;; esac
    sleep 0.2
  done
}

case "${1:-}" in
start)
  if [ "${2:-}" = fresh ] || [ ! -f "$DISK" ]; then
    qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$DISK" 30G
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$D/vars.fd"
  fi
  launch "" && echo "started pid $(cat "$PID")"
  ;;
gpu-del)  qmp device_del '{"id":"gpu0"}'; sleep 2; qmp query-pci | grep -c gpu0 ;;
gpu-add)  qmp device_add '{"driver":"virtio-gpu-gl-pci","id":"gpu0","bus":"rp0"}' ;;
save)
  t0=$(date +%s.%N)
  printf 'RAM=%s\nCPUS=%s\nDISPLAY_MODE=%s\nNOGPU=%s\n' "$RAM" "$CPUS" "$DISPLAY_MODE" "$( qmp query-pci | grep -q '"gpu0"' && echo "" || echo 1 )" > "$D/vm.conf"
  qmp stop >/dev/null; set_caps; rm -f "$RAMF"
  r=$(qmp migrate "{\"uri\":\"file:$RAMF\"}"); echo "$r" | grep -q '"error"' && { echo "MIGRATE REFUSED: $r"; qmp cont >/dev/null; exit 1; }
  wait_migrate || { qmp cont >/dev/null; exit 1; }
  t1=$(date +%s.%N); sync "$RAMF"
  qmp quit >/dev/null 2>&1; sleep 1
  printf "SAVE ok: %.1fs, file %s (%s)\n" "$(echo "$t1-$t0"|bc)" "$RAMF" "$(du -h "$RAMF" | cut -f1)"
  ;;
restore)
  t0=$(date +%s.%N)
  [ -f "$D/vm.conf" ] && . "$D/vm.conf"   # machine config pinned at save time
  launch "-incoming defer" "${NOGPU:-}" || exit 1
  set_caps
  qmp migrate-incoming "{\"uri\":\"file:$RAMF\"}" >/dev/null
  wait_migrate || exit 1
  qmp cont >/dev/null
  t1=$(date +%s.%N)
  printf "RESTORE ok: %.1fs (pid %s)\n" "$(echo "$t1-$t0"|bc)" "$(cat "$PID")"
  ;;
status) qmp query-status; qmp query-kvm ;;
ssh) shift; $SSH "$@" ;;
stop) qmp quit ;;
clean) qmp quit 2>/dev/null; sleep 1; rm -f "$DISK" "$RAMF" "$QMP" "$PID" "$SER"; echo cleaned ;;
*) echo "usage: $0 start [fresh]|save|restore|gpu-del|gpu-add|status|ssh <cmd>|stop|clean"; exit 1 ;;
esac

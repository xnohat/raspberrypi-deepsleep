# HackberryPi CM5 — Nghiên cứu "hibernate thật" qua ảo hoá / kernel VM

Ngày: 2026-09-12. Máy: CM5 Lite (BCM2712, 4× Cortex-A76), 16GB RAM, NVMe
(đọc ~370MB/s, ghi ~440MB/s direct), kernel 6.12.47+rpt-rpi-v8, Bookworm,
QEMU 10.0.2, Docker 29.1.3 (/var/lib/docker 285GB), podman/CRIU chưa cài.
Bối cảnh: FINDINGS §6 (hibernate stock = không), fake-sleep ~1270mA, fastboot
= reconstruction. Câu hỏi: có cách nào cho "hibernate thật" mà vẫn chạy được
docker/podman không?

## 0. Kết luận ngắn

| Hướng | Verdict | Vì sao |
|---|---|---|
| **A. Guest-state hibernation** — workload chạy trong 1 VM KVM ARM64, "ngủ" = QEMU save RAM+state ra file → host tắt hẳn (0mA) → boot host 16s → restore VM | ✅ **Khả thi nhất**, cần prototype | KVM VHE chạy OK trên máy (đã boot VM `-accel kvm`). QEMU 10.0.2 có `mapped-ram`+`multifd` (ghi song song, O_DIRECT). Docker/Podman trong guest **không cần nested virt**. |
| **B. CRIU checkpoint process trên host** (podman checkpoint / criu dump) | ⚠️ Chỉ hợp container headless | CRIU chính thức: process mở **device file** (GPU/DRM, input) hoặc nối **Xserver/compositor** = không dump được. Desktop + CrawBot Electron + chromium = không. |
| **C. Custom kernel CONFIG_HIBERNATION trên host** | ❓ **Chưa ai verify**, không phải "bất khả" về lý thuyết | Kconfig arm64: `ARCH_HIBERNATION_POSSIBLE=y` đã bật trên host, chỉ thiếu `CONFIG_HIBERNATION`. Blocker thật = driver Pi (rp1, vc4, raspberrypi-firmware) **0 pm hook** → freeze/thaw không có gì để restore state. Rủi ro cao, đường dài. |

**"Nested virtualization" là hiểu nhầm:** Docker Engine / Podman chạy **trong
guest** chỉ cần namespaces + cgroups + seccomp của kernel guest — y hệt như
trên host. KVM lồng (KVM-trong-KVM) chỉ cần khi muốn chạy *VM* bên trong VM
(Podman Machine, Docker Desktop, Waydroid-qua-VM…). Cortex-A76 = Armv8.2-A,
**không có FEAT_NV/NV2** → kernel host báo `KVM_CAP_ARM_EL2 = 0`, không có
dòng "Nested Virtualization Support" trong dmesg. → Không có nested KVM
hardware, và **không cần**.

## 1. Bằng chứng đã đọc (primary source)

### 1.1 Máy này
- `/sys/power/state` rỗng; `/proc/config.gz`: `CONFIG_SUSPEND`/`HIBERNATION`
  không set; nhưng `CONFIG_ARCH_HIBERNATION_POSSIBLE=y`, `CONFIG_CPU_PM=y`,
  `CONFIG_SWAP=y`, `CONFIG_KVM=y`, `CONFIG_CGROUP_FREEZER=y`,
  `CONFIG_CHECKPOINT_RESTORE=y`.
- dmesg: `kvm [1]: VHE mode initialized successfully`, IPA 40 bit.
  `qemu-system-aarch64 -M virt -accel kvm -cpu host` khởi tạo VM OK
  (mới test init, chưa test guest chạy + save/restore).
- ioctl `KVM_CHECK_EXTENSION(KVM_CAP_ARM_EL2)` = 0 → không nested.
- QEMU 10.0.2 caps: `multifd, mapped-ram, background-snapshot, postcopy-ram,
  zero-copy-send…`; devices có: `virtio-gpu-pci`, `virtio-gpu-gl-pci`
  (venus=on/off, blob), `vhost-user-fs-pci`, `virtio-9p-pci`,
  `vhost-vsock-pci`, `virtio-input-host`, `virtio-keyboard/tablet`,
  `usb-host`. libvirglrenderer1 0.10.4. Display backends: gtk, sdl,
  egl-headless, dbus. **virtiofsd chưa cài.**
- Swap hiện là 4× zram 15.6G — **không dùng được làm resume device** cho
  hướng C (zram mất khi tắt máy); cần swapfile/partition thật trên NVMe.

### 1.2 Kernel (raspberrypi/linux rpi-6.12.y)
- `arch/arm64/Kconfig`: `ARCH_HIBERNATION_POSSIBLE def_bool y depends on CPU_PM`.
- `kernel/power/Kconfig`: `HIBERNATION depends on SWAP && ARCH_HIBERNATION_POSSIBLE`
  → về mặt Kconfig, build custom kernel bật được.
- `bcm2712_defconfig`: `# CONFIG_SUSPEND is not set`, `CONFIG_PM=y` — RPi
  tắt có chủ đích.
- `arch/arm64/kernel/hibernate.c`: code arm64 generic có xử lý
  `el2_reset_needed()` (nVHE) & `__hyp_stub_vectors`; máy này chạy VHE.
- Đếm pm hook (`suspend|resume`) trong driver Pi: `drivers/mfd/rp1.c` = 0,
  `drivers/gpu/drm/vc4/vc4_drv.c` = 0, `drivers/firmware/raspberrypi.c` = 0;
  `pcie-brcmstb.c` = 8, `sdhci-brcmstb.c` = 8, `xhci-pci.c` = 25.
  → **RP1 (toàn bộ I/O: USB/Ethernet/GPIO/I2C/PWM quạt/DPI panel) và
  VideoCore firmware mailbox không có freeze/thaw/restore** — hibernate
  resume sẽ thức dậy với firmware đã re-init RP1/VC từ boot nhưng kernel
  tin rằng state cũ còn → gần chắc chắn hỏng I/O sau resume.
- `arch/arm64/kernel/cpufeature.c`: `ARM64_HAS_NESTED_VIRT` cần
  `ID_AA64MMFR2_EL1.NV >= NV2` và `kvm_get_mode()==KVM_MODE_NV`.
- FINDINGS §5: PSCI `CPU_ON` fail -22 sau offline → hibernate resume cần
  offline/online CPU phụ (`disable_nonboot_cpus`) → **thêm 1 blocker nữa
  cho hướng C trên firmware Pi hiện tại.**

### 1.3 QEMU v10.0.2 (source)
- `hw/display/virtio-gpu-base.c:185-186`:
  `if (virtio_gpu_virgl_enabled(g->conf)) error_setg(&g->migration_blocker,
  "virgl is not yet migratable")` → **virtio-gpu-gl (virgl/venus) = KHÔNG
  save/restore được.** `virtio-gpu-pci` thường (2D, có `vmstate_virtio_gpu`
  + blob state) thì migratable.
- `hw/input/virtio-input-host.c:221`: `.unmigratable = 1` → evdev
  passthrough không migrate; dùng `virtio-keyboard/tablet` (QEMU-emulated,
  migratable) thay thế.
- `hw/usb/host-libusb.c:1750`: `vmstate_usb_host` có `post_load` → usb-host
  có vmstate (migrate được về mặt QEMU, thiết bị thật vẫn bị reset).
- `hw/virtio/vhost-user-fs.c:356-367`: virtiofs migrate được **chỉ khi
  backend hỗ trợ device state** (`vhost_supports_device_state`), nếu không
  → `-ENOTSUP`. virtiofsd Rust mới có; Debian bookworm không có package →
  dùng **virtio-9p** (migratable, chậm hơn) hoặc disk image riêng.
- `docs/devel/migration/mapped-ram.rst`: "Mapped-ram migration is best done
  non-live, i.e. by stopping the VM"; bật `multifd`+`mapped-ram`, `migrate
  file:/path`, `direct-io on`; file có kích thước bị chặn = RAM guest.

### 1.4 CRIU / Podman
- criu.org "What cannot be checkpointed": *"If a task has opened or mapped
  any character or block device … dump (and restore) is impossible"*;
  *"Dumping + restoring an application connected to a 'real' Xserver … is
  impossible now due to part of the app's state is in the Xserver"*.
- Podman `container checkpoint`: cần CRIU ≥3.11 (bookworm có 3.17.1),
  crun 1.8.1; hỗ trợ `--tcp-established`, `--file-locks`, `--export`.
  Cùng arch mới restore được (arm64→arm64 OK).
- Docker `checkpoint` vẫn là experimental.

## 2. Thiết kế hướng A (đề xuất) — "guest-state hibernation + host cold boot"

```
HOST (Pi OS tối giản)              GUEST "work" (Debian/Pi OS arm64, KVM)
- labwc/foot + pideepsleep         - desktop của anh (labwc/xfce) qua virtio-gpu 2D
- qemu-system-aarch64 -accel kvm   - CrawBot/AICoworker gateway, chromium
- AICoworker gateway *có thể* ở    - Docker/Podman (namespaces, KHÔNG cần KVM)
  host để điều khiển VM từ chat    - dữ liệu: qcow2 riêng (+ 9p share ↔ host)
```

Chu trình "hibernate":
1. QMP `stop` → `migrate_set_capability multifd on, mapped-ram on`,
   `direct-io on`, `migrate file:/var/vm/work.ram` (RAM guest N GB ghi
   song song vào NVMe ~440MB/s → 8GB ≈ 20-25s, 4GB ≈ 10s).
2. Kill QEMU, `fastboot-save`/shutdown host → **0mA thật**.
3. Boot host (16s) → autostart QEMU `-incoming file:/var/vm/work.ram`
   (mapped-ram đọc ~370MB/s; có thể lazy-load bằng `MAP_PRIVATE`).
4. Guest tiếp tục **đúng chỗ đang làm**: shell, tmux, chromium, docker
   containers đang chạy — không phải reconstruction.

Tổng resume ≈ 16s boot + 10-25s restore ≈ **30-45s**, so với fastboot hiện
tại (boot + relaunch app + pre-typed command, mất trạng thái trong RAM).

Giới hạn phải chấp nhận / cần test:
- **GPU:** guest chỉ được `virtio-gpu-pci` 2D (không virgl/venus → không
  GL/Vulkan tăng tốc trong guest). Compositor trong guest render bằng CPU
  (llvmpipe/pixman) trên 720×720 — có thể đủ, phải đo. Chromium tắt GPU.
- **Waydroid** cần binder trong *guest kernel* + GPU → rất có thể không
  chạy trong guest; giữ ở host hoặc bỏ.
- **Input:** không dùng `virtio-input-host` (unmigratable); dùng
  `virtio-keyboard-pci`/`virtio-tablet-pci` qua display backend của QEMU
  (gtk/sdl trên labwc host) hoặc chạy guest desktop qua **SPICE/VNC** vào
  host — cả 2 đều migratable.
- **RAM split:** host 16GB; guest 6-10GB. File RAM = đúng size guest RAM
  (mapped-ram bounded) → nên set guest RAM vừa đủ + `virtio-balloon`.
- **Clock/network:** sau restore guest clock nhảy; TCP session cũ chết;
  cần `chrony`/`hwclock` sync + wifi ở host.
- **Disk consistency:** qcow2 guest chỉ được dùng bởi đúng file RAM đã
  save (pair RAM file ↔ disk snapshot); ghi thêm vào disk giữa 2 lần =
  hỏng. Nên `qemu-img snapshot`/backing-file mỗi lần save.
- **Docker hiện tại 285GB ở host** → phải chọn: dời data vào guest disk
  hoặc mount 9p (chậm với overlayfs). Đơn giản nhất: guest có disk riêng
  100-200GB cho docker.
- **Bảo mật:** file RAM chứa toàn bộ bí mật trong RAM guest; NVMe không mã
  hoá → chmod 600 hoặc LUKS.

Điện: hibernate = tắt hẳn → 0mA (như fastboot). Đổi lại là mất GPU
acceleration trong guest và overhead KVM ~5-10% CPU.

## 3. Hướng B — khi nào đáng dùng
Cài `podman + crun + criu` (bookworm có sẵn) → `podman container checkpoint
--export` cho **container headless** (DB, ollama, dev server) trước fastboot,
`podman container restore --import` sau boot. Bổ sung tốt cho fastboot hiện
tại (giữ được state container), nhưng **không** cứu được desktop/Electron.

## 4. Hướng C — điều kiện để thử (không khuyến nghị)
Build kernel rpi-6.12.y với `CONFIG_HIBERNATION=y` + swapfile NVMe thật +
`resume=`/`resume_offset=` trên cmdline, nghĩa là *tất cả* driver Pi phải có
freeze/thaw đúng (rp1, vc4, VC firmware mailbox, pcie-brcmstb, dwc2/xhci,
brcmfmac) + PSCI CPU_ON phải hoạt động (đang fail -22, FINDINGS §5). Không
có báo cáo nào thành công trên Pi 5/CM5 tới 09/2026 (RPi engineer: "no
hardware support"). Đây là dự án kernel dev nhiều tuần với xác suất thấp;
để sau nếu firmware RPi cập nhật.

## 5. Prototype đề xuất (disposable, cần anh duyệt)
Mục tiêu: chứng minh chu trình save → kill → boot → restore giữ được
process + container trong guest. Không đụng host config, không đụng
pideepsleep, xoá sạch sau khi xong.
1. Tạo qcow2 20GB + cài Debian arm64 cloud image (không cần cài đặt tay),
   RAM 2GB, `-accel kvm -cpu host -device virtio-gpu-pci -display none`
   (serial console) — pass 1 headless.
2. Trong guest: cài podman, chạy container `counter` (in số tăng mỗi giây
   vào stdout + file).
3. QMP `stop` + `migrate file:` (mapped-ram, multifd 4, direct-io) → đo
   thời gian + size. Kill QEMU.
4. Khởi động lại QEMU `-incoming file:` → đo thời gian; kiểm tra counter
   **tiếp tục từ số cũ**, container `Up`, uptime guest không reset.
5. (Pass 2, nếu pass 1 OK) guest RAM 6GB + desktop nhẹ + chromium qua
   virtio-gpu 2D + SPICE/gtk display trên host → đo độ mượt 720×720 + đo
   save/restore ở size thật.
Pass/fail rõ: counter liên tục = PASS; mọi thứ khác = FAIL với log.

Tài nguyên: ~25GB NVMe tạm, ~30-40 phút, không reboot host.

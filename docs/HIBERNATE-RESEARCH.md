# HackberryPi CM5 — Nghiên cứu "hibernate thật" qua ảo hoá / kernel VM

Ngày: 2026-09-12. Máy: CM5 Lite (BCM2712, 4× Cortex-A76), 16GB RAM, NVMe
(đọc ~370MB/s, ghi ~440MB/s direct), kernel 6.12.47+rpt-rpi-v8, Bookworm,
QEMU 10.0.2, Docker 29.1.3 (/var/lib/docker 285GB), podman/CRIU chưa cài.
Bối cảnh: FINDINGS §6 (hibernate stock = không), fake-sleep chỉ giảm ~50% so
với thức (số đo còn nhiễu, xem memory 2026-08-31), fastboot = reconstruction. Câu hỏi: có cách nào cho "hibernate thật" mà vẫn chạy được
docker/podman không?

## 0. Kết luận ngắn

| Hướng | Verdict | Vì sao |
|---|---|---|
| **A. Guest-state hibernation** — workload chạy trong 1 VM KVM ARM64, "ngủ" = QEMU save RAM+state ra file → host tắt hẳn (drain ≈ fastboot) → boot host 16s → restore VM | ✅ **Khả thi nhất**, cần prototype | KVM VHE chạy OK trên máy (đã boot VM `-accel kvm`). QEMU 10.0.2 có `mapped-ram`+`multifd` (ghi song song, O_DIRECT). Docker/Podman trong guest **không cần nested virt**. |
| **B. CRIU checkpoint process trên host** (podman checkpoint / criu dump) | ⚠️ Chỉ hợp container headless | CRIU chính thức: process mở **device file** (GPU/DRM, input) hoặc nối **Xserver/compositor** = không dump được. Desktop + CrawBot Electron + chromium = không. |
| **C. Custom kernel CONFIG_HIBERNATION trên host** | ❓ **Chưa ai verify**, không phải "bất khả" về lý thuyết | Kconfig arm64: `ARCH_HIBERNATION_POSSIBLE=y` đã bật trên host, chỉ thiếu `CONFIG_HIBERNATION`. Blocker thật = driver Pi (rp1, vc4, raspberrypi-firmware) **0 pm hook** → freeze/thaw không có gì để restore state. Rủi ro cao, đường dài. |

**"Nested virtualization" là hiểu nhầm:** Docker Engine / Podman chạy **trong
guest** chỉ cần namespaces + cgroups + seccomp của kernel guest — y hệt như
trên host. KVM lồng (KVM-trong-KVM) chỉ cần khi muốn chạy *VM* bên trong VM
(Podman Machine, Docker Desktop, Waydroid-qua-VM…). Cortex-A76 = Armv8.2-A,
FEAT_NV ra đời ở Armv8.3, NV2 ở Armv8.4 (Arm doc, đọc qua tổng hợp — chưa
đọc trực tiếp TRM). Kernel rpi-6.12.y (`cpufeature.c`) chỉ bật
`ARM64_HAS_NESTED_VIRT` khi `ID_AA64MMFR2_EL1.NV >= NV2` **và** boot với
`kvm-arm.mode=nested`; máy này không có dòng "Nested Virtualization
Support" trong dmesg. → Không có nested KVM hardware, và **không cần**.

## 1. Bằng chứng đã đọc (primary source)

### 1.0 Trạng thái kiểm chứng
Mới chứng minh: KVM khởi tạo được VM (paused, không disk). **Chưa** chạy
guest, chưa chạy container trong guest, chưa save/restore lần nào. Mọi con
số thời gian/điện ở dưới là ước tính, chờ prototype.

### 1.1 Máy này
- `/sys/power/state` rỗng; `/proc/config.gz`: `CONFIG_SUSPEND`/`HIBERNATION`
  không set; nhưng `CONFIG_ARCH_HIBERNATION_POSSIBLE=y`, `CONFIG_CPU_PM=y`,
  `CONFIG_SWAP=y`, `CONFIG_KVM=y`, `CONFIG_CGROUP_FREEZER=y`,
  `CONFIG_CHECKPOINT_RESTORE=y`.
- dmesg: `kvm [1]: VHE mode initialized successfully`, IPA 40 bit.
  `qemu-system-aarch64 -M virt -accel kvm -cpu host` khởi tạo VM OK
  (mới test init, chưa test guest chạy + save/restore).
- (Đã thử ioctl `KVM_CAP_ARM_EL2` nhưng hằng số đó **không tồn tại** trong
  uapi rpi-6.12.y → kết quả vô nghĩa, bỏ. Bằng chứng nested = mục 1.2.)
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
- Đếm pm hook (`dev_pm_ops|freeze|thaw|poweroff|restore|_suspend(|_resume(`)
  trong driver Pi: `mfd/rp1.c`=0, `pinctrl-rp1.c`=0, `vc4_drv.c`=1,
  `vc4_kms.c`=0, `vc4_hvs.c`=0, `firmware/raspberrypi.c`=0,
  `bcm2835-mailbox.c`=0; ngược lại `pcie-brcmstb.c`=8, `sdhci-brcmstb.c`=8,
  `xhci-pci.c`=25. Đây là **grep, chưa đọc từng driver** — hook có thể nằm
  file khác. Kết luận thận trọng: **rủi ro device-state chưa được xử lý**
  ở RP1 (USB/Ethernet/GPIO/I2C/PWM quạt/DPI) và VideoCore mailbox; sau
  resume firmware đã re-init các khối này từ boot, kernel có thể giữ state
  cũ → khả năng cao hỏng I/O, cần kernel dev thật để xác nhận.
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
2. Kill QEMU sau khi migrate báo `completed` + `fsync` file, rồi shutdown
   host → drain như fastboot (gần 0; PMIC/RTC vẫn ăn rất ít).
3. Boot host (16s) → autostart QEMU `-incoming file:/var/vm/work.ram`
   (mapped-ram đọc ~370MB/s; có thể lazy-load bằng `MAP_PRIVATE`).
4. Guest tiếp tục **đúng chỗ đang làm**: shell, tmux, chromium, docker
   containers đang chạy — không phải reconstruction.

Tổng resume ≈ 16s boot + 10-25s restore ≈ **30-45s (ước tính từ băng thông
NVMe đo bằng dd, chưa đo save/restore thật)**, so với fastboot hiện
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
- **Checkpoint invariants (bắt buộc):** (1) RAM file ↔ disk image là 1 cặp,
  disk chỉ QEMU đó được mở; (2) shutdown host chỉ sau khi QMP báo
  `completed` và file đã fsync; (3) machine type / device list / RAM size
  pin cứng trong 1 file cấu hình, đổi = không restore được; (4) sau restore
  chờ mạng lên rồi mới coi là "dậy".

Điện: hibernate = tắt hẳn → drain như fastboot (chưa đo riêng). Đổi lại là mất GPU
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

## 6. Kết quả prototype (2026-09-13 00:05–00:22) — guest-state checkpoint PASS (cùng host, 1 lần/pass)

Script: `docs/hibernate-proto-vm.sh` (qemu -M virt -accel kvm -cpu host,
mapped-ram + multifd 4 + direct-io, QMP qua unix socket). Guest: Debian 12
generic arm64 cloud image + cloud-init (podman, chrony), disk qcow2 30G.

| Pass | Guest | Save | Restore | RAM file | Bằng chứng continuity |
|---|---|---|---|---|---|
| 1 headless | 2GB, podman container counter | **9.8s** | **4.5s** | 1.4GB thực (2.3GB logical, sparse) | counter 46 → 48 → 52 sau restore; uptime 132→135s; podman `Up` liên tục |
| 2 desktop | 4GB, XFCE + chromium + xfce4-terminal đếm tick, virtio-gpu 2D, `-display gtk` trên labwc host | **9.4s** | **4.5s** | 1.3GB thực (4.4GB logical) | uptime 404→409s, chromium 10 proc giữ nguyên, terminal tiếp tục đếm tick 305→327; ảnh `hibernate-proto-pass2-*.png` |

Quan sát:
- KVM thật (`-cpu host` → guest thấy Cortex-A76), không TCG. Guest boot
  cloud-init ~40s lần đầu.
- Save/restore không tỉ lệ với RAM cấp cho guest mà với **RAM đang dùng**
  (mapped-ram bỏ qua zero page): 2GB và 4GB guest đều ~1.3-1.4GB file, ~9.5s.
  Ước lượng guest 8GB dùng thật 5-6GB → save ~30-40s, restore ~15-20s.
- Restore 4.5s = QEMU khởi tạo + nạp file + `cont` (số đo 1 lần, chưa lặp).
  Đây là checkpoint trạng thái guest trên cùng host — **chưa** test chu
  trình tắt/bật nguồn host thật.
- **Nhiệt/CPU:** guest desktop idle (XFCE + chromium mở example.com) → qemu
  14–45% một core trên host (render CPU vì không có GPU trong guest), SoC
  65.9°C / quạt 2954rpm; pause VM 20s → 63.9°C. Headless guest ≈ 0%. → VM có
  desktop **nóng hơn host-native ~2°C ở idle**, và sẽ tệ hơn khi có
  animation/video (mọi frame là CPU).
- Màn hình: guest 720×720 qua `xrandr --newmode`, hiển thị trong cửa sổ gtk
  của QEMU trên labwc (có thể fullscreen). Bàn phím/chuột qua
  virtio-keyboard/tablet OK (migratable).
- Bug gặp: `-daemonize` làm hỏng `-display gtk` + `-incoming` → dùng
  `setsid` + chờ QMP socket. `sync` file RAM trước khi quit.

### 6.1 Câu hỏi "guest phải giống y OS host, kernel gốc" (đã sửa 00:35)
**Đính chính:** kiểm tra lại `/proc/config.gz` — kernel RPi 6.12.47 stock
**không có** `CONFIG_VIRTIO_BLK/NET/PCI/MMIO` lẫn `PCI_HOST_GENERIC` (chỉ có
`VIRTIO_VSOCKETS_COMMON=m`, `VIRTIO_MENU=y`; không có file `virtio*.ko` nào
trong `/lib/modules`). Câu "kernel host có virtio module" em nói trước đó là
SAI. Initrd không tạo ra driver được → **kernel stock không boot được cấu
hình QEMU `-M virt` này**. Còn "dùng chung đúng kernel đang chạy của host"
thì đó là container (namespaces), không phải KVM.

Cái làm được: **userspace Pi OS y hệt** (rootfs Pi OS, user pi, package,
docker data) + một trong hai kernel guest:
- (a) kernel Debian generic arm64 (`linux-image-arm64`, đã chứng minh boot
  KVM ở prototype) — không có patch RPi nhưng trong VM không cần;
- (b) kernel RPi tự build thêm virtio + PCI_HOST_GENERIC — giữ "chất RPi",
  tốn 1-2h build, không đụng kernel host.
Rootfs guest phải là bản sao **có giới hạn** (host đang dùng 338G/468G, 172G
ngoài docker → không clone nguyên cả `/`); không bao giờ gắn partition root
host đang mount vào guest ở chế độ ghi.

**GPU:** V3D (`1002000000.v3d`) không có iommu_group, host không có
`vfio-platform` → không passthrough. VirGL/venus trong guest **có thể** cho
GL/Vulkan (chưa test trên V3D host) nhưng QEMU 10 chặn migration khi bật
virgl → **không thể vừa có GPU tăng tốc vừa snapshot VM**. Hybrid khả dĩ:
app cần GPU (waydroid, game) chạy ở host, phần còn lại trong guest.

**Nhiệt (đính chính):** số 65.9°C vs 63.9°C chỉ là 1 điểm đo + pause 20s,
`ps %CPU` là trung bình đời process — **chưa đủ** để kết luận VM nóng hơn
bao nhiêu. Chỉ chắc: guest desktop render bằng CPU nên có tải nền; cần đo
A/B ≥10 phút nếu muốn số thật.

**Lưu ý prototype:** lần restore pass 2 fail đầu tiên là do gọi `restore`
thiếu `RAM=4096 DISPLAY_MODE=gtk` (rơi về default 2GB/none → cấu hình lệch
với snapshot), không chỉ vì `-daemonize`. Bài học: cấu hình máy phải được
**ghi vào file cạnh snapshot** và restore đọc từ đó, không truyền qua env.

### 6.2 Bước tiếp (chưa làm, cần anh duyệt)
1. Chọn kernel guest (a) Debian generic hay (b) RPi rebuild + virtio.
2. Tạo rootfs guest bounded (debootstrap/rsync có exclude, ≤30G) mang
   userspace Pi OS; boot KVM; verify docker + AICoworker trong guest.
3. vm.sh v2: config file cạnh snapshot, fail-fast QMP, PID chính xác.
4. Test host power-cycle thật (save → shutdown → boot → restore).

## 7. Hybrid "3D trong VM + hibernate" (2026-09-13 00:40–00:50) — CHƯA làm được

Mục tiêu: có GL/Vulkan trong guest khi làm việc, rút GPU trước khi save,
cắm lại sau restore.

| Bước | Kết quả | Bằng chứng |
|---|---|---|
| virgl trên V3D host (`-display gtk,gl=on -device virtio-gpu-gl-pci`) | ✅ **Chạy** | guest `glxinfo`: `OpenGL renderer string: virgl (V3D 7.1.10.2)`, `Accelerated: yes`, Mesa 22.3.6 GL 3.1; dmesg guest `features: +virgl +edid`; glmark2 chạy trong XFCE |
| Save khi GPU-gl còn gắn | ❌ | QMP: `{"error": {"desc": "virgl is not yet migratable"}}` |
| Hot-unplug GPU (`device_del gpu0`, gắn trên pcie-root-port) | ❌ | QMP: `Device 'virtio-gpu-gl-pci' does not support hotplugging` — `hw/display/virtio-gpu-pci.c:68 dc->hotpluggable = false` |
| vhost-user-gpu (GPU render trong process **ngoài** QEMU, `/usr/lib/qemu/vhost-user-gpu --virgl -r renderD128`, memfd share) | GL ✅ (cùng renderer virgl V3D) nhưng save ❌ | vẫn `virgl is not yet migratable` — blocker gắn ở `virtio-gpu-base.c:186` trong realize, dùng chung cho mọi biến thể virgl |

**Kết luận:** với QEMU 10.0.2 stock, **không có tổ hợp nào** cho cả 3D lẫn
snapshot: blocker là code QEMU, không phải giới hạn phần cứng; không hotplug
được; đổi sang vhost-user-gpu không thoát.

Đường còn lại (chưa thử, cần anh duyệt vì phải build QEMU):
- **Patch QEMU 1 dòng** (bỏ `migrate_add_blocker` khi dùng vhost-user-gpu)
  + rebuild từ source Debian. Save sẽ thành công (QEMU chỉ giữ virtio
  state; GPU state nằm trong process vhost-user-gpu bị mất). Sau restore,
  process vhost-user-gpu mới trắng trơn → guest driver `virtio_gpu` tưởng
  resource cũ còn → màn hình rác/Xorg treo cho tới khi **restart Xorg**
  (mất cửa sổ GUI, nhưng shell/tmux/docker/AICoworker gateway sống). Đây là
  cách "hibernate mất GUI, giữ process" — có thể chấp nhận nếu GUI trong
  guest chỉ là terminal + chromium (chromium có session restore riêng).
  Rủi ro: guest kernel driver có thể panic khi resource biến mất; cần test.
- Chờ upstream: QEMU/virglrenderer chưa có kế hoạch serialize GPU state
  (crosvm có snapshot sơ khai, không dùng được với QEMU).

Ghi chú vận hành: `-daemonize` + `-display gtk` không tương thích; QEMU cho
gtk cần `XDG_RUNTIME_DIR`/`WAYLAND_DISPLAY` của user pi; `vm.conf` giờ được
ghi cạnh snapshot và `restore` đọc từ đó (RAM/CPUS/DISPLAY_MODE/NOGPU).

### 7.1 Patch QEMU bỏ blocker — TEST THẬT: SEGFAULT (01:16–01:55)

Build QEMU 10.0.2 từ source (`--enable-virglrenderer --enable-opengl
--enable-gtk --enable-kvm`, 4 core A76) với patch
`docs/hibernate-qemu-virgl-unblock.patch` (bỏ `migrate_add_blocker` khi env
`QEMU_GPU_ALLOW_MIGRATE=1`, opt-in). ⚠️ Patch này là **thí nghiệm, không an
toàn, không dùng thường** — nó chỉ tắt cảnh báo, không thêm code lưu GPU.

Cấu hình test: **`virtio-gpu-gl-pci` in-process** (không phải vhost-user-gpu).
Kết quả: guest virgl (renderer `virgl (V3D 7.1.10.2)`) → QMP `stop` →
`migrate file:` mapped-ram → status `active` ~5s → **QEMU segfault
(exit 139)**, file RAM dở dang 4.4GB. Không có core dump/backtrace.

Nguyên nhân **khả dĩ (suy từ source, chưa xác nhận bằng backtrace)**:
`hw/display/virtio-gpu.c virtio_gpu_save()` duyệt `g->reslist` và ghi
`pixman_image_get_data(res->image)` cho mọi resource không-blob; resource do
virgl tạo (`virtio-gpu-virgl.c virgl_cmd_create_resource_2d`) không có
`res->image` (pixel nằm trong GL texture của host) → NULL deref. Blocker
"virgl is not yet migratable" do đó không phải cờ hành chính mà chặn đúng
code path chưa biết serialize GPU resource.

**Verdict (trong phạm vi đã test):** các cách đã thử — hot-unplug trên QEMU
stock, vhost-user-gpu, và patch bỏ blocker với `virtio-gpu-gl-pci` — đều
không cho "3D + snapshot". Chưa chứng minh được tổ hợp nào chạy; cũng
**chưa** chứng minh mọi hướng đều bất khả (chưa thử vhost-user-gpu + patch,
chưa thử guest 2 GPU với GL render-only + stop app GL trước save). Đi tiếp
đúng nghĩa cần QEMU/virglrenderer lưu được GPU resource/context — hiện
không thấy sẵn.

Hai lựa chọn thực dụng:
- **2D + guest-state checkpoint** (§6, đã chạy trên cùng host; chưa test qua
  tắt/bật nguồn host thật).
- **3D không snapshot** — guest virgl, dừng bằng fastboot-style
  reconstruction như hiện tại.

Binary patched ở `/home/pi/vmproto/build/qemu-10.0.2/b/` (không cài vào hệ
thống); `hibernate-proto-vm.sh` hỗ trợ `QEMU_BIN`, `DISPLAY_MODE=gl`.

## 8. Mức 1 "lossy virgl checkpoint" (2026-09-13 02:20–02:55) — PROOF-OF-CONCEPT ĐẠT

Patch `docs/hibernate-qemu-virgl-lossy.patch` (QEMU 10.0.2, opt-in
`QEMU_GPU_ALLOW_MIGRATE=1`): (a) bỏ migration blocker virgl; (b)
`virtio_gpu_save` bỏ qua resource không có pixman image (= resource virgl);
(c) `post_load` bỏ qua scanout trỏ tới resource không tồn tại. **GPU state
KHÔNG được lưu** — chỉ RAM + virtio state. Đánh dấu: thí nghiệm, không an toàn
cho dùng chung.

### 8.1 Phát hiện về hiển thị (độc lập với migration)
`-display gtk,gl=on` trên labwc/V3D host cho **cửa sổ đen** ngay cả boot mới
với QEMU stock, với gl=es, với fbcon (không Xorg); `egl-headless` screendump
"no surface". Guest X framebuffer lúc đó cũng chỉ 1 màu (glamor trên virgl
vẽ vào texture host, không có pixel phía guest). `gl=off` hiển thị bình
thường. → Đường trình chiếu GL của QEMU trên host này chưa chạy (GtkGLArea
đòi GL ≥3.2, V3D desktop GL 3.1 — nghi vấn, chưa chứng minh). Kết luận
"3D trong VM chạy" lúc 01:09 chỉ dựa trên `glxinfo` — chưa đủ; đã sửa.

### 8.2 Cấu hình 2 GPU (chạy được, có hình)
`-display gtk,gl=on -device virtio-gpu-pci,id=gpu2d` (scanout, gl=off path)
`+ -device virtio-gpu-gl-pci,id=gpu0` (render node). Guest: card0 = 2D
(Xorg modeset, llvmpipe), card1/renderD129 = virgl. Xorg GPU-1 glamor "on
virgl (V3D)" nhưng DRI_PRIME/offload sink lỗi BadValue → GLX app vẫn
llvmpipe. **App gọi EGL thẳng vào `/dev/dri/renderD129` (GBM/surfaceless)
được `virgl (V3D 7.1.10.2)`** — tức accel có cho app biết chọn render node
(kmscube/EGL/chromium `--render-node`...), không tự động cho mọi GLX app.
Màn hình host hiển thị đúng (1223 màu).

### 8.3 Save/restore với cấu hình 2 GPU + patch (test `docs/hibernate-proto-gl2-test.sh`)
| | |
|---|---|
| Save | 7.1s, file 946MB (guest 4GB) |
| Restore | 3.3s |
| Continuity | uptime 25→34s, counter 3→12→29, tick liên tục, Xorg giữ nguyên PID, **màn hình host có hình ngay** (1224 màu), mở terminal mới vẽ được |
| GL sau restore, **không** restart Xorg | EGL app mới trên renderD129: `GL_RENDERER=virgl (V3D)`, `glGetError=1286` (INVALID_FRAMEBUFFER_OPERATION — context/resource cũ trong virglrenderer đã mất) |
| GL sau `systemctl restart lightdm` (test §8 lần 1, cấu hình 1 GPU) | glxinfo virgl OK, glmark2 = 667 |

Kết luận mức 1: **process/container/desktop 2D sống qua checkpoint; GPU
accel dùng lại được sau khi khởi động lại client GL** (app đang giữ context
GL cũ sẽ lỗi — cần restart app đó hoặc display server). Chưa test: tắt
nguồn host thật; app GL thật (chromium/waydroid) qua chu trình này; độ ổn
định lặp nhiều lần; guest kernel có rò resource id cũ không.

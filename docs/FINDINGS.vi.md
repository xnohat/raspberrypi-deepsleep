# HackberryPi CM5 — Nhật ký nghiên cứu

> 🇬🇧 [English (main): FINDINGS.md](FINDINGS.md)

Toàn bộ phát hiện từ phiên đào sâu 30-31/08/2026. Mọi thứ đều đo/verify
trên máy thật (HackberryPi CM5, CM5 Lite, Raspberry Pi OS Bookworm,
kernel 6.12.47+rpt-rpi-v8) trừ khi ghi chú khác.

## 1. Điều khiển quạt

- Quạt: pwm-fan, hwmon tên `pwmfan` (số hwmonN đổi mỗi lần boot — phải
  resolve theo tên!). Điều khiển: `pwm1_enable` (1=tay, 2=auto), `pwm1` (0-255).
- Đặc tính đo được: **stall dưới pwm≈100-110**; pwm120=1343rpm, 140=2503,
  160=3957, 255≈9600rpm (rất ồn).
- Config gốc: 40°C→pwm200, 50°C→pwm255 → idle là gào hết cỡ.
- Curve mới (`/boot/firmware/config.txt`): 55°C→115, 65°C→145, 72°C→190,
  78°C→255, hysteresis 5°C. Idle <50°C = quạt tắt.
- **Bẫy**: thermal zone chạy theo interrupt — sau khi chỉnh pwm tay,
  governor chỉ tính lại khi nhiệt VƯỢT QUA mốc trip; nằm giữa 2 mốc là quạt
  kẹt 0rpm dù 68°C. Fix: seed `cooling_device0/cur_state` theo nhiệt hiện
  tại lúc wake.
- CM5 throttle ~80-85°C; full load 4 core chỉ 72.7°C với curve này → an toàn.

## 2. IRQ storm cảm ứng (bug nóng máy + hao pin thật sự)

- Triệu chứng: thread `irq/…-edt-ft5406` ăn ~100% một core 24/7;
  826 ngắt/giây khi KHÔNG chạm; SoC nóng hơn ~15°C; quạt chạy suốt.
- Cảm ứng: FT5406 (driver edt_ft5x06) trên **i2c-gpio bit-bang** (GPIO10/11),
  addr 0x48, chân INT = **GPIO27** (bank RP1: gpio-596, pinctrl-rp1 pin 27).
- Nguyên nhân gốc: overlay khai báo ngắt LEVEL_LOW nhưng **không set bias
  cho GPIO27**. Chân float thấp → ngắt mức giữ vĩnh viễn. i2c sạch
  (crc_errors=0), event chạm là thật — chỉ là chân INT (floating) không bao
  giờ nhả.
- **EDGE_FALLING KHÔNG dùng được**: đổi sang edge là cảm ứng chết hẳn
  (không có cạnh nào). Chân INT cần pull-up.
- **Fix**: bật pull-up nội của RP1 cho GPIO27.
  - cách nhanh: `gpio=27=ip,pu` trong config.txt (firmware set trước overlay)
  - cách chuẩn: pinctrl fragment trong overlay (`bias-pull-up`,
    `function="gpio"`, `pins="gpio27"`) + tham chiếu `pinctrl-0` ở node
    touch. Cả hai đã verify trên máy: idle 0 ngắt/giây, chạm vẫn nhạy.
- Đã gửi upstream: [PR #48](https://github.com/ZitaoTech/HackberryPiCM5/pull/48).
  Repo cộng đồng `CNflysky/hackberrypiq20` cũng dùng EDGE (0x2) *kèm
  pull-up pinctrl* — pull-up mới là phần cốt lõi.
- Lưu ý: `ps` hiện %CPU trung bình từ boot — sau khi fix, thread irq vẫn
  hiện % cao từ trước; đo bằng delta `/proc/PID/stat`.

## 3. Màn hình panel (720×720 DPI)

- Panel: TFT 4" 720×720, DPI RGB666 (`vc4-kms-dpi` + `drm-rp1-dpi`),
  pixel clock 36.832MHz, driver `panel-dpi` generic (không có init sequence).
- **Bug giật**: tắt màn bằng software (`wlopm --off` / `wlr-randr --off`)
  làm pixel clock NGỪNG. Tắt ngắn (≤5s) không sao; tắt lâu (60s+) làm TCON
  trong panel trôi → bật lại giật ~5 phút. PLL relock chuẩn (check dmesg)
  — lỗi nằm ở panel.
- **Nút màn hình chuyên dụng là cách tắt màn ĐÚNG**: nó điều khiển đèn nền
  thuần hardware; pixel clock vẫn chạy → không bao giờ giật.
- Chức năng nút màn (hardware, chip U49): **tap = bật/tắt đèn nền,
  giữ = xoay vòng mức sáng**. Giảm sáng thật = tiết kiệm pin thật.
- Không có đường chỉnh sáng software: không có `/sys/class/backlight`;
  đèn nền do U49 (touch-key controller, nhãn "YX-1024-LED") → R2 10Ω →
  Q3 (MOSFET AO3400A) đóng cắt DISP_LEDK; anode LED ăn ~11.5V từ mạch
  boost MT3540 (U59). Không dây nào nối tới GPIO Pi (đã soi schematic).
  Gamma dimming software (labwc có `zwlr_gamma_control_manager_v1`,
  gammastep chạy được) khả thi nhưng không tiết kiệm điện.
- Chân RESET panel (`DISP_RESET`, pin 6) chỉ nối nút SW3 + pull-up 10k —
  không nối GPIO. Panel dở chứng thì bấm nút reset màn là re-init ngay.
- Mod phần cứng (hàn DISP_RESET → GPIO trống + `reset-gpios` trong overlay)
  sẽ cho phép reset panel bằng software / tắt màn software không giật.

## 4. Đo điện (fuel gauge MAX17048, pin 5000mAh)

- Sysfs: `/sys/class/power_supply/battery/` (capacity %, charge_now µAh —
  bước nhảy ~50mAh, voltage_now µV).
- Thức, màn sáng, đang làm việc: **~1.3-1.4A** (≈3.7h).
- Ngủ giả (services stopped, freq cap, wifi off): **~430mA** → ~10-12h.
  Đây là mức nền SoC+RAM+RP1+regulators của CM5; không có suspend thật thì
  không xuống sâu hơn được.
- NVMe (Samsung MZAL4512HBLU): APST bật sẵn, idle PS3 (60mW) sau 100ms,
  có PS4 (5mW) — KHÔNG phải nguồn hao đáng kể.
- Sạc khi máy thức ăn ~1.3A có thể **hoà vốn hoặc âm** với củ sạc yếu —
  pin từng đứng im 4% suốt 30 phút. Muốn sạc nhanh: tắt máy (fastboot).

## 5. CPU hotplug là cái bẫy

- `echo 0 > .../cpuN/online` chạy được, nhưng bật lại FAIL:
  **`psci: failed to boot CPU (-22)`** — core chết tới khi reboot.
  Firmware RPi không implement PSCI CPU_ON cho flow này.
- Thay thế: governor `powersave` + ghim `scaling_max_freq` = `cpuinfo_min_freq`.
  Core idle WFI ở tần số thấp chỉ tốn hơn core tắt hẳn vài mA.

## 6. Hibernate bất khả thi (kernel stock)

- `/sys/power/state` RỖNG, không có `/sys/power/disk`, không build
  CONFIG_HIBERNATION. `CanHibernate` → "na".
- Kể cả build kernel riêng: resume-from-disk trên Pi là known-broken
  (firmware không nhảy về image được; VideoCore/RP1 không restore state).
  Cộng đồng fail nhiều năm.
- Vì vậy mới có **Fastboot**: lưu state phiên → shutdown sạch → dựng lại
  khi boot (chromium session restore + manifest tmux + relaunch/prefill
  lệnh). Gọi đúng tên: dựng lại, không phải resume.

## 7. Đường đi của nút nguồn

- Input device riêng `pwr_button` (KEY_POWER 116) — tách khỏi keyboard
  controller. KEY_POWER cũng xuất hiện trên event0/2/3 (bàn phím Q20).
- **Đừng** để nhiều handler tranh nút: setup gốc có acpid events,
  `/usr/bin/pwrkey` (desktop), VÀ systemd-logind cùng phản ứng. Daemon
  của mình grab evdev độc quyền và cho tất cả nghỉ hưu.
- Long-press phải bắn **NGAY TẠI ngưỡng khi còn giữ** (không phải lúc thả):
  giữ "quá lâu" sẽ dính cắt nguồn cứng PMIC (đã gặp: máy tắt mà log không
  có event nút nào) — bắn sớm, lưu nhanh.
- polkit: chạy `systemctl stop` bằng user desktop sẽ popup xác thực; cộng
  với freeze process là treo compositor. Giải pháp: daemon chạy root +
  sudoers NOPASSWD cho đúng 2 script entry (không dùng polkit rule rộng).

## 8. Lưu ý freeze pass (deep sleep)

- SIGSTOP diện rộng rất mong manh. Tuyệt đối không freeze: compositor,
  polkit agent (modal grab = treo UI), watchdog/logger (chúng poll qua
  child `sleep` — freeze `sleep` là chúng chết đơ: mất an toàn quạt +
  mất log), AI gateway, dbus, hay process trùng tên daemon nút.
- `ps -o comm` cắt 15 ký tự (`deepsleep-watch`) — phải match prefix.
- Chạy helper qua `systemd-run` (cgroup/scope riêng, sống sót qua freeze,
  `--collect` tự dọn).

## 9. Kiến trúc tmux đa cửa sổ (PiTerm)

- Grouped sessions (`tmux new-session -t main`) chung windows nhưng mỗi
  session giữ "current window" riêng → mỗi cửa sổ terminal = 1 view độc lập.
- **Dedup khi save**: `list-panes -a` liệt panes lặp theo từng thành viên
  group — chỉ serialize 1 session đại diện mỗi group, kèm số view và
  window đang chọn của từng view (`view_windows`).
- Bắt lệnh foreground: `os.tcgetpgrp` trên tty pane cần `O_NOCTTY` + cùng
  user; fallback: duyệt `/proc/<pane_pid>/task/*/children`.
- Allowlist tự chạy lại: chỉ TUI chỉ-đọc (btop/htop/top). `watch` và `ssh`
  bị loại có chủ đích (chạy lệnh tuỳ ý / side effect mạng+auth). Còn lại
  gõ sẵn, không bao giờ tự chạy.
- tmux `display-menu` cần flag `-O` để menu không đóng khi thả chuột.

## 10. File & tham khảo

- `docs/Schematic_HackberryPi_CM5_Q20.pdf` — schematic chính chủ (tải từ
  repo ZitaoTech, thư mục Hardware/). Các net đã map: đèn nền (§3),
  DISP_RESET, đường DPI, i2c-gpio 10/11, INT GPIO27.
- Repo gốc: https://github.com/ZitaoTech/HackberryPiCM5
- Repo cộng đồng (DKMS): https://github.com/CNflysky/hackberrypiq20
- Fork + overlay build sẵn:
  https://github.com/xnohat/HackberryPiCM5/releases/tag/touch-fix-v1

## Việc còn mở / làm tiếp

- Đo lại drain deep sleep sau nâng cấp stop-services (kỳ vọng ~320-350mA;
  lần đo trước bị gián đoạn).
- Thay freeze SIGSTOP diện rộng bằng allowlist service tường minh
  (phần mong manh nhất còn lại).
- Restore PASS check nên verify cả mapping per-view, không chỉ check
  process tồn tại.
- Mod phần cứng tuỳ chọn: DISP_RESET → GPIO để software điều khiển panel.
- Đề xuất ZitaoTech bổ sung tài liệu nút chỉnh sáng (README họ chưa ghi).

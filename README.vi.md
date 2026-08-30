# Pi Deep Sleep + Fastboot + PiTerm

> 🇬🇧 [English (main): README.md](README.md)

Bộ quản lý nguồn + terminal cho **HackberryPi CM5** (máy cầm tay Raspberry Pi
CM5 của [ZitaoTech](https://github.com/ZitaoTech/HackberryPiCM5)) — dùng được
cho các máy Pi khác.

Khởi nguồn từ một câu than — *"quạt ồn vl"* — rồi thành cuộc đại tu nguồn
điện. Xem [docs/FINDINGS.vi.md](docs/FINDINGS.vi.md) để đọc toàn bộ nhật ký
nghiên cứu (curve quạt, IRQ storm cảm ứng, bug panel, đo pin, mổ schematic).

## Tính năng

### 1. Deep Sleep (nhấn ngắn nút nguồn)
Chế độ "ngủ giả" tiết kiệm tối đa cho nền tảng không có suspend thật:
- tắt quạt (kèm watchdog nhiệt qua systemd: >70°C tự trả quạt về auto)
- tắt wifi + bluetooth (`WIFI_OFF=1` mặc định — chỉnh được)
- stop các service nặng (docker, containerd, ollama, waydroid, tailscale,
  snapd, cups, lxc...) và khi dậy **chỉ bật lại đúng những cái đang chạy**
- kill process x86 giả lập qemu
- ghim tần số CPU xuống đáy + governor powersave
  (⚠️ KHÔNG offline core — CM5 dính lỗi PSCI CPU_ON -22, core chết tới reboot)
- freeze process không thiết yếu (SIGSTOP) — giữ AI gateway sống
  (`KEEP_AGENT=1`) để còn điều khiển từ xa nếu giữ wifi
- nhấn lần nữa để dậy: mọi thứ khôi phục, cooling state được seed lại

Đo thực tế: thức ~1.3A; ngủ giả ~430mA (mức nền SoC+RAM+RP1 của CM5 — không
thể thấp hơn nếu không có suspend thật). Pin 5000mAh → ngủ giả ~10-12h.
Qua đêm dài: dùng **Fastboot**.

### 2. Fastboot (giữ nút nguồn 2 giây)
Lưu phiên làm việc → shutdown sạch (gần như không hao pin) → boot lên tự
dựng lại:
- **tmux**: toàn bộ session/window/pane + thư mục; **lệnh đang chạy**:
  TUI chỉ-đọc (btop/htop/top) tự chạy lại, các lệnh khác — kể cả lệnh cuối
  của shell đang rảnh — được **gõ sẵn** trên prompt chờ bạn Enter
- **Chromium**: khôi phục tabs bằng session restore gốc
- **Cửa sổ PiTerm**: mở lại, mỗi cửa sổ về đúng window nó đang xem
- **File manager**: mở lại (ở $HOME — giới hạn wayland, xem FINDINGS)
- Save kiểu transaction (giữ snapshot `.previous`), restore verify xong
  mới xoá marker retry

> Đây là **dựng lại phiên** (relaunch/prefill), không phải hibernate.
> Kernel/firmware Pi không thể suspend-to-disk (FINDINGS §6).

### 3. PiTerm
`foot` (wayland-native, siêu nhẹ) + `tmux`:
- **đa cửa sổ grouped**: mỗi cửa sổ terminal là 1 view độc lập trên kho
  windows chung (mở tab bên này, nhảy sang từ bên kia được)
- status bar: 🔋 pin · 🌡 nhiệt · 🌀 quạt rpm · 📶 wifi · giờ
- **chuột**: kéo = chọn (giữ selection), chuột phải = menu ngữ cảnh
  (Copy / Copy+Paste khi có selection; Paste / Tab mới / Split / Zoom / Đóng)
- theme Tokyo Night, canh cho màn 720×720 (chạy vừa btop)
- session sống xuyên qua Fastboot

### 4. Daemon nút nguồn
Chạy evdev (device `pwr_button`, grab độc quyền — thay thế acpid/logind):
- nhấn ngắn → toggle deep sleep
- **giữ 2s → fastboot bắn NGAY khi còn đang giữ** (không race với lúc thả
  tay, và nhanh hơn ngưỡng cắt nguồn cứng PMIC)
- bỏ qua autorepeat, debounce từng cú nhấn, khoá dispatch
- state machine có test tự động bằng uinput (`test-btn-daemon.py`)

## Cài đặt

```bash
git clone https://github.com/xnohat/raspberrypi-deepsleep
cd raspberrypi-deepsleep
sudo ./install.sh     # cài deps + tất cả, chạy lại nhiều lần vô hại
sudo ./doctor.sh      # kiểm tra sức khoẻ bất cứ lúc nào
```

Gỡ: `sudo ./uninstall.sh` (trả nút nguồn về mặc định).

## Cách dùng

| Thao tác | Kết quả |
|---|---|
| Nút nguồn, nhấn ngắn | bật/tắt deep sleep |
| Nút nguồn, giữ 2s rồi thả | lưu phiên + shutdown |
| Gõ `fastboot` trong terminal | như giữ 2s |
| Nút màn hình, tap | bật/tắt đèn nền (hardware) |
| Nút màn hình, **giữ** | xoay vòng mức sáng (hardware) |
| PiTerm chuột phải | menu ngữ cảnh |

## Cấu trúc repo

Xem README.md (EN). Docs nghiên cứu: `docs/FINDINGS.vi.md`,
schematic: `docs/Schematic_HackberryPi_CM5_Q20.pdf`.

## Đóng góp upstream

Fix IRQ storm cảm ứng (826 ngắt/giây đốt 1 core CPU) đã gửi lên:
[ZitaoTech/HackberryPiCM5#48](https://github.com/ZitaoTech/HackberryPiCM5/pull/48)
kèm overlay build sẵn tại [releases](https://github.com/xnohat/HackberryPiCM5/releases/tag/touch-fix-v1).

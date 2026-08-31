#!/usr/bin/env python3
"""Pi Power — desktop GUI for HackberryPi CM5 power management.

Tabs: Trạng thái (live) / Quạt (auto curve + manual) / Điện (battery
chart + drain stats) / Cấu hình (sleep & button settings).
Privileged writes go through `sudo pipower-apply.sh` (narrow rules).
Tkinter only — no external dependencies. Sized for the 720×720 screen.
"""
import os
import re
import subprocess
import time
import tkinter as tk
from tkinter import ttk, messagebox

APPLY = ["sudo", "-n", "/usr/local/bin/pipower-apply.sh"]
CONFIG_TXT = "/boot/firmware/config.txt"
SLEEP_SH = "/usr/local/bin/powerbtn-deepsleep.sh"
DAEMON_PY = "/usr/local/bin/powerbtn-daemon.py"
BAT_LOG = "/var/log/battery-drain.log"

BG = "#1a1b26"
FG = "#c0caf5"
ACCENT = "#7aa2f7"
GOOD = "#9ece6a"
WARN = "#e0af68"
BAD = "#f7768e"
DIM = "#414868"


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def fan_hwmon():
    base = "/sys/class/hwmon"
    try:
        for d in sorted(os.listdir(base)):
            if read(f"{base}/{d}/name") == "pwmfan":
                return f"{base}/{d}"
    except OSError:
        pass
    return None


def apply_cmd(*args, timeout=40):
    try:
        r = subprocess.run(APPLY + [str(a) for a in args],
                           capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return False, "timeout"


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Pi Power")
        self.geometry("700x660")
        self.configure(bg=BG)

        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", background=BG, foreground=FG, font=("Sans", 11))
        style.configure("TNotebook", background=BG, borderwidth=0, tabmargins=(6, 6, 6, 0))
        style.configure("TNotebook.Tab", padding=(18, 10), font=("Sans", 12, "bold"))
        style.map("TNotebook.Tab",
                  background=[("selected", ACCENT)],
                  foreground=[("selected", "#1a1b26")],
                  padding=[("selected", (18, 10))],
                  expand=[("selected", (0, 0, 0, 0))])
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=FG)
        style.configure("Big.TLabel", font=("Sans", 16, "bold"))
        style.configure("Huge.TLabel", font=("Sans", 26, "bold"), foreground=ACCENT)
        style.configure("TButton", font=("Sans", 12, "bold"), padding=(14, 10))
        style.configure("Danger.TButton", foreground=BAD)
        style.configure("Horizontal.TScale", background=BG)

        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=6, pady=6)
        self.tab_status = ttk.Frame(nb)
        self.tab_fan = ttk.Frame(nb)
        self.tab_power = ttk.Frame(nb)
        self.tab_cfg = ttk.Frame(nb)
        nb.add(self.tab_status, text=" 📊 Trạng thái ")
        nb.add(self.tab_fan, text=" 🌀 Quạt ")
        nb.add(self.tab_power, text=" 🔋 Điện ")
        nb.add(self.tab_cfg, text=" ⚙️ Cấu hình ")
        self.nb = nb

        self._build_status()
        self._build_fan()
        self._build_power()
        self._build_cfg()

        self._tick()
        nb.bind("<<NotebookTabChanged>>", self._on_tab)

    # ── Trạng thái ────────────────────────────────────────────────
    def _build_status(self):
        f = self.tab_status
        self.lbl_temp = ttk.Label(f, style="Huge.TLabel")
        self.lbl_temp.pack(pady=(24, 4))
        self.lbl_fan = ttk.Label(f, style="Big.TLabel")
        self.lbl_fan.pack(pady=4)
        self.lbl_bat = ttk.Label(f, style="Big.TLabel")
        self.lbl_bat.pack(pady=4)
        self.lbl_misc = ttk.Label(f)
        self.lbl_misc.pack(pady=4)

        ttk.Label(f, text="").pack(pady=6)
        row = ttk.Frame(f)
        row.pack(pady=8)
        ttk.Button(row, text="😴 Deep Sleep",
                   command=lambda: self._action("sleep",
                       "Vào deep sleep? (màn đứng hình, bấm nút nguồn để dậy)")
                   ).pack(side="left", padx=8)
        ttk.Button(row, text="💾 Fastboot",
                   command=lambda: self._action("fastboot",
                       "Lưu phiên làm việc và TẮT MÁY?")
                   ).pack(side="left", padx=8)
        ttk.Button(row, text="🔄 Reboot", style="Danger.TButton",
                   command=lambda: self._action("reboot", "Khởi động lại máy?")
                   ).pack(side="left", padx=8)

    def _action(self, do, confirm):
        if messagebox.askyesno("Pi Power", confirm, parent=self):
            ok, out = apply_cmd("action", do)
            if not ok:
                messagebox.showerror("Pi Power", out or "lỗi", parent=self)

    def _tick(self):
        temp = int(read("/sys/class/thermal/thermal_zone0/temp", "0")) / 1000
        fh = fan_hwmon()
        rpm = read(f"{fh}/fan1_input", "?") if fh else "?"
        mode = read(f"{fh}/pwm1_enable", "?") if fh else "?"
        pwm = read(f"{fh}/pwm1", "?") if fh else "?"
        pct = read("/sys/class/power_supply/battery/capacity", "?")
        uah = read("/sys/class/power_supply/battery/charge_now", "0")
        uv = read("/sys/class/power_supply/battery/voltage_now", "0")
        freq = int(read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "0")) // 1000

        col = GOOD if temp < 60 else (WARN if temp < 72 else BAD)
        self.lbl_temp.configure(text=f"🌡 {temp:.1f}°C", foreground=col)
        mode_txt = {"1": "manual", "2": "auto"}.get(mode, mode)
        self.lbl_fan.configure(text=f"🌀 {rpm} rpm  (pwm {pwm} · {mode_txt})")
        self.lbl_bat.configure(
            text=f"🔋 {pct}%  ({int(uah)//1000} mAh · {int(uv)/1e6:.2f} V)")
        self.lbl_misc.configure(text=f"CPU {freq} MHz · {time.strftime('%H:%M:%S')}")
        self.after(2000, self._tick)

    # ── Quạt ──────────────────────────────────────────────────────
    def _build_fan(self):
        f = self.tab_fan
        self.fan_mode = tk.StringVar(value="auto")
        top = ttk.Frame(f)
        top.pack(fill="x", pady=(14, 6), padx=14)
        ttk.Label(top, text="Chế độ:", style="Big.TLabel").pack(side="left")
        for val, txt in (("auto", "🤖 Auto (theo nhiệt)"), ("manual", "✋ Manual")):
            ttk.Radiobutton(top, text=txt, value=val, variable=self.fan_mode,
                            command=self._fan_mode_changed).pack(side="left", padx=10)

        # Auto: slider-based curve editor with live curve canvas
        self.fr_auto = ttk.Frame(f)
        self.fr_auto.pack(fill="both", expand=True, padx=14)
        self.curve_canvas = tk.Canvas(self.fr_auto, bg="#16161e",
                                      highlightthickness=0, height=170)
        self.curve_canvas.pack(fill="x", pady=(8, 6))
        self.curve_vars = []
        self.sel_point = tk.IntVar(value=0)
        selrow = ttk.Frame(self.fr_auto)
        selrow.pack(fill="x", pady=2)
        ttk.Label(selrow, text="Chọn mức:", style="Big.TLabel").pack(side="left")
        for i in range(4):
            ttk.Radiobutton(selrow, text=f"  {i+1}  ", value=i,
                            variable=self.sel_point,
                            command=self._curve_sel_changed).pack(side="left", padx=4)
        for i in range(4):
            tv, sv = tk.IntVar(), tk.IntVar()
            tv.trace_add("write", lambda *_: self._curve_redraw())
            sv.trace_add("write", lambda *_: self._curve_redraw())
            self.curve_vars.append((tv, sv))
        # sliders operate on the SELECTED point
        gr = ttk.Frame(self.fr_auto)
        gr.pack(fill="x", pady=2)
        ttk.Label(gr, text="🌡 Nhiệt:", width=9).grid(row=0, column=0, sticky="w")
        self.sl_temp_val = ttk.Label(gr, width=6, font=("Sans", 13, "bold"),
                                     foreground=WARN)
        self.sl_temp_val.grid(row=0, column=2)
        self.sl_temp = ttk.Scale(gr, from_=35, to=88, orient="horizontal", length=440,
                                 command=lambda v: self._curve_slider("t", v))
        self.sl_temp.grid(row=0, column=1, padx=4)
        ttk.Label(gr, text="🌀 Tốc độ:", width=9).grid(row=1, column=0, sticky="w")
        self.sl_speed_val = ttk.Label(gr, width=6, font=("Sans", 13, "bold"),
                                      foreground=ACCENT)
        self.sl_speed_val.grid(row=1, column=2)
        self.sl_speed = ttk.Scale(gr, from_=0, to=255, orient="horizontal", length=440,
                                  command=lambda v: self._curve_slider("s", v))
        self.sl_speed.grid(row=1, column=1, padx=4)
        rowb = ttk.Frame(self.fr_auto)
        rowb.pack(pady=6)
        ttk.Button(rowb, text="▶ Test mức này 5s",
                   command=self._fan_test_selected).pack(side="left", padx=6)
        ttk.Button(rowb, text="↩ Mặc định",
                   command=self._fan_reset_default).pack(side="left", padx=6)
        ttk.Button(rowb, text="💾 Lưu curve (cần reboot)",
                   command=self._fan_save).pack(side="left", padx=6)
        self.lbl_fan_msg = ttk.Label(self.fr_auto, foreground=GOOD)
        self.lbl_fan_msg.pack(pady=2)
        self._updating_sliders = False

        # Manual: big slider
        self.fr_manual = ttk.Frame(f)
        self.man_pwm = tk.IntVar(value=120)
        self.lbl_man = ttk.Label(self.fr_manual, style="Huge.TLabel")
        self.lbl_man.pack(pady=(30, 6))
        sc = ttk.Scale(self.fr_manual, from_=0, to=255, orient="horizontal",
                       variable=self.man_pwm, length=560,
                       command=lambda _=None: self.lbl_man.configure(
                           text=f"pwm {self.man_pwm.get()}"))
        sc.pack(pady=6)
        rowm = ttk.Frame(self.fr_manual)
        rowm.pack(pady=6)
        for d in (-10, -1, +1, +10):
            ttk.Button(rowm, text=f"{d:+d}", width=5,
                       command=lambda d=d: self._man_nudge(d)).pack(side="left", padx=4)
        ttk.Button(self.fr_manual, text="✋ Áp tốc độ này",
                   command=self._fan_manual_apply).pack(pady=10)
        ttk.Label(self.fr_manual, foreground=WARN,
                  text="Manual giữ tốc độ cố định (bỏ qua nhiệt!).\n"
                       "Chuyển về Auto để trả quạt cho hệ thống.").pack()
        self.lbl_man.configure(text=f"pwm {self.man_pwm.get()}")

        self._fan_load_curve()

    def _spin(self, parent, var, lo, hi, step):
        fr = ttk.Frame(parent)
        fr.pack(side="left", padx=6)
        ttk.Button(fr, text="−", width=3,
                   command=lambda: var.set(max(lo, var.get() - step))).pack(side="left")
        ttk.Label(fr, textvariable=var, width=5, anchor="center",
                  font=("Sans", 13, "bold")).pack(side="left", padx=2)
        ttk.Button(fr, text="+", width=3,
                   command=lambda: var.set(min(hi, var.get() + step))).pack(side="left")

    def _fan_load_curve(self):
        txt = read(CONFIG_TXT)
        for i, (tv, sv) in enumerate(self.curve_vars):
            t = re.search(rf"^dtparam=fan_temp{i}=(\d+)", txt, re.M)
            s = re.search(rf"^dtparam=fan_temp{i}_speed=(\d+)", txt, re.M)
            tv.set(int(t.group(1)) // 1000 if t else [55, 65, 72, 78][i])
            sv.set(int(s.group(1)) if s else [115, 145, 190, 255][i])
        self._curve_sel_changed()

    def _curve_sel_changed(self):
        i = self.sel_point.get()
        tv, sv = self.curve_vars[i]
        self._updating_sliders = True
        self.sl_temp.set(tv.get())
        self.sl_speed.set(sv.get())
        self._updating_sliders = False
        self.sl_temp_val.configure(text=f"{tv.get()}°C")
        self.sl_speed_val.configure(text=str(sv.get()))
        self._curve_redraw()

    def _curve_slider(self, which, val):
        if self._updating_sliders:
            return
        i = self.sel_point.get()
        tv, sv = self.curve_vars[i]
        v = int(float(val))
        if which == "t":
            # clamp between neighbors to keep temps increasing
            lo = self.curve_vars[i - 1][0].get() + 1 if i > 0 else 35
            hi = self.curve_vars[i + 1][0].get() - 1 if i < 3 else 88
            v = max(lo, min(hi, v))
            tv.set(v)
            self.sl_temp_val.configure(text=f"{v}°C")
        else:
            sv.set(v)
            self.sl_speed_val.configure(text=str(v))

    def _curve_redraw(self):
        c = getattr(self, "curve_canvas", None)
        if not c:
            return
        c.delete("all")
        w = c.winfo_width() or 640
        h = c.winfo_height() or 170
        pad_l, pad_r, pad_t, pad_b = 40, 14, 12, 24
        tmin, tmax = 35, 88

        def X(t):
            return pad_l + (w - pad_l - pad_r) * (t - tmin) / (tmax - tmin)

        def Y(s):
            return h - pad_b - (h - pad_t - pad_b) * s / 255

        # grid
        for s in (0, 128, 255):
            c.create_line(pad_l, Y(s), w - pad_r, Y(s), fill=DIM, dash=(2, 4))
            c.create_text(pad_l - 5, Y(s), text=str(s), anchor="e",
                          fill=DIM, font=("Sans", 8))
        for t in (40, 50, 60, 70, 80):
            c.create_line(X(t), pad_t, X(t), h - pad_b, fill=DIM, dash=(2, 4))
            c.create_text(X(t), h - pad_b + 10, text=f"{t}°",
                          fill=DIM, font=("Sans", 8))
        # current temp marker
        now_t = int(read("/sys/class/thermal/thermal_zone0/temp", "0")) / 1000
        if tmin < now_t < tmax:
            c.create_line(X(now_t), pad_t, X(now_t), h - pad_b,
                          fill=BAD, width=1)
            c.create_text(X(now_t), pad_t - 2, text=f"{now_t:.0f}°",
                          fill=BAD, anchor="s", font=("Sans", 8, "bold"))
        # step curve: fan off until point 1, then steps
        pts = [(tv.get(), sv.get()) for tv, sv in self.curve_vars]
        path = [(tmin, 0), (pts[0][0], 0)]
        for i, (t, s) in enumerate(pts):
            path.append((t, s))
            nxt = pts[i + 1][0] if i < 3 else tmax
            path.append((nxt, s))
        for a, b in zip(path, path[1:]):
            c.create_line(X(a[0]), Y(a[1]), X(b[0]), Y(b[1]),
                          fill=ACCENT, width=3)
        # point handles (selected = bigger, warn color)
        sel = self.sel_point.get()
        for i, (t, s) in enumerate(pts):
            r = 8 if i == sel else 5
            col = WARN if i == sel else GOOD
            c.create_oval(X(t) - r, Y(s) - r, X(t) + r, Y(s) + r,
                          fill=col, outline="")
            c.create_text(X(t), Y(s) - r - 8, text=str(i + 1),
                          fill=col, font=("Sans", 9, "bold"))

    def _fan_reset_default(self):
        for (tv, sv), (t, spd) in zip(self.curve_vars,
                                      [(55, 115), (65, 145), (72, 190), (78, 255)]):
            tv.set(t)
            sv.set(spd)
        self._curve_sel_changed()
        self.lbl_fan_msg.configure(text="Đã nạp curve mặc định (chưa lưu — bấm Lưu nếu ưng)",
                                   foreground=WARN)

    def _fan_test_selected(self):
        i = self.sel_point.get()
        pwm = self.curve_vars[i][1].get()
        self.lbl_fan_msg.configure(text=f"Đang quay pwm {pwm} trong 5s...",
                                   foreground=WARN)
        self.update()
        ok, out = apply_cmd("fan-test", pwm, 5)
        self.lbl_fan_msg.configure(text=out, foreground=GOOD if ok else BAD)

    def _fan_mode_changed(self):
        if self.fan_mode.get() == "manual":
            self.fr_auto.pack_forget()
            self.fr_manual.pack(fill="both", expand=True, padx=14)
        else:
            self.fr_manual.pack_forget()
            self.fr_auto.pack(fill="both", expand=True, padx=14)
            ok, out = apply_cmd("fan-auto")
            self.lbl_fan_msg.configure(
                text="Đã trả quạt về auto" if ok else out, 
                foreground=GOOD if ok else BAD)

    def _man_nudge(self, d):
        self.man_pwm.set(max(0, min(255, self.man_pwm.get() + d)))
        self.lbl_man.configure(text=f"pwm {self.man_pwm.get()}")

    def _fan_manual_apply(self):
        ok, out = apply_cmd("fan-manual", self.man_pwm.get())
        messagebox.showinfo("Pi Power", out, parent=self) if not ok else None
        self.lbl_man.configure(text=f"pwm {self.man_pwm.get()} ✓" if ok else "lỗi")

    def _fan_save(self):
        pts = [(tv.get(), sv.get()) for tv, sv in self.curve_vars]
        if any(pts[i][0] >= pts[i+1][0] for i in range(3)):
            self.lbl_fan_msg.configure(text="Nhiệt độ phải tăng dần!", foreground=BAD)
            return
        if not messagebox.askyesno("Pi Power",
                "Ghi curve mới vào config.txt?\n(backup tự động, cần reboot để ăn)",
                parent=self):
            return
        args = []
        for t, s in pts:
            args += [t * 1000, s, 5000]
        ok, out = apply_cmd("fan-save", *args)
        self.lbl_fan_msg.configure(text=out, foreground=GOOD if ok else BAD)

    # ── Điện ──────────────────────────────────────────────────────
    def _build_power(self):
        f = self.tab_power
        top = ttk.Frame(f)
        top.pack(fill="x", padx=10, pady=(10, 2))
        ttk.Label(top, text="Khung giờ:", style="Big.TLabel").pack(side="left")
        self.pw_hours = tk.IntVar(value=24)
        for h in (6, 24, 72):
            ttk.Radiobutton(top, text=f"{h}h", value=h, variable=self.pw_hours,
                            command=self._power_refresh).pack(side="left", padx=6)
        ttk.Button(top, text="⟳", width=3, command=self._power_refresh).pack(side="right")
        self.canvas = tk.Canvas(f, bg="#16161e", highlightthickness=0, height=300)
        self.canvas.pack(fill="both", expand=True, padx=10, pady=6)
        self.lbl_drain = ttk.Label(f, style="Big.TLabel", justify="center")
        self.lbl_drain.pack(pady=(0, 10))

    def _power_refresh(self):
        hours = self.pw_hours.get()
        cutoff = time.time() - hours * 3600
        series = []
        try:
            with open(BAT_LOG) as fh:
                for line in fh:
                    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) capacity=(\d+) "
                                 r"charge_uah=(\d+) mv=(\d+) state=(\w+)", line)
                    if not m:
                        continue
                    ts = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
                    if ts >= cutoff:
                        series.append((ts, int(m.group(2)), int(m.group(3)), m.group(5)))
        except OSError:
            pass
        c = self.canvas
        c.delete("all")
        w = c.winfo_width() or 660
        h = c.winfo_height() or 300
        if len(series) < 2:
            c.create_text(w // 2, h // 2, fill=DIM, font=("Sans", 13),
                          text="Chưa đủ dữ liệu — battery logger đang thu thập...")
            self.lbl_drain.configure(text="")
            return
        t0, t1 = series[0][0], series[-1][0]
        span = max(t1 - t0, 1)
        pad = 34
        # grid + axis
        for pct in (0, 25, 50, 75, 100):
            y = h - pad - (h - 2 * pad) * pct / 100
            c.create_line(pad, y, w - 8, y, fill=DIM, dash=(2, 4))
            c.create_text(pad - 4, y, text=f"{pct}", anchor="e", fill=DIM, font=("Sans", 8))
        # line segments colored by state
        prev = None
        for ts, pct, uah, state in series:
            x = pad + (w - pad - 8) * (ts - t0) / span
            y = h - pad - (h - 2 * pad) * pct / 100
            if prev:
                col = ACCENT if state == "AWAKE" else GOOD
                c.create_line(prev[0], prev[1], x, y, fill=col, width=3)
            prev = (x, y)
        c.create_text(pad + 6, 12, anchor="w", fill=ACCENT, font=("Sans", 10),
                      text="── thức")
        c.create_text(pad + 90, 12, anchor="w", fill=GOOD, font=("Sans", 10),
                      text="── sleep")
        # drain stats
        stats = {}
        for (ta, _, ua, sa), (tb, _, ub, _) in zip(series, series[1:]):
            d_uah = ua - ub
            d_h = (tb - ta) / 3600
            if d_h <= 0 or abs(d_uah) > 500000:
                continue
            v = stats.setdefault(sa, [0, 0.0])
            v[0] += d_uah
            v[1] += d_h
        parts = []
        cap = 5000
        for st, (uah_, h_) in sorted(stats.items()):
            if h_ > 0.05:
                ma = uah_ / 1000 / h_
                if ma > 10:
                    est = cap / ma
                    parts.append(f"{'Thức' if st=='AWAKE' else 'Sleep'}: "
                                 f"~{ma:.0f} mA (pin đầy ≈ {est:.1f}h)")
                elif ma < -10:
                    parts.append(f"{'Thức' if st=='AWAKE' else 'Sleep'}: "
                                 f"sạc +{-ma:.0f} mA")
        self.lbl_drain.configure(text="\n".join(parts) or "Chưa đủ dữ liệu xả pin")

    # ── Cấu hình ──────────────────────────────────────────────────
    def _build_cfg(self):
        f = self.tab_cfg
        self.cfg_vars = {}
        rows = [
            ("WIFI_OFF", "Tắt wifi khi sleep (trâu pin, mất remote)", "bool"),
            ("FAN_OFF", "Tắt quạt khi sleep (watchdog vẫn gác)", "bool"),
            ("KEEP_AGENT", "Giữ AI gateway sống khi sleep", "bool"),
            ("PANEL_OFF", "Tắt scanout màn hình khi sleep (−0.6W, có thể giật màn sau khi dậy — tắt/bật màn bằng nút để hết)", "bool"),
            ("WATCHDOG_TEMP", "Ngưỡng bật lại quạt khi sleep (°C)", "temp"),
            ("LONG_MS", "Giữ nút bao lâu để Fastboot (giây)", "sec"),
        ]
        box = ttk.Frame(f)
        box.pack(fill="x", padx=16, pady=14)
        for key, label, kind in rows:
            row = ttk.Frame(box)
            row.pack(fill="x", pady=7)
            ttk.Label(row, text=label, wraplength=430,
                      justify="left").pack(side="left")
            if kind == "bool":
                v = tk.IntVar()
                ttk.Checkbutton(row, variable=v).pack(side="right")
            else:
                v = tk.DoubleVar() if kind == "sec" else tk.IntVar()
                fr = ttk.Frame(row)
                fr.pack(side="right")
                if kind == "temp":
                    ttk.Button(fr, text="−", width=3,
                               command=lambda v=v: v.set(max(50, v.get() - 1))).pack(side="left")
                    ttk.Label(fr, textvariable=v, width=4, anchor="center",
                              font=("Sans", 13, "bold")).pack(side="left")
                    ttk.Button(fr, text="+", width=3,
                               command=lambda v=v: v.set(min(90, v.get() + 1))).pack(side="left")
                else:
                    ttk.Button(fr, text="−", width=3,
                               command=lambda v=v: v.set(max(0.5, round(v.get() - 0.5, 1)))).pack(side="left")
                    ttk.Label(fr, textvariable=v, width=4, anchor="center",
                              font=("Sans", 13, "bold")).pack(side="left")
                    ttk.Button(fr, text="+", width=3,
                               command=lambda v=v: v.set(min(10, round(v.get() + 0.5, 1)))).pack(side="left")
            self.cfg_vars[key] = v
        ttk.Button(f, text="💾 Lưu cấu hình (ăn ngay)",
                   command=self._cfg_save).pack(pady=10)
        self.lbl_cfg_msg = ttk.Label(f, foreground=GOOD)
        self.lbl_cfg_msg.pack()
        self._cfg_load()

    def _cfg_load(self):
        sl = read(SLEEP_SH)
        dm = read(DAEMON_PY)
        def var(text, key):
            m = re.search(rf"^{key}=(\S+)", text, re.M)
            return m.group(1) if m else None
        for k in ("WIFI_OFF", "FAN_OFF", "KEEP_AGENT", "PANEL_OFF"):
            v = var(sl, k)
            if v is not None:
                self.cfg_vars[k].set(int(v))
        wt = var(sl, "WATCHDOG_TEMP")
        if wt:
            self.cfg_vars["WATCHDOG_TEMP"].set(int(wt) // 1000)
        lm = re.search(r"^LONG_MS = (\d+)", dm, re.M)
        if lm:
            self.cfg_vars["LONG_MS"].set(int(lm.group(1)) / 1000)

    def _cfg_save(self):
        args = []
        for k in ("WIFI_OFF", "FAN_OFF", "KEEP_AGENT", "PANEL_OFF"):
            args += [k, int(self.cfg_vars[k].get())]
        args += ["WATCHDOG_TEMP", int(self.cfg_vars["WATCHDOG_TEMP"].get()) * 1000]
        args += ["LONG_MS", int(float(self.cfg_vars["LONG_MS"].get()) * 1000)]
        ok, out = apply_cmd("config-set", *args)
        self.lbl_cfg_msg.configure(text=out if out else ("đã lưu" if ok else "lỗi"),
                                   foreground=GOOD if ok else BAD)

    def _on_tab(self, _):
        if self.nb.index("current") == 2:
            self.after(50, self._power_refresh)


if __name__ == "__main__":
    App().mainloop()

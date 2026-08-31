#!/usr/bin/env python3
# Regression test: fan curve chart click/drag interaction (needs a Wayland/X session).
# Run: DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 python3 tests/test-fan-chart-interaction.py
# Verifies: click selects nearest point, drag sets speed (clamped 0..255) + temp
# (kept strictly increasing between neighbours), sliders/labels stay in sync.
import importlib.util
spec=importlib.util.spec_from_file_location('g','/usr/local/bin/pipower-gui.py')
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
app=g.App(); app.nb.select(1); app.update(); app.update_idletasks()
c=app.curve_canvas; c.update_idletasks()
res=[]

# TEST A: click near point 3 (index 2) -> sel_point becomes 2
x3=app._cv_x(app.curve_vars[2][0].get()); 
c.event_generate('<Button-1>', x=int(x3), y=80); app.update()
res.append(("click selects nearest point", app.sel_point.get()==2))

# TEST B: drag selected point to a new y (speed) and x (temp), check clamp + vars update
w=c.winfo_width() or 640; h=c.winfo_height() or 170
c.event_generate('<B1-Motion>', x=int(x3), y=20); app.update()  # near top = high speed
sp=app.curve_vars[2][1].get()
res.append(("drag raises speed toward 255", sp>200))
res.append(("speed within 0..255", 0<=sp<=255))

# TEST C: temp stays strictly increasing (drag point2 far left, should clamp above point1)
c.event_generate('<B1-Motion>', x=int(app._cv_x(30)), y=80); app.update()
t1=app.curve_vars[1][0].get(); t2=app.curve_vars[2][0].get(); t3=app.curve_vars[3][0].get()
res.append(("temps increasing after over-drag left", t1<t2<t3))

# TEST D: slider + label synced with vars after drag
res.append(("temp label matches var", app.sl_temp_val.cget('text')==f"{app.curve_vars[2][0].get()}°C"))

# TEST E: click updates radio selection var for point 1 and 4
for idx in (0,3):
    xi=app._cv_x(app.curve_vars[idx][0].get())
    c.event_generate('<Button-1>', x=int(xi), y=90); app.update()
    res.append((f"click selects point {idx+1}", app.sel_point.get()==idx))

app.destroy()
ok=all(v for _,v in res)
for name,v in res: print(("  PASS" if v else "  FAIL"), name)
print("ALL PASS" if ok else "SOME FAILED")

"""Renders the sleek composer redesign (owner request B, 2026-11-07) for approval: Mac at 1440 x 900 and 1280 x 800 and the
phone at 390, in Soft Tactile (C) and Camera Body (B). Writes plans/design-direction/sleek/after-*.png.

    PHOSPHOR=<@phosphor-icons/core package> python3 design/direction/sleek.py

What changes from the shipped composer (plans/design-direction.md §10):
- One tool switch: the sidebar has a single "Suite" item; tools change only from the title ("Shot ▾").
- Presets is one quiet button that opens a popover (the strip of stills is gone).
- No "Setup" / "Inputs" headings: the rows and the slots group by space.
- Rows 32 pt with 13 pt text and no icons; the inputs one row of 44 pt tiles with 11 pt captions; a slim prompt bar.
- The picture is capped at 58 % of the window height; no sample stills, an empty canvas before the first take.
- Three type sizes on the page (17 / 13 / 11), no filled panels except the prompt bar.
"""
import json, os, subprocess, tempfile
from pathlib import Path

import render as R

OUT = R.OUT / "sleek"
THEMES = dict(R.THEMES)
THEMES["c"] = dict(name="Soft Tactile", canvas="#E7E2D9", raised="#F3F0EA", field="#EAE5DC", ink="#23262A", ink2="#5E5C57", hair="#D9D3C8",
                   accent="#4E6B45", action="#4E6B45", onaction="#FFFFFF", scrim="rgba(35,38,42,.55)", display="Outfit", text="Outfit",
                   rc=24, rk=16, rp=12, float="0 12px 32px rgba(35,38,42,.14)", outline="none")
R.FONT_FILES["Outfit"] = [("outfit_400", 400), ("outfit_500", 500), ("outfit_600", 600)]

ROWS = [("Camera", "35 mm film, anamorphic"), ("Light", "Window"), ("Look", "Golden warmth"), ("Style", "UGC, calm"),
        ("References", "None"), ("Settings", "8 s · 16:9, 1 take")]
SLOTS = [("Character", "angles/mcu.webp"), ("Start frame", None), ("End frame", None)]
PROMPT = 'walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile.'

def css(t):
    f = t["text"]
    return f"""
.s-title{{font:600 17px/22px "{f}";letter-spacing:-.01em}} .s-body{{font:400 13px/18px "{f}"}} .s-cap{{font:400 11px/14px "{f}";color:var(--ink2)}}
.s-row{{height:32px;display:flex;align-items:center;gap:12px;border-radius:calc(var(--rp) / 1.5);padding:0 8px;margin:0 -8px}}
.s-row .k{{color:var(--ink2);width:84px;flex:none}} .s-row .v{{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:right}}
.s-quiet{{height:28px;padding:0 10px;display:flex;align-items:center;gap:6px;color:var(--ink2);border-radius:var(--rp);font:500 13px/18px "{f}"}}
.s-go{{background:var(--action);color:var(--onaction);border-radius:calc(var(--rk) * .75);height:36px;padding:0 18px;display:flex;align-items:center;font:600 13px/18px "{f}";white-space:nowrap}}
.s-tile{{width:44px;height:44px;border-radius:calc(var(--rk) * .75);overflow:hidden;flex:none}}
.s-tile img{{width:100%;height:100%;object-fit:cover;display:block}}
.s-empty{{border:1px dashed color-mix(in srgb,var(--ink2) 55%,transparent);display:grid;place-items:center;color:var(--ink2)}}
.s-chip{{background:var(--field);border-radius:6px;padding:0 5px;font-weight:500}}
"""

def page(body, t, w, h):
    return (f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{css(t)}</style>'
            f'<body style="width:{w}px;height:{h}px;overflow:hidden;position:relative">{body}</body>')

def chip(txt, sig): return f'<span class="s-chip"><span style="color:var(--accent)">{sig}</span>{txt}</span>'

def canvas(aspect_w, aspect_h, max_w, max_h, tag):
    """The empty canvas: the shape outlined on the surface tone, centred, with a one-line hint."""
    scale = min(max_w / aspect_w, max_h / aspect_h)
    w, h = aspect_w * scale, aspect_h * scale
    return (f'<div style="width:{max_w}px;height:{h:.0f}px;display:grid;place-items:center">'
            f'<div style="width:{w:.0f}px;height:{h:.0f}px;background:var(--raised);border:1px solid var(--hair);border-radius:var(--rk);'
            f'display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px">'
            f'<div class="s-body" style="color:var(--ink2)">Your shot appears here</div><div class="s-cap">{tag}</div></div></div>')

def tiles():
    cells = []
    for name, src in SLOTS:
        box = (f'<div class="s-tile"><img src="{R.img(R.PV / src)}"></div>' if src else
               f'<div class="s-tile s-empty">{R.icon("plus", 16)}</div>')
        cells.append(f'<div style="width:64px"><div>{box}</div><div class="s-cap" style="margin-top:6px;color:{"var(--ink)" if src else "var(--ink2)"}">{name}</div></div>')
    return f'<div class="row" style="gap:8px;align-items:flex-start">{"".join(cells)}</div>'

def rows():
    return "".join(f'<div class="s-row s-body"><div class="k">{k}</div><div class="v">{v}</div>{R.icon("caret-right", 12, "var(--ink2)")}</div>' for k, v in ROWS)

def presets_popover(t):
    """Text only: a name and what it sets up (no stills, owner fix A1)."""
    items = [("Café walk-in", "Window light, slow dolly in"), ("Product close-up", "Macro lens, soft top light"),
             ("Street interview", "Handheld, daylight, 9:16"), ("Golden hour portrait", "85 mm, warm backlight")]
    cells = "".join(f'<div style="padding:7px 8px;margin:0 -8px;border-radius:calc(var(--rp) / 1.5)"><div class="s-body">{n}</div><div class="s-cap">{d}</div></div>'
                    for n, d in items)
    return (f'<div style="position:absolute;top:40px;right:0;width:260px;background:var(--raised);border:1px solid var(--hair);border-radius:calc(var(--rk) * .75);'
            f'box-shadow:{t["float"] if t["float"] != "none" else "none"};padding:6px 16px;z-index:5">{cells}</div>')

def mac(t, w, h, popover=False):
    side_w = 208
    nav = [("house", "Home"), ("user", "Models"), ("video-camera", "Suite"), ("squares-four", "Library"), ("stack", "Queue"), ("film-strip", "Edit")]
    side = "".join(f'<div class="row s-body" style="gap:10px;height:30px;padding:0 10px;border-radius:calc(var(--rp) / 1.5);'
                   f'{"background:var(--field);color:var(--ink);font-weight:500" if l == "Suite" else "color:var(--ink2)"}">{R.icon(i, 16)}{l}</div>' for i, l in nav)
    pad_x, pad_top, pad_bot = 32, 20, 24
    rail = 288
    main_w = w - side_w - 2 * pad_x
    pic_w = main_w - rail - 32
    pic_h = round(h * 0.58)
    tag = "16:9 · 8 s"
    bar = (f'<div style="background:var(--raised);border-radius:var(--rk);padding:12px 12px 10px 16px">'
           f'<div class="s-body" style="font-size:13px;line-height:20px">{chip("Demo", "@")} {PROMPT} {chip("Dolly in", "#")}</div>'
           f'<div class="row" style="gap:4px;margin-top:8px;margin-left:-10px"><div class="s-quiet">HD {R.icon("caret-down", 12)}</div>'
           f'<div class="s-quiet">{R.icon("speaker-high", 16)}</div><div class="s-quiet">{R.icon("microphone-slash", 16)}</div>'
           f'<div class="grow"></div><div class="s-go">Generate · $0.64</div></div></div>')
    return f"""
<div class="row" style="height:100%;align-items:stretch">
 <div style="width:{side_w}px;flex:none;padding:20px 14px;border-right:1px solid var(--hair);display:flex;flex-direction:column;gap:2px">
   <div class="s-title" style="padding:0 10px 18px">MUSE</div>{side}
   <div class="grow"></div><div class="s-cap" style="padding:0 10px">$4.17 left</div></div>
 <div class="grow" style="padding:{pad_top}px {pad_x}px {pad_bot}px;display:flex;flex-direction:column">
   <div class="row" style="height:32px;position:relative">
     <div class="row s-title" style="gap:6px">Shot {R.icon("caret-down", 14, "var(--ink2)")}</div><div class="grow"></div>
     <div class="s-quiet" style="{"background:var(--field);color:var(--ink)" if popover else ""}">Presets</div>
     {presets_popover(t) if popover else ""}</div>
   <div class="row" style="gap:32px;align-items:flex-start;margin-top:20px">
     {canvas(16, 9, pic_w, pic_h, tag)}
     <div style="width:{rail}px;flex:none;padding-top:4px">{rows()}<div style="height:24px"></div>{tiles()}</div>
   </div>
   <div style="height:20px"></div>
   {bar}
 </div></div>"""

def phone(t):
    rows_html = "".join(f'<div class="row s-body" style="height:48px;gap:12px;font-size:14px"><div style="color:var(--ink2);width:96px">{k}</div>'
                        f'<div class="grow" style="text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{v}</div>{R.icon("caret-right", 14, "var(--ink2)")}</div>'
                        for k, v in ROWS[:4] + [ROWS[5]])
    return f"""
<div class="row" style="height:52px;padding:0 4px">
  <div class="iconbtn">{R.icon("caret-left", 22)}</div><div class="grow"></div>
  <div class="row s-title" style="gap:6px">Shot {R.icon("caret-down", 14, "var(--ink2)")}</div><div class="grow"></div>
  <div class="s-quiet" style="height:44px;font-size:14px">Presets</div></div>
<div style="padding:4px 20px 0">{canvas(16, 9, 350, 210, "16:9 · 8 s")}</div>
<div style="padding:16px 20px 0">
  <div style="background:var(--raised);border-radius:var(--rk);padding:12px 14px;font-size:14px;line-height:21px">
    {chip("Demo", "@")} {PROMPT} {chip("Dolly in", "#")}</div>
  <div style="margin-top:16px">{tiles()}</div>
  <div style="margin-top:8px">{rows_html}</div>
</div>
<div class="row" style="position:absolute;left:0;right:0;bottom:0;padding:12px 20px 24px;background:var(--canvas);gap:4px">
  <div class="s-quiet" style="height:44px;font-size:14px;margin-left:-10px">HD {R.icon("caret-down", 12)}</div>
  <div class="s-quiet" style="height:44px">{R.icon("speaker-high", 18)}</div>
  <div class="grow"></div><div class="s-go" style="height:44px;padding:0 22px;font-size:14px">Generate · $0.64</div></div>"""

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = []
    for k in ("c", "b"):
        jobs += [(f"after-mac-1440-{k}", lambda t: mac(t, 1440, 900), k, 1440, 900),
                 (f"after-mac-1280-{k}", lambda t: mac(t, 1280, 800), k, 1280, 800),
                 (f"after-phone-390-{k}", phone, k, 390, 844)]
    jobs.append(("after-mac-1280-c-presets", lambda t: mac(t, 1280, 800, popover=True), "c", 1280, 800))
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for name, fn, k, w, h in jobs:
            f = Path(tmp) / f"{name}.html"; f.write_text(page(fn(THEMES[k]), THEMES[k], w, h))
            spec.append({"html": f.as_uri(), "png": str(OUT / f"{name}.png"), "w": w, "h": h})
        js = Path(tmp) / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(400); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(spec)], check=True, env={**os.environ, "NODE_PATH": root})

if __name__ == "__main__":
    main()

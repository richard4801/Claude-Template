"""Renders the design-direction key screens (plans/design-direction.md §9) for the owner's approval.

Home, the composer and the Camera → Setup picker, rebuilt with the direction's tokens (colour roles, type scale, spacing,
radii, Phosphor Regular icons), in Camera Body (B) and Editorial (A); plus the composer on the Mac at 1280 px.
Imagery is the real studio material: the Blender preview stills (design/previews) and the hardware renders.

    python3 design/direction/render.py          # writes plans/design-direction/*.png
Needs: Playwright with its Chromium (preinstalled in the cloud sessions), the Phosphor core package unpacked at $PHOSPHOR
(default: design/icons/phosphor, see design/icons/README.md).
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans" / "design-direction"
FONTS = REPO / "android/app/src/main/res/font"
PHOS = Path(os.environ.get("PHOSPHOR", REPO / "design/icons/phosphor")) / "assets/regular"  # @phosphor-icons/core 2.1.1 (npm pack)
PV, HW = REPO / "design/previews", REPO / "design/hardware"

THEMES = {
    "b": dict(name="Camera Body", canvas="#0D0E0F", raised="#17191B", field="#212427", ink="#ECEAE5", ink2="#A9A6A0", hair="#2C3033",
              accent="#F2A93B", action="#F2A93B", onaction="#1A1205", scrim="rgba(0,0,0,.55)", display="Barlow Condensed", text="Barlow",
              rc=14, rk=10, rp=8, float="none", outline="none"),
    "a": dict(name="Editorial", canvas="#EFEBE3", raised="#F8F5EF", field="#E7E1D6", ink="#141210", ink2="#67605A", hair="#CFC7BA",
              accent="#B5121B", action="#141210", onaction="#F8F5EF", scrim="rgba(20,18,16,.55)", display="Instrument Serif", text="Archivo",
              rc=4, rk=2, rp=2, float="0 12px 32px rgba(20,18,16,.14)", outline="none"),
}
FONT_FILES = {"Barlow Condensed": [("barlow_condensed_600", 600), ("barlow_condensed_700", 700)], "Barlow": [("barlow_400", 400), ("barlow_500", 500), ("barlow_600", 600)],
              "Instrument Serif": [("instrument_serif_400", 400)], "Archivo": [("archivo_400", 400), ("archivo_500", 500), ("archivo_600", 600)]}

def icon(name, size=20, color="currentColor"):
    svg = (PHOS / f"{name}.svg").read_text()
    return svg.replace("<svg ", f'<svg width="{size}" height="{size}" style="color:{color};flex:none" aria-hidden="true" ', 1)

def img(p): return Path(p).as_uri()

def css(t, mac=False):
    faces = "".join(f'@font-face{{font-family:"{fam}";src:url("{(FONTS / (f + ".ttf")).as_uri()}");font-weight:{w}}}'
                    for fam in (t["display"], t["text"]) for f, w in FONT_FILES[fam])
    return faces + f"""
:root{{--canvas:{t['canvas']};--raised:{t['raised']};--field:{t['field']};--ink:{t['ink']};--ink2:{t['ink2']};--hair:{t['hair']};
--accent:{t['accent']};--action:{t['action']};--onaction:{t['onaction']};--scrim:{t['scrim']};--rc:{t['rc']}px;--rk:{t['rk']}px;--rp:{t['rp']}px}}
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:var(--canvas);color:var(--ink);font:400 15px/21px "{t['text']}",sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}}
.display{{font:{'400 32px/34px' if t['display']=='Instrument Serif' else '700 30px/32px'} "{t['display']}",serif}}
.title{{font:600 20px/26px "{t['text']}"}} .heading{{font:600 16px/22px "{t['text']}"}} .label{{font:500 14px/18px "{t['text']}"}}
.caption{{font:400 13px/18px "{t['text']}";color:var(--ink2)}} .micro{{font:500 11px/14px "{t['text']}"}}
.row{{display:flex;align-items:center}} .gap2{{gap:8px}} .gap3{{gap:12px}} .gap4{{gap:16px}} .grow{{flex:1;min-width:0}}
.media{{border-radius:var(--rc);overflow:hidden;background:var(--field);position:relative}} .media img{{width:100%;height:100%;object-fit:cover;display:block}}
.action{{background:var(--action);color:var(--onaction);border-radius:var(--rk);height:48px;display:flex;align-items:center;justify-content:center;gap:8px;font:600 15px/18px "{t['text']}"}}
.textbtn{{color:var(--ink);font:500 14px/18px "{t['text']}";display:flex;align-items:center;gap:6px;height:44px}}
.iconbtn{{width:44px;height:44px;display:grid;place-items:center;color:var(--ink)}}
.scrimtag{{position:absolute;left:8px;bottom:8px;background:var(--scrim);color:#fff;border-radius:var(--rp);padding:3px 7px;font:500 11px/14px "{t['text']}"}}
.float{{box-shadow:{t['float']}}}
"""

def page(body, t, w, h): return f'<!doctype html><meta charset="utf-8"><style>{css(t)}</style><body style="width:{w}px;height:{h}px;overflow:hidden">{body}</body>'

# ---------------------------------------------------------------- Home (phone)
def home(t):
    tabs = [("house", "Home", True), ("video-camera", "Suite", False), ("squares-four", "Library", False), ("stack", "Queue", False), ("user", "You", False)]
    takes = [("genres/drama.jpg", "8 s"), ("eras/1970s.jpg", "10 s"), ("lighting/contre_jour.jpg", "Photo"), ("genres/music_video.jpg", "6 s")]
    models = [("angles/full.jpg", "Demo model", "2 outfits"), ("angles/cowboy.jpg", "Demo model B", "Sheet in progress")]
    return f"""
<div style="padding:8px 16px 0" class="row"><div class="grow label" style="font-family:'{t['display']}';font-size:18px;letter-spacing:.02em">MUSE</div>
  <div class="label" style="color:var(--ink2)">$4.17</div></div>
<div style="padding:16px 16px 0"><div class="display">Models</div></div>
<div style="padding:16px 16px 0">
  <div class="media" style="height:300px"><img src="{img(PV/'angles/ms.jpg')}"></div>
  <div class="row" style="margin-top:12px"><div class="grow"><div class="heading">Demo model</div><div class="caption">2 outfits, identity locked</div></div>
    <div class="textbtn">{icon('caret-right',20)}</div></div>
  <div class="row gap2" style="margin-top:12px"><div class="action grow">{icon('video-camera',20,'var(--onaction)')}New shot</div>
    <div class="action" style="background:var(--field);color:var(--ink);width:52px">{icon('camera',20)}</div></div>
</div>
<div style="padding:24px 16px 0" class="row"><div class="heading grow">Recent takes</div><div class="label" style="color:var(--ink2)">Library</div></div>
<div class="row gap2" style="padding:12px 16px 0;overflow:hidden">
  {''.join(f'<div class="media" style="width:104px;height:140px;flex:none"><img src="{img(PV/p)}"><div class="scrimtag">{d}</div></div>' for p, d in takes)}
</div>
<div style="padding:24px 16px 0" class="row"><div class="heading grow">All models</div><div class="iconbtn" style="width:auto">{icon('plus',20)}</div></div>
<div class="row gap3" style="padding:8px 16px 0">
  {''.join(f'<div class="grow"><div class="media" style="height:150px"><img src="{img(PV/p)}"></div><div class="label" style="margin-top:8px">{n}</div><div class="caption">{c}</div></div>' for p, n, c in models)}
</div>
<div style="position:absolute;left:0;right:0;bottom:0;height:72px;background:var(--canvas);border-top:1px solid var(--hair)" class="row">
  {''.join(f'<div class="grow" style="display:flex;flex-direction:column;align-items:center;gap:4px;color:{"var(--ink)" if on else "var(--ink2)"};position:relative">{"<div style=&quot;position:absolute;top:-12px;width:24px;height:2px;background:var(--accent)&quot;></div>" if on else ""}{icon(i,24)}<div class="micro">{l}</div></div>' for i, l, on in tabs)}
</div>"""

# ---------------------------------------------------------------- Composer (phone)
def chip(txt, sig):
    return f'<span style="background:var(--field);border-radius:var(--rp);padding:1px 6px;font-weight:500"><span style="color:var(--accent)">{sig}</span>{txt}</span>'

SETTINGS = [("film-strip", "Camera", "35 mm film · Anamorphic"), ("lightbulb-filament", "Light", "Window"), ("palette", "Look", "Golden warmth"),
            ("sliders-horizontal", "Style", "UGC · Calm")]

# Each input slot carries its own name under the thumbnail; the empty slot says what it adds (owner fix 4).
SLOTS = [("Character", "angles/mcu.jpg", ""), ("Start frame", "genres/romance.jpg", ""), ("End frame", None, "Optional")]

def slots(sz):
    cells = []
    for name, src, note in SLOTS:
        box = (f'<div class="media" style="width:{sz}px;height:{sz}px"><img src="{img(PV/src)}"></div>' if src else
               f'<div style="width:{sz}px;height:{sz}px;border-radius:var(--rc);border:1.5px dashed var(--ink2);display:grid;place-items:center;color:var(--ink2)">{icon("plus",20)}</div>')
        cells.append(f'<div style="width:{sz + 8}px">{box}<div class="micro" style="margin-top:6px;color:{"var(--ink)" if src else "var(--ink2)"}">{name}</div>'
                     f'<div class="micro" style="color:var(--ink2);font-weight:400;height:14px">{note}</div></div>')
    return f'<div class="row gap2" style="align-items:flex-start">{"".join(cells)}</div>'

def composer(t):
    rows = "".join(f'<div class="row gap3" style="height:48px">{icon(i,20,"var(--ink2)")}<div class="label grow" style="color:var(--ink2)">{l}</div>'
                   f'<div class="label">{v}</div>{icon("caret-right",16,"var(--ink2)")}</div>' for i, l, v in SETTINGS)
    return f"""
<div class="row" style="padding:4px 4px 0"><div class="iconbtn">{icon('caret-left',24)}</div><div class="title grow" style="text-align:center">Shot</div><div class="iconbtn">{icon('dots-three',24)}</div></div>
<div style="padding:8px 16px 0"><div class="media" style="height:270px"><img src="{img(PV/'lighting/window.jpg')}"><div class="scrimtag">9:16 · 8 s</div></div></div>
<div style="padding:16px 16px 0">
  <div style="background:var(--raised);border-radius:var(--rk);padding:12px 14px;min-height:96px;font-size:15px;line-height:23px">
    {chip('Demo','@')} walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile. {chip('Dolly in','#')}</div>
  <div style="margin-top:12px">{slots(64)}</div>
</div>
<div style="padding:12px 16px 0">{rows}</div>
<div style="position:absolute;left:0;right:0;bottom:0;padding:12px 16px 20px;background:var(--canvas);border-top:1px solid var(--hair)" class="row gap2">
  <div class="textbtn" style="padding:0 6px">HD {icon('caret-down',16,'var(--ink2)')}</div>
  <div class="iconbtn">{icon('speaker-high',20)}</div>
  <div class="action grow">Generate · $0.64</div></div>"""

# ---------------------------------------------------------------- Picker (phone sheet, Camera → Setup with the drum)
def auto_tile():
    # "Auto" is a real option with its own visual: the aperture mark on the field tone, same size as the hardware renders.
    return (f'<div style="width:64px;height:64px;border-radius:50%;background:var(--field);display:grid;place-items:center">{icon("aperture",32,"var(--ink)")}</div>')

def drum(items, sel, kind):
    out, n = [], len(items)
    for k, (name, src) in enumerate(items):
        d = k - sel
        if n >= 5 and abs(d) > n // 2: d -= n if d > 0 else -n   # 5+ options: the wheel loops
        if abs(d) > 2: continue
        sc, op = (1, 1) if d == 0 else ((.86, .55) if abs(d) == 1 else (.72, .22))
        y = 160 + d * 74
        el = f'<div style="width:72px;height:72px;display:grid;place-items:center">{auto_tile()}</div>' if src == "auto" else \
             f'<img src="{img(HW/(src+".webp"))}" style="width:72px;height:72px;object-fit:contain">' if kind == "hw" else \
             f'<div style="width:72px;height:72px;display:grid;place-items:center;font:600 18px/1 var(--tf);color:var(--ink)">{src}</div>'
        out.append(f'<div style="position:absolute;left:0;right:0;top:{y - 36}px;display:grid;place-items:center;transform:scale({sc}) perspective(300px) rotateX({-d*18}deg);opacity:{op}">{el}</div>')
    return "".join(out)

# The camera bag is always dark (design/README.md decision 3): its sheet uses this palette in every theme, with the theme's type.
BAG = dict(raised="#141414", field="#1E1F21", ink="#ECEAE5", ink2="#A9A6A0", hair="#2C3033")

def picker(t):
    cols = [("Camera", [("Auto", "auto"), ("35 mm film", "body-05-film35"), ("Cinema camera", "body-02-super35"), ("16 mm film", "body-06-film16"), ("Super 8", "body-10-super8"), ("Phone", "body-08-phone")], 1, "hw", "Fine grain, warm halation"),
            ("Lens", [("Auto", "auto"), ("Anamorphic", "lens-02-anamorphic"), ("Warm vintage", "lens-04-warm-vintage"), ("Clean sharp", "lens-01-clean-prime"), ("Vintage anamorphic", "lens-03-vintage-anamorphic")], 1, "hw", "Oval bokeh, flares"),
            ("Focal", [("24 mm", "24"), ("35 mm", "35"), ("50 mm", "50"), ("85 mm", "85"), ("135 mm", "135")], 2, "txt", "Natural, like the eye"),
            ("Aperture", [("f/1.4", "1.4"), ("f/2.8", "2.8"), ("f/5.6", "5.6"), ("f/11", "11")], 1, "txt", "Soft background")]
    seg = "".join(f'<div class="label grow" style="text-align:center;height:36px;line-height:36px;border-radius:calc(var(--rk) - 2px);{"background:var(--raised);color:var(--ink)" if i == 0 else "color:var(--ink2)"}">{s}</div>'
                  for i, s in enumerate(["Setup", "Angle", "Movement", "Directed"]))
    drums = "".join(f'<div class="grow" style="display:flex;flex-direction:column;align-items:center">'
                    f'<div class="caption" style="height:22px;margin-bottom:6px">{c}</div><div style="position:relative;width:100%;height:320px;overflow:hidden">{drum(items, sel, kind)}</div>'
                    f'<div class="label" style="text-align:center;margin-top:6px">{items[sel][0]}</div><div class="caption" style="text-align:center;font-size:12px;line-height:16px;padding:0 2px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">{cap}</div></div>'
                    for c, items, sel, kind, cap in cols)
    return f"""
<div style="position:absolute;inset:0;background:var(--canvas)"><div style="padding:8px 16px;opacity:.35"><div class="media" style="height:220px;margin-top:52px"><img src="{img(PV/'lighting/window.jpg')}"></div></div></div>
<div style="position:absolute;inset:0;background:rgba(0,0,0,.45)"></div>
<div class="float" style="position:absolute;left:0;right:0;bottom:0;top:96px;background:{BAG['raised']};color:{BAG['ink']};border-radius:var(--rc) var(--rc) 0 0;--tf:'{t['text']}';--raised:{BAG['raised']};--field:{BAG['field']};--ink:{BAG['ink']};--ink2:{BAG['ink2']};--hair:{BAG['hair']}">
  <div style="width:36px;height:4px;border-radius:2px;background:var(--hair);margin:8px auto 0"></div>
  <div class="row" style="padding:8px 8px 0 16px"><div class="title grow">Camera</div><div class="textbtn" style="color:var(--ink2);padding:0 8px">Reset</div><div class="iconbtn">{icon('x',22)}</div></div>
  <div class="row" style="margin:8px 16px 0;background:var(--field);border-radius:var(--rk);padding:3px">{seg}</div>
  <div style="position:relative;margin:20px 8px 0">
    <div style="position:absolute;left:0;right:0;top:{28 + 160 - 40}px;height:80px;border-top:1px solid var(--hair);border-bottom:1px solid var(--hair);background:var(--field);opacity:.6"></div>
    <div class="row" style="position:relative;align-items:flex-start">{drums}</div>
  </div>
  <div style="position:absolute;left:16px;right:16px;bottom:24px;{'background:#F8F5EF;color:#141210' if t['action'] == '#141210' else ''}" class="action">Done</div>
</div>"""

# ---------------------------------------------------------------- Composer (Mac 1280 and 1000)
# Owner fix 1: the preview fills the height between the title and the prompt bar, the bar sits right under it, no dead bands.
# At narrow widths the bar's controls drop to icon plus value; the price on Generate is always visible.
def composer_mac(t, w=1280):
    narrow = w < 1100
    nav = [("house", "Home", False), ("user", "Models", False), ("video-camera", "Shot", True), ("camera", "Photo", False), ("users-three", "Character swap", False),
           ("film-strip", "Storyboard", False), ("squares-four", "Library", False), ("stack", "Queue", False)]
    side = "".join(f'<div class="row gap3" style="height:36px;padding:0 12px;border-radius:var(--rk);{"background:var(--field);color:var(--ink)" if on else "color:var(--ink2)"}">{icon(i,20)}<div class="label">{l}</div></div>' for i, l, on in nav)
    rows = "".join(f'<div class="row gap3" style="height:44px">{icon(i,20,"var(--ink2)")}<div class="label grow" style="color:var(--ink2)">{l}</div><div class="label" style="white-space:nowrap">{v}</div></div>' for i, l, v in SETTINGS)
    rail, sidew = (264, 200) if narrow else (300, 220)
    tip = lambda txt: f' title="{txt}" aria-label="{txt}"'
    bar = (f'<div class="textbtn">HD {icon("caret-down",16,"var(--ink2)")}</div><div class="iconbtn"{tip("Sound on")}>{icon("speaker-high",20)}</div>'
           f'<div class="iconbtn" style="color:var(--ink2)"{tip("Not speaking")}>{icon("microphone-slash",20)}</div>') if narrow else \
          (f'<div class="textbtn">HD {icon("caret-down",16,"var(--ink2)")}</div><div class="textbtn" style="color:var(--ink2)">{icon("speaker-high",18)} Sound</div>'
           f'<div class="textbtn" style="color:var(--ink2)">{icon("microphone-slash",18)} Not speaking</div>')
    return f"""
<div class="row" style="height:100%;align-items:stretch">
 <div style="width:{sidew}px;flex:none;padding:16px 12px;border-right:1px solid var(--hair);position:relative"><div class="label" style="font-family:'{t['display']}';font-size:18px;padding:4px 12px 16px">MUSE</div>{side}
   <div class="caption" style="position:absolute;bottom:20px;left:24px">$4.17 left</div></div>
 <div class="grow" style="padding:16px 24px 20px;display:flex;flex-direction:column;gap:12px">
   <div class="row" style="height:32px"><div class="title grow">Shot</div><div class="textbtn" style="color:var(--ink2);height:32px">Presets</div></div>
   <div class="row gap4" style="flex:1;min-height:0;align-items:stretch">
     <div class="media" style="flex:1"><img src="{img(PV/'lighting/window.jpg')}"><div class="scrimtag">16:9 · 8 s</div></div>
     <div style="width:{rail}px;flex:none">
       <div class="heading" style="margin-bottom:4px">Setup</div>{rows}
       <div class="heading" style="margin:20px 0 8px">Inputs</div>{slots(72 if not narrow else 64)}</div>
   </div>
   <div style="background:var(--raised);border-radius:var(--rk);padding:12px 16px">
     <div style="font-size:15px;line-height:23px">{chip('Demo','@')} walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile. {chip('Dolly in','#')}</div>
     <div class="row gap2" style="margin-top:8px">{bar}<div class="grow"></div><div class="action" style="padding:0 24px;white-space:nowrap">Generate · $0.64</div></div></div>
 </div></div>"""

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = [(f"home-{k}", home, k, 390, 844) for k in THEMES] + [(f"composer-{k}", composer, k, 390, 844) for k in THEMES] + \
           [(f"picker-{k}", picker, k, 390, 844) for k in THEMES] + [("composer-mac-b", composer_mac, "b", 1280, 800), ("composer-mac-1000-b", lambda t: composer_mac(t, 1000), "b", 1000, 720)]
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for name, fn, k, w, h in jobs:
            f = Path(tmp) / f"{name}.html"; f.write_text(page(fn(THEMES[k]), THEMES[k], w, h))
            spec.append({"html": f.as_uri(), "png": str(OUT / f"{name}.png"), "w": w, "h": h})
        js = Path(tmp) / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 2 });
    await p.goto(j.html); await p.waitForTimeout(400); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(spec)], check=True, env={**os.environ, "NODE_PATH": root})

if __name__ == "__main__":
    main()

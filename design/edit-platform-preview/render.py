"""Mock of Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md), for the coordinator.

The platform views move out of the take viewer and into Edit: the preview gets a view picker (Clean, TikTok, Reels, Shorts,
Facebook for portrait; Clean, YouTube, Facebook for landscape). A platform view draws that app's generic chrome (our own
drawing: grey bars for text, Phosphor glyphs for buttons, no logos or brand colours) over the edit, with that app's red
safe-area box. Clean draws nothing; the Safe area switch works in every view (in Clean it shows the box that is safe on
every app). Camera Body (B) is the dark theme, Editorial (A) the light one, as in the swap-viewer mockups.

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/edit-platform-preview/render.py
Writes plans/design/edit-platform-preview/*.png. Reuses design/edit-layout/render.py (tokens, fonts, the Edit shell).
"""
import json, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "edit-layout"))
import render as E  # noqa: E402

REPO = E.REPO
OUT = REPO / "plans" / "design" / "edit-platform-preview"
icon, poster = E.icon, E.poster
RED = "#FF5A5F"

# The server's table (server/api/src/suite/previewLayouts.ts): fractions of the frame each app's buttons cover.
ZONES = {"tiktok": (0.11, 0.29, 0.03, 0.17), "reels": (0.10, 0.30, 0.03, 0.16), "shorts": (0.09, 0.30, 0.03, 0.17),
         "facebook": (0.10, 0.28, 0.03, 0.16)}
# Clean: the box that is safe on every app (the largest inset of each side).
ALL = tuple(max(z[i] for z in ZONES.values()) for i in range(4))


def bar(w, h, dim=False):
    return f'<div style="width:{w}px;height:{h}px;border-radius:{h/2}px;background:rgba(255,255,255,{.55 if dim else .85});flex:none"></div>'


def glyph(name, k, count=True):
    c = bar(18 * k, max(3, 5 * k)) if count else ""
    return f'<div style="display:flex;flex-direction:column;align-items:center;gap:{3*k}px">{icon(name, round(21*k), "#fff")}{c}</div>'


def tiktok_chrome(w, h):
    """TikTok's generic layout over the frame (the same parts as PhoneSkin in TakeViewer.swift)."""
    k = w / 300
    nav = 56 * k
    av = 40 * k
    rail = "".join(glyph(n, k) for n in ["heart", "chat-circle-dots", "bookmark-simple", "share-fat"])
    navs = "".join(f'<div style="flex:1;display:flex;justify-content:center">{icon(n, round(18*k), "#fff")}</div>'
                   for n in ["house", "users-three", "plus-square", "chat-circle", "user"])
    return f"""
<div style="position:absolute;inset:0;pointer-events:none">
  <div style="position:absolute;left:{18*k}px;right:{18*k}px;top:{8*k}px;display:flex;justify-content:space-between">{bar(28*k, 7*k)}{bar(40*k, 7*k)}</div>
  <div style="position:absolute;left:0;right:0;top:{32*k}px;display:flex;justify-content:center;gap:{14*k}px">{bar(50*k, 8*k, True)}{bar(44*k, 8*k)}</div>
  <div style="position:absolute;right:{14*k}px;top:{28*k}px">{icon("magnifying-glass", round(18*k), "#fff")}</div>
  <div style="position:absolute;right:{10*k}px;bottom:{nav + 16*k}px;display:flex;flex-direction:column;align-items:center;gap:{16*k}px">
    <div style="width:{av}px;height:{av}px;border-radius:50%;background:rgba(255,255,255,.75);box-shadow:inset 0 0 0 1.5px #fff"></div>{rail}
    <div style="width:{32*k}px;height:{32*k}px;border-radius:50%;background:#333;box-shadow:inset 0 0 0 {5*k}px #121212"></div></div>
  <div style="position:absolute;left:{12*k}px;bottom:{nav + 14*k}px;width:{w*0.62}px;display:flex;flex-direction:column;gap:{6*k}px">
    {bar(w*0.62*0.4, 9*k)}{bar(w*0.62*0.92, 7*k, True)}{bar(w*0.62*0.64, 7*k, True)}
    <div style="display:flex;gap:{6*k}px;align-items:center">{icon("music-note", round(11*k), "#fff")}{bar(w*0.62*0.52, 6*k, True)}</div></div>
  <div style="position:absolute;left:0;right:0;bottom:0;height:{nav}px;background:rgba(0,0,0,.92);display:flex;align-items:center;padding-bottom:{6*k}px">{navs}</div>
</div>"""


def youtube_chrome(w, h):
    """YouTube's generic in-player layout (landscape): title row on top, controls along the bottom."""
    k = w / 640
    return f"""
<div style="position:absolute;inset:0;pointer-events:none">
  <div style="position:absolute;left:0;right:0;top:0;height:{h*0.16}px;background:linear-gradient(rgba(0,0,0,.55),rgba(0,0,0,0))"></div>
  <div style="position:absolute;left:{16*k}px;top:{14*k}px;display:flex;gap:{10*k}px;align-items:center">
    <div style="width:{26*k}px;height:{26*k}px;border-radius:50%;background:rgba(255,255,255,.75)"></div>{bar(180*k, 10*k)}</div>
  <div style="position:absolute;right:{16*k}px;top:{16*k}px;display:flex;gap:{14*k}px">{icon("clock", round(18*k), "#fff")}{icon("share-fat", round(18*k), "#fff")}</div>
  <div style="position:absolute;left:0;right:0;bottom:0;height:{h*0.16}px;background:linear-gradient(rgba(0,0,0,0),rgba(0,0,0,.6))"></div>
  <div style="position:absolute;left:{12*k}px;right:{12*k}px;bottom:{38*k}px;height:{3*k}px;background:rgba(255,255,255,.35)"><div style="width:30%;height:100%;background:#fff"></div></div>
  <div style="position:absolute;left:{14*k}px;right:{14*k}px;bottom:{10*k}px;display:flex;align-items:center;gap:{14*k}px">
    {icon("play", round(18*k), "#fff")}{icon("skip-forward", round(18*k), "#fff")}{icon("speaker-high", round(18*k), "#fff")}{bar(70*k, 7*k, True)}
    <div style="flex:1"></div>{icon("closed-captioning", round(18*k), "#fff")}{icon("gear-six", round(18*k), "#fff")}{icon("corners-out", round(18*k), "#fff")}</div>
</div>"""


def safe_box(z, label):
    top, bottom, left, right = z
    return (f'<div title="{label}" style="position:absolute;left:{left*100}%;top:{top*100}%;right:{right*100}%;bottom:{bottom*100}%;'
            f'border:1.5px dashed {RED};border-radius:2px;pointer-events:none"></div>')


def caption_on_frame(w, h, y, warn):
    """A caption page (Word pop) centred at y (fraction of the frame)."""
    fs = round(h * 0.04)
    outline = f"outline:1.5px solid {RED};outline-offset:4px;" if warn else ""
    return (f'<div style="position:absolute;left:0;right:0;top:{y*100}%;transform:translateY(-50%);display:flex;justify-content:center;pointer-events:none">'
            f'<div style="{outline}border-radius:3px;font:900 {fs}px/1.1 Outfit, Barlow, sans-serif;color:#fff;text-transform:uppercase;'
            f'text-shadow:0 2px 6px rgba(0,0,0,.6);text-align:center;max-width:{w*0.82}px">I always <span style="color:#F2D84B">order</span> the</div></div>')


def view_bar(t, landscape, view, safe_on):
    opts = ["Clean", "YouTube", "Facebook"] if landscape else ["Clean", "TikTok", "Reels", "Shorts", "Facebook"]
    seg = "".join(f'<div class="{"on" if o == view else ""}">{o}</div>' for o in opts)
    sw_bg = t["accent"] if safe_on else t["field"]
    knob = t["onaction"] if safe_on else t["ink2"]
    switch = (f'<div style="width:32px;height:18px;border-radius:9px;background:{sw_bg};position:relative;flex:none;'
              f'{"" if safe_on else "box-shadow:inset 0 0 0 1px " + t["hair"]}"><div style="position:absolute;top:2px;left:{16 if safe_on else 2}px;'
              f'width:14px;height:14px;border-radius:7px;background:{knob}"></div></div>')
    return f"""<div class="row" style="gap:8px">
    <div class="caption ink2">View</div>
    <div class="seg caption" style="height:28px">{seg}</div>
    <div style="width:12px"></div>
    <div class="row" style="gap:8px" title="The red box: where each app leaves your picture clear. Approximate.">{switch}<div class="caption">Safe area</div></div>
    <div class="grow"></div><div class="caption ink2 num">Fit · 43%</div></div>"""


def warning(t, text, fix):
    return (f'<div class="row" style="gap:8px;min-height:28px">{icon("warning", 16, RED)}'
            f'<div class="caption">{text}</div><div class="caption" style="color:{t["accent"]};font-weight:500;white-space:nowrap">{fix}</div></div>')


def viewer(t, view, safe_on=True, landscape=False, caption_y=0.78):
    # The frame: as tall as the viewer allows, at the canvas shape.
    fh = 430 if not landscape else 300
    fw = round(fh * 9 / 16) if not landscape else round(fh * 16 / 9)
    frame_img = poster("dolly_in" if not landscape else "follow")
    chrome = ""
    zone, zone_label = None, ""
    if view == "TikTok":
        chrome = tiktok_chrome(fw, fh)
        zone, zone_label = ZONES["tiktok"], "TikTok's safe area"
    elif view == "YouTube":
        chrome = youtube_chrome(fw, fh)
        zone, zone_label = (0.12, 0.16, 0.03, 0.03), "YouTube's safe area"
    elif view == "Clean":
        zone, zone_label = (ALL if not landscape else (0.05, 0.05, 0.05, 0.05)), "Safe on every app"
    unsafe = zone is not None and caption_y + 0.03 > 1 - zone[1]
    box = safe_box(zone, zone_label) if (safe_on and zone) else ""
    if view == "Clean" and safe_on:
        tag = f'<div class="micro" style="position:absolute;left:{zone[2]*100}%;top:calc({zone[0]*100}% - 18px);color:{RED}">Safe on every app</div>'
    elif safe_on and zone:
        tag = ""
    else:
        tag = ""
    frame = f"""<div style="position:relative;width:{fw}px;height:{fh}px;background:url({frame_img}) center/cover;border-radius:2px;overflow:hidden">
      {caption_on_frame(fw, fh, caption_y, unsafe and safe_on)}{chrome}{box}{tag}</div>"""
    warn = ""
    if unsafe and safe_on:
        where = {"TikTok": "TikTok's caption and buttons", "Clean": "some apps' captions and buttons", "YouTube": "YouTube's controls"}[view]
        warn = warning(t, f"Captions sit under {where} (0:01–0:09).", "Move into the safe area")
    return f"""<div class="col grow" style="min-width:0;padding:16px;gap:12px">
  {view_bar(t, landscape, view, safe_on)}
  <div class="grow row" style="justify-content:center;background:{t['viewer']};border-radius:{t['rc']}px;min-height:0;overflow:hidden">{frame}</div>
  {warn or '<div style="height:28px"></div>'}
  <div class="row" style="gap:8px;justify-content:center">
    <div class="label num" style="width:120px">0:03.2 / 0:15.0</div><div class="grow"></div>
    <div class="btn icon plain" title="Back to the start">{icon('skip-back', 20)}</div>
    <div class="btn icon plain" title="Back one frame">{icon('caret-left', 20)}</div>
    <div class="btn icon" style="width:40px;height:40px;border-radius:999px;background:{t['ink']};color:{t['canvas']}" title="Play">{icon('play', 18)}</div>
    <div class="btn icon plain" title="Forward one frame">{icon('caret-right', 20)}</div>
    <div class="btn icon plain" title="Forward one second">{icon('skip-forward', 20)}</div><div class="grow"></div>
    <div class="row" style="width:120px;justify-content:flex-end;gap:4px"><div class="btn icon plain">{icon('camera', 20)}</div><div class="btn icon plain" title="Sound">{icon('speaker-high', 20)}</div>
      <div class="btn icon plain" title="Full screen">{icon('arrows-out-simple', 20)}</div></div>
  </div></div>"""


def page(t, w, h, view, safe_on=True, landscape=False):
    wide = w >= 1440
    top = E.topbar(t, wide, True)
    if landscape:
        top = top.replace('<div class="on">9:16</div><div>1:1</div><div>4:5</div><div>16:9</div>',
                          '<div>9:16</div><div>1:1</div><div>4:5</div><div class="on">16:9</div>')
    return f"""<!doctype html><meta charset="utf-8"><style>{E.css(t)}</style>
<body style="width:{w}px;height:{h}px"><div class="row" style="height:100%;align-items:stretch">{E.rail(t)}
<div class="col grow" style="min-width:0">{top}
  <div class="row grow" style="min-height:0;align-items:stretch;overflow:hidden">{E.media(t)}{viewer(t, view, safe_on, landscape)}{E.inspector(t)}</div>
  {E.timeline(t, wide)}
</div></div></body>"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    jobs = []
    shots = [("edit-tiktok-dark", "b", "TikTok", True, False), ("edit-tiktok-light", "a", "TikTok", True, False),
             ("edit-clean-dark", "b", "Clean", False, False), ("edit-clean-light", "a", "Clean", False, False),
             ("edit-clean-safe-dark", "b", "Clean", True, False), ("edit-youtube-landscape-dark", "b", "YouTube", True, True)]
    for name, key, view, safe_on, landscape in shots:
        p = tmp / f"{name}.html"
        p.write_text(page(E.THEMES[key], 1440, 900, view, safe_on, landscape))
        jobs.append(dict(html=p.as_uri(), png=str(OUT / f"{name}.png"), w=1440, h=900))
    js = tmp / "shoot.js"
    js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 2 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
    subprocess.run(["node", str(js), json.dumps(jobs)], check=True, cwd=tmp)


if __name__ == "__main__":
    main()

"""Renders the Create mocks (plans/ai-suite-design.md, build step 1) for the owner's approval.

Mac at 1440 x 900 and 1280 x 800, phone at 390 x 844, in Soft Tactile (C) and Camera Body (B). Writes
plans/ai-suite-mocks/<screen>-<size>-<theme>.png and a contact sheet per theme.

    PHOSPHOR=<@phosphor-icons/core package> python3 design/direction/create.py

Imagery is real studio material only: the Blender preview stills and loop posters (design/previews), the hardware renders
(design/hardware) and the approved drums as the app draws them (design/direction/assets/drums-setup.png, cropped from the
Android RigDrum screenshot test). No sample photos, no placeholders.
"""
import json, os, subprocess, tempfile
from pathlib import Path

import render as R
import sleek as S

OUT = R.REPO / "plans" / "ai-suite-mocks"
THEMES = S.THEMES
PV, HW, ASSETS = R.PV, R.HW, Path(__file__).resolve().parent / "assets"
I = R.icon

def src(p): return R.img(PV / p)

MODEL = "Zelphira"
MODEL_IMG = "angles/mcu.webp"

# ---------------------------------------------------------------- shared CSS (on top of render.css)
def css(t):
    f = t["text"]
    return f"""
:root{{--side:{'#E1DBD1' if t['canvas'] == '#E7E2D9' else '#0A0B0C'}}}
.t17{{font:600 17px/22px "{f}";letter-spacing:-.01em}} .t15{{font:400 15px/23px "{f}"}} .t13{{font:400 13px/18px "{f}"}} .t13m{{font:500 13px/18px "{f}"}}
.t11{{font:400 11px/14px "{f}";color:var(--ink2)}} .ink2{{color:var(--ink2)}}
.quiet{{height:28px;padding:0 10px;display:inline-flex;align-items:center;gap:6px;color:var(--ink2);border-radius:8px;font:500 13px/18px "{f}";white-space:nowrap}}
.quiet.on{{background:var(--field);color:var(--ink)}}
.outline{{height:28px;padding:0 12px;display:inline-flex;align-items:center;gap:6px;color:var(--ink);border:1px solid var(--hair);border-radius:8px;font:500 13px/18px "{f}";white-space:nowrap}}
.go{{background:var(--action);color:var(--onaction);border-radius:10px;height:40px;display:flex;align-items:center;justify-content:center;font:600 14px/18px "{f}";white-space:nowrap}}
.rrow{{height:32px;display:flex;align-items:center;gap:12px}} .rrow .k{{width:64px;flex:none;color:var(--ink2)}}
.rrow .v{{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}} .rrow .v.auto{{color:var(--ink2)}}
.rrow.off .k,.rrow.off .v{{opacity:.5}}
.tile{{width:44px;height:44px;border-radius:8px;overflow:hidden;flex:none;position:relative}} .tile img{{width:100%;height:100%;object-fit:cover;display:block}}
.tile.empty{{border:1px dashed color-mix(in srgb,var(--ink2) 55%,transparent);display:grid;place-items:center;color:var(--ink2)}}
.chip{{background:var(--field);border-radius:6px;padding:1px 6px;font-weight:500;white-space:nowrap}} .chip i{{font-style:normal;color:var(--accent)}}
.card{{border-radius:8px;overflow:hidden;position:relative;flex:none;background:var(--field)}} .card img{{width:100%;height:100%;object-fit:cover;display:block}}
.glabel{{font:500 13px/18px "{f}";color:var(--ink2);margin:0 0 10px}}
.hair{{background:var(--hair)}}
.panel{{background:var(--raised);border:1px solid var(--hair);border-radius:14px;box-shadow:{t['float'] if t['float'] != 'none' else 'none'}}}
.tab{{height:32px;display:flex;align-items:center;padding:0 2px;color:var(--ink2);font:500 13px/18px "{f}";border-bottom:2px solid transparent}}
.tab.on{{color:var(--ink);border-color:var(--ink)}}
.scrim{{position:absolute;inset:0;background:linear-gradient(transparent 45%,rgba(0,0,0,.72))}}
"""

def page(body, t, w, h):
    return (f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{S.css(t)}{css(t)}</style>'
            f'<body style="width:{w}px;height:{h}px;overflow:hidden;position:relative">{body}</body>')

def chip(txt, sig): return f'<span class="chip"><i>{sig}</i>{txt}</span>'

# ---------------------------------------------------------------- the Mac shell
NAV = [("magic", "Create"), ("squares-four", "Library"), ("user", "Models"), ("film-slate", "Edit"), ("paper-plane-tilt", "Posts")]
NAV_ICON = {"Create": "plus-square", "Library": "squares-four", "Models": "user", "Edit": "scissors", "Posts": "paper-plane-tilt"}

def sidebar(w):
    rows = []
    for _, name in NAV:
        on = name == "Create"
        badge = '<span class="t11" style="margin-left:auto">3 to review</span>' if name == "Library" else ""
        rows.append(f'<div class="row t13" style="gap:10px;height:30px;padding:0 10px;border-radius:8px;'
                    f'{"background:var(--field);color:var(--ink);font-weight:500" if on else "color:var(--ink2)"}">{I(NAV_ICON[name], 16)}{name}{badge}</div>')
    return (f'<div style="width:{w}px;flex:none;padding:20px 12px 16px;border-right:1px solid var(--hair);display:flex;flex-direction:column;gap:2px">'
            f'<div class="t17" style="padding:0 10px 18px">MUSE</div>{"".join(rows)}<div class="grow"></div>'
            f'<div class="row t13" style="gap:10px;height:30px;padding:0 10px;color:var(--ink2)">{I("gear-six", 16)}Settings</div>'
            f'<div class="t11" style="padding:8px 10px 0">$6.07 left</div></div>')

def mac_frame(t, w, h, composer_html, feed_html, overlay=""):
    side = 208 if w >= 1400 else 192
    col = 400 if w >= 1400 else 372
    return (f'<div class="row" style="height:100%;align-items:stretch">{sidebar(side)}'
            f'<div style="width:{col}px;flex:none;border-right:1px solid var(--hair);display:flex;flex-direction:column">{composer_html}</div>'
            f'<div class="grow" style="position:relative;overflow:hidden">{feed_html}{overlay}</div></div>')

# ---------------------------------------------------------------- the composer column
def composer(mode="Shot", inputs=None, prompt=None, rows=None, notice=None, footer=None, extra=""):
    """Header, a scrolling middle (inputs, prompt, rig rows, notice) and the pinned footer."""
    tiles = []
    for name, img, note in inputs or []:
        box = f'<div class="tile"><img src="{src(img)}"></div>' if img else f'<div class="tile empty">{I("plus", 16)}</div>'
        tiles.append(f'<div style="width:58px">{box}<div class="t11" style="margin-top:5px;color:{"var(--ink)" if img else "var(--ink2)"};white-space:nowrap">{name}</div>'
                     f'<div class="t11" style="height:14px">{note}</div></div>')
    prompt_html = prompt or '<span class="ink2">Describe the shot. Type @ for a model, # for a camera move.</span>'
    rows_html = ""
    for r in rows or []:
        k, v = r[0], r[1]
        cls = r[2] if len(r) > 2 else ""
        rows_html += (f'<div class="rrow t13 {cls}"><div class="k">{k}</div><div class="v {"auto" if v == "Auto" else ""}">{v}</div>'
                      f'{I("caret-right", 12, "var(--ink2)") if cls != "off" else ""}</div>')
    return f"""
<div class="row" style="height:56px;padding:0 20px 0 24px;flex:none">
  <div class="row t17" style="gap:6px">{mode} {I("caret-down", 14, "var(--ink2)")}</div><div class="grow"></div><div class="quiet">Presets</div></div>
<div class="grow" style="padding:4px 24px 0;overflow:hidden">
  <div class="row" style="gap:6px;align-items:flex-start">{"".join(tiles)}</div>
  {"" if prompt is False else f'<div class="t15" style="margin-top:14px;background:var(--raised);border-radius:12px;padding:12px 14px;min-height:120px">{prompt_html}</div>'}
  {extra}
  <div style="margin-top:14px">{rows_html}</div>
  {notice or ""}
</div>
<div style="flex:none;padding:12px 24px 20px;border-top:1px solid var(--hair)">{footer or footer_shot()}</div>"""

def footer_shot(price="$0.65", line="9:16, 10 s, 1 take, sound on", quality="HD", label=None, off=False):
    return (f'<div class="row" style="gap:4px;margin:0 -10px 10px"><div class="quiet">{quality} {I("caret-down", 12)}</div>'
            f'<div class="quiet" style="color:var(--ink2)">{line}</div></div>'
            f'<div class="go" style="{"opacity:.4" if off else ""}">{label or ("Generate" if off else "Generate · " + price)}</div>')

def rig_check(text, fix="Fix"):
    return (f'<div class="row t13" style="gap:8px;margin-top:10px;padding:8px 10px;border-radius:8px;background:var(--field)">'
            f'{I("warning", 14, "var(--ink2)")}<div class="grow">{text}</div><div class="t13m" style="color:var(--accent)">{fix}</div></div>')

AUTO_ROWS = [("Camera", "Auto"), ("Angle", "Auto"), ("Move", "Auto"), ("Light", "Auto"), ("Look", "Auto"), ("Style", "Auto")]
SHOT_ROWS = [("Camera", "35 mm film, anamorphic"), ("Angle", "Eye level, medium"), ("Move", "Dolly in"), ("Light", "Window"),
             ("Look", "Golden warmth"), ("Style", "UGC, calm")]
SHOT_INPUTS = [(MODEL, MODEL_IMG, ""), ("Start frame", None, "Optional"), ("End frame", None, "Optional"), ("References", None, "Up to 9")]
# The working state's rig: the clash the rig check names is really there (24 mm on a close-up).
WORKING_ROWS = [("Camera", "35 mm film, anamorphic, 24 mm"), ("Angle", "Eye level, close-up"), ("Move", "Dolly in"), ("Light", "Window"),
                ("Look", "Golden warmth"), ("Style", "UGC, calm")]
SHOT_PROMPT = (f'{chip(MODEL, "@")} walks out of the café into the evening street, stops at the corner and looks back over her shoulder. '
               f'{chip("Dolly in", "#")}')

# ---------------------------------------------------------------- the feed
TAKES_TODAY = [("eras/2010s.jpg", 9 / 16), ("lighting/golden_hour.webp", 9 / 16), ("genres/epic.jpg", 16 / 9), ("lighting/contre_jour.webp", 9 / 16),
               ("eras/1990s.jpg", 9 / 16), ("lighting/blue_hour.webp", 9 / 16)]
TAKES_YDAY = [("genres/documentary.jpg", 9 / 16), ("lighting/neon.webp", 9 / 16), ("eras/2020s.jpg", 16 / 9), ("genres/noir.jpg", 9 / 16),
              ("lighting/practicals.webp", 9 / 16), ("lighting/candle.webp", 9 / 16), ("angles/low.webp", 9 / 16)]

def card(img, ar, h, extra="", style=""):
    return f'<div class="card" style="width:{h * ar:.0f}px;height:{h}px;{style}"><img src="{src(img)}">{extra}</div>'

def justified(items, W, target, gap=10):
    """Rows that span the feed width (Google Photos style): each row is one height, chosen so its cards fill W; the last
    row keeps the target height and sits left-aligned. items: (render(h) -> html, aspect)."""
    rows, row, out = [], [], []
    for it in items:
        row.append(it)
        if sum(a for _, a in row) * target + gap * (len(row) - 1) >= W:
            rows.append((row, True)); row = []
    if row: rows.append((row, False))
    for r, full in rows:
        h = (W - gap * (len(r) - 1)) / sum(a for _, a in r) if full else target
        out.append(f'<div class="row" style="gap:{gap}px;align-items:flex-start;margin-bottom:{gap}px">{"".join(fn(h) for fn, _ in r)}</div>')
    return "".join(out)

def group(label, cards, right=""):
    return (f'<div style="margin-bottom:22px"><div class="row" style="margin-bottom:10px"><div class="glabel" style="margin:0">{label}</div>'
            f'<div class="grow"></div>{right}</div>{cards if isinstance(cards, str) else '<div class="row" style="gap:10px;flex-wrap:wrap;align-items:flex-start">' + "".join(cards) + "</div>"}</div>')

def feed_bar(title="All takes"):
    return (f'<div class="row" style="height:56px;padding:0 24px;flex:none"><div class="quiet on" style="margin-left:-10px">{title} {I("caret-down", 12)}</div>'
            f'<div class="grow"></div><div class="quiet">Select</div></div>')

def running_card(img, ar, h, pct, left):
    blur = (f'<div style="position:absolute;inset:0;backdrop-filter:blur(14px) saturate(.6);background:rgba(0,0,0,.25)"></div>'
            f'<div style="position:absolute;left:12px;right:12px;bottom:12px;color:#fff">'
            f'<div class="t13m">{pct}%</div><div class="t11" style="color:rgba(255,255,255,.75)">{left}</div>'
            f'<div style="height:3px;border-radius:2px;background:rgba(255,255,255,.25);margin-top:8px"><div style="height:3px;width:{pct}%;border-radius:2px;background:#fff"></div></div></div>')
    return card(img, ar, h, blur)

def queued_card(img, ar, h):
    return card(img, ar, h, '<div style="position:absolute;inset:0;background:color-mix(in srgb,var(--canvas) 55%,transparent)"></div>'
                '<div class="t11" style="position:absolute;left:10px;bottom:9px;color:var(--ink)">Queued</div>', "opacity:.9")

def hover_card(img, ar, h):
    """The hovered take: it plays; its prompt and specs at the bottom; the four actions and More as 28 pt targets down the
    right edge, each with a tooltip (the one under the pointer is drawn)."""
    acts = [("shuffle", "Vary"), ("arrow-line-right", "Extend"), ("frame-corners", "Use as start frame"), ("scissors", "Open in Edit"), ("dots-three", "More")]
    btns = "".join(f'<div title="{n}" style="width:28px;height:28px;border-radius:8px;display:grid;place-items:center;'
                   f'background:{"rgba(255,255,255,.32)" if n == "Use as start frame" else "rgba(0,0,0,.45)"};color:#fff">{I(i, 16)}</div>' for i, n in acts)
    over = (f'<div class="scrim"></div><div style="position:absolute;left:10px;right:44px;bottom:10px;color:#fff">'
            f'<div class="t11" style="color:rgba(255,255,255,.9);display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">'
            f'Zelphira walks out of the café into the evening street…</div>'
            f'<div class="t11" style="color:rgba(255,255,255,.7);margin-top:3px">9:16, 10 s, $0.65</div></div>'
            f'<div style="position:absolute;right:6px;top:6px;display:flex;flex-direction:column;gap:4px">{btns}</div>'
            f'<div style="position:absolute;left:8px;top:8px;width:20px;height:20px;border-radius:50%;border:1.5px solid rgba(255,255,255,.85)"></div>')
    c = card(img, ar, h, over, "outline:2px solid var(--ink);outline-offset:2px")
    tip = (f'<div class="t11" style="position:absolute;left:calc(100% - 4px);top:{6 + 2 * 32 + 4}px;background:var(--ink);color:var(--canvas);'
           f'padding:4px 8px;border-radius:6px;white-space:nowrap;z-index:4">Use as start frame</div>')
    return f'<div style="position:relative;flex:none">{c}{tip}</div>'

def tooltip(text, x, y):
    return (f'<div class="t11" style="position:absolute;left:{x}px;top:{y}px;background:var(--ink);color:var(--canvas);padding:4px 8px;border-radius:6px;'
            f'white-space:nowrap;z-index:4">{text}</div>')

# ---------------------------------------------------------------- Mac screens
def m_empty(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, rows=AUTO_ROWS, footer=footer_shot(off=True))
    presets = [("Café walk-in", "Window light, slow dolly in"), ("Street at night", "Neon, handheld follow"), ("Golden hour portrait", "85 mm, warm backlight")]
    sug = "".join(f'<div style="border:1px solid var(--hair);border-radius:12px;padding:12px 14px;width:200px;text-align:left">'
                  f'<div class="t13m">{n}</div><div class="t11" style="margin-top:2px">{d}</div></div>' for n, d in presets)
    feed = (f'<div style="position:absolute;inset:0;display:grid;place-items:center"><div style="text-align:center">'
            f'<div class="t15">Your takes appear here</div><div class="t13 ink2" style="margin-top:4px">Write a shot on the left, or start from a preset.</div>'
            f'<div class="row" style="gap:10px;margin-top:20px;justify-content:center">{sug}</div></div></div>')
    return mac_frame(t, w, h, comp, feed)

def feed_w(w): return w - (208 if w >= 1400 else 192) - (400 if w >= 1400 else 372) - 48

def feed_today(h_card, W=700, running=True, queued=True, hover=None, extra_days=False):
    blocks = []
    if queued:
        blocks.append(group("Queued, 2 shots", [queued_card("lighting/neon.webp", 9 / 16, h_card * .7), queued_card("eras/1970s.jpg", 9 / 16, h_card * .7)],
                            right='<div class="outline">Run · $1.30</div>'))
    items = []
    if running: items.append((lambda h: running_card("lighting/window.webp", 9 / 16, h, 62, "About 40 s left"), 9 / 16))
    for k, (img, ar) in enumerate(TAKES_TODAY):
        items.append(((lambda h, i=img, a=ar: hover_card(i, a, h)) if hover == k else (lambda h, i=img, a=ar: card(i, a, h)), ar))
    blocks.append(group("Today", justified(items, W, h_card)))
    if extra_days: blocks.append(group("Yesterday", justified([(lambda h, i=i, a=a: card(i, a, h), a) for i, a in TAKES_YDAY], W, h_card)))
    return blocks

def m_working(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, prompt=SHOT_PROMPT, rows=WORKING_ROWS,
                    notice=rig_check("A 24 mm lens on a close-up stretches the face."), footer=footer_shot())
    hc = 220 if w >= 1400 else 190
    feed = f'<div style="position:absolute;inset:0;display:flex;flex-direction:column">{feed_bar()}<div style="padding:0 24px;overflow:hidden">{"".join(feed_today(hc, feed_w(w), extra_days=False))}</div></div>'
    return mac_frame(t, w, h, comp, feed)

def m_results(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, prompt=SHOT_PROMPT, rows=SHOT_ROWS, footer=footer_shot())
    hc = 220 if w >= 1400 else 190
    feed = (f'<div style="position:absolute;inset:0;display:flex;flex-direction:column">{feed_bar()}'
            f'<div style="padding:0 24px;overflow:hidden">{"".join(feed_today(hc, feed_w(w), running=False, queued=False, hover=1, extra_days=True))}</div></div>')
    tip = ""
    return mac_frame(t, w, h, comp, feed + tip)

def m_viewer(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, prompt=SHOT_PROMPT, rows=SHOT_ROWS, footer=footer_shot())
    hc = 220 if w >= 1400 else 190
    feed = (f'<div style="position:absolute;inset:0;display:flex;flex-direction:column;opacity:.25">{feed_bar()}'
            f'<div style="padding:0 24px">{"".join(feed_today(hc, feed_w(w), running=False, queued=False, extra_days=True))}</div></div>')
    side = 208 if w >= 1400 else 192
    col = 400 if w >= 1400 else 372
    media_w = w - side - col - 48
    media_h = min(media_w * 9 / 16, h - 300)
    media_w = media_h * 16 / 9
    acts = [("shuffle", "Vary"), ("arrow-line-right", "Extend"), ("frame-corners", "Use as start frame"), ("scissors", "Open in Edit")]
    act_html = "".join(f'<div class="outline">{I(i, 14)}{n}</div>' for i, n in acts)
    rig = "; ".join(v if k == "Camera" or v.startswith("UGC") else v[0].lower() + v[1:] for k, v in SHOT_ROWS)
    viewer = f"""
<div style="position:absolute;inset:0;background:var(--canvas);padding:16px 24px;z-index:3;display:flex;flex-direction:column">
  <div class="row" style="height:28px"><div class="t11">Today, 14:32</div><div class="grow"></div><div class="t11" style="margin-right:16px">3 of 13</div><div style="color:var(--ink2)">{I("x", 18)}</div></div>
  <div style="position:relative;margin-top:10px;display:grid;place-items:center">
    <div class="card" style="width:{media_w:.0f}px;height:{media_h:.0f}px;border-radius:10px"><img src="{src('genres/epic.jpg')}"></div></div>
  <div class="row" style="gap:6px;margin-top:16px;flex-wrap:wrap"><div class="outline" style="background:var(--raised)">{I("arrow-counter-clockwise", 14)}Reuse settings</div>{act_html}
    <div class="quiet">{I("dots-three", 16)}More</div></div>
  <div class="t13" style="margin-top:14px;max-width:640px">{SHOT_PROMPT}</div>
  <div class="t11" style="margin-top:6px">{rig}</div><div class="t11" style="margin-top:2px">16:9, 10 s, HD, $0.65</div>
</div>"""
    return mac_frame(t, w, h, comp, feed + viewer)

def rig_panel(t, w, tab, body, saved=True):
    tabs = "".join(f'<div class="tab {"on" if n == tab else ""}">{n}</div>' for n in ["Camera", "Angle", "Move", "Light", "Look", "Style"])
    rigs = "".join(f'<div class="quiet" style="border:1px solid var(--hair)">{n}</div>' for n in ["Café golden", "Night street", "Studio clean"])
    saved_html = (f'<div class="row" style="gap:6px;margin-top:14px"><div class="t11" style="margin-right:4px">Saved rigs</div>{rigs}'
                  f'<div class="grow"></div><div class="quiet">Save rig…</div></div>') if saved else ""
    return (f'<div class="panel" style="position:absolute;left:12px;top:12px;bottom:12px;right:12px;padding:16px 24px 20px;display:flex;flex-direction:column;z-index:3">'
            f'<div class="row" style="gap:20px;border-bottom:1px solid var(--hair)">{tabs}<div class="grow"></div>'
            f'<div style="color:var(--ink2);padding-bottom:6px">{I("x", 18)}</div></div>{saved_html}{body}</div>')

def m_rig_camera(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, prompt=SHOT_PROMPT, rows=SHOT_ROWS, footer=footer_shot())
    feed = f'<div style="position:absolute;inset:0;opacity:.25;display:flex;flex-direction:column">{feed_bar()}<div style="padding:0 24px">{"".join(feed_today(200, feed_w(w), running=False, queued=False))}</div></div>'
    dh = h - 190
    body = (f'<div class="row t13" style="gap:8px;margin-top:16px"><span style="width:7px;height:7px;border-radius:50%;background:#F2A93B"></span>'
            f'35 mm film, anamorphic, 50 mm, f/2.8<div class="grow"></div><div class="quiet">Reset</div></div>'
            f'<div style="flex:1;min-height:0;margin-top:12px;border-radius:12px;background:#141414;display:grid;place-items:center;overflow:hidden">'
            f'<img src="{(ASSETS / "drums-setup.png").as_uri()}" style="height:{dh}px;max-width:100%;object-fit:contain"></div>')
    return mac_frame(t, w, h, comp, feed + rig_panel(t, w, "Camera", body))

MOVES = [("static", "Static"), ("dolly_in", "Dolly in"), ("dolly_out", "Dolly out"), ("orbit_left", "Orbit left"), ("crane_up", "Crane up"),
         ("handheld", "Handheld"), ("follow", "Follow"), ("whip_pan", "Whip pan"), ("rack_focus", "Rack focus"), ("drone_reveal", "Drone reveal"),
         ("truck_left", "Truck left"), ("tilt_up", "Tilt up"), ("micro_push", "Micro push"), ("steadicam", "Steadicam"), ("zoom_in", "Zoom in"),
         ("pan_right", "Pan right")]

def m_rig_move(t, w, h):
    comp = composer(inputs=SHOT_INPUTS, prompt=SHOT_PROMPT, rows=SHOT_ROWS, footer=footer_shot())
    feed = f'<div style="position:absolute;inset:0;opacity:.25;display:flex;flex-direction:column">{feed_bar()}<div style="padding:0 24px">{"".join(feed_today(200, feed_w(w), running=False, queued=False))}</div></div>'
    cats = "".join(f'<div class="quiet {"on" if c == "All" else ""}">{c}</div>' for c in ["All", "Push and pull", "Orbit", "Crane", "Handheld", "Pan and tilt", "Drone"])
    cols = 5 if w >= 1400 else 4
    gw = (w - (208 if w >= 1400 else 192) - (400 if w >= 1400 else 372) - 24 - 48 - (cols - 1) * 12) / cols
    tiles = ""
    for k, (f, n) in enumerate(MOVES[: cols * 3]):
        on = f == "dolly_in"
        tiles += (f'<div style="width:{gw:.0f}px"><div class="card" style="width:{gw:.0f}px;height:{gw * 9 / 16:.0f}px;{"outline:2px solid var(--accent);outline-offset:2px" if on else ""}">'
                  f'<img src="{src("moves/" + f + ".webp")}"></div><div class="row t13" style="margin-top:6px;gap:6px">{n}'
                  f'{"<span class=t11 style=margin-left:auto>In the prompt</span>" if on else ""}</div></div>')
    body = (f'<div class="row" style="gap:6px;margin-top:16px;margin-left:-10px">{cats}<div class="grow"></div>'
            f'<div class="row t13 ink2" style="gap:6px;border:1px solid var(--hair);border-radius:8px;height:28px;padding:0 10px;width:180px">{I("magnifying-glass", 14)}Search moves</div></div>'
            f'<div class="row t13" style="gap:12px;margin-top:14px;padding:10px 12px;border-radius:10px;background:var(--field)">'
            f'<span class="t13m">Dolly in</span><span class="ink2">Intensity</span>'
            f'<div style="width:160px;height:3px;border-radius:2px;background:var(--hair);position:relative"><div style="width:60%;height:3px;background:var(--ink);border-radius:2px"></div>'
            f'<div style="position:absolute;left:60%;top:-5px;width:13px;height:13px;border-radius:50%;background:var(--raised);border:1.5px solid var(--ink);margin-left:-6px"></div></div>'
            f'<span class="ink2">Gentle</span><div class="grow"></div><span class="t11">1 of 2 moves</span></div>'
            f'<div class="row" style="gap:12px;flex-wrap:wrap;margin-top:16px;align-items:flex-start;overflow:hidden">{tiles}</div>')
    return mac_frame(t, w, h, comp, feed + rig_panel(t, w, "Move", body))

PHOTO_TAKES = ["angles/mcu.webp", "angles/cu.webp", "angles/ms.webp", "angles/hip.webp", "lighting/window.webp", "lighting/soft_cross.webp",
               "lighting/studio_3pt.webp", "lighting/ring_light.webp", "angles/high.webp", "angles/eye.webp"]

def m_photo(t, w, h):
    rows = [("Camera", "Full frame, 85 mm"), ("Angle", "Eye level, close-up"), ("Light", "Soft cross"), ("Look", "Auto"), ("Style", "Fashion")]
    inputs = [(MODEL, MODEL_IMG, ""), ("Outfit", "genres/fashion.jpg", ""), ("Product", None, "Optional"), ("References", None, "Up to 3")]
    prompt = f'{chip(MODEL, "@")} sitting on a linen sofa by a tall window, relaxed, looking just past the camera.'
    foot = (f'<div class="row" style="gap:4px;margin:0 -10px 10px"><div class="quiet">4 photos {I("caret-down", 12)}</div>'
            f'<div class="quiet">4:5</div></div><div class="go">Generate · 4 photos · $0.46</div>')
    comp = composer("Photo", inputs, prompt, rows, footer=foot)
    hc = 200 if w >= 1400 else 170
    feed = (f'<div style="position:absolute;inset:0;display:flex;flex-direction:column">{feed_bar("All photos")}<div style="padding:0 24px">'
            f'{group("Today", justified([(lambda h, i=i: card(i, 4 / 5, h), 4 / 5) for i in PHOTO_TAKES[:6]], feed_w(w), hc))}'
            f'{group("Yesterday", justified([(lambda h, i=i: card(i, 4 / 5, h), 4 / 5) for i in PHOTO_TAKES[4:]], feed_w(w), hc))}</div></div>')
    items = [("Window portrait", "Soft side light, 85 mm, 4:5"), ("Studio clean", "Three-point light, white sweep"), ("Golden hour outdoors", "Warm backlight, 50 mm"),
             ("Mirror selfie", "Phone camera, bathroom light"), ("Product in hand", "Close-up, soft top light"), ("Editorial", "Hard flash, 35 mm film")]
    cells = "".join(f'<div style="padding:7px 10px;margin:0 -10px;border-radius:8px;{"background:var(--field)" if k == 0 else ""}">'
                    f'<div class="t13">{n}</div><div class="t11">{d}</div></div>' for k, (n, d) in enumerate(items))
    col = 400 if w >= 1400 else 372
    pop = (f'<div class="panel" style="position:absolute;left:{(208 if w >= 1400 else 192) + col - 288}px;top:48px;width:280px;padding:8px 20px 10px;z-index:5">'
           f'<div class="t11" style="padding:4px 0 4px">Photo presets</div>{cells}'
           f'<div class="t13m" style="padding:8px 0 2px;color:var(--accent)">Save current as preset</div></div>')
    return (mac_frame(t, w, h, comp, feed).replace('<div class="quiet">Presets</div>', '<div class="quiet on">Presets</div>', 1) + pop)

SCENES = [("Zelphira steps out of the café door, the street still wet.", "4 s", "Dolly out"),
          ("She stops at the corner under the neon sign and lights flicker.", "3 s", "Static"),
          ("Close on her face as she looks back over her shoulder.", "3 s", "Micro push")]

def m_storyboard(t, w, h):
    rows = [("Camera", "35 mm film, anamorphic"), ("Light", "Neon"), ("Look", "Golden warmth"), ("Style", "Drama, slow")]
    inputs = [(MODEL, MODEL_IMG, ""), ("Cast", None, "Up to 3")]
    foot = (f'<div class="row" style="gap:4px;margin:0 -10px 10px"><div class="quiet">HD {I("caret-down", 12)}</div>'
            f'<div class="quiet">9:16, 3 scenes, 10 s</div></div><div class="go">Generate · 3 shots · $1.95</div>')
    comp = composer("Storyboard", inputs, False, rows, footer=foot,
                    notice='<div class="t11" style="margin-top:8px">This rig is shared by every scene. A scene can set its own move.</div>')
    feed = f'<div style="position:absolute;inset:0;opacity:.25;display:flex;flex-direction:column">{feed_bar()}<div style="padding:0 24px">{"".join(feed_today(200, feed_w(w), running=False, queued=False))}</div></div>'
    scenes = ""
    for k, (p, ln, mv) in enumerate(SCENES):
        scenes += (f'<div class="row" style="gap:16px;padding:14px 0;border-bottom:1px solid var(--hair);align-items:flex-start">'
                   f'<div class="t13m ink2" style="width:56px;flex:none;padding-top:2px">Scene {k + 1}</div>'
                   f'<div class="t15 grow">{p.replace("Zelphira", chip("Zelphira", "@"))}</div>'
                   f'<div class="quiet" style="border:1px solid var(--hair)">{ln}</div><div class="quiet" style="border:1px solid var(--hair)">{chip(mv, "#")}</div>'
                   f'<div style="color:var(--ink2);padding-top:4px">{I("dots-six-vertical", 16)}</div></div>')
    body = (f'<div class="row" style="margin-bottom:6px"><div class="t17">Scenes</div><div class="grow"></div><div class="t11">10 s in all</div>'
            f'<div style="color:var(--ink2);margin-left:16px">{I("x", 18)}</div></div>{scenes}'
            f'<div class="row t13m" style="gap:8px;height:44px;color:var(--accent)">{I("plus", 16)}Add scene</div>')
    panel = f'<div class="panel" style="position:absolute;inset:12px;padding:16px 24px;z-index:3">{body}</div>'
    return mac_frame(t, w, h, comp, feed + panel)

def m_recast(t, w, h):
    rows = [("Look", "Auto")]
    inputs = [("Clip", "angles/two_shot.webp", "0:12")]
    foot = (f'<div class="row" style="gap:4px;margin:0 -10px 10px"><div class="quiet">HD {I("caret-down", 12)}</div>'
            f'<div class="quiet">12 s, original audio</div></div><div class="go">Generate · $1.10</div>')
    comp = composer("Recast", inputs, False, rows, footer=foot,
                    extra=f'<div class="row t13m" style="gap:6px;margin-top:12px;color:var(--accent)">{I("plus", 14)}Add direction</div>',
                    notice='<div class="t11" style="margin-top:6px">Camera, angle, move and light come from your clip.</div>')
    feed = f'<div style="position:absolute;inset:0;opacity:.25;display:flex;flex-direction:column">{feed_bar()}<div style="padding:0 24px">{"".join(feed_today(200, feed_w(w), running=False, queued=False))}</div></div>'
    side = 208 if w >= 1400 else 192
    col = 400 if w >= 1400 else 372
    area_w = w - side - col - 24 - 48
    fh = min(area_w * 9 / 16, h - 330)
    area_w = fh * 16 / 9
    faces = [(0.36, 0.30, "1"), (0.71, 0.33, "2")]
    marks = "".join(f'<div style="position:absolute;left:{x * 100}%;top:{y * 100}%;transform:translate(-50%,-50%);width:{fh * .2:.0f}px;height:{fh * .2:.0f}px;'
                    f'border-radius:50%;border:2px solid {"var(--accent)" if n == "1" else "#fff"}"></div>'
                    f'<div class="t11" style="position:absolute;left:{x * 100}%;top:{y * 100 - 14}%;transform:translate(-50%,-100%);background:{"var(--accent)" if n == "1" else "rgba(0,0,0,.6)"};'
                    f'color:#fff;border-radius:6px;padding:1px 6px">Person {n}</div>' for x, y, n in faces)
    mapping = (f'<div class="t13m" style="margin-bottom:10px">Who replaces whom</div>'
               f'<div class="row t13" style="gap:10px;height:52px;border-bottom:1px solid var(--hair)"><div class="ink2" style="width:64px">Person 1</div>'
               f'<div class="tile" style="width:32px;height:32px"><img src="{src(MODEL_IMG)}"></div>{MODEL}<div class="grow"></div>{I("caret-down", 12, "var(--ink2)")}</div>'
               f'<div class="row t13" style="gap:10px;height:52px;border-bottom:1px solid var(--hair)"><div class="ink2" style="width:64px">Person 2</div>'
               f'<span class="ink2">Keep as is</span><div class="grow"></div>{I("caret-down", 12, "var(--ink2)")}</div>'
               f'<div class="t11" style="margin-top:12px">Click a face on the first frame to add a person. Up to 4.</div>')
    body = (f'<div class="row" style="margin-bottom:14px"><div class="t17">People</div><div class="grow"></div><div style="color:var(--ink2)">{I("x", 18)}</div></div>'
            f'<div class="card" style="width:{area_w:.0f}px;height:{fh:.0f}px;border-radius:10px">'
            f'<img src="{src("angles/two_shot.webp")}">{marks}</div><div style="max-width:{area_w:.0f}px;margin-top:18px">{mapping}</div>')
    panel = f'<div class="panel" style="position:absolute;inset:12px;padding:16px 24px;z-index:3">{body}</div>'
    return mac_frame(t, w, h, comp, feed + panel)

# ---------------------------------------------------------------- phone
TABS = [("plus-square", "Create"), ("squares-four", "Library"), ("user", "Models"), ("user-circle", "You")]

def tabbar():
    cells = "".join(f'<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:2px;color:{"var(--ink)" if n == "Create" else "var(--ink2)"}">'
                    f'{I(i, 22)}<div class="t11" style="color:inherit">{n}</div></div>' for i, n in TABS)
    return f'<div class="row" style="position:absolute;left:0;right:0;bottom:0;height:76px;padding:8px 8px 22px;background:var(--canvas);border-top:1px solid var(--hair)">{cells}</div>'

def p_feed(t):
    cw = (390 - 32 - 8) / 2
    cards = [running_card("lighting/window.webp", 9 / 16, cw * 16 / 9, 62, "About 40 s left")] + [card(i, 9 / 16, cw * 16 / 9) for i, _ in TAKES_TODAY[:3]]
    grid = f'<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">{"".join(c.replace(f"width:{cw * 9 / 16 * 16 / 9:.0f}px", "width:100%") for c in cards)}</div>'
    bar = (f'<div style="position:absolute;left:12px;right:12px;bottom:88px;background:var(--raised);border:1px solid var(--hair);border-radius:16px;padding:10px 10px 10px 14px;'
           f'box-shadow:{t["float"] if t["float"] != "none" else "none"}">'
           f'<div style="width:32px;height:4px;border-radius:2px;background:var(--hair);margin:-4px auto 8px"></div>'
           f'<div class="t15" style="font-size:14px;line-height:20px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">{SHOT_PROMPT}</div>'
           f'<div class="row" style="gap:4px;margin-top:8px"><div class="quiet on" style="height:36px">Shot {I("caret-down", 12)}</div><div class="grow"></div>'
           f'<div class="go" style="height:40px;padding:0 16px">Generate · $0.65</div></div></div>')
    return f"""
<div class="row" style="height:52px;padding:0 16px"><div class="t17">Create</div><div class="grow"></div><div class="quiet" style="height:44px">Select</div></div>
<div style="padding:0 16px"><div class="glabel">Today</div>{grid}</div>{bar}{tabbar()}"""

def p_sheet(t):
    rows = "".join(f'<div class="row t13" style="height:48px;gap:12px;font-size:14px;border-bottom:1px solid var(--hair)"><div class="ink2" style="width:72px">{k}</div>'
                   f'<div class="grow" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{v}</div>{I("caret-right", 14, "var(--ink2)")}</div>' for k, v in WORKING_ROWS)
    tiles = "".join(f'<div style="width:62px"><div class="tile {"" if img else "empty"}" style="width:48px;height:48px">{"<img src=" + src(img) + ">" if img else I("plus", 16)}</div>'
                    f'<div class="t11" style="margin-top:5px;color:{"var(--ink)" if img else "var(--ink2)"};white-space:nowrap">{n}</div></div>' for n, img, _ in SHOT_INPUTS)
    return f"""
<div style="position:absolute;inset:0;opacity:.35">{p_feed(t)}</div><div style="position:absolute;inset:0;background:rgba(0,0,0,.35)"></div>
<div style="position:absolute;left:0;right:0;top:48px;bottom:0;background:var(--canvas);border-radius:20px 20px 0 0;display:flex;flex-direction:column">
  <div style="width:36px;height:4px;border-radius:2px;background:var(--hair);margin:8px auto 0"></div>
  <div class="row" style="height:52px;padding:0 16px"><div class="row t17" style="gap:6px">Shot {I("caret-down", 14, "var(--ink2)")}</div><div class="grow"></div><div class="quiet" style="height:44px">Presets</div></div>
  <div class="grow" style="padding:0 16px;overflow:hidden">
    <div class="row" style="gap:4px;align-items:flex-start">{tiles}</div>
    <div class="t15" style="margin-top:12px;background:var(--raised);border-radius:12px;padding:12px 14px">{SHOT_PROMPT}</div>
    <div style="margin-top:8px">{rows}</div>
    {rig_check("A 24 mm lens on a close-up stretches the face.")}
  </div>
  <div style="padding:10px 16px 24px;border-top:1px solid var(--hair)">
    <div class="row" style="gap:4px;margin:0 -10px 8px"><div class="quiet" style="height:40px">HD {I("caret-down", 12)}</div><div class="quiet" style="height:40px">9:16, 10 s, 1 take, sound on</div></div>
    <div class="go" style="height:48px;font-size:15px">Generate · $0.65</div></div>
</div>"""

def p_rig(t):
    bag = S.THEMES["b"]
    return f"""
<div style="position:absolute;inset:0;opacity:.3">{p_sheet(t)}</div><div style="position:absolute;inset:0;background:rgba(0,0,0,.45)"></div>
<div style="position:absolute;left:0;right:0;top:40px;bottom:0;background:#141414;color:#ECEAE5;border-radius:20px 20px 0 0;display:flex;flex-direction:column;--ink2:#A9A6A0;--hair:#2C3033;--field:#1E1F21">
  <div style="width:36px;height:4px;border-radius:2px;background:#2C3033;margin:8px auto 0"></div>
  <div class="row" style="height:56px;padding:0 8px 0 16px"><div class="t17">Camera</div><div class="grow"></div><div class="quiet" style="height:44px">Reset</div>
    <div style="width:44px;height:44px;display:grid;place-items:center">{I("x", 20)}</div></div>
  <div class="row t13" style="gap:8px;padding:0 16px 10px"><span style="width:7px;height:7px;border-radius:50%;background:#F2A93B"></span>35 mm film, anamorphic, 50 mm, f/2.8</div>
  <div class="grow" style="display:grid;place-items:start center;overflow:hidden"><img src="{(ASSETS / 'drums-setup.png').as_uri()}" style="width:358px"></div>
  <div style="padding:12px 16px 24px"><div class="go" style="height:48px;background:#F2A93B;color:#1A1205">Done</div></div>
</div>"""

# ---------------------------------------------------------------- render
MAC = [("1-empty", m_empty), ("2-working", m_working), ("3a-results-hover", m_results), ("3b-viewer", m_viewer), ("4a-rig-camera", m_rig_camera),
       ("4b-rig-move", m_rig_move), ("5-photo-presets", m_photo), ("6a-storyboard", m_storyboard), ("6b-recast", m_recast)]
PHONE = [("p1-feed", p_feed), ("p2-composer-sheet", p_sheet), ("p3-rig-camera", p_rig)]

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = []
    for k in ("c", "b"):
        for name, fn in MAC:
            for w, h in ((1440, 900), (1280, 800)):
                jobs.append((f"{name}-{w}-{k}", fn, k, w, h))
        for name, fn in PHONE:
            jobs.append((f"{name}-390-{k}", fn, k, 390, 844))
    only = os.environ.get("ONLY")
    if only: jobs = [j for j in jobs if only in j[0]]
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for name, fn, k, w, h in jobs:
            t = THEMES[k]
            body = fn(t, w, h) if fn.__code__.co_argcount == 3 else fn(t)
            f = Path(tmp) / f"{name}.html"; f.write_text(page(body, t, w, h))
            spec.append({"html": f.as_uri(), "png": str(OUT / f"{name}.png"), "w": w, "h": h})
        js = Path(tmp) / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(spec)], check=True, env={**os.environ, "NODE_PATH": root})
    if not only: contact_sheets()
    print(f"wrote {len(jobs)} mocks to {OUT}")

def contact_sheets():
    """One overview per theme: the nine Mac screens at 1440 (scaled) and the three phone screens."""
    from PIL import Image, ImageDraw
    for k in ("c", "b"):
        macs = [Image.open(OUT / f"{n}-1440-{k}.png").convert("RGB").resize((480, 300)) for n, _ in MAC]
        phones = [Image.open(OUT / f"{n}-390-{k}.png").convert("RGB").resize((139, 300)) for n, _ in PHONE]
        sheet = Image.new("RGB", (3 * 480 + 4 * 16, 4 * (300 + 26) + 16), THEMES[k]["canvas"])
        d = ImageDraw.Draw(sheet)
        tiles = [(n, im) for (n, _), im in zip(MAC, macs)] + [(n, im) for (n, _), im in zip(PHONE, phones)]
        for i, (n, im) in enumerate(tiles):
            if i < 9: x, y = 16 + (i % 3) * 496, 16 + (i // 3) * 326
            else: x, y = 16 + (i - 9) * 155, 16 + 3 * 326
            sheet.paste(im, (x, y)); d.text((x, y + 304), n, fill=THEMES[k]["ink2"])
        sheet.save(OUT / f"overview-{k}.png")

if __name__ == "__main__":
    main()

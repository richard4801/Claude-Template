"""Renders the cinematic AI Suite mocks (owner direction 2026-11-07: "a real sleek design", Higgsfield-like cinematic as a
direction, not a copy) for approval. The app around the Suite stays exactly as today (top bar, sidebar with Video suite
and its tools); only the Suite pages change. Writes plans/ai-suite-cinematic/<screen>-<size>-<theme>.png.

    PHOSPHOR=<@phosphor-icons/core package> python3 design/direction/cinematic.py

The Suite is always a dark cinematic surface (near-black, faint warm grain) in every app theme, like the camera bag; the
theme's accent marks selection, glow and Generate. Imagery is our own only: the Blender preview stills and loop posters,
the hardware renders and the app's drums.
"""
import json, os, subprocess, tempfile
from pathlib import Path

import render as R
import sleek as S

OUT = R.REPO / "plans" / "ai-suite-cinematic"
THEMES = dict(S.THEMES)
THEMES["d"] = dict(name="Creator Pop", canvas="#FFF6EC", raised="#FFFFFF", field="#FFEBD8", ink="#111111", ink2="#55504A", hair="#111111",
                   accent="#FF7EB6", action="#FF7EB6", onaction="#111111", scrim="rgba(17,17,17,.55)", display="Bricolage Grotesque", text="Figtree",
                   rc=16, rk=12, rp=999, float="0 12px 32px rgba(17,17,17,.14)", outline="none")
R.FONT_FILES["Bricolage Grotesque"] = [("bricolage_grotesque_700", 700), ("bricolage_grotesque_800", 800)]
R.FONT_FILES["Figtree"] = [("figtree_400", 400), ("figtree_500", 500), ("figtree_600", 600)]
for _k in THEMES: THEMES[_k] = dict(THEMES[_k], key=_k)
# The suite room shell var (--rad) is needed on the outer page too, for the rounded room.
PV, HW, ASSETS = R.PV, R.HW, Path(__file__).resolve().parent / "assets"
I = R.icon
def pv(p): return R.img(PV / p)
def hw(p): return R.img(HW / (p + ".webp"))

MODEL = "Zelphira"
MODEL_IMG = "angles/mcu.webp"
STAGE = "genres/epic.jpg"           # the latest take: the café at dusk, 16:9
PROMPT_TXT = "walks out of the café into the evening street, stops at the corner and looks back over her shoulder."

# Grain: a static SVG noise tile at low opacity (no animation).
GRAIN = ("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'>"
         "<feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 1  0 0 0 0 .9  0 0 0 0 .8  0 0 0 .55 0'/>"
         "</filter><rect width='160' height='160' filter='url(%23n)'/></svg>")

# ---------------------------------------------------------------- the Suite's "dark room", derived from each theme
# Owner constraint: it must not clash with the app's theme. Every colour below is a darkened or lightened shade of the
# theme's own tokens (ink, accent, link, raised, caution): no new hues.
def _rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def _hex(c): return "#%02X%02X%02X" % tuple(max(0, min(255, round(v))) for v in c)
def mix(a, b, t): A, B = _rgb(a), _rgb(b); return _hex(tuple(x + (y - x) * t for x, y in zip(A, B)))
def lum(h):
    def ch(v): v /= 255; return v / 12.92 if v <= .03928 else ((v + .055) / 1.055) ** 2.4
    r, g, b = _rgb(h); return .2126 * ch(r) + .7152 * ch(g) + .0722 * ch(b)
def contrast(a, b): x, y = sorted((lum(a), lum(b)), reverse=True); return (x + .05) / (y + .05)

ROLES = {  # android core DesignTokens.roles: canvas, raised, ink, accent, link, action, onAction, caution
    "a": dict(raised="#F8F5EF", ink="#141210", accent="#B5121B", link="#B5121B", caution="#8A5200"),
    "b": dict(raised="#17191B", ink="#ECEAE5", accent="#F2A93B", link="#F2A93B", caution="#F2C14E"),
    "c": dict(raised="#F3F0EA", ink="#23262A", accent="#4E6B45", link="#4E6B45", caution="#7F5418"),
    "d": dict(raised="#FFFFFF", ink="#111111", accent="#FF7EB6", link="#1F4BFF", caution="#9A4D00"),
}

def room(k):
    r = ROLES[k]
    if k == "b":   # Camera Body is already a dark room
        s0, w, acc, gen, ongen = "#0D0E0F", r["ink"], r["accent"], r["accent"], "#1A1205"
    elif k == "a":  # Editorial: its ink black, warmed a touch by its red; red as the mark
        s0 = mix(r["ink"], r["accent"], .05); w = r["raised"]; acc = mix(r["accent"], "#FFFFFF", .22); gen = r["accent"]; ongen = r["raised"]
    elif k == "c":  # Soft Tactile: deep olive charcoal from its ink and sage; the sage lifted for the mark
        s0 = mix(mix(r["ink"], r["accent"], .32), "#000000", .42); w = r["raised"]; acc = mix(r["accent"], "#D8E8C8", .45); gen = acc; ongen = mix(r["ink"], "#000000", .3)
    else:           # Creator Pop: its ink deepened with its cobalt; the pink as the mark
        s0 = mix(mix(r["ink"], r["link"], .22), "#000000", .25); w = r["raised"]; acc = r["accent"]; gen = r["accent"]; ongen = r["ink"]
    w2 = mix(w, s0, .36)
    warn = r["caution"] if k == "b" else mix(r["caution"], "#FFFFFF", .55)
    return dict(s0=s0, w=w, w2=w2, acc=acc, gen=gen, ongen=ongen, warn=warn, raised=r["raised"] if k != "b" else "#ECEAE5")

def rgba(h, a): r, g, b = _rgb(h); return f"rgba({r},{g},{b},{a})"

def contrast_report():
    rows = []
    for k in "abcd":
        R_ = room(k)
        rows.append((k, R_["s0"], round(contrast(R_["w"], R_["s0"]), 1), round(contrast(R_["w2"], R_["s0"]), 1), round(contrast(R_["ongen"], R_["gen"]), 1),
                     round(contrast(R_["acc"], R_["s0"]), 1), round(contrast(R_["warn"], R_["s0"]), 1)))
    return rows

def css(t):
    f = t["text"]
    k = t["key"]
    R_ = room(k)
    s0 = R_["s0"]
    return f"""
.suite{{--s0:{s0};--s1:{rgba(s0, .55)};--tint:{rgba(R_["raised"], .07)};--s2:{rgba(R_["w"], .06)};--sl:{rgba(R_["w"], .11)};--w:{R_["w"]};--w2:{R_["w2"]};
  --acc:{R_["acc"]};--gen:{R_["gen"]};--ongen:{R_["ongen"]};--warn:{R_["warn"]};--rad:{min(t["rc"], 20)}px;
  background:var(--s0);color:var(--w);position:relative;overflow:hidden;font-family:"{f}"}}
.suite .grain{{position:absolute;inset:0;background:url("{GRAIN}");opacity:.05;pointer-events:none;mix-blend-mode:screen;z-index:6}}
.c17{{font:600 17px/22px "{f}";letter-spacing:-.01em}} .c15{{font:400 15px/22px "{f}"}} .c13{{font:400 13px/18px "{f}"}} .c13m{{font:500 13px/18px "{f}"}}
.c11{{font:400 11px/14px "{f}";color:var(--w2)}} .w2{{color:var(--w2)}}
.glass{{background:linear-gradient(var(--tint),var(--tint)),var(--s1);backdrop-filter:blur(28px) saturate(1.2);-webkit-backdrop-filter:blur(28px) saturate(1.2);border:1px solid var(--sl);
  border-radius:var(--rad);box-shadow:0 24px 60px rgba(0,0,0,.45)}}
.ctile{{width:64px;height:64px;border-radius:12px;overflow:hidden;position:relative;background:var(--s2);flex:none}} .ctile img{{width:100%;height:100%;object-fit:cover;display:block}}
.ctile.empty{{border:1px dashed rgba(255,255,255,.22);background:transparent;display:grid;place-items:center;color:var(--w2)}}
.rchip{{border-radius:14px;background:var(--s2);border:1px solid var(--sl);overflow:hidden;flex:1;min-width:0;position:relative}}
.rchip .th{{height:58px;position:relative;overflow:hidden;background:var(--s0)}} .rchip .th img{{width:100%;height:100%;object-fit:cover;display:block}}
.rchip .th img.hw{{object-fit:contain;padding:4px}}
.rchip .tx{{padding:7px 10px 8px}} .rchip .tx .k{{font:400 11px/14px "{f}";color:var(--w2)}} .rchip .tx .v{{font:500 13px/16px "{f}";color:var(--w);height:32px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}}
.rchip.on{{border-color:var(--acc);box-shadow:0 0 0 1px var(--acc),0 0 22px color-mix(in srgb,var(--acc) 45%,transparent)}}
.pill{{height:32px;padding:0 12px;border-radius:10px;background:var(--s2);border:1px solid var(--sl);display:inline-flex;align-items:center;gap:7px;font:500 13px/18px "{f}";color:var(--w);white-space:nowrap}}
.pill .ic{{color:var(--w2);display:flex}}
.gen{{height:48px;padding:0 26px;border-radius:calc(var(--rad) * .7);background:var(--gen);color:var(--ongen);display:flex;align-items:center;justify-content:center;font:600 15px/18px "{f}";
  white-space:nowrap;box-shadow:0 0 28px color-mix(in srgb,var(--gen) 50%,transparent),inset 0 1px 0 rgba(255,255,255,.25)}}
.chipi{{background:rgba(255,255,255,.10);border-radius:7px;padding:1px 7px;font-weight:500;white-space:nowrap}} .chipi i{{font-style:normal;color:var(--acc)}}
.poster{{border-radius:10px;overflow:hidden;position:relative;flex:none;background:var(--s0)}} .poster img{{width:100%;height:100%;object-fit:cover;display:block}}
.poster.sel{{box-shadow:0 0 0 2px var(--acc),0 0 24px color-mix(in srgb,var(--acc) 50%,transparent)}}
.ghost{{height:30px;padding:0 10px;display:inline-flex;align-items:center;gap:6px;color:var(--w2);border-radius:9px;font:500 13px/18px "{f}";white-space:nowrap}}
.ghost.on{{background:var(--s2);color:var(--w)}}
"""

def page(body, t, w, h):
    return (f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{S.css(t)}{css(t)}</style>'
            f'<body style="width:{w}px;height:{h}px;overflow:hidden;position:relative">{body}</body>')

def chipi(txt, sig): return f'<span class="chipi"><i>{sig}</i>{txt}</span>'

# ---------------------------------------------------------------- the app chrome, as it is today
SIDE = [("house", "Home", "⌘1"), ("user", "Models", "⌘2"), ("video-camera", "Video suite", "⌘3")]
TOOLS = ["Shot", "Photo", "Character swap", "Storyboard", "Talking · lipsync", "UGC ad", "Extend & upscale", "Camera stage"]
AFTER = [("selection", "Templates", "⇧⌘T"), ("scissors", "Edit", ""), ("list", "Queue", "1"), ("squares-four", "Library", "⌘6"), ("paper-plane-tilt", "Posts", "⌘7")]

def topbar(t, w):
    dots = "".join(f'<span style="width:16px;height:16px;border-radius:50%;background:{c};display:inline-block;margin-left:10px;border:1.5px solid var(--hair)"></span>'
                   for c in ("#B5121B", "#F2A93B", "#4E6B45", "#FF7EB6"))
    return (f'<div class="row" style="height:52px;padding:0 20px 0 96px;border-bottom:1px solid var(--hair);background:var(--canvas)">'
            f'<div class="t13" style="width:180px">MUSE Studio</div><div class="grow" style="display:flex;justify-content:center">'
            f'<div class="row t13 ink2" style="gap:8px;width:420px;height:30px;border-radius:9px;background:var(--field);padding:0 12px">{I("magnifying-glass", 14)}Search or jump to…'
            f'<span class="grow"></span><span class="t11">⌘K</span></div></div><div class="t13" style="color:var(--ink)">Theme</div>{dots}'
            f'<div style="margin-left:22px">{I("user-circle", 20)}</div></div>')

def sidebar(tool):
    def row(icon, name, key, on=False, indent=0):
        return (f'<div class="row t13" style="gap:12px;height:34px;padding:0 10px 0 {10 + indent}px;border-radius:9px;{"background:var(--field);font-weight:500" if on else ""}">'
                f'{I(icon, 18) if icon else ""}<span>{name}</span><span class="grow"></span><span class="t11">{key}</span></div>')
    sub = "".join(f'<div class="row t13" style="height:28px;padding-left:34px;gap:8px;{"font-weight:500" if n == tool else "color:var(--ink2)"}">'
                  f'{"<span style=&quot;width:5px;height:5px;border-radius:50%;background:var(--accent)&quot;></span>" if n == tool else ""}{n}</div>' for n in TOOLS)
    sub = sub.replace("&quot;", '"')
    return (f'<div style="width:228px;flex:none;padding:18px 12px;background:var(--canvas);display:flex;flex-direction:column;gap:2px">'
            f'<div style="font:700 30px/34px \'{CUR["display"]}\';padding:4px 10px 18px">MUSE</div>'
            f'{"".join(row(i, n, k, on=(n == "Video suite")) for i, n, k in SIDE)}{sub}'
            f'{"".join(row(i, n, k) for i, n, k in AFTER)}<div class="t11" style="padding:14px 10px 0">Create</div></div>')

def app(t, w, h, tool, suite_html):
    return (f'<div style="display:flex;flex-direction:column;height:100%">{topbar(t, w)}<div class="row" style="flex:1;min-height:0;align-items:stretch">'
            f'{sidebar(tool)}<div class="grow" style="padding:8px 8px 8px 0;background:var(--canvas);display:flex">'
            f'<div class="suite grow" style="border-radius:{min(t["rc"], 20)}px;box-shadow:inset 0 0 0 1px var(--sl),0 1px 0 var(--sl)">{suite_html}<div class="grain"></div></div></div></div></div>')

# ---------------------------------------------------------------- the stage
def ambient(img, opacity=.55):
    """A blurred copy of the image behind everything: the stage's light spills into the UI."""
    return (f'<div style="position:absolute;inset:-80px;background:url({pv(img)}) center/cover;filter:blur(70px) saturate(1.3);opacity:{opacity}"></div>'
            f'<div style="position:absolute;inset:0;background:radial-gradient(ellipse at 50% 38%,transparent 0%,color-mix(in srgb,var(--s0) 55%,transparent) 60%,color-mix(in srgb,var(--s0) 92%,transparent) 100%)"></div>')

def stage_take(img, sw, sh, top):
    vign = 'box-shadow:inset 0 0 120px rgba(0,0,0,.55)'
    return (f'<div style="position:absolute;left:50%;top:{top}px;transform:translateX(-50%);width:{sw:.0f}px;height:{sh:.0f}px;border-radius:14px;overflow:hidden;'
            f'box-shadow:0 30px 80px rgba(0,0,0,.6)"><img src="{pv(img)}" style="width:100%;height:100%;object-fit:cover;display:block">'
            f'<div style="position:absolute;inset:0;{vign}"></div>'
            f'<div class="row c11" style="position:absolute;left:14px;bottom:12px;gap:10px;color:rgba(255,255,255,.85)">'
            f'<span style="display:flex;color:#fff">{I("play", 14)}</span>Take 3 of 3<span style="margin-left:6px">0:06 / 0:10</span></div></div>')

def stage_empty(sw, sh, top):
    corners = "".join(f'<div style="position:absolute;{v}:14px;{hz}:14px;width:18px;height:18px;border-{v}:1.5px solid rgba(255,255,255,.35);border-{hz}:1.5px solid rgba(255,255,255,.35)"></div>'
                      for v in ("top", "bottom") for hz in ("left", "right"))
    leak = ('<div style="position:absolute;right:-12%;top:-30%;width:70%;height:90%;background:radial-gradient(closest-side,rgba(255,170,90,.30),rgba(255,120,60,.10) 55%,transparent);filter:blur(10px)"></div>'
            '<div style="position:absolute;left:-10%;bottom:-40%;width:60%;height:80%;background:radial-gradient(closest-side,color-mix(in srgb,var(--acc) 22%,transparent),transparent);filter:blur(16px)"></div>')
    return (f'<div style="position:absolute;left:50%;top:{top}px;transform:translateX(-50%);width:{sw:.0f}px;height:{sh:.0f}px;border-radius:14px;overflow:hidden;'
            f'background:color-mix(in srgb,var(--s0) 85%,#000);border:1px solid rgba(255,255,255,.07)">{leak}{corners}'
            f'<div style="position:absolute;inset:0;display:grid;place-items:center;text-align:center"><div>'
            f'<div class="c15" style="color:var(--w)">Your first take plays here</div><div class="c13 w2" style="margin-top:4px">16:9, 10 s. Describe the shot below.</div></div></div></div>')

# ---------------------------------------------------------------- the dock
def tiles(items):
    out = []
    for name, img in items:
        box = f'<div class="ctile"><img src="{pv(img)}"></div>' if img else f'<div class="ctile empty">{I("plus", 18)}</div>'
        out.append(f'<div style="width:70px">{box}<div class="c11" style="margin-top:6px;color:{"var(--w)" if img else "var(--w2)"};white-space:nowrap">{name}</div></div>')
    return f'<div class="row" style="gap:8px;align-items:flex-start;flex:none">{"".join(out)}</div>'

def swatches(cols): return '<div style="position:absolute;left:0;right:0;bottom:0;height:8px;display:flex">' + "".join(f'<span style="flex:1;background:{c}"></span>' for c in cols) + "</div>"

def rchip(k, v, thumb, kind="still", on=False, extra=""):
    if thumb is None:
        th = f'<div style="position:absolute;inset:0;display:grid;place-items:center;color:var(--w2)">{I("aperture", 26)}</div>'
    elif kind == "hw":
        th = f'<img class="hw" src="{hw(thumb)}">'
    else:
        th = f'<img src="{pv(thumb)}">'
    return (f'<div class="rchip {"on" if on else ""}"><div class="th">{th}{extra}</div>'
            f'<div class="tx"><div class="k">{k}</div><div class="v" style="{"color:var(--w2)" if v == "Auto" else ""}">{v}</div></div></div>')

GOLDEN = ["#F1C27A", "#D98B3A", "#8C4A22", "#3B2A22", "#1C1A1F"]
SHOT_CHIPS = lambda sel=None: [rchip("Camera", "35 mm film", "body-05-film35", "hw", sel == "Camera"), rchip("Lens", "Anamorphic, 24&nbsp;mm", "lens-02-anamorphic", "hw", sel == "Lens"),
                               rchip("Light", "Window", "lighting/window.webp", on=sel == "Light"), rchip("Look", "Golden warmth", "lighting/golden_hour.webp", on=sel == "Look", extra=swatches(GOLDEN)),
                               rchip("Style", "Epic, slow", "genres/epic.jpg", on=sel == "Style"), rchip("Move", "Dolly in", "moves/dolly_in.webp", on=sel == "Move")]
AUTO_CHIPS = [rchip("Camera", "Auto", None), rchip("Lens", "Auto", None), rchip("Light", "Auto", None), rchip("Look", "Auto", None),
              rchip("Style", "Auto", None), rchip("Move", "Auto", None)]

def pills(items): return "".join(f'<div class="pill"><span class="ic">{I(i, 15)}</span>{v}</div>' for i, v in items)
SHOT_PILLS = [("gauge", "HD"), ("crop", "16:9"), ("timer", "10 s"), ("speaker-high", "Sound on"), ("copy", "1 take")]

def dock(dw, left, bottom, inputs, prompt, chips, pill_items, gen, check=None):
    prompt_html = prompt or '<span class="w2">Describe the shot. Type @ for a model, # for a camera move.</span>'
    check_html = (f'<div class="row c13" style="gap:8px;margin-top:10px;color:var(--warn)">{I("warning", 14)}<span style="color:var(--w)">{check}</span>'
                  f'<span class="c13m" style="color:var(--acc);margin-left:6px">Fix</span></div>') if check else ""
    return (f'<div class="glass" style="position:absolute;left:{left}px;bottom:{bottom}px;width:{dw}px;padding:16px 16px 14px;z-index:4">'
            f'<div class="row" style="gap:16px;align-items:flex-start">{tiles(inputs)}<div class="grow"><div class="c15" style="min-height:66px">{prompt_html}</div>{check_html}</div></div>'
            f'<div class="row" style="gap:8px;margin-top:14px">{"".join(chips)}</div>'
            f'<div class="row" style="gap:8px;margin-top:14px">{pills(pill_items)}<div class="grow"></div>{gen}</div></div>')

# ---------------------------------------------------------------- the takes rail
RAIL_TAKES = [("genres/epic.jpg", True), ("eras/2010s.jpg", False), ("eras/1990s.jpg", False), ("genres/documentary.jpg", False), ("lighting/blue_hour.webp", False),
              ("eras/2020s.jpg", False), ("genres/noir.jpg", False), ("lighting/golden_hour.webp", False)]

def rail(rw, running=True, empty=False, hover=2, takes=RAIL_TAKES, ar=16 / 9, label="Takes"):
    head = (f'<div class="row" style="height:44px"><div class="c13m">{label}</div><div class="grow"></div>'
            f'<div class="ghost on">All {I("caret-down", 12)}</div></div>')
    if empty:
        return (f'<div style="position:absolute;right:0;top:0;bottom:0;width:{rw}px;padding:8px 20px 0 8px;z-index:3">{head}'
                f'<div class="c13 w2" style="margin-top:8px">Takes land here as they render, newest on top.</div></div>')
    cols = 2 if ar < 1 else 1
    pw = (rw - 28 - (cols - 1) * 10) / cols
    ph = pw / ar
    cards = []
    if running:
        cards.append(f'<div class="poster" style="width:{pw}px;height:{ph:.0f}px"><img src="{pv("lighting/window.webp")}" style="filter:blur(10px) brightness(.6)">'
                     f'<div style="position:absolute;left:12px;right:12px;bottom:10px"><div class="row c13m">62%<span class="grow"></span><span class="c11" style="color:rgba(255,255,255,.75)">About 40 s left</span></div>'
                     f'<div style="height:3px;border-radius:2px;background:rgba(255,255,255,.2);margin-top:7px"><div style="height:3px;width:62%;border-radius:2px;background:var(--acc);box-shadow:0 0 10px var(--acc)"></div></div></div></div>')
    for k, (img, sel) in enumerate(takes):
        over = ""
        lift = ""
        if k == hover:
            acts = [("shuffle", "Vary"), ("arrow-line-right", "Extend"), ("frame-corners", "Use as start frame"), ("scissors", "Open in Edit"), ("dots-three", "More")]
            btn = "".join(f'<div title="{n}" style="width:28px;height:28px;border-radius:8px;display:grid;place-items:center;background:rgba(0,0,0,.5);'
                          f'backdrop-filter:blur(8px);color:#fff">{I(i, 15)}</div>' for i, n in acts)
            over = (f'<div style="position:absolute;inset:0;background:linear-gradient(transparent 40%,rgba(0,0,0,.7))"></div>'
                    f'<div class="row" style="position:absolute;left:8px;bottom:8px;gap:4px">{btn}</div>')
            lift = "transform:translateY(-3px);box-shadow:0 14px 30px rgba(0,0,0,.6)"
        cards.append(f'<div class="poster {"sel" if sel else ""}" style="width:{pw}px;height:{ph:.0f}px;{lift}"><img src="{pv(img)}">{over}</div>')
    return (f'<div style="position:absolute;right:0;top:0;bottom:0;width:{rw}px;padding:8px 20px 0 8px;z-index:3;overflow:hidden">{head}'
            f'<div style="display:flex;flex-wrap:wrap;gap:10px;margin-top:4px">{"".join(cards)}</div></div>'
            f'<div style="position:absolute;right:0;bottom:0;width:{rw}px;height:80px;background:linear-gradient(transparent,var(--s0));z-index:3"></div>')

def suite_header(tool, right="", rw=260):
    return (f'<div class="row" style="position:absolute;left:28px;top:16px;right:{rw + 28}px;height:36px;z-index:5">'
            f'<div class="row c17" style="gap:8px">{tool} {I("caret-down", 14, "var(--w2)")}</div><div class="grow"></div>{right}</div>')

# ---------------------------------------------------------------- Mac screens
def geometry(w, h):
    cw, ch = w - 228 - 8, h - 52 - 16              # the Suite room under the top bar, right of the sidebar (8 pt shell margin)
    rw = 260 if w >= 1400 else 228                 # the takes rail
    sw_area = cw - rw                              # stage + dock area
    dw = sw_area - 56
    dock_h = 328
    stage_top = 64
    stage_h = ch - dock_h - stage_top - 20 - 18     # the stage ends just above the dock
    stage_w = min(stage_h * 16 / 9, sw_area - 120)
    stage_h = stage_w * 9 / 16
    return cw, ch, rw, sw_area, dw, stage_w, stage_h, stage_top

def m_shot(t, w, h):
    cw, ch, rw, sa, dw, sw, sh, st = geometry(w, h)
    prompt = f'{chipi(MODEL, "@")} {PROMPT_TXT} {chipi("Dolly in", "#")}'
    gen = '<div class="gen">Generate · $0.65</div>'
    inside = (f'<div style="position:absolute;left:0;top:0;bottom:0;width:{sa}px">{ambient(STAGE)}{stage_take(STAGE, sw, sh, st)}'
              f'{dock(dw, 28, 20, [(MODEL, MODEL_IMG), ("Start frame", None), ("End frame", None)], prompt, SHOT_CHIPS("Lens"), SHOT_PILLS, gen, "A 24 mm lens on a close-up stretches the face.")}</div>'
              f'{rail(rw)}{suite_header("Shot", right=f"<div class=ghost>Presets</div>", rw=rw)}')
    return app(t, w, h, "Shot", inside)

def m_empty(t, w, h):
    cw, ch, rw, sa, dw, sw, sh, st = geometry(w, h)
    gen = '<div class="gen" style="opacity:.45;box-shadow:none">Generate</div>'
    inside = (f'<div style="position:absolute;left:0;top:0;bottom:0;width:{sa}px">{stage_empty(sw, sh, st)}'
              f'{dock(dw, 28, 20, [(MODEL, MODEL_IMG), ("Start frame", None), ("End frame", None)], None, AUTO_CHIPS, SHOT_PILLS, gen)}</div>'
              f'{rail(rw, empty=True)}{suite_header("Shot", right=f"<div class=ghost>Presets</div>", rw=rw)}')
    return app(t, w, h, "Shot", inside)

GENRES = [("genres/ugc.jpg", "UGC", "Authentic creator content"), ("genres/commercial.jpg", "Commercial", "Polished ad"), ("genres/drama.jpg", "Drama", "Quiet, emotional, close"),
          ("genres/epic.jpg", "Epic", "Wide, grand, sweeping"), ("genres/romance.jpg", "Romance", "Warm, soft, intimate"), ("genres/noir.jpg", "Noir", "Hard shadows, smoke"),
          ("genres/music_video.jpg", "Music video", "Bold colour, stylised")]
ERAS = ["1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s", "Future"]

def m_rig(t, w, h):
    """The Style picker over the Suite: genre on an arc carousel, the era ruler and tempo under it."""
    cw, ch, rw, sa, dw, sw, sh, st = geometry(w, h)
    prompt = f'{chipi(MODEL, "@")} {PROMPT_TXT} {chipi("Dolly in", "#")}'
    base = (f'<div style="position:absolute;left:0;top:0;bottom:0;width:{sa}px">{ambient(STAGE)}{stage_take(STAGE, sw, sh, st)}'
            f'{dock(dw, 28, 20, [(MODEL, MODEL_IMG), ("Start frame", None), ("End frame", None)], prompt, SHOT_CHIPS("Style"), SHOT_PILLS, "<div class=gen>Generate · $0.65</div>")}</div>'
            f'{rail(rw, hover=None)}{suite_header("Shot")}')
    mw, mh = cw - 120, ch - 80
    cx = mw / 2
    cards = ""
    sel = 3
    cbase = min(300, (mh - 250 - 70 - 64) / 1.25)   # the centre card and its caption fit above the era ruler
    k_ = cbase / 300
    for k, (img, name, cap) in enumerate(GENRES):
        d = k - sel
        sc = [1, .78, .62, .5][min(abs(d), 3)]
        cw_ = cbase * sc
        x = cx + (d * (210 if abs(d) == 1 else 190) + (40 * d if abs(d) > 1 else 0)) * k_ - cw_ / 2
        y = 70 + abs(d) ** 1.6 * 26
        rot = d * 7
        op = [1, .8, .5, .3][min(abs(d), 3)]
        glow = "box-shadow:0 0 0 2px var(--acc),0 0 40px color-mix(in srgb,var(--acc) 50%,transparent);" if d == 0 else "box-shadow:0 18px 40px rgba(0,0,0,.6);"
        cards += (f'<div style="position:absolute;left:{x:.0f}px;top:{y:.0f}px;width:{cw_:.0f}px;transform:rotate({rot}deg);transform-origin:50% 160%;opacity:{op};z-index:{10 - abs(d)}">'
                  f'<div class="poster" style="width:{cw_:.0f}px;height:{cw_ * 1.25:.0f}px;border-radius:14px;{glow}"><img src="{pv(img)}"></div>'
                  + (f'<div style="text-align:center;margin-top:12px"><div class="c17">{name}</div><div class="c13 w2">{cap}</div></div>' if d == 0 else "")
                  + '</div>')
    ticks = ""
    for k, e in enumerate(ERAS):
        on = e == "2010s"
        ticks += (f'<div style="flex:1;text-align:center"><div style="height:{18 if on else 10}px;width:{2 if on else 1}px;margin:0 auto;background:{"var(--acc)" if on else "rgba(255,255,255,.35)"};'
                  f'{"box-shadow:0 0 10px var(--acc)" if on else ""}"></div><div class="c11" style="margin-top:6px;color:{"var(--w)" if on else "var(--w2)"}">{e}</div></div>')
    tempos = "".join(f'<div class="ghost {"on" if n == "Slow" else ""}" style="height:32px;{"box-shadow:0 0 0 1px var(--acc)" if n == "Slow" else ""}">{n}</div>'
                     for n in ["Auto", "Slow", "Calm", "Steady", "Brisk", "Frenetic"])
    tabs = "".join(f'<div class="c13m" style="padding:6px 0;{"color:var(--w);border-bottom:2px solid var(--acc)" if n == "Style" else "color:var(--w2)"}">{n}</div>'
                   for n in ["Camera", "Angle", "Move", "Light", "Look", "Style"])
    saved = "".join(f'<div class="ghost" style="border:1px solid var(--sl)">{n}</div>' for n in ["Café dusk", "Night street", "Studio clean"])
    modal = (f'<div style="position:absolute;inset:0;background:color-mix(in srgb,var(--s0) 70%,transparent);z-index:7"></div>'
             f'<div class="glass" style="position:absolute;left:60px;top:40px;width:{mw}px;height:{mh}px;z-index:8;background:color-mix(in srgb,var(--s0) 88%,transparent);padding:18px 24px;overflow:hidden">'
             f'<div class="row" style="gap:22px;border-bottom:1px solid var(--sl)">{tabs}<div class="grow"></div>'
             f'<div class="c11" style="margin-right:6px">Saved rigs</div>{saved}<div style="color:var(--w2);margin-left:14px">{I("x", 18)}</div></div>'
             f'<div class="c13 w2" style="margin-top:14px">Genre</div>'
             f'<div style="position:relative;height:{mh - 250}px">{cards}</div>'
             f'<div style="position:absolute;left:24px;right:24px;bottom:74px"><div class="row" style="align-items:flex-start"><div class="c13 w2" style="width:70px;margin-top:-8px">Era</div>'
             f'<div class="row grow" style="border-top:1px solid var(--sl);padding-top:0;align-items:flex-start">{ticks}</div></div></div>'
             f'<div class="row" style="position:absolute;left:24px;right:24px;bottom:20px;gap:6px"><div class="c13 w2" style="width:70px">Tempo</div>{tempos}'
             f'<div class="grow"></div><div class="c13 w2">Epic, 2010s, slow</div></div></div>')
    return app(t, w, h, "Shot", base + modal)

def m_camera(t, w, h):
    """The Camera picker over the Suite: the approved drums, as the app draws them."""
    cw, ch, rw, sa, dw, sw, sh, st = geometry(w, h)
    base = (f'<div style="position:absolute;left:0;top:0;bottom:0;width:{sa}px">{ambient(STAGE)}{stage_take(STAGE, sw, sh, st)}</div>{rail(rw, hover=None)}{suite_header("Shot")}')
    mw, mh = 700, ch - 80
    tabs = "".join(f'<div class="c13m" style="padding:6px 0;{"color:var(--w);border-bottom:2px solid var(--acc)" if n == "Camera" else "color:var(--w2)"}">{n}</div>'
                   for n in ["Camera", "Angle", "Move", "Light", "Look", "Style"])
    modal = (f'<div style="position:absolute;inset:0;background:color-mix(in srgb,var(--s0) 70%,transparent);z-index:7"></div>'
             f'<div class="glass" style="position:absolute;left:{(cw - mw) / 2:.0f}px;top:40px;width:{mw}px;height:{mh}px;z-index:8;background:color-mix(in srgb,var(--s0) 92%,transparent);padding:18px 24px;display:flex;flex-direction:column">'
             f'<div class="row" style="gap:22px;border-bottom:1px solid var(--sl)">{tabs}<div class="grow"></div><div style="color:var(--w2)">{I("x", 18)}</div></div>'
             f'<div class="row c13" style="gap:8px;margin-top:14px"><span style="width:7px;height:7px;border-radius:50%;background:#F2A93B"></span>35 mm film, anamorphic, 50 mm, f/2.8'
             f'<div class="grow"></div><div class="ghost">Reset</div></div>'
             f'<div style="flex:1;min-height:0;display:grid;place-items:center;margin-top:8px"><img src="{(ASSETS / "drums-setup.png").as_uri()}" style="height:{mh - 130}px"></div></div>')
    return app(t, w, h, "Shot", base + modal)

PHOTOS = ["angles/mcu.webp", "angles/cu.webp", "angles/ms.webp", "angles/hip.webp", "lighting/soft_cross.webp", "lighting/window.webp", "lighting/studio_3pt.webp", "angles/eye.webp"]

def m_photo(t, w, h):
    cw, ch, rw, sa, dw, sw, sh, st = geometry(w, h)
    # The latest set of four on the stage: the picked one large, the other three beside it.
    big_h = sh
    big_w = big_h * 4 / 5
    small_h = (big_h - 2 * 10) / 3
    small_w = small_h * 4 / 5
    group_w = big_w + 10 + small_w
    x0 = (sa - group_w) / 2
    stage = (f'<div style="position:absolute;left:{x0:.0f}px;top:{st}px;width:{big_w:.0f}px;height:{big_h:.0f}px;border-radius:14px;overflow:hidden;box-shadow:0 0 0 2px var(--acc),0 30px 80px rgba(0,0,0,.6)">'
             f'<img src="{pv("angles/mcu.webp")}" style="width:100%;height:100%;object-fit:cover"><div style="position:absolute;inset:0;box-shadow:inset 0 0 90px rgba(0,0,0,.5)"></div></div>'
             + "".join(f'<div class="poster" style="position:absolute;left:{x0 + big_w + 10:.0f}px;top:{st + k * (small_h + 10):.0f}px;width:{small_w:.0f}px;height:{small_h:.0f}px"><img src="{pv(i)}"></div>'
                       for k, i in enumerate(["angles/cu.webp", "lighting/soft_cross.webp", "angles/hip.webp"])))
    chips = [rchip("Camera", "Full frame", "body-04-fullframe", "hw"), rchip("Lens", "85 mm", "lens-01-clean-prime", "hw"), rchip("Light", "Soft cross", "lighting/soft_cross.webp"),
             rchip("Look", "Naturalistic", None), rchip("Style", "Fashion", "genres/fashion.jpg")]
    pills_ = [("images", "4 photos"), ("crop", "4:5"), ("gauge", "HD")]
    prompt = f'{chipi(MODEL, "@")} sitting on a linen sofa by a tall window, relaxed, looking just past the camera.'
    inside = (f'<div style="position:absolute;left:0;top:0;bottom:0;width:{sa}px">{ambient("angles/mcu.webp", .4)}{stage}'
              f'{dock(dw, 28, 20, [(MODEL, MODEL_IMG), ("Outfit", "genres/fashion.jpg"), ("Product", None), ("References", None)], prompt, chips, pills_, "<div class=gen>Generate · 4 photos · $0.46</div>")}</div>'
              f'{rail(rw, running=False, hover=None, takes=[(p, k == 0) for k, p in enumerate(PHOTOS)], ar=4 / 5, label="Photos")}'
              f'{suite_header("Photo", right="<div class=ghost>Presets</div>", rw=rw)}')
    return app(t, w, h, "Photo", inside)

# ---------------------------------------------------------------- phone
def p_shot(t):
    st, sh = 64, 330 + 24
    chips = SHOT_CHIPS("Lens")
    row = "".join(f'<div style="width:104px;flex:none;display:flex">{c}</div>' for c in chips)
    pills_ = "".join(f'<div class="pill" style="height:36px"><span class="ic">{I(i, 15)}</span>{v}</div>' for i, v in SHOT_PILLS[:3])
    return f"""
<div class="suite" style="position:absolute;inset:0">{ambient(STAGE, .5)}
  <div class="row" style="position:absolute;left:4px;right:4px;top:6px;height:48px;z-index:5"><div style="width:44px;height:44px;display:grid;place-items:center">{I("caret-left", 22)}</div>
    <div class="grow" style="display:flex;justify-content:center"><div class="row c17" style="gap:6px">Shot {I("caret-down", 14, "var(--w2)")}</div></div>
    <div style="width:44px;height:44px;display:grid;place-items:center">{I("film-strip", 20)}</div></div>
  <div style="position:absolute;left:12px;right:12px;top:{st}px;height:{sh - 24:.0f}px;border-radius:14px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.6)">
    <img src="{pv(STAGE)}" style="width:100%;height:100%;object-fit:cover"><div style="position:absolute;inset:0;box-shadow:inset 0 0 80px rgba(0,0,0,.5)"></div>
    <div class="row c11" style="position:absolute;left:12px;bottom:10px;gap:8px;color:rgba(255,255,255,.85)">{I("play", 13)}Take 3 of 3</div></div>
  <div class="row" style="position:absolute;left:12px;right:0;top:{st + sh - 12:.0f}px;gap:8px;overflow:hidden">
    {"".join(f'<div class="poster {"sel" if k == 0 else ""}" style="width:58px;height:33px;border-radius:7px"><img src="{pv(i)}"></div>' for k, (i, _) in enumerate(RAIL_TAKES[:6]))}</div>
  <div class="glass" style="position:absolute;left:8px;right:8px;bottom:12px;padding:14px 12px 12px;z-index:4">
    <div class="c15" style="font-size:14px;line-height:21px">{chipi(MODEL, "@")} {PROMPT_TXT} {chipi("Dolly in", "#")}</div>
    <div class="row c13" style="gap:8px;margin-top:8px;color:var(--warn)">{I("warning", 14)}<span style="color:var(--w)">24 mm on a close-up stretches the face.</span><span class="c13m" style="color:var(--acc)">Fix</span></div>
    <div class="row" style="gap:8px;margin-top:12px;overflow:hidden;margin-right:-12px">{row}</div>
    <div class="row" style="gap:6px;margin-top:12px;overflow:hidden">{pills_}</div>
    <div class="gen" style="margin-top:12px">Generate · $0.65</div>
  </div><div class="grain"></div></div>"""

# ---------------------------------------------------------------- render
MAC = [("1-shot", m_shot), ("2-empty", m_empty), ("3-rig-style", m_rig), ("4-rig-camera", m_camera), ("5-photo", m_photo)]
PHONE = [("p1-shot", p_shot)]

CUR = THEMES["c"]

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = []
    for k in ("a", "b", "c", "d"):
        for name, fn in MAC:
            for w, h in ((1440, 900), (1280, 800)) if k == "c" else ((1440, 900),):
                jobs.append((f"{name}-{w}-{k}", fn, k, w, h))
        for name, fn in PHONE:
            jobs.append((f"{name}-390-{k}", fn, k, 390, 844))
    only = os.environ.get("ONLY")
    if only: jobs = [j for j in jobs if only in j[0]]
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for name, fn, k, w, h in jobs:
            t = THEMES[k]
            global CUR; CUR = t
            body = fn(t, w, h) if fn.__code__.co_argcount == 3 else fn(t)
            f = Path(tmp) / f"{name}.html"; f.write_text(page(body, t, w, h))
            spec.append({"html": f.as_uri(), "png": str(OUT / f"{name}.png"), "w": w, "h": h})
        js = Path(tmp) / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(400); await p.screenshot({ path: j.png }); await p.close(); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(spec)], check=True, env={**os.environ, "NODE_PATH": root})
    print(f"wrote {len(jobs)} mocks to {OUT}")

if __name__ == "__main__":
    main()

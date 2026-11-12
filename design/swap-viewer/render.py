"""Mockups for New Swap and the take viewer (plans/swap-viewer-design.md), for the owner's approval.

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1 package> python3 design/swap-viewer/render.py

Writes plans/design/swap-viewer/*.png. Reuses the design-direction tokens, fonts and icon helper
(design/direction/render.py). Camera Body (B) is the dark theme, Editorial (A) the light one.
Platform skins are generic drawings of each layout (grey bars for text, Phosphor glyphs for buttons): no logos,
no brand colours, no platform type.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "direction"))
import render as R  # noqa: E402

REPO = R.REPO
OUT = REPO / "plans" / "design" / "swap-viewer"
PV = R.PV
T = R.THEMES
icon, img = R.icon, R.img

# 9:16 crops of the Blender previews (design/previews), so a portrait take is truly 9:16 in every frame.
PORTRAIT = Path(__file__).resolve().parent / "assets/portrait-a.jpg"
PORTRAIT2 = Path(__file__).resolve().parent / "assets/portrait-b.jpg"
LANDSCAPE = PV / "genres/fashion.jpg"
LIB = ["moves/follow.webp", "angles/cowboy.webp", "moves/selfie.webp", "angles/ms.webp", "moves/orbit_left.webp",
       "angles/hip.webp", "moves/lead.webp", "angles/low.webp", "moves/dolly_in.webp", "angles/full.webp"]


def extra_css(t):
    f = t["text"]
    return f"""
.seg{{display:inline-flex;background:var(--field);border-radius:var(--rk);padding:2px;gap:2px}}
.seg>div{{height:28px;padding:0 12px;display:flex;align-items:center;border-radius:calc(var(--rk) - 2px);font:500 13px/18px "{f}";color:var(--ink2);white-space:nowrap}}
.seg>.on{{background:var(--raised);color:var(--ink);box-shadow:inset 0 0 0 1px var(--hair)}}
.sw{{width:32px;height:18px;border-radius:9px;background:var(--field);position:relative;flex:none;box-shadow:inset 0 0 0 1px var(--hair)}}
.sw::after{{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:7px;background:var(--ink2)}}
.sw.on{{background:var(--accent);box-shadow:none}} .sw.on::after{{left:16px;background:var(--onaction)}}
.field{{background:var(--field);border-radius:var(--rk);min-height:36px;padding:8px 12px;font:400 14px/20px "{f}";color:var(--ink)}}
.field.ph{{color:var(--ink2)}}
.quiet{{height:32px;padding:0 12px;display:inline-flex;align-items:center;gap:6px;border-radius:var(--rk);font:500 13px/18px "{f}";color:var(--ink);box-shadow:inset 0 0 0 1px var(--hair);white-space:nowrap}}
.link{{font:500 13px/18px "{f}";color:var(--accent);white-space:nowrap}}
.go{{background:var(--action);color:var(--onaction);border-radius:var(--rk);height:40px;padding:0 20px;display:flex;align-items:center;font:600 14px/18px "{f}";white-space:nowrap}}
.go.off{{background:var(--field);color:var(--ink2)}}
.cap{{font:400 13px/18px "{f}";color:var(--ink2)}} .mic{{font:500 11px/14px "{f}"}}
.b13{{font:400 13px/18px "{f}"}} .l13{{font:500 13px/18px "{f}"}}
.bar{{background:rgba(255,255,255,.85);border-radius:3px;height:8px}}
.bar.dim{{background:rgba(255,255,255,.55)}}
.zone{{position:absolute;background:repeating-linear-gradient(135deg,rgba(255,255,255,.20) 0 6px,rgba(255,255,255,0) 6px 12px);}}
.ann{{font:500 11px/14px "{f}";color:var(--ink2)}}
"""


def page(body, t, w, h):
    return (f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{extra_css(t)}</style>'
            f'<body style="width:{w}px;height:{h}px;overflow:hidden;position:relative">{body}</body>')


def mac_shell(t, content, active="Suite"):
    nav = [("house", "Home"), ("user", "Models"), ("video-camera", "Suite"), ("film-strip", "Edit"), ("squares-four", "Library"), ("stack", "Queue")]
    side = "".join(f'<div class="row gap3" style="height:32px;padding:0 10px;border-radius:var(--rk);'
                   f'{"background:var(--field);color:var(--ink)" if l == active else "color:var(--ink2)"}">{icon(i, 18)}<div class="l13">{l}</div></div>'
                   for i, l in nav)
    lights = "".join(f'<div style="width:12px;height:12px;border-radius:6px;background:var(--field);box-shadow:inset 0 0 0 1px var(--hair)"></div>' for _ in range(3))
    return f"""
<div class="row" style="height:100%;align-items:stretch">
 <div style="width:200px;flex:none;padding:14px 10px;border-right:1px solid var(--hair);position:relative;background:var(--canvas)">
   <div class="row gap2" style="padding:0 6px 18px">{lights}</div>
   <div class="label" style="font-family:'{t['display']}';font-size:18px;padding:0 10px 14px">MUSE</div>{side}
   <div class="cap" style="position:absolute;bottom:18px;left:20px">$41.17 left</div></div>
 <div class="grow" style="display:flex;flex-direction:column;min-width:0">{content}</div>
</div>"""


# ------------------------------------------------------------------ New Swap (Mac)

def toggle_row(name, on, value, field="", note=""):
    head = (f'<div class="row gap3" style="min-height:44px"><div class="grow"><div class="label">{name}</div>'
            f'<div class="cap" style="font-size:12px;line-height:16px">{value}</div></div><div class="sw{" on" if on else ""}"></div></div>')
    body = f'<div style="display:flex;flex-direction:column;gap:8px;padding:0 0 4px">{field}{f"<div class=cap>{note}</div>" if note else ""}</div>' if on and field else ""
    return f'<div style="display:flex;flex-direction:column;gap:8px">{head}{body}</div>'


def her_chip(t, empty=False):
    face = f'<div style="width:36px;height:36px;border-radius:var(--rp);overflow:hidden;flex:none"><img src="{img(PV/"angles/mcu.webp")}" style="width:100%;height:100%;object-fit:cover"></div>'
    return (f'<div class="row gap3" style="background:var(--field);border-radius:var(--rk);padding:6px 12px 6px 6px">{face}'
            f'<div class="grow"><div class="l13">Demo model</div><div class="cap" style="font-size:12px;line-height:16px">Face and figure from her pictures</div></div>'
            f'<div class="link">Change</div></div>')


def rail(t, filled):
    if filled:
        bg = ('<div class="seg"><div class="on">Describe</div><div>Photo</div></div>'
              '<div class="field">A rooftop at golden hour, city lights behind her</div>')
        rows = [toggle_row("Background", True, "Describe the new place", bg),
                toggle_row("Outfit", False, "Kept from the clip"),
                toggle_row("Character", True, "Her, with the figure lock", her_chip(t) + '<div class="link" style="color:var(--ink2)">Face swap from a photo instead</div>'),
                toggle_row("Look &amp; light", True, "Time of day, light, grade", '<div class="field">Warmer, soft window light</div>')]
    else:
        rows = [toggle_row("Background", False, "Kept from the clip"),
                toggle_row("Outfit", False, "Kept from the clip"),
                toggle_row("Character", True, "Her, with the figure lock", her_chip(t) + '<div class="link" style="color:var(--ink2)">Face swap from a photo instead</div>'),
                toggle_row("Look &amp; light", False, "Kept from the clip")]
    sep = '<div style="height:12px"></div>'
    return f"""
<div style="width:352px;flex:none;display:flex;flex-direction:column">
  <div class="heading">Changes</div>
  <div class="cap" style="margin-top:4px">Switch on what should change. Write only the change.</div>
  <div style="margin-top:16px">{sep.join(rows)}</div>
  <div class="grow"></div>
  <div class="cap">Kept from the clip: motion, camera, timing and sound.</div>
</div>"""


def trim_strip(width):
    n = 12
    cw = width / n
    frames = "".join(f'<img src="{img(PV/LIB[i % len(LIB)])}" style="width:{cw:.1f}px;height:56px;object-fit:cover;flex:none;opacity:{1 if 1 <= i <= 5 else .35}">' for i in range(n))
    a, b = cw * 1, cw * 6
    handle = lambda x: f'<div style="position:absolute;top:-2px;left:{x - 4:.0f}px;width:8px;height:60px;border-radius:3px;background:var(--accent)"></div>'
    return f"""
<div style="width:{width}px">
  <div style="position:relative;height:56px;border-radius:var(--rp);overflow:visible">
    <div class="row" style="height:56px;border-radius:var(--rp);overflow:hidden">{frames}</div>
    <div style="position:absolute;top:0;left:{a:.0f}px;width:{b - a:.0f}px;height:56px;box-shadow:inset 0 2px 0 var(--accent),inset 0 -2px 0 var(--accent)"></div>
    {handle(a)}{handle(b)}
  </div>
  <div class="row" style="margin-top:8px"><div class="cap grow">Uses 0:02–0:12 of 0:24, 10 s. Wan 2.7 Edit takes up to 10 s.</div><div class="link">Use the whole clip</div></div>
</div>"""


def bottom_bar(t, filled, model_open=False):
    if filled:
        left = (f'<div class="row gap2 quiet" style="box-shadow:{"inset 0 0 0 1px var(--accent)" if model_open else "inset 0 0 0 1px var(--hair)"}">'
                f'Auto · Wan 2.7 Edit · Replicate {icon("caret-up" if model_open else "caret-down", 16, "var(--ink2)")}</div>'
                f'<div class="cap">Background and light only, keeps the sound, 1080p</div>')
        right = '<div class="cap" style="text-align:right">10 s, 1080p</div><div class="go">Generate · $1.00</div>'
    else:
        left = f'<div class="quiet" style="color:var(--ink2)">Auto {icon("caret-down", 16, "var(--ink2)")}</div><div class="cap">The model and price show once a video is added</div>'
        right = '<div class="go off">Generate</div>'
    return f"""
<div class="row gap3" style="height:72px;padding:0 32px;border-top:1px solid var(--hair);flex:none">
  <div class="row gap2 quiet">{icon("speaker-high", 16)} Clip sound</div>
  {left}<div class="grow"></div>{right}
</div>"""


def header(title, extra=""):
    return f"""
<div class="row gap4" style="height:64px;padding:0 32px;flex:none">
  <div class="title">{title}</div>{extra}<div class="grow"></div>
  <div class="row gap2 cap" style="color:var(--ink)">{icon("squares-four", 18)} Takes</div>
</div>"""


SWITCH = '<div class="seg"><div>Swap</div><div class="on">New Swap (beta)</div></div>'


def newswap_mac(t, filled=True, model_open=False):
    if filled:
        fh = 500
        fw = fh * 9 / 16
        stage = f"""
<div class="grow" style="display:flex;flex-direction:column;align-items:center;min-width:0">
  <div class="row gap3" style="width:600px;height:32px">
    <div class="l13 grow">beach_walk.mp4</div><div class="cap">0:24, 1080 × 1920</div>
    <div class="quiet">Replace {icon("caret-down", 16, "var(--ink2)")}</div></div>
  <div class="media" style="margin-top:12px;width:{fw:.0f}px;height:{fh}px;border-radius:var(--rc)"><img src="{img(PORTRAIT)}"></div>
  <div style="margin-top:20px">{trim_strip(600)}</div>
</div>"""
    else:
        tiles = "".join(f'<div style="width:104px;flex:none"><div class="media" style="width:104px;height:185px"><img src="{img(PV/p)}">'
                        f'<div class="scrimtag">{d}</div></div><div class="cap" style="margin-top:6px;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{n}</div></div>'
                        for p, d, n in zip(LIB, ["0:08", "0:10", "0:12", "0:06", "0:24", "0:10", "0:15", "0:09", "0:07", "0:10"],
                                           ["Café, golden hour", "Street, dusk", "Selfie, mirror", "Studio white", "Beach walk",
                                            "Hallway turn", "Market lead", "Low angle", "Dolly in", "Full body"]))
        stage = f"""
<div class="grow" style="display:flex;flex-direction:column;min-width:0">
  <div class="heading">Add the video to remix</div>
  <div class="cap" style="margin-top:4px">Pick a take from your Library, upload a file, or paste a link. You can also drop a file anywhere here.</div>
  <div class="row gap3" style="margin-top:16px"><div class="seg"><div class="on">Library</div><div>Upload</div><div>Paste link</div></div>
    <div class="grow"></div><div class="row gap2 cap">{icon("magnifying-glass", 16)} Search takes</div></div>
  <div style="margin-top:16px;display:flex;flex-wrap:wrap;gap:24px 16px">{tiles}</div>
</div>"""
    pop = model_menu(t) if model_open else ""
    content = header("Swap", SWITCH) + f"""
<div class="row" style="flex:1;min-height:0;padding:8px 32px 24px;gap:32px;align-items:stretch">{stage}{rail(t, filled)}</div>
{bottom_bar(t, filled, model_open)}{pop}"""
    return mac_shell(t, content)


def model_menu(t):
    groups = [
        ("Edits the clip", [("Wan 2.7 Edit · Replicate", "$1.00", "Up to 10 s, 1080p, keeps the sound", "auto"),
                            ("Kling O1 Edit · Replicate", "$1.26", "Up to 10 s, 720p", ""),
                            ("Genjutsu Light · Higgsfield", "$2.00", "Up to 15 s, 720p, best for her face", ""),
                            ("Seedance 2.5 · fal", "$1.40", "Up to 12 s, 1080p, not tested yet", "")]),
        ("Follows the clip as a reference", [("MiniMax H3 · Replicate", "$1.10", "Motion and framing close, not exact", ""),
                                             ("Wan 3.0 · Higgsfield", "Live", "Priced by the provider when you pick it", "")]),
        ("Uses frames from the clip", [("Veo 3.1 Lite · Google", "$0.80", "First and last frame; motion follows your words", "")]),
        ("Not available", [("Kling 4.0 · fal", "", "fal isn't set up in Settings → Providers", "off")]),
    ]
    rows = ""
    for g, items in groups:
        rows += f'<div class="mic" style="color:var(--ink2);padding:12px 16px 4px">{g}</div>'
        for name, price, line, flag in items:
            sel = flag == "auto"
            rows += (f'<div class="row gap3" style="padding:6px 16px;{"opacity:.5;" if flag == "off" else ""}{"box-shadow:inset 2px 0 0 var(--accent);background:var(--field);" if sel else ""}">'
                     f'<div class="grow"><div class="l13">{name}{" <span class=cap style=font-size:12px>Auto picks this</span>" if sel else ""}</div>'
                     f'<div class="cap" style="font-size:12px;line-height:16px">{line}</div></div><div class="l13">{price}</div></div>')
    return f"""
<div style="position:absolute;left:330px;bottom:64px;width:440px;background:var(--raised);border-radius:var(--rc);box-shadow:{t['float'] if t['float'] != 'none' else 'inset 0 0 0 1px var(--hair)'};padding:8px 0 10px">
  <div style="padding:8px 16px 8px"><div class="field ph row gap2" style="min-height:32px;padding:6px 10px">{icon("magnifying-glass", 16)} Find a model</div></div>
  <div class="row gap3" style="padding:8px 16px">
    <div class="grow"><div class="l13">Auto</div><div class="cap" style="font-size:12px;line-height:16px">Picks for your switches: now Wan 2.7 Edit, because only the background and light change</div></div></div>
  {rows}
  <div class="cap" style="padding:10px 16px 0;font-size:12px">Prices are for this clip: 10 s at 1080p.</div>
</div>"""


# ------------------------------------------------------------------ New Swap states (Mac, one panel each)

def states(t):
    w, h = 240, 427

    def panel(title, inner, under):
        return (f'<div style="width:280px"><div class="label" style="margin-bottom:12px">{title}</div>'
                f'<div class="media" style="width:{w}px;height:{h}px">{inner}</div><div style="margin-top:12px;width:{w}px">{under}</div></div>')
    sk = f'<div style="position:absolute;inset:0;background:var(--field)"></div>'
    uploading = panel("Clip uploading", sk + f'<div style="position:absolute;left:16px;right:16px;bottom:16px"><div class="cap" style="color:var(--ink)">Uploading beach_walk.mp4</div>'
                      f'<div style="margin-top:8px;height:2px;background:var(--hair)"><div style="width:62%;height:2px;background:var(--ink)"></div></div></div>',
                      '<div class="cap">The switches can be set while it uploads. Generate waits for it.</div>')
    gen = panel("Generating", f'<img src="{img(PORTRAIT)}" style="opacity:.45">'
                f'<div style="position:absolute;left:16px;right:16px;bottom:16px;color:#fff"><div class="l13">Generating, about 2 min left</div>'
                f'<div class="mic" style="opacity:.8;margin-top:2px">Wan 2.7 Edit · Replicate</div>'
                f'<div style="margin-top:8px;height:2px;background:rgba(255,255,255,.3)"><div style="width:40%;height:2px;background:#fff"></div></div></div>',
                '<div class="cap">Leaving is safe. The take lands in Takes and you get a notice.</div><div class="row gap3" style="margin-top:8px"><div class="link" style="color:var(--ink2)">Cancel</div></div>')
    failed = panel("Failed", f'<img src="{img(PORTRAIT)}" style="opacity:.25">'
                   f'<div style="position:absolute;left:16px;right:16px;top:16px"><div class="row gap2 l13" style="color:var(--{"ink"})">{icon("warning", 16, t["accent"] if t is T["b"] else "#B5121B")} Wan 2.7 Edit stopped</div></div>',
                   '<div class="b13">The provider timed out after 10 min. You weren\'t charged.</div>'
                   '<div class="row gap3" style="margin-top:12px"><div class="go" style="height:32px;padding:0 14px;font-size:13px">Try again · $1.00</div><div class="link">Pick another model</div></div>')
    done = panel("Done", f'<img src="{img(PORTRAIT2)}">',
                 '<div class="b13">Rooftop remix is ready.</div><div class="row gap3" style="margin-top:8px"><div class="link">Open in the viewer</div><div class="link" style="color:var(--ink2)">Reuse settings</div></div>')
    return f'<div style="padding:40px 48px"><div class="title">New Swap: the stage in each state</div><div class="row gap5" style="margin-top:32px;align-items:flex-start;gap:24px">{uploading}{gen}{failed}{done}</div></div>'


# ------------------------------------------------------------------ Skins (generic platform layouts)

def g(name, size=26):
    return icon(name, size, "#fff")


def rail_btn(name, count=True, size=26):
    return f'<div style="display:flex;flex-direction:column;align-items:center;gap:3px">{g(name, size)}{"<div class=bar style=width:18px;height:5px></div>" if count else ""}</div>'


def skin_layer(kind, s, zones):
    """Overlay for a 9:19.5 phone screen of width s (px). Text is grey bars; buttons are Phosphor glyphs."""
    k = s / 300  # base layout was drawn for a 300 px wide screen
    sz = round(26 * k)
    status = f'<div class="row" style="position:absolute;top:{8*k:.0f}px;left:{18*k:.0f}px;right:{18*k:.0f}px"><div class="bar" style="width:{28*k:.0f}px;height:{7*k:.0f}px"></div><div class="grow"></div><div class="bar" style="width:{40*k:.0f}px;height:{7*k:.0f}px"></div></div>'
    nav_icons = {"tiktok": ["house", "users-three", "plus-square", "chat-teardrop", "user"],
                 "reels": ["house", "magnifying-glass", "plus-square", "film-reel", "user-circle"],
                 "shorts": ["house", "lightning", "plus-circle", "play-circle", "user-circle"],
                 "facebook": ["house", "video", "users-three", "storefront", "bell"]}.get(kind)
    out = status
    navh = 56 * k
    if nav_icons:
        out += (f'<div class="row" style="position:absolute;left:0;right:0;bottom:0;height:{navh:.0f}px;background:rgba(0,0,0,.92);justify-content:space-around;padding-bottom:{10*k:.0f}px">'
                + "".join(g(i, round(22 * k)) for i in nav_icons) + '</div>')
    cap_bottom = navh + 14 * k
    capw = s * 0.62

    def caption(name_extra=""):
        return (f'<div style="position:absolute;left:{12*k:.0f}px;bottom:{cap_bottom:.0f}px;width:{capw:.0f}px;display:flex;flex-direction:column;gap:{6*k:.0f}px">'
                f'{name_extra}<div class="bar dim" style="width:92%;height:{7*k:.0f}px"></div><div class="bar dim" style="width:64%;height:{7*k:.0f}px"></div>'
                f'<div class="row" style="gap:{6*k:.0f}px">{g("music-note", round(13*k))}<div class="bar dim" style="width:52%;height:{6*k:.0f}px"></div></div></div>')
    avatar = lambda d: f'<div style="width:{d*k:.0f}px;height:{d*k:.0f}px;border-radius:50%;background:rgba(255,255,255,.75);box-shadow:0 0 0 {1.5*k:.1f}px #fff;flex:none"></div>'
    railx = 10 * k
    if kind == "tiktok":
        out += f'<div class="row" style="position:absolute;top:{34*k:.0f}px;left:0;right:0;justify-content:center;gap:{14*k:.0f}px"><div class="bar dim" style="width:{50*k:.0f}px;height:{8*k:.0f}px"></div><div class="bar" style="width:{44*k:.0f}px;height:{8*k:.0f}px"></div></div>'
        out += f'<div style="position:absolute;top:{30*k:.0f}px;right:{14*k:.0f}px">{g("magnifying-glass", round(22*k))}</div>'
        out += (f'<div style="position:absolute;right:{railx:.0f}px;bottom:{navh + 16*k:.0f}px;display:flex;flex-direction:column;align-items:center;gap:{16*k:.0f}px">'
                f'{avatar(40)}{rail_btn("heart-straight", size=sz)}{rail_btn("chat-circle-dots", size=sz)}{rail_btn("bookmark-simple", size=sz)}{rail_btn("share-fat", size=sz)}'
                f'<div style="width:{32*k:.0f}px;height:{32*k:.0f}px;border-radius:50%;background:#333;box-shadow:0 0 0 {5*k:.0f}px #111"></div></div>')
        out += caption(f'<div class="bar" style="width:40%;height:{9*k:.0f}px"></div>')
    elif kind == "reels":
        out += f'<div class="row" style="position:absolute;top:{32*k:.0f}px;left:{14*k:.0f}px;right:{14*k:.0f}px"><div class="bar" style="width:{54*k:.0f}px;height:{10*k:.0f}px"></div><div class="grow"></div>{g("camera", round(22*k))}</div>'
        out += (f'<div style="position:absolute;right:{railx:.0f}px;bottom:{navh + 16*k:.0f}px;display:flex;flex-direction:column;align-items:center;gap:{18*k:.0f}px">'
                f'{rail_btn("heart", size=sz)}{rail_btn("chat-circle", size=sz)}{rail_btn("paper-plane-tilt", size=sz)}{rail_btn("dots-three-vertical", False, sz)}'
                f'<div style="width:{26*k:.0f}px;height:{26*k:.0f}px;border-radius:{5*k:.0f}px;background:rgba(255,255,255,.6);box-shadow:0 0 0 {2*k:.0f}px #fff"></div></div>')
        out += caption(f'<div class="row" style="gap:{8*k:.0f}px">{avatar(26)}<div class="bar" style="width:34%;height:{9*k:.0f}px"></div>'
                       f'<div style="width:{46*k:.0f}px;height:{20*k:.0f}px;border-radius:{6*k:.0f}px;box-shadow:inset 0 0 0 {1.2*k:.1f}px rgba(255,255,255,.8)"></div></div>')
    elif kind == "shorts":
        out += f'<div class="row" style="position:absolute;top:{30*k:.0f}px;right:{14*k:.0f}px;gap:{16*k:.0f}px">{g("magnifying-glass", round(22*k))}{g("dots-three-vertical", round(22*k))}</div>'
        out += (f'<div style="position:absolute;right:{railx:.0f}px;bottom:{navh + 16*k:.0f}px;display:flex;flex-direction:column;align-items:center;gap:{16*k:.0f}px">'
                f'{rail_btn("thumbs-up", size=sz)}{rail_btn("thumbs-down", False, sz)}{rail_btn("chat-centered-dots", size=sz)}{rail_btn("share-fat", size=sz)}{rail_btn("arrows-clockwise", size=sz)}'
                f'<div style="width:{28*k:.0f}px;height:{28*k:.0f}px;border-radius:{6*k:.0f}px;background:rgba(255,255,255,.6)"></div></div>')
        out += caption(f'<div class="row" style="gap:{8*k:.0f}px">{avatar(26)}<div class="bar" style="width:30%;height:{9*k:.0f}px"></div>'
                       f'<div style="width:{60*k:.0f}px;height:{22*k:.0f}px;border-radius:{11*k:.0f}px;background:rgba(255,255,255,.9)"></div></div>')
    elif kind == "facebook":
        out += (f'<div class="row" style="position:absolute;top:{30*k:.0f}px;left:{14*k:.0f}px;right:{14*k:.0f}px;gap:{14*k:.0f}px">{g("caret-left", round(22*k))}'
                f'<div class="bar" style="width:{48*k:.0f}px;height:{10*k:.0f}px"></div><div class="grow"></div>{g("magnifying-glass", round(22*k))}{g("user-circle", round(22*k))}</div>')
        out += (f'<div style="position:absolute;right:{railx:.0f}px;bottom:{navh + 16*k:.0f}px;display:flex;flex-direction:column;align-items:center;gap:{18*k:.0f}px">'
                f'{rail_btn("thumbs-up", size=sz)}{rail_btn("chat-circle", size=sz)}{rail_btn("share-fat", size=sz)}{rail_btn("dots-three", False, sz)}</div>')
        out += caption(f'<div class="row" style="gap:{8*k:.0f}px">{avatar(26)}<div class="bar" style="width:30%;height:{9*k:.0f}px"></div>'
                       f'<div style="width:{44*k:.0f}px;height:{20*k:.0f}px;border-radius:{6*k:.0f}px;background:rgba(255,255,255,.25)"></div></div>')
    if zones and kind != "clean":
        h = s * 19.5 / 9
        top, bottom, right = {"tiktok": (.11, .29, .17), "reels": (.10, .30, .16), "shorts": (.09, .30, .17), "facebook": (.10, .28, .16)}[kind]
        out += (f'<div class="zone" style="left:0;right:0;top:0;height:{h*top:.0f}px"></div>'
                f'<div class="zone" style="left:0;right:0;bottom:0;height:{h*bottom:.0f}px"></div>'
                f'<div class="zone" style="right:0;top:{h*top:.0f}px;bottom:{h*bottom:.0f}px;width:{s*right:.0f}px"></div>'
                f'<div style="position:absolute;left:{s*.05:.0f}px;right:{s*right:.0f}px;top:{h*top:.0f}px;bottom:{h*bottom:.0f}px;border:1px dashed rgba(255,255,255,.8);border-radius:{4*k:.0f}px"></div>')
    return out


def phone(src, s, kind="clean", zones=False, t=None, seek=None):
    """A generic phone: rounded body, thin even bezel, a round front camera. Screen 9:19.5; the 9:16 video fills it
    (cropped at the sides, as the platforms do on tall phones). Clean view: the video fits the width, black above/below."""
    h = s * 19.5 / 9
    bez = max(6, s * 0.035)
    r = s * 0.13
    fit = "cover" if kind != "clean" else "contain"
    over = skin_layer(kind, s, zones) if kind != "clean" else ""
    sk = seek_pill(seek, s / 300) if seek else ""
    return (f'<div style="padding:{bez:.0f}px;border-radius:{r + bez:.0f}px;background:#0a0a0a;box-shadow:0 0 0 1px #3a3d40;flex:none">'
            f'<div style="position:relative;width:{s:.0f}px;height:{h:.0f}px;border-radius:{r:.0f}px;overflow:hidden;background:#000">'
            f'<img src="{img(src)}" style="width:100%;height:100%;object-fit:{fit};display:block">'
            f'<div style="position:absolute;top:{10*s/300:.0f}px;left:50%;width:{10*s/300:.0f}px;height:{10*s/300:.0f}px;margin-left:-{5*s/300:.0f}px;border-radius:50%;background:#000;box-shadow:0 0 0 1px #222"></div>'
            f'{over}{sk}</div></div>')


def seek_pill(txt, k=1.0):
    return (f'<div style="position:absolute;left:50%;top:44%;transform:translateX(-50%);background:rgba(0,0,0,.6);color:#fff;border-radius:{8*k:.0f}px;'
            f'padding:{6*k:.0f}px {12*k:.0f}px;font:500 {13*k:.0f}px/{18*k:.0f}px Barlow,sans-serif;font-variant-numeric:tabular-nums;white-space:nowrap">{txt}</div>')


# ------------------------------------------------------------------ Viewer (Mac)

SKINS = [("clean", "Clean"), ("tiktok", "TikTok"), ("reels", "Reels"), ("shorts", "Shorts"), ("facebook", "Facebook")]


def actions_rail(t):
    quiet = [("arrow-clockwise", "Redo"), ("arrow-line-right", "Extend"), ("arrows-out-simple", "Upscale"), ("scissors", "Split"), ("export", "Share")]
    rows = "".join(f'<div class="row gap3" style="height:36px;padding:0 12px;border-radius:var(--rk);box-shadow:inset 0 0 0 1px var(--hair)">{icon(i, 18)}<div class="l13">{l}</div></div>' for i, l in quiet)
    return f"""
<div style="width:176px;flex:none;display:flex;flex-direction:column;gap:8px">
  <div class="go" style="justify-content:center;gap:8px">{icon("check", 18, t['onaction'])}Keep</div>
  {rows}
  <div class="row gap3" style="height:36px;padding:0 12px;color:var(--ink2)">{icon("dots-three", 18)}<div class="l13">More</div></div>
  <div style="margin-top:16px" class="cap">9:16 · 10 s<br>1080 × 1920<br>$1.00</div>
</div>"""


def viewer_head(title, sub, pos):
    return f"""
<div class="row gap3" style="height:64px;padding:0 32px;flex:none">
  <div class="row gap2 cap" style="color:var(--ink)">{icon("caret-left", 18)} Takes</div>
  <div style="width:16px"></div>
  <div class="grow"><div class="heading">{title}</div><div class="cap" style="font-size:12px;line-height:16px">{sub}</div></div>
  <div class="cap">{pos}</div>
  <div class="iconbtn" style="width:32px;height:32px" title="Previous take (↑)">{icon("caret-up", 18)}</div>
  <div class="iconbtn" style="width:32px;height:32px" title="Next take (↓)">{icon("caret-down", 18)}</div>
  <div class="iconbtn" style="width:32px;height:32px" title="Close (Esc)">{icon("x", 18)}</div>
</div>"""


def preview_bar(sel, device=True, zones=False, landscape=False):
    skins = [("clean", "Clean"), ("youtube", "YouTube"), ("facebook", "Facebook")] if landscape else SKINS
    seg = "".join(f'<div class="{"on" if k == sel else ""}">{l}</div>' for k, l in skins)
    return f"""
<div class="row gap4" style="justify-content:center;height:40px;flex:none">
  <div class="seg">{seg}</div>
  <div class="row gap2 b13">{'<div class="sw on"></div>' if device else '<div class="sw"></div>'}{"Laptop" if landscape else "Phone"} frame</div>
  <div class="row gap2 b13">{'<div class="sw on"></div>' if zones else '<div class="sw"></div>'}Safe zones</div>
</div>"""


def viewer_mac(t, kind="tiktok", device=True, zones=False, seek=None):
    if device:
        s = 300
        media = phone(PORTRAIT2, s, kind, zones, t, seek)
    else:
        h = 640
        media = (f'<div class="media" style="width:{h*9/16:.0f}px;height:{h}px;border-radius:var(--rc)"><img src="{img(PORTRAIT2)}">'
                 f'{seek_pill(seek) if seek else ""}</div>')
    hint = '<div class="cap" style="text-align:center;margin-top:12px;font-size:12px">Space play or pause · ← → 3 s · ⇧ 10 s · J K L</div>' if not device else ""
    content = viewer_head("Rooftop remix", "New Swap, Wan 2.7 Edit · Replicate", "2 of 14") + preview_bar(kind, device, zones) + f"""
<div class="row" style="flex:1;min-height:0;justify-content:center;align-items:center;gap:48px;padding:12px 32px 24px">
  <div style="width:176px"></div>
  <div style="display:flex;flex-direction:column;align-items:center">{media}{hint}</div>
  {actions_rail(t)}
</div>"""
    return mac_shell(t, content)


def laptop(src, w, kind="youtube"):
    h = w * 10 / 16
    if kind == "youtube":
        vid_w = w * .66
        inner = (f'<div style="position:absolute;inset:0;background:#0f0f0f">'
                 f'<div class="row" style="height:{h*.07:.0f}px;padding:0 {w*.02:.0f}px;gap:{w*.015:.0f}px">{g("list", 16)}<div class="bar" style="width:{w*.06:.0f}px;height:8px"></div><div class="grow"></div>'
                 f'<div style="width:{w*.3:.0f}px;height:{h*.04:.0f}px;border-radius:999px;box-shadow:inset 0 0 0 1px #444"></div><div class="grow"></div>{g("bell", 16)}<div style="width:16px;height:16px;border-radius:50%;background:#666"></div></div>'
                 f'<div style="position:absolute;left:{w*.02:.0f}px;top:{h*.09:.0f}px;width:{vid_w:.0f}px">'
                 f'<div style="width:100%;aspect-ratio:16/9;border-radius:8px;overflow:hidden"><img src="{img(src)}" style="width:100%;height:100%;object-fit:cover;display:block"></div>'
                 f'<div class="bar" style="margin-top:12px;width:70%;height:10px"></div>'
                 f'<div class="row" style="margin-top:12px;gap:8px"><div style="width:26px;height:26px;border-radius:50%;background:#666"></div><div class="bar dim" style="width:18%"></div>'
                 f'<div style="width:62px;height:22px;border-radius:11px;background:rgba(255,255,255,.9)"></div><div class="grow"></div>'
                 f'<div style="width:90px;height:22px;border-radius:11px;background:#333"></div><div style="width:60px;height:22px;border-radius:11px;background:#333"></div></div></div>'
                 f'<div style="position:absolute;right:{w*.02:.0f}px;top:{h*.09:.0f}px;width:{w*.27:.0f}px;display:flex;flex-direction:column;gap:10px">'
                 + "".join(f'<div class="row" style="gap:8px;align-items:flex-start"><div style="width:44%;aspect-ratio:16/9;border-radius:6px;background:#2a2a2a;flex:none"></div>'
                           f'<div class="grow" style="display:flex;flex-direction:column;gap:5px"><div class="bar dim" style="width:90%;height:6px"></div><div class="bar dim" style="width:60%;height:6px;opacity:.6"></div></div></div>' for _ in range(6))
                 + '</div></div>')
    else:
        inner = f'<img src="{img(src)}" style="position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000">'
    return f"""
<div style="display:flex;flex-direction:column;align-items:center">
  <div style="padding:{w*.018:.0f}px;border-radius:{w*.025:.0f}px {w*.025:.0f}px 4px 4px;background:#0a0a0a;box-shadow:0 0 0 1px #3a3d40">
    <div style="position:relative;width:{w:.0f}px;height:{h:.0f}px;overflow:hidden">{inner}</div></div>
  <div style="width:{w*1.16:.0f}px;height:{w*.022:.0f}px;background:#2a2c2f;border-radius:0 0 {w*.03:.0f}px {w*.03:.0f}px;box-shadow:0 0 0 1px #3a3d40"></div>
</div>"""


def viewer_landscape(t):
    content = viewer_head("Studio, one light", "Shot, Kling 4.0 · fal", "5 of 14") + preview_bar("youtube", True, False, True) + f"""
<div style="flex:1;min-height:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:28px;padding:12px 32px 24px">
  {laptop(LANDSCAPE, 760)}
  <div class="row gap2">
    <div class="go" style="height:36px;gap:8px">{icon("check", 18, t['onaction'])}Keep</div>
    {"".join(f'<div class="quiet" style="height:36px">{icon(i, 18)}{l}</div>' for i, l in [("arrow-clockwise", "Redo"), ("arrow-line-right", "Extend"), ("arrows-out-simple", "Upscale"), ("scissors", "Split"), ("export", "Share")])}
    <div class="quiet" style="height:36px;box-shadow:none;color:var(--ink2)">{icon("dots-three", 18)}More</div>
  </div>
</div>"""
    return mac_shell(t, content)


def skins_sheet(t):
    s = 210
    cells = "".join(f'<div style="display:flex;flex-direction:column;align-items:center;gap:12px">{phone(PORTRAIT2, s, k, k != "clean", t)}<div class="label">{l}</div></div>' for k, l in SKINS)
    return (f'<div style="padding:36px 48px"><div class="title">Preview as: one take on each layout</div>'
            f'<div class="cap" style="margin-top:4px">Generic drawings of each app\'s layout, with safe zones on. Hatched areas sit under the app\'s buttons and captions; keep faces and text inside the dashed box.</div>'
            f'<div class="row" style="margin-top:28px;justify-content:space-between;align-items:flex-start">{cells}</div></div>')


# ------------------------------------------------------------------ Android

def android_viewer(t):
    s = 390
    ripple = (f'<div style="position:absolute;right:-90px;top:30%;width:230px;height:300px;border-radius:50%;background:rgba(255,255,255,.14)"></div>'
              f'<div style="position:absolute;right:26px;top:43%;color:#fff;text-align:center">{g("fast-forward", 28)}<div class="mic" style="margin-top:4px">+6 s</div></div>')
    acts = [("check", "Keep", True), ("arrow-clockwise", "Redo", False), ("arrow-line-right", "Extend", False), ("arrows-out-simple", "Upscale", False), ("scissors", "Split", False), ("export", "Share", False)]
    row = "".join(f'<div style="width:60px;display:flex;flex-direction:column;align-items:center;gap:4px;color:{"var(--accent)" if on else "var(--ink)"}">{icon(i, 24)}<div class="mic">{l}</div></div>' for i, l, on in acts)
    vh = s * 16 / 9
    return f"""
<div style="position:absolute;inset:0;background:#000"></div>
<div style="position:absolute;left:0;top:0;width:{s}px;height:{vh:.0f}px;overflow:hidden">
  <img src="{img(PORTRAIT2)}" style="width:100%;height:100%;object-fit:cover">{ripple}
  <div class="row" style="position:absolute;top:36px;left:4px;right:4px">
    <div class="iconbtn" style="color:#fff">{icon("caret-left", 24)}</div><div class="grow"></div>
    <div class="iconbtn" style="color:#fff">{icon("device-mobile", 24)}</div><div class="iconbtn" style="color:#fff">{icon("dots-three", 24)}</div></div>
  {seek_pill("0:08 / 0:10", 1)}
</div>
<div style="position:absolute;left:0;right:0;bottom:0;height:{844 - vh:.0f}px;background:var(--canvas);display:flex;flex-direction:column;justify-content:center;padding:0 15px">
  <div class="row" style="justify-content:space-between">{row}</div></div>"""


def android_newswap(t, filled=True):
    vh = 300
    if filled:
        src = (f'<div class="row" style="gap:16px;padding:8px 16px 0;align-items:flex-start">'
               f'<div class="media" style="width:{vh*9/16:.0f}px;height:{vh}px;flex:none"><img src="{img(PORTRAIT)}"></div>'
               f'<div class="grow" style="display:flex;flex-direction:column;gap:8px"><div class="l13">beach_walk.mp4</div><div class="cap">0:24</div>'
               f'<div class="cap">Uses 0:02–0:12, 10 s</div><div class="link">Trim</div><div class="link" style="color:var(--ink2)">Replace</div></div></div>')
        rows = [toggle_row("Background", True, "Describe the new place", '<div class="field">A rooftop at golden hour</div>'),
                toggle_row("Outfit", False, "Kept from the clip"),
                toggle_row("Character", True, "Her, with the figure lock", her_chip(t)),
                toggle_row("Look &amp; light", True, "Time of day, light, grade", '<div class="field">Warmer, soft window light</div>')]
        bar = (f'<div class="row gap2"><div class="quiet">Auto · Wan 2.7 Edit {icon("caret-down", 16, "var(--ink2)")}</div><div class="grow"></div><div class="cap">10 s, 1080p</div></div>'
               f'<div class="action" style="margin-top:12px">Generate · $1.00</div>')
    else:
        src = ('<div style="padding:8px 16px 0"><div style="height:180px;border-radius:var(--rc);background:var(--field);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px">'
               f'<div class="label">Add the video to remix</div><div class="row gap2"><div class="quiet" style="height:44px">{icon("squares-four", 18)}Library</div>'
               f'<div class="quiet" style="height:44px">{icon("upload-simple", 18)}Upload</div><div class="quiet" style="height:44px">{icon("link", 18)}Paste link</div></div></div></div>')
        rows = [toggle_row("Background", False, "Kept from the clip"), toggle_row("Outfit", False, "Kept from the clip"),
                toggle_row("Character", True, "Her, with the figure lock", her_chip(t)), toggle_row("Look &amp; light", False, "Kept from the clip")]
        bar = '<div class="cap">The model and price show once a video is added</div><div class="action" style="margin-top:12px;background:var(--field);color:var(--ink2)">Generate</div>'
    return f"""
<div class="row" style="padding:36px 4px 0"><div class="iconbtn">{icon("caret-left", 24)}</div><div class="title grow">Swap</div>
  <div class="seg" style="margin-right:12px"><div>Swap</div><div class="on">New</div></div></div>
{src}
<div style="padding:16px 16px 0">{"".join(rows)}</div>
<div style="position:absolute;left:0;right:0;bottom:0;padding:12px 16px 24px;background:var(--canvas);border-top:1px solid var(--hair)">{bar}</div>"""


# ------------------------------------------------------------------ main

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = [
        ("newswap-mac-empty-dark", lambda: newswap_mac(T["b"], False), "b", 1440, 900),
        ("newswap-mac-empty-light", lambda: newswap_mac(T["a"], False), "a", 1440, 900),
        ("newswap-mac-filled-dark", lambda: newswap_mac(T["b"], True), "b", 1440, 900),
        ("newswap-mac-filled-light", lambda: newswap_mac(T["a"], True), "a", 1440, 900),
        ("newswap-mac-models-dark", lambda: newswap_mac(T["b"], True, True), "b", 1440, 900),
        ("newswap-mac-states-dark", lambda: states(T["b"]), "b", 1240, 640),
        ("newswap-android-empty-dark", lambda: android_newswap(T["b"], False), "b", 390, 844),
        ("newswap-android-filled-light", lambda: android_newswap(T["a"], True), "a", 390, 844),
        ("viewer-mac-tiktok-dark", lambda: viewer_mac(T["b"], "tiktok", True, False), "b", 1440, 900),
        ("viewer-mac-reels-zones-light", lambda: viewer_mac(T["a"], "reels", True, True), "a", 1440, 900),
        ("viewer-mac-clean-noframe-dark", lambda: viewer_mac(T["b"], "clean", False, False, "+3 s   0:07 / 0:10"), "b", 1440, 900),
        ("viewer-mac-clean-phone-light", lambda: viewer_mac(T["a"], "clean", True, False), "a", 1440, 900),
        ("viewer-skins-dark", lambda: skins_sheet(T["b"]), "b", 1440, 680),
        ("viewer-skins-light", lambda: skins_sheet(T["a"]), "a", 1440, 680),
        ("viewer-mac-landscape-laptop-dark", lambda: viewer_landscape(T["b"]), "b", 1440, 900),
        ("viewer-android-dark", lambda: android_viewer(T["b"]), "b", 390, 844),
    ]
    only = set(sys.argv[1:])
    with tempfile.TemporaryDirectory() as d:
        spec = []
        for name, fn, k, w, h in jobs:
            if only and name not in only:
                continue
            p = Path(d) / f"{name}.html"
            p.write_text(page(fn(), T[k], w, h))
            spec.append(dict(html=p.as_uri(), png=str(OUT / f"{name}.png"), w=w, h=h))
        js = Path(d) / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 2 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(spec)], check=True, env={**os.environ, "NODE_PATH": root})


if __name__ == "__main__":
    main()

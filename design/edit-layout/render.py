"""Mock of the redesigned Mac Edit suite (plans/edit-layout.md) for the owner's approval, before building.

The clean app style of plans/design-direction.md (colour roles, type scale, spacing, radii, Phosphor Regular), in all four
themes, Soft Tactile first. Sizes: 1280 × 800 and a 13" MacBook Air window (1470 × 882), plus the 1280 layout with the
inspector and media collapsed. Stand-in footage is the Blender preview posters (design/previews/moves), no people.

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/edit-layout/render.py   # writes plans/edit-layout/after_*.png
Needs Playwright with its Chromium (preinstalled in the cloud sessions).
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans" / "edit-layout"
FONTS = REPO / "android/app/src/main/res/font"
PHOS = Path(os.environ.get("PHOSPHOR", REPO / "design/icons/phosphor")) / "assets/regular"
MOVES = REPO / "design/previews/moves"

# plans/design-direction.md §2–§4 (roles, radii) and §3 (families).
THEMES = {
    "c": dict(name="Soft Tactile", canvas="#E7E2D9", raised="#F3F0EA", field="#EAE5DC", ink="#23262A", ink2="#5E5C57", hair="#D9D3C8",
              accent="#4E6B45", sel="#4E6B45", action="#4E6B45", onaction="#FFFFFF", display="Outfit", text="Outfit", rc=24, rk=16, rp=12,
              float="0 12px 32px rgba(35,38,42,.14)", viewer="#1C1E21"),
    "a": dict(name="Editorial", canvas="#EFEBE3", raised="#F8F5EF", field="#E7E1D6", ink="#141210", ink2="#67605A", hair="#CFC7BA",
              accent="#B5121B", sel="#B5121B", action="#141210", onaction="#F8F5EF", display="Instrument Serif", text="Archivo", rc=4, rk=2, rp=2,
              float="0 12px 32px rgba(20,18,16,.14)", viewer="#141210"),
    "b": dict(name="Camera Body", canvas="#0D0E0F", raised="#17191B", field="#212427", ink="#ECEAE5", ink2="#A9A6A0", hair="#2C3033",
              accent="#F2A93B", sel="#F2A93B", action="#F2A93B", onaction="#1A1205", display="Barlow Condensed", text="Barlow", rc=14, rk=10, rp=8,
              float="none", viewer="#000000"),
    "d": dict(name="Creator Pop", canvas="#FFF6EC", raised="#FFFFFF", field="#FFEBD8", ink="#111111", ink2="#55504A", hair="#E8D9C6",
              accent="#FF7EB6", sel="#111111", action="#FF7EB6", onaction="#111111", display="Bricolage Grotesque", text="Figtree", rc=16, rk=12, rp=999,
              float="0 12px 32px rgba(17,17,17,.14)", viewer="#111111"),
}
FONT_FILES = {
    "Outfit": [("outfit_400", 400), ("outfit_500", 500), ("outfit_600", 600)],
    "Instrument Serif": [("instrument_serif_400", 400)], "Archivo": [("archivo_400", 400), ("archivo_500", 500), ("archivo_600", 600)],
    "Barlow Condensed": [("barlow_condensed_600", 600)], "Barlow": [("barlow_400", 400), ("barlow_500", 500), ("barlow_600", 600)],
    "Bricolage Grotesque": [("bricolage_grotesque_700", 700)], "Figtree": [("figtree_400", 400), ("figtree_500", 500), ("figtree_600", 600)],
}


def icon(name, size=20, color="currentColor"):
    svg = (PHOS / f"{name}.svg").read_text()
    return svg.replace("<svg ", f'<svg width="{size}" height="{size}" style="color:{color};flex:none" aria-hidden="true" ', 1)


def css(t):
    fams = {t["display"], t["text"]}
    faces = "".join(f'@font-face{{font-family:"{fam}";src:url("{(FONTS / (f + ".ttf")).as_uri()}");font-weight:{w}}}'
                    for fam in fams for f, w in FONT_FILES[fam])
    d4 = t["display"] == "Bricolage Grotesque"
    return faces + f"""
*{{box-sizing:border-box;margin:0;padding:0}}
body{{background:{t['canvas']};color:{t['ink']};font-family:"{t['text']}";font-size:15px;line-height:21px;-webkit-font-smoothing:antialiased;overflow:hidden}}
.display{{font-family:"{t['display']}";font-size:28px;line-height:32px;font-weight:{700 if d4 else 600 if t['display']=='Barlow Condensed' else 400}}}
.title{{font-size:20px;line-height:26px;font-weight:600}} .heading{{font-size:16px;line-height:22px;font-weight:600}}
.label{{font-size:14px;line-height:18px;font-weight:500}} .caption{{font-size:13px;line-height:18px}} .micro{{font-size:11px;line-height:14px;font-weight:500}}
.ink2{{color:{t['ink2']}}} .num{{font-variant-numeric:tabular-nums}}
.row{{display:flex;align-items:center}} .col{{display:flex;flex-direction:column}} .grow{{flex:1;min-width:0}}
.btn{{height:32px;padding:0 12px;border-radius:{t['rk']}px;display:inline-flex;align-items:center;gap:8px;background:{t['field']};color:{t['ink']};white-space:nowrap}}
.btn.plain{{background:transparent}} .btn.icon{{width:32px;padding:0;justify-content:center}}
.btn.action{{background:{t['action']};color:{t['onaction']};{'outline:2px solid #111;' if d4 else ''}}}
.btn.on{{background:{t['ink']};color:{t['canvas']}}}
.seg{{display:flex;background:{t['field']};border-radius:{t['rk']}px;padding:2px;height:32px}}
.seg div{{padding:0 12px;display:flex;align-items:center;border-radius:{max(t['rk']-2,0)}px;color:{t['ink2']}}}
.seg div.on{{background:{t['raised']};color:{t['ink']};{'outline:2px solid #111;' if d4 else ''}}}
.hair{{background:{t['hair']}}}
.panel{{background:{t['raised']}}}
.chip{{height:28px;padding:0 10px;border-radius:{t['rp']}px;display:inline-flex;align-items:center;gap:6px;background:{t['field']}}}
.thumb{{border-radius:{t['rk']}px;background-size:cover;background-position:center}}
"""


SIDEBAR_ICONS = ["house", "user", "video-camera", "squares-four", "scissors", "stack", "squares-four", "paper-plane-tilt"]


def rail(t):
    items = [("house", False), ("user", False), ("video-camera", False), ("scissors", True), ("stack", False), ("squares-four", False), ("paper-plane-tilt", False)]
    cells = "".join(f'<div class="row" style="width:44px;height:40px;justify-content:center;border-radius:{t["rk"]}px;'
                    f'{"background:" + t["field"] + ";" if on else ""}position:relative">{icon(n, 20, t["ink"] if on else t["ink2"])}'
                    f'{"<div style=position:absolute;left:-10px;top:12px;width:3px;height:16px;border-radius:2px;background:" + t["accent"] + "></div>" if on else ""}</div>'
                    for n, on in items)
    return (f'<div class="col" style="width:72px;align-items:center;gap:4px;padding-top:16px;border-right:1px solid {t["hair"]}">'
            f'<div class="display" style="font-size:24px;margin-bottom:16px">M</div>{cells}'
            f'<div class="grow"></div><div style="margin-bottom:16px">{icon("sliders-horizontal", 20, t["ink2"])}</div></div>')


def poster(name):
    return (MOVES / f"{name}.webp").as_uri()


def topbar(t, wide, inspector_open):
    return f"""<div class="row" style="height:56px;padding:0 16px;gap:12px;border-bottom:1px solid {t['hair']}">
  <div class="btn icon plain" title="Back">{icon('caret-left', 20)}</div>
  <div class="col" style="min-width:0;max-width:{360 if wide else 260}px"><div class="heading" style="white-space:nowrap">Living room dance</div>
    <div class="caption ink2" style="white-space:nowrap">Version 1 · not exported yet</div></div>
  <div class="grow"></div>
  <div class="seg label"><div class="on">9:16</div><div>1:1</div><div>4:5</div><div>16:9</div></div>
  <div class="grow"></div>
  <div class="btn plain label">{icon('chat-circle-text', 18)}Claude</div>
  <div class="btn plain label">{icon('stack', 18)}Templates</div>
  <div class="btn plain label">{icon('lightbulb', 18)}Hook ideas</div>
  {'' if inspector_open else '<div class="btn plain label">' + icon('sidebar-simple', 18) + 'Show inspector</div>'}
  <div class="btn action label">{icon('export', 18)}Export</div>
</div>"""


def media(t):
    tabs = [("film-strip", "Takes", True), ("upload-simple", "Uploads", False), ("music-notes", "Music", False),
            ("text-aa", "Text", False), ("sticker", "Stickers", False), ("stack", "Templates", False)]
    tab_html = "".join(f'<div class="col" style="width:64px;height:56px;align-items:center;justify-content:center;gap:4px;border-radius:{t["rk"]}px;'
                       f'{"background:" + t["field"] + ";color:" + t["ink"] if on else "color:" + t["ink2"]}">{icon(i, 20)}<div class="micro">{l}</div></div>'
                       for i, l, on in tabs)
    tiles = "".join(f'<div class="col" style="gap:6px"><div class="thumb" style="height:112px;background-image:url({poster(p)})"></div>'
                    f'<div class="caption" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{c}</div>'
                    f'<div class="micro ink2 num">{d}</div></div>'
                    for p, c, d in [("dolly_in", "Living room dance", "15.0 s"), ("follow", "Kitchen walk", "8.0 s"),
                                    ("crane_down", "Rooftop turn", "6.0 s"), ("handheld", "Café counter", "8.0 s")])
    return f"""<div class="row" style="width:304px;border-right:1px solid {t['hair']};align-items:stretch;overflow:hidden">
  <div class="col" style="width:72px;padding:12px 4px;gap:4px;align-items:center;border-right:1px solid {t['hair']}">{tab_html}</div>
  <div class="col grow" style="padding:16px;gap:12px;min-width:0">
    <div class="row"><div class="heading grow">Takes</div><div class="btn icon plain" title="Hide media">{icon('caret-double-left', 18, t['ink2'])}</div></div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">{tiles}</div>
    <div class="grow"></div>
    <div class="row" style="gap:8px"><div class="btn label grow" style="justify-content:center">{icon('upload-simple', 18)}Import</div>
      <div class="btn label grow" style="justify-content:center">{icon('microphone', 18)}Record VO</div></div>
  </div></div>"""


def viewer(t):
    return f"""<div class="col grow" style="min-width:0;padding:16px;gap:12px">
  <div class="row" style="gap:8px"><div class="caption ink2">Safe area</div>
    <div class="seg caption" style="height:28px"><div class="on">Off</div><div>TikTok</div><div>Reels</div><div>Shorts</div></div>
    <div class="grow"></div><div class="caption ink2 num">Fit · 100%</div></div>
  <div class="grow row" style="justify-content:center;background:{t['viewer']};border-radius:{t['rc']}px;min-height:0;overflow:hidden">
    <div style="height:92%;aspect-ratio:9/16;background:url({poster('dolly_in')}) center/cover;border-radius:4px"></div></div>
  <div class="row" style="gap:8px;justify-content:center">
    <div class="label num" style="width:120px">0:03.2 / 0:15.0</div><div class="grow"></div>
    <div class="btn icon plain" title="Back 1 frame">{icon('skip-back', 20)}</div>
    <div class="btn icon" style="width:40px;height:40px;border-radius:999px;background:{t['ink']};color:{t['canvas']}" title="Play">{icon('play', 20)}</div>
    <div class="btn icon plain" title="Forward 1 frame">{icon('skip-forward', 20)}</div><div class="grow"></div>
    <div class="row" style="width:120px;justify-content:flex-end;gap:4px"><div class="btn icon plain" title="Sound">{icon('speaker-high', 20)}</div>
      <div class="btn icon plain" title="Full screen">{icon('arrows-out-simple', 20)}</div></div>
  </div></div>"""


def inspector(t):
    secs = [("text-aa", "Captions", True), ("text-t", "Text", False), ("film-strip", "Video", False),
            ("waveform", "Audio", False), ("timer", "Speed", False), ("sparkle", "Animate", False)]
    secs = [(("magic-wand" if n == "sparkle" else n), l, on) for n, l, on in secs]
    secs = [(("arrows-clockwise" if l == "Animate" else n), l, on) for n, l, on in secs]
    grid = "".join(f'<div class="row label" style="height:36px;gap:6px;padding:0 10px;border-radius:{t["rk"]}px;'
                   f'{"background:" + t["field"] + ";color:" + t["ink"] if on else "color:" + t["ink2"]}">{icon(i, 18)}{l}</div>'
                   for i, l, on in secs)
    styles = "".join(f'<div class="col" style="gap:6px"><div class="row" style="height:56px;justify-content:center;border-radius:{t["rk"]}px;background:{bg};'
                     f'{"outline:2px solid " + t["sel"] + ";outline-offset:2px;" if on else ""}"><span style="font-weight:700;font-size:14px;color:{fg}">{w}</span></div>'
                     f'<div class="caption {"" if on else "ink2"}">{n}</div></div>'
                     for n, w, bg, fg, on in [("Word pop", "ALWAYS", "#2A2D31", "#F2D84B", True), ("Karaoke", "always", "#2A2D31", "#4FC3D9", False),
                                              ("Clean", "Always", "#2A2D31", "#FFFFFF", False), ("Boxed", "Always", "#F3F0EA", "#111111", False)])
    return f"""<div class="col" style="width:328px;border-left:1px solid {t['hair']};padding:16px;gap:16px;overflow:hidden;position:relative">
  <div style="position:absolute;right:4px;top:120px;width:4px;height:120px;border-radius:2px;background:{t['hair']}"></div>
  <div class="row"><div class="heading grow">Inspector</div><div class="btn icon plain" title="Hide inspector">{icon('sidebar-simple', 18, t['ink2'])}</div></div>
  <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:4px">{grid}</div>
  <div style="height:1px" class="hair"></div>
  <div class="col" style="gap:8px"><div class="heading">Auto-captions</div>
    <div class="caption ink2">Word-timed captions from what's said in the video. Edit the words in Captions and hooks.</div>
    <div><div class="btn label">{icon('closed-captioning', 18)}Make captions</div></div></div>
  <div class="col" style="gap:8px"><div class="heading">Style</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">{styles}</div></div>
</div>"""


def timeline(t, wide):
    tools = [("scissors", "Split"), ("trash", "Delete"), ("gauge", "Speed"), ("diamond", "Keyframe"), ("crop", "Crop")]
    tool_html = "".join(f'<div class="btn plain label" title="{l}">{icon(i, 18)}{l if wide else ""}</div>' if wide else
                        f'<div class="btn icon plain" title="{l}">{icon(i, 18)}</div>' for i, l in tools)
    ticks = "".join(f'<div class="micro ink2 num" style="position:absolute;left:{x * 100 / 16:.2f}%;top:6px">0:{x:02d}</div>' for x in range(0, 16, 2))
    frames = "".join(f'<div style="flex:1;height:100%;background:url({poster(p)}) center/cover"></div>'
                     for p in ["dolly_in", "dolly_in", "follow", "follow", "crane_down", "crane_down", "handheld", "handheld"] * 2)
    wave = "".join(f'<div style="width:3px;height:{6 + (i * 37 % 22)}px;background:{t["ink2"]};border-radius:2px;opacity:.7"></div>' for i in range(150))
    track = lambda icon_name, label, body, h: (
        f'<div class="row" style="height:{h}px;border-bottom:1px solid {t["hair"]}">'
        f'<div class="row" style="width:176px;height:100%;padding:0 12px;gap:8px;border-right:1px solid {t["hair"]}">{icon(icon_name, 18, t["ink2"])}'
        f'<div class="label grow">{label}</div>{icon("speaker-high", 16, t["ink2"])}{icon("eye", 16, t["ink2"])}</div>'
        f'<div class="grow" style="height:100%;padding:6px 8px;position:relative">{body}</div></div>')
    vid = f'<div class="row" style="height:100%;border-radius:{min(t["rk"], 8)}px;overflow:hidden;outline:2px solid {t["sel"]};width:94%">{frames}</div>'
    cap = "".join(f'<div class="micro" style="position:absolute;left:{x}%;top:9px;height:24px;padding:0 8px;display:flex;align-items:center;'
                  f'border-radius:{min(t["rk"], 8)}px;background:{t["field"]}">{w}</div>' for x, w in [(2, "I always"), (18, "order the"), (36, "same thing"), (58, "every time")])
    aud = f'<div class="row" style="height:100%;gap:2px;align-items:center;padding:0 6px;border-radius:{min(t["rk"], 8)}px;background:{t["field"]};width:94%;overflow:hidden">{wave}</div>'
    return f"""<div class="col" style="height:268px;border-top:1px solid {t['hair']}">
  <div class="row" style="height:48px;padding:0 12px;gap:4px;border-bottom:1px solid {t['hair']}">
    {tool_html}<div style="width:1px;height:20px;margin:0 6px" class="hair"></div>
    <div class="btn icon plain" title="Undo">{icon('arrow-counter-clockwise', 18)}</div><div class="btn icon plain" title="Redo">{icon('arrow-clockwise', 18, t['ink2'])}</div>
    <div style="width:1px;height:20px;margin:0 6px" class="hair"></div>
    <div class="btn on label">{icon('magnet', 18)}Ripple</div><div class="btn plain label">{icon('scissors', 18)}Cut silences</div>
    {'<div class="btn plain label">' + icon('music-note', 18) + 'Snap to beat</div>' if wide else '<div class="btn icon plain" title="Snap to beat">' + icon('music-note', 18) + '</div>'}
    <div class="grow"></div>
    <div class="row" style="gap:8px">{icon('magnifying-glass-minus', 18, t['ink2'])}<div style="width:96px;height:4px;border-radius:2px;background:{t['field']};position:relative">
      <div style="position:absolute;left:52px;top:-6px;width:16px;height:16px;border-radius:8px;background:{t['raised']};border:1px solid {t['hair']}"></div></div>{icon('magnifying-glass-plus', 18, t['ink2'])}</div>
  </div>
  <div class="row" style="height:28px;border-bottom:1px solid {t['hair']}"><div style="width:176px;border-right:1px solid {t['hair']};height:100%"></div>
    <div class="grow" style="position:relative;height:100%">{ticks}<div style="position:absolute;left:20%;top:0;bottom:-176px;width:2px;background:{t['accent']}"></div></div></div>
  {track('film-strip', 'Video', vid, 72)}{track('closed-captioning', 'Captions', cap, 44)}{track('waveform', 'Sound', aud, 56)}
  <div class="grow"></div>
</div>"""


def page(t, w, h, inspector_open=True, media_open=True):
    wide = w >= 1440
    return f"""<!doctype html><meta charset="utf-8"><style>{css(t)}</style>
<body style="width:{w}px;height:{h}px"><div class="row" style="height:100%;align-items:stretch">{rail(t)}
<div class="col grow" style="min-width:0">{topbar(t, wide, inspector_open)}
  <div class="row grow" style="min-height:0;align-items:stretch;overflow:hidden">{media(t) if media_open else ''}{viewer(t)}{inspector(t) if inspector_open else ''}</div>
  {timeline(t, wide)}
</div></div></body>"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    jobs = []
    for key in ["c", "a", "b", "d"]:
        t = THEMES[key]
        for (w, h) in [(1280, 800), (1470, 882)]:
            p = tmp / f"after_{key}_{w}x{h}.html"
            p.write_text(page(t, w, h))
            jobs.append(dict(html=p.as_uri(), png=str(OUT / f"after_{key}_{w}x{h}.png"), w=w, h=h))
        p = tmp / f"after_{key}_1280x800_collapsed.html"
        p.write_text(page(t, 1280, 800, inspector_open=False, media_open=False))
        jobs.append(dict(html=p.as_uri(), png=str(OUT / f"after_{key}_1280x800_collapsed.png"), w=1280, h=800))
    js = tmp / "shoot.js"
    js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
    subprocess.run(["node", str(js), json.dumps(jobs)], check=True, cwd=tmp)


if __name__ == "__main__":
    main()

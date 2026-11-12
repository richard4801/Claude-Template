"""Edit → Uploads as a media bin (owner, 2026-11-12): before and after, Camera Body (dark) and Editorial (light).

Owner: "There's redundant features, and the AI-ish info. We don't need to be told how an upload button works. And this
section is not properly visually optimised for a real experience."

    python3 design/direction/edit_panels.py     # writes plans/design/edit-panels/uploads-{b,a}.png

Each sheet shows the Mac's media panel at its real size (304 pt: the 72 pt tab rail and the 232 pt panel):
  1. Today: six import buttons for one job, the ✦ card that explains them, a truncated row, uneven buttons.
  2. Empty: one drop zone and one short line; "Add" is the only button.
  3. Six uploads: a grid of thumbnails (audio as a waveform tile), the type mark and length on each, filter chips
     because the kinds are mixed, "+" and the full name on the tile under the pointer.
  4. Add open: From this Mac, From a link, Record voice-over (and the playback choice for recording).
  5. Recording: the header's Add becomes a live strip with Stop.

Rules applied (skill §1, direction §2–§5): Phosphor Regular only; tone not shadow (one `float` for the menu, none in
Camera Body); grouping by space, no boxes inside the panel; one selection mark per region; sentence case; no sparkle,
no helper copy; the "·" only inside the media badge.
"""
import json, os, subprocess, tempfile
from pathlib import Path

import render as R

R.PHOS = R.REPO / "design/icons/phosphor"
OUT = R.REPO / "plans/design/edit-panels"
I = R.icon
DANGER = {"b": "#FF6B5E", "a": "#B5121B"}
PANEL_W, RAIL_W, H = 304, 72, 760

TABS = [("Takes", "film-strip"), ("Uploads", "upload-simple"), ("Music", "music-notes"), ("Text", "text-aa"),
        ("Stickers", "sticker"), ("Templates", "stack")]

ITEMS = [  # name, kind, length, still
    ("Living room dance", "video", "0:15", "angles/full.webp"),
    ("Downloaded clip 0412", "video", "0:23", "angles/mcu.webp"),
    ("Night drive", "audio", "2:48", None),
    ("Studio logo", "image", None, "lighting/neon.webp"),
    ("Voice-over 1", "audio", "0:12", None),
    ("Street walk", "video", "0:08", "angles/ots.webp"),
]


def css(t, k):
    f = t["text"]
    return f"""
.sheet{{display:flex;gap:40px;padding:56px 40px 40px;background:{'#060707' if k == 'b' else '#E2DCD1'}}}
.col{{display:flex;flex-direction:column;gap:12px}}
.cap{{font:600 14px/18px "{f}";color:{'#ECEAE5' if k == 'b' else '#141210'}}} .cap span{{font-weight:400;opacity:.7}}
.frame{{width:{PANEL_W}px;height:{H}px;background:var(--canvas);display:flex;overflow:hidden;position:relative;border-radius:6px;
  box-shadow:0 0 0 1px var(--hair)}}
.rail{{width:{RAIL_W}px;flex:none;padding:12px 4px;display:flex;flex-direction:column;align-items:center;gap:4px;border-right:1px solid var(--hair)}}
.tab{{width:64px;height:56px;border-radius:var(--rk);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;color:var(--ink2);font:500 11px/14px "{f}"}}
.tab.on{{background:var(--field);color:var(--ink)}}
.pn{{flex:1;min-width:0;display:flex;flex-direction:column;position:relative}}
.hd{{height:48px;padding:0 8px 0 16px;display:flex;align-items:center;gap:8px;flex:none}}
.h{{font:600 16px/22px "{f}";flex:1}}
.add{{height:28px;padding:0 10px 0 8px;border-radius:var(--rk);background:var(--field);display:flex;align-items:center;gap:6px;font:500 13px/18px "{f}";color:var(--ink)}}
.ib{{width:28px;height:28px;display:grid;place-items:center;color:var(--ink2);border-radius:var(--rk)}}
.chips{{display:flex;gap:4px;padding:0 12px 12px}}
.chip{{height:24px;padding:0 8px;border-radius:var(--rp);display:flex;align-items:center;font:500 12px/16px "{f}";color:var(--ink2)}}
.chip.on{{background:var(--field);color:var(--ink)}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:12px 8px;padding:0 12px}}
.tile{{display:flex;flex-direction:column;gap:4px;min-width:0}}
.th{{height:124px;border-radius:var(--rc);overflow:hidden;position:relative;background:var(--field)}}
.th img{{width:100%;height:100%;object-fit:cover;display:block}}
.badge{{position:absolute;left:6px;bottom:6px;height:18px;padding:0 5px;border-radius:var(--rp);background:var(--scrim);color:#fff;display:flex;align-items:center;gap:4px;font:500 11px/14px "{f}"}}
.plus{{position:absolute;right:6px;top:6px;width:28px;height:28px;border-radius:var(--rk);background:var(--scrim);color:#fff;display:grid;place-items:center}}
.nm{{font:400 12px/16px "{f}";color:var(--ink);white-space:nowrap;overflow:hidden}}
.tip{{position:absolute;z-index:3;background:{'#2A2D30' if k == 'b' else '#FBF9F5'};color:var(--ink);font:400 12px/16px "{f}";padding:4px 8px;border-radius:4px;
  box-shadow:{'0 0 0 1px #3A3E42' if k == 'b' else '0 4px 12px rgba(20,18,16,.18),0 0 0 .5px rgba(20,18,16,.2)'};white-space:nowrap}}
.wave{{position:absolute;inset:22px 10px 30px;display:flex;align-items:center;gap:2px}}
.wave i{{flex:1;background:var(--ink2);border-radius:1px;opacity:.85}}
.drop{{margin:4px 12px 12px;flex:1;border:1.5px dashed var(--hair);border-radius:var(--rc);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;
  color:var(--ink2);font:400 13px/18px "{f}"}}
.menu{{position:absolute;z-index:4;right:8px;top:42px;width:236px;white-space:nowrap;padding:5px;border-radius:8px;background:{'#232629' if k == 'b' else '#FBF9F5'};
  box-shadow:{'0 0 0 1px #3A3E42' if k == 'b' else '0 12px 32px rgba(20,18,16,.18),0 0 0 .5px rgba(20,18,16,.2)'};font:400 13px/18px "{f}"}}
.mi{{height:26px;padding:0 10px 0 24px;border-radius:5px;display:flex;align-items:center;color:var(--ink);position:relative}}
.mi.hi{{background:var(--accent);color:{'#1A1205' if k == 'b' else '#FFFFFF'}}}
.mi .k{{margin-left:auto;opacity:.6}}
.mi .ck{{position:absolute;left:6px;top:5px}}
.sep{{height:1px;background:var(--hair);margin:5px 8px}}
.rec{{height:36px;margin:0 12px 12px;padding:0 4px 0 10px;border-radius:var(--rk);background:var(--field);display:flex;align-items:center;gap:8px;font:500 13px/18px "{f}"}}
.dot{{width:8px;height:8px;border-radius:50%;background:var(--danger)}}
.stop{{margin-left:auto;height:28px;padding:0 10px;border-radius:var(--rk);background:var(--canvas);display:flex;align-items:center;font:500 13px/18px "{f}"}}
/* today */
.old-row{{display:flex;align-items:center;gap:8px;font:400 13px/18px "{f}";height:32px}}
.old-btn{{height:32px;padding:0 12px;border-radius:var(--rk);background:var(--field);display:inline-flex;align-items:center;gap:8px;font:500 14px/18px "{f}";white-space:nowrap;align-self:flex-start}}
.note{{display:flex;gap:10px;padding:12px 14px;border-radius:var(--rk);background:var(--field);font:400 13px/18px "{f}"}}
.chk{{display:flex;align-items:center;gap:6px;font:400 13px/18px "{f}";color:var(--ink2)}}
.chk i{{width:14px;height:14px;border-radius:3px;border:1px solid var(--ink2);display:inline-block}}
"""


def rail(on="Uploads"):
    return '<div class="rail">' + "".join(
        f'<div class="tab{" on" if n == on else ""}">{I(ic, 16)}<span>{n}</span></div>' for n, ic in TABS) + "</div>"


def header(rec=False):
    right = "" if rec else f'<div class="add">{I("plus", 14)}Add</div>'
    return f'<div class="hd"><div class="h">Uploads</div>{right}<div class="ib">{I("caret-double-left", 16)}</div></div>'


def frame(inner, on="Uploads"):
    return f'<div class="frame">{rail(on)}<div class="pn">{inner}</div></div>'


def wave(seed):
    import math
    bars = "".join(f'<i style="height:{int(18 + 70 * abs(math.sin(i * 0.7 + seed) * math.cos(i * 0.23 + seed * 2)))}%"></i>' for i in range(22))
    return f'<div class="wave">{bars}</div>'


def tile(name, kind, length, still, hover=False):
    mark = {"video": "film-strip", "image": "image", "audio": "waveform"}[kind]
    body = f'<img src="{R.img(R.PV / still)}">' if still else wave(len(name))
    badge = f'<div class="badge">{I(mark, 12)}{length or ""}</div>' if length else f'<div class="badge">{I(mark, 12)}</div>'
    plus = f'<div class="plus">{I("plus", 14)}</div>' if hover else ""
    shown = name if len(name) <= 17 else name[:7].rstrip() + "\u2026" + name[-5:].lstrip()
    return f'<div class="tile{" hover" if hover else ""}"><div class="th">{body}{badge}{plus}</div><div class="nm">{shown}</div></div>'


def today(t, k):
    inner = f"""
<div class="hd" style="height:auto;padding:12px 16px 8px"><div class="h">Uploads</div><div class="ib">{I("caret-double-left", 16)}</div></div>
<div style="padding:0 16px;display:flex;flex-direction:column;gap:12px;flex:1">
  <div class="old-row"><span style="color:var(--ink2)">{I("film-strip", 15)}</span><span>Downl…</span><span style="margin-left:auto;color:var(--ink2)">0:23</span>
    <span class="ib" style="color:var(--ink)">{I("plus", 14)}</span><span class="ib" style="color:var(--ink);margin-left:-8px">{I("stack", 14)}</span></div>
  <div class="old-btn">{I("upload-simple", 15)}Import video or picture</div>
  <div class="note"><span style="font-size:13px">✦</span><span>Import voice-overs and sounds from this Mac.</span></div>
  <div style="display:flex;flex-direction:column;gap:8px"><div class="old-btn">{I("music-notes", 15)}Import music</div><div class="old-btn">{I("speaker-high", 15)}Import sound</div></div>
</div>
<div style="padding:16px;display:flex;flex-direction:column;gap:8px">
  <div class="old-btn">{I("upload-simple", 15)}Import</div><div class="old-btn">{I("link", 15)}From a link</div><div class="old-btn">{I("microphone", 15)}Record VO</div>
  <div class="chk"><i></i>Play the video while recording</div>
</div>"""
    return frame(inner)


def empty(t, k):
    return frame(header() + f'<div class="drop">{I("upload-simple", 24)}<span>Drop files here or Add</span></div>')


def filled(t, k, menu=False, rec=False, hover=True):
    tiles = "".join(tile(*it, hover=hover and i == 1) for i, it in enumerate(ITEMS))
    chips = '<div class="chips">' + "".join(f'<div class="chip{" on" if c == "All" else ""}">{c}</div>' for c in ("All", "Video", "Images", "Audio")) + "</div>"
    tip = '<div class="tip" style="left:60px;top:262px">Downloaded clip 0412</div>' if hover and not menu and not rec else ""
    m = ""
    if menu:
        m = (f'<div class="menu"><div class="mi hi">From this Mac…<span class="k">⌘I</span></div><div class="mi">From a link…</div>'
             f'<div class="mi">Record voice-over</div><div class="sep"></div>'
             f'<div class="mi"><span class="ck">{I("check", 13)}</span>Play the video while recording</div></div>')
    recbar = (f'<div class="rec"><span class="dot"></span>Recording<span style="color:var(--ink2);font-weight:400">0:07</span>'
              f'<div class="stop">Stop</div></div>') if rec else ""
    return frame(header(rec) + recbar + chips + f'<div class="grid">{tiles}</div>' + tip + m)


def sheet(t, k):
    cols = [("Today", today(t, k)), ("Empty", empty(t, k)), ("Six uploads", filled(t, k)),
            ("Add", filled(t, k, menu=True, hover=False)), ("Recording a voice-over", filled(t, k, rec=True, hover=False))]
    return '<div class="sheet">' + "".join(
        f'<div class="col"><div class="cap">{c}{"" if i else " <span>(before)</span>"}</div>{body}</div>' for i, (c, body) in enumerate(cols)) + "</div>"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    W, HH = 40 + 5 * PANEL_W + 4 * 40 + 40, 56 + 30 + H + 40
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for k in ("b", "a"):
            t = dict(R.THEMES[k])
            f = Path(tmp) / f"uploads-{k}.html"
            f.write_text(f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{css(t, k)}:root{{--danger:{DANGER[k]}}}</style>'
                         f'<body style="width:{W}px;height:{HH}px;overflow:hidden">{sheet(t, k)}</body>')
            spec.append({"html": f.as_uri(), "png": str(OUT / f"uploads-{k}.png"), "w": W, "h": HH})
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

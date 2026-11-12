"""The floating Claude panel as frosted glass (owner, 2026-11-12: "Liquid Glass in spirit", orb AND panel).

The panel is the system glass material over the app (macOS 26+: .glassEffect in a GlassEffectContainer; older macOS:
.ultraThinMaterial with a bright hairline edge and an inner highlight). Here CSS stands in for it: backdrop blur and
saturation, a tint of the theme's canvas, the hairline and the inner highlight, then the living edge ON TOP of the glass
edge. The orbs are the real shader's overlay (design/direction/orb_frost.py) over a blurred backdrop, exactly the two
layers the Mac draws.

    python3 design/direction/frost_panel.py    → plans/design/claude-panel/frost-panel-{b,a,c}.png
"""
import base64, json, os, subprocess, tempfile
from pathlib import Path

import claude_panel as P
import orb_frost as F

R = P.R
OUT = P.OUT
DARK = {"b"}
STATE = {"idle": "idle", "writing": "thinking", "operating": "operating"}


def b64(p):
    return "data:image/png;base64," + base64.b64encode(Path(p).read_bytes()).decode()


def frost_css(k):
    dark = k in DARK
    tint = 58 if dark else 52
    hair = "rgba(255,255,255,.16)" if dark else "rgba(255,255,255,.75)"
    hi = "rgba(255,255,255,.10)" if dark else "rgba(255,255,255,.55)"
    card = 46 if dark else 50
    return f"""
.glass{{position:absolute;right:24px;top:24px;bottom:24px;width:400px;border-radius:calc(var(--rc) + 4px);overflow:hidden;
  background:color-mix(in srgb,var(--canvas) {tint}%,transparent);
  backdrop-filter:blur(34px) saturate(175%) brightness({0.92 if dark else 1.06});-webkit-backdrop-filter:blur(34px) saturate(175%);
  box-shadow:0 24px 64px rgba(0,0,0,{.5 if dark else .18}),inset 0 0 0 1px {hair},inset 0 1px 0 {hi},inset 0 -1px 0 rgba(255,255,255,{.04 if dark else .3})}}
.glass::before{{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;
  background:linear-gradient(160deg,rgba(255,255,255,{.10 if dark else .35}) 0%,rgba(255,255,255,0) 28%)}}
.edge{{position:absolute;right:24px;top:24px;bottom:24px;width:400px;border-radius:calc(var(--rc) + 4px);padding:1.5px;pointer-events:none;
  background:conic-gradient(from 200deg,#FF3DA8bb,#8E5BFFbb,#3B82FFbb,#2FE0C0bb,#FF3DA8bb);
  -webkit-mask:linear-gradient(#000 0 0) content-box,linear-gradient(#000 0 0);-webkit-mask-composite:xor;mask-composite:exclude;
  filter:drop-shadow(0 0 6px rgba(150,110,255,.35))}}
.glass .p{{background:transparent}}
.glass .card{{background:color-mix(in srgb,var(--raised) {card}%,transparent);box-shadow:inset 0 0 0 1px {hair}}}
.glass .you,.glass .chip,.glass .pill,.glass .bar,.glass .send,.glass .mo.hover,.glass .tile b{{background:color-mix(in srgb,var(--field) 60%,transparent)}}
.glass .comp{{background:color-mix(in srgb,var(--raised) {card}%,transparent);border-color:{hair}}}
.forb{{position:relative;display:inline-block;flex:none;border-radius:50%;
  backdrop-filter:blur(5px) saturate(160%) brightness({1.05 if dark else 1.08});-webkit-backdrop-filter:blur(5px)}}
.forb i{{position:absolute;inset:-5%;background-size:100% 100%}}
"""


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        imgs = {}
        for light in (False, True):
            d = F.overlays(tmp / "ov", 32, light)
            for s in STATE.values():
                imgs[(s, light)] = b64(d / f"{s}-{'light' if light else 'dark'}.png")
        pages = []
        for k in ("b", "a", "c"):
            t = P.THEMES[k]
            light = k not in DARK
            P.orb = lambda size, state, kk, light=light: (f'<span class="forb" role="img" aria-label="Claude" style="width:{size}px;height:{size}px">'
                                                          f'<i style="background-image:url({imgs[(STATE.get(state, "idle"), light)]})"></i></span>')
            body = (P.app_backdrop(t) + f'<div class="glass">{P.panel(t, k)}</div><div class="edge"></div>')
            f = tmp / f"frost-{k}.html"
            f.write_text(f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{P.css(t, k)}{frost_css(k)}</style>'
                         f'<body style="width:1440px;height:900px;overflow:hidden;position:relative">{body}</body>')
            pages.append({"html": f.as_uri(), "png": str(OUT / f"frost-panel-{k}.png"), "w": 1440, "h": 900})
        js = tmp / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 2 });
    await p.goto(j.html); await p.waitForTimeout(500); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(js), json.dumps(pages)], check=True, env={**os.environ, "NODE_PATH": root})


if __name__ == "__main__":
    main()

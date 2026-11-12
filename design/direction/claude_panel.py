"""Renders the Claude panel redesign (owner's chosen reference, 2026-11-12) in MUSE's own themes for review.

Only the right-hand chat panel of the reference is taken (plans/design/claude-panel/owner-reference-2026-11-12.webp),
restyled with plans/design-direction.md tokens: header (title, "Sees" pill, model menu, New chat, History), the reply
cards (Plan, Clip analysis, What I changed, Approve), the live activity strip, quick-action chips and the composer.

    python3 design/direction/claude_panel.py     # writes plans/design/claude-panel/panel-{b,a,c}.png

Rules applied (skill §1, direction §2/§4): tone not shadow; no cards inside cards (the price table is rows inside the
Approve card, not a box); one `action` fill on screen (Approve) so Send stays quiet until there is text; `accent` only
marks progress and the live step; state colour (positive) only on ticked plan steps; Phosphor Regular icons only.
"""
import json, os, subprocess, tempfile
from pathlib import Path

import render as R

R.PHOS = R.REPO / "design/icons/phosphor"
OUT = R.REPO / "plans/design/claude-panel"
THEMES = dict(R.THEMES)
THEMES["c"] = dict(name="Soft Tactile", canvas="#E7E2D9", raised="#F3F0EA", field="#EAE5DC", ink="#23262A", ink2="#5E5C57", hair="#D9D3C8",
                   accent="#4E6B45", action="#4E6B45", onaction="#FFFFFF", scrim="rgba(35,38,42,.55)", display="Outfit", text="Outfit",
                   rc=24, rk=16, rp=12, float="0 12px 32px rgba(35,38,42,.14)", outline="none")
R.FONT_FILES["Outfit"] = [("outfit_400", 400), ("outfit_500", 500), ("outfit_600", 600)]
POSITIVE = {"b": "#7BD88F", "a": "#2F6B3A", "c": "#4E6B45"}
STILL = R.img(R.PV / "angles/mcu.webp")
I = R.icon


def css(t, k):
    f = t["text"]
    return f"""
.p{{width:100%;height:100%;display:flex;flex-direction:column;background:var(--canvas)}}
.hd{{padding:16px 16px 12px;display:flex;flex-direction:column;gap:8px}}
.t17{{font:600 17px/22px "{f}"}} .t13{{font:400 13px/18px "{f}"}} .t13m{{font:500 13px/18px "{f}"}} .t11{{font:500 11px/14px "{f}"}}
.ink2{{color:var(--ink2)}}
.pill{{height:24px;padding:0 8px;border-radius:var(--rp);background:var(--field);display:inline-flex;align-items:center;gap:6px;font:500 12px/16px "{f}";color:var(--ink2);white-space:nowrap}}
.menu{{height:28px;padding:0 8px;border-radius:var(--rp);display:inline-flex;align-items:center;gap:4px;font:500 13px/18px "{f}";color:var(--ink)}}
.ib{{width:28px;height:28px;display:grid;place-items:center;color:var(--ink2);border-radius:var(--rp)}}
.feed{{flex:1;min-height:0;overflow:hidden;padding:4px 16px 0;display:flex;flex-direction:column;gap:16px}}
.who{{display:flex;align-items:baseline;gap:8px;margin-bottom:4px}}
.you{{align-self:flex-end;max-width:86%;background:var(--field);border-radius:var(--rk);padding:8px 12px;font:400 14px/20px "{f}"}}
.card{{background:var(--raised);border-radius:var(--rk);padding:12px}}
.step{{display:flex;gap:8px;align-items:flex-start;font:400 13px/18px "{f}";padding:3px 0}}
.box{{width:16px;height:16px;border-radius:4px;border:1.5px solid var(--ink2);flex:none;margin-top:1px;display:grid;place-items:center}}
.box.on{{border-color:var(--pos);background:var(--pos);color:var(--canvas)}}
.done{{color:var(--ink2)}}
.thumb{{width:112px;height:140px;border-radius:calc(var(--rk) * .8);overflow:hidden;position:relative;flex:none}}
.thumb img{{width:100%;height:100%;object-fit:cover}}
.play{{position:absolute;inset:0;display:grid;place-items:center;color:#fff}}
.play span{{width:36px;height:36px;border-radius:50%;background:var(--scrim);display:grid;place-items:center}}
.dur{{position:absolute;right:6px;bottom:6px;background:var(--scrim);color:#fff;border-radius:6px;padding:1px 6px;font:500 11px/14px "{f}"}}
.mo{{display:flex;gap:8px;align-items:baseline;padding:4px 6px;margin:0 -6px;border-radius:var(--rp);font:400 13px/18px "{f}"}}
.mo .tc{{font:500 12px/18px "{f}";color:var(--ink);width:68px;flex:none}}
.mo.hover{{background:var(--field)}}
.chg{{display:flex;align-items:center;gap:8px;height:32px;font:400 13px/18px "{f}"}}
.chg .to{{color:var(--ink);font-weight:600}}
.undo{{margin-left:auto;display:inline-flex;align-items:center;gap:4px;color:var(--ink2);font:500 12px/16px "{f}"}}
.price{{display:flex;font:400 13px/20px "{f}";color:var(--ink2)}} .price span:last-child{{margin-left:auto;color:var(--ink)}}
.total{{display:flex;font:600 13px/20px "{f}";border-top:1px solid var(--hair);padding-top:6px;margin-top:4px}} .total span:last-child{{margin-left:auto}}
.btns{{display:flex;gap:8px;margin-top:12px}}
.go{{flex:1;height:36px;border-radius:var(--rk);background:var(--action);color:var(--onaction);display:grid;place-items:center;font:600 14px/18px "{f}"}}
.no{{flex:1;height:36px;border-radius:var(--rk);color:var(--ink);display:grid;place-items:center;font:500 14px/18px "{f}";border:1px solid var(--hair)}}
.act{{margin:12px 16px 0;display:flex;flex-direction:column;gap:6px}}
.bar{{height:3px;border-radius:2px;background:var(--field);overflow:hidden}} .bar i{{display:block;height:100%;background:var(--accent)}}
.key{{font:500 11px/14px "{f}";color:var(--ink2);border:1px solid var(--hair);border-radius:4px;padding:1px 5px}}
.chips{{display:flex;gap:6px;padding:12px 16px 8px;flex-wrap:nowrap}}
.chip{{height:28px;padding:0 8px;border-radius:var(--rp);background:var(--field);display:inline-flex;align-items:center;gap:4px;font:500 12px/16px "{f}";white-space:nowrap}}
.comp{{margin:0 16px 16px;background:var(--raised);border-radius:var(--rk);padding:10px 12px 8px;border:1px solid var(--hair)}}
.ph{{font:400 14px/20px "{f}";color:var(--ink2);min-height:40px}}
.send{{width:32px;height:32px;border-radius:calc(var(--rk) * .8);background:var(--field);color:var(--ink2);display:grid;place-items:center;margin-left:auto}}
:root{{--pos:{POSITIVE[k]}}}
"""


def panel(t, k):
    check = I("check", 12)
    steps = [("Watch the clip and lock her look", True), ("Swap the outfit to a hoodie, same light and motion", True), ("Render a 15 s preview for review", False)]
    plan = "".join(f'<div class="step"><span class="box{" on" if d else ""}">{check if d else ""}</span><span class="{"done" if d else ""}">{s}</span></div>' for s, d in steps)
    moments = [("0:00–0:03", "Establishing shot", False), ("0:04–0:10", "Face toward camera, best for the swap", True), ("0:11–0:15", "Closing shot", False)]
    mo = "".join(f'<div class="mo{" hover" if h else ""}"><span class="tc">{tc}</span><span>{lab}</span></div>' for tc, lab, h in moments)
    undo = f'<span class="undo">{I("arrow-counter-clockwise", 14)}Undo</span>'
    return f"""<div class="p">
 <div class="hd">
  <div class="row gap2"><div class="t17 grow">Claude</div>
   <div class="menu">Opus 5.5{I("caret-down", 14)}</div>
   <div class="ib" title="New chat">{I("plus", 18)}</div><div class="ib" title="History">{I("clock-counter-clockwise", 18)}</div></div>
  <div><span class="pill">{I("eye", 14)}Sees: Suite · Swap</span></div>
 </div>
 <div class="feed">
  <div class="you">Swap the outfit to a hoodie, keep the same scene and mood, and give me a quick plan.</div>
  <div>
   <div class="who"><span class="t13m">Claude</span><span class="t11 ink2">2:14 PM</span></div>
   <div class="card"><div class="t13m" style="margin-bottom:6px">Plan: outfit swap</div>{plan}</div>
  </div>
  <div class="card row gap3" style="align-items:flex-start">
   <div class="thumb"><img src="{STILL}"><div class="play"><span>{I("play", 18, "#fff")}</span></div><span class="dur">0:15</span></div>
   <div class="grow"><div class="t13m">Clip analysis</div><div class="t13 ink2" style="margin:2px 0 6px">Three moments in your clip</div>{mo}</div>
  </div>
  <div class="card"><div class="t13m" style="margin-bottom:2px">What I changed</div>
   <div class="chg"><span class="ink2">Background</span>{I("caret-right", 12, "var(--ink2)")}<span class="to">Describe it</span>{undo}</div>
   <div class="chg"><span class="ink2">Outfit</span>{I("caret-right", 12, "var(--ink2)")}<span class="to">Hoodie</span>{undo}</div>
  </div>
  <div class="card">
   <div class="t13m">Generate · 15 s · $1.17</div><div class="t13 ink2" style="margin:2px 0 10px">A new version with the outfit swap</div>
   <div class="price"><span>Video, 15 s at $0.066/s</span><span>$0.99</span></div>
   <div class="price"><span>2 reference images past the 5 included</span><span>$0.18</span></div>
   <div class="total"><span>Total</span><span>$1.17</span></div>
   <div class="btns"><div class="go">Approve</div><div class="no">Decline</div></div>
  </div>
 </div>
 <div class="act">
  <div class="row gap2 t13"><span class="grow">Opening Swap… setting outfit…</span><span class="t11 ink2">42%</span><span class="key">Esc to stop</span></div>
  <div class="bar"><i style="width:42%"></i></div>
 </div>
 <div class="chips"><span class="chip">{I("play-circle", 14)}Watch my clip</span><span class="chip">{I("pencil-simple", 14)}Write the prompt</span><span class="chip">{I("coins", 14)}Check the price</span></div>
 <div class="comp"><div class="ph">Tell me what to do next…</div>
  <div class="row gap2" style="color:var(--ink2)"><span class="ib" title="Attach a file">{I("paperclip", 18)}</span><span class="ib" title="Attach a photo">{I("image", 18)}</span>
   <span class="ib" title="Attach a video">{I("video-camera", 18)}</span><span class="ib" title="Attach a document">{I("file-text", 18)}</span>
   <div class="send" title="Send">{I("paper-plane-right", 16)}</div></div></div>
</div>"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    W, H = 400, 1040
    with tempfile.TemporaryDirectory() as tmp:
        spec = []
        for k in ("b", "a", "c"):
            t = THEMES[k]
            f = Path(tmp) / f"panel-{k}.html"
            f.write_text(f'<!doctype html><meta charset="utf-8"><style>{R.css(t)}{css(t, k)}</style>'
                         f'<body style="width:{W}px;height:{H}px;overflow:hidden">{panel(t, k)}</body>')
            spec.append({"html": f.as_uri(), "png": str(OUT / f"panel-{k}.png"), "w": W, "h": H})
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

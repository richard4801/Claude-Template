"""Mock of the Mac "Recreate this edit" screens (plans/recreate-edit.md), inside the approved Edit layout, for the owner's
approval before building: the Recipe view (a reference broken into its recipe, with how each shot will be made) and the
side-by-side Compare with the match score. All four themes, Soft Tactile first, at 1280 × 800.

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/recreate/render.py   # writes plans/recreate/*.png
Data is workstream 1's fixture (server/api/test/fixtures/recipe-v1.json, a real analysis of the test reference); stand-in
footage is the Blender preview posters (design/previews/moves), no people.
"""
import importlib.util, json, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans" / "recreate"
_spec = importlib.util.spec_from_file_location("editlayout", REPO / "design/edit-layout/render.py")
E = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(E)
icon, css, rail, poster, THEMES = E.icon, E.css, E.rail, E.poster, E.THEMES

REF = json.loads((REPO / "server/api/test/fixtures/recipe-v1.json").read_text())
R = REF["recipe"]
POSTERS = ["follow", "dolly_in", "crane_down"]
BRIEFS = ["Wide · eye level · walks into frame", "Close-up · eye level · flips her hair", "Medium · low angle · holds the pose"]
FILL = [("From your takes", "Living room dance · 82% alike", None), ("To generate", "Push-in on a close-up", "$0.64"), ("To generate", "Still, low angle", "$0.64")]


def topbar(t, title, mode):
    seg = "".join(f'<div class="{"on" if m == mode else ""}">{m}</div>' for m in ["Recipe", "Compare"])
    action = ('<div class="btn action label">' + icon("hammer", 18) + 'Build the edit</div>' if mode == "Recipe"
              else '<div class="btn action label">' + icon("export", 18) + 'Export</div>')
    return f"""<div class="row" style="height:56px;padding:0 16px;gap:12px;border-bottom:1px solid {t['hair']}">
  <div class="btn icon plain" title="Back">{icon('caret-left', 20)}</div>
  <div class="col" style="min-width:0"><div class="heading" style="white-space:nowrap">{title}</div>
    <div class="caption ink2" style="white-space:nowrap">Reference · 4.4 s · 3 shots · kept 30 days</div></div>
  <div class="grow"></div><div class="seg label">{seg}</div><div class="grow"></div>
  <div class="btn plain label">{icon('chat-circle-text', 18)}Claude</div>{action}
</div>"""


def lanes(t, scores=False):
    dur = R["source"]["durationSec"]
    pct = lambda s: s / dur * 100
    shots = ""
    for i, s in enumerate(R["slots"]):
        sel = i == 1
        state, _, price = FILL[i]
        tag = (f'<div class="micro" style="padding:2px 8px;border-radius:{t["rp"]}px;background:{t["raised"]};color:{t["ink"]}">'
               f'{"Yours" if state.startswith("From") else "To generate"}</div>')
        score = (f'<div class="micro num" style="padding:2px 8px;border-radius:{t["rp"]}px;background:{t["raised"]}">{[93, 81, 84][i]}%</div>' if scores else tag)
        shots += (f'<div style="position:absolute;left:calc({pct(s["startSec"]):.2f}% + 2px);width:calc({pct(s["endSec"] - s["startSec"]):.2f}% - 4px);top:6px;bottom:6px;'
                  f'border-radius:{min(t["rk"], 10)}px;overflow:hidden;background:url({poster(POSTERS[i])}) center/cover;'
                  f'{"outline:2px solid " + t["sel"] + ";outline-offset:1px;" if sel else ""}">'
                  f'<div class="row" style="position:absolute;left:6px;right:6px;bottom:6px;gap:6px">'
                  f'<div class="micro" style="padding:2px 8px;border-radius:{t["rp"]}px;background:rgba(0,0,0,.6);color:#fff">{i + 1}</div><div class="grow"></div>{score}</div></div>')
    text = "".join(f'<div class="micro" style="position:absolute;left:{pct(x["startSec"]):.2f}%;width:{pct(x["endSec"] - x["startSec"]):.2f}%;top:8px;height:24px;'
                   f'display:flex;align-items:center;padding:0 8px;border-radius:{min(t["rk"], 8)}px;background:{t["field"]}">“{x["words"].capitalize()}”</div>' for x in R["text"])
    trans = "".join(f'<div style="position:absolute;left:{pct(x["atSec"]):.2f}%;top:6px;transform:translateX(-50%)" class="row">'
                    f'<div class="micro" style="padding:2px 8px;border-radius:{t["rp"]}px;background:{t["field"]}">{x["kind"].capitalize()}</div></div>' for x in R["transitions"])
    beats = "".join(f'<div style="position:absolute;left:{pct(b):.2f}%;top:{10 if b in R["sound"]["strong"] else 16}px;bottom:10px;width:2px;border-radius:1px;'
                    f'background:{t["accent"] if b in R["sound"]["strong"] else t["ink2"]};opacity:{1 if b in R["sound"]["strong"] else .5}"></div>' for b in R["sound"]["beats"])
    ticks = "".join(f'<div class="micro ink2 num" style="position:absolute;left:{x / dur * 100:.2f}%;top:6px">0:{x:04.1f}</div>' for x in [0, 1, 2, 3, 4])

    def lane(ic, label, body, h):
        return (f'<div class="row" style="height:{h}px;border-bottom:1px solid {t["hair"]}">'
                f'<div class="row" style="width:176px;height:100%;padding:0 12px;gap:8px;border-right:1px solid {t["hair"]}">{icon(ic, 18, t["ink2"])}<div class="label">{label}</div></div>'
                f'<div class="grow" style="height:100%;position:relative;margin:0 8px">{body}</div></div>')
    return f"""<div class="col" style="height:268px;border-top:1px solid {t['hair']}">
  <div class="row" style="height:28px;border-bottom:1px solid {t['hair']}"><div style="width:176px;border-right:1px solid {t['hair']};height:100%"></div>
    <div class="grow" style="position:relative;height:100%;margin:0 8px">{ticks}<div style="position:absolute;left:47%;top:0;bottom:-240px;width:2px;background:{t['accent']}"></div></div></div>
  {lane('film-strip', 'Shots', shots, 104)}{lane('text-t', 'Text', text, 40)}{lane('arrows-left-right', 'Transitions', trans, 36)}{lane('metronome', 'Beats · 120 BPM', beats, 44)}
</div>"""


def player(t, label, poster_name, h="100%"):
    return f"""<div class="col grow" style="min-width:0;gap:8px">
  <div class="row"><div class="label grow">{label}</div></div>
  <div class="grow row" style="justify-content:center;background:{t['viewer']};border-radius:{t['rc']}px;min-height:0;overflow:hidden">
    <div style="height:92%;aspect-ratio:9/16;background:url({poster(poster_name)}) center/cover;border-radius:4px;position:relative">
      <div style="position:absolute;left:12%;right:12%;bottom:22%;text-align:center;color:#fff;font-weight:700;font-size:15px;letter-spacing:.5px">SUMMER</div></div></div>
</div>"""


def transport(t):
    return f"""<div class="row" style="gap:8px;justify-content:center">
    <div class="label num" style="width:120px">0:02.1 / 0:04.4</div><div class="grow"></div>
    <div class="btn icon plain" title="Back 1 frame">{icon('skip-back', 20)}</div>
    <div class="btn icon" style="width:40px;height:40px;border-radius:999px;background:{t['ink']};color:{t['canvas']}" title="Play">{icon('play', 20)}</div>
    <div class="btn icon plain" title="Forward 1 frame">{icon('skip-forward', 20)}</div><div class="grow"></div>
    <div class="row" style="width:120px;justify-content:flex-end"><div class="btn icon plain" title="Sound">{icon('speaker-high', 20)}</div></div></div>"""


def recipe_panel(t):
    sw = "".join(f'<div style="flex:1;height:28px;background:{c}"></div>' for c in R["grade"]["swatches"])
    state, why, price = FILL[1]
    return f"""<div class="col" style="width:328px;border-left:1px solid {t['hair']};padding:16px;gap:16px;overflow:hidden">
  <div class="col" style="gap:4px"><div class="heading">Shot 2 of 3</div><div class="caption ink2 num">0:01.5–0:02.7 · 1.2 s · 87% sure</div></div>
  <div class="col" style="gap:6px"><div class="label">What happens</div><div class="caption">{BRIEFS[1]}</div>
    <div class="caption ink2">Camera: push in · Speed: steady</div></div>
  <div class="col" style="gap:8px;padding:12px;border-radius:{t['rk']}px;background:{t['field']}">
    <div class="row"><div class="label grow">{state}</div><div class="label num">{price}</div></div>
    <div class="caption ink2">{why} with your model, 1.2 s, 9:16.</div>
    <div class="row" style="gap:8px"><div class="btn label" style="background:{t['raised']}">Use one of my takes</div></div></div>
  <div style="height:1px" class="hair"></div>
  <div class="col" style="gap:8px"><div class="heading">The whole edit</div>
    <div class="caption">{R['summary']}</div>
    <div class="row caption ink2 num" style="gap:16px"><span>3 shots</span><span>27 cuts a minute</span><span>120 BPM</span></div></div>
  <div class="col" style="gap:8px"><div class="label">Look · {R['grade']['look']['label']}</div>
    <div class="row" style="border-radius:{t['rk']}px;overflow:hidden">{sw}</div></div>
  <div class="col" style="gap:4px"><div class="label">Making it</div>
    <div class="caption ink2">1 shot from your takes, 2 to generate · $1.28 in all. You approve before anything is made.</div></div>
</div>"""


def recipe_page(t):
    return f"""<!doctype html><meta charset="utf-8"><style>{css(t)}</style>
<body style="width:1280px;height:800px"><div class="row" style="height:100%;align-items:stretch">{rail(t)}
<div class="col grow" style="min-width:0">{topbar(t, 'Summer cut', 'Recipe')}
  <div class="row grow" style="min-height:0;align-items:stretch;overflow:hidden">
    <div class="col grow" style="min-width:0;padding:16px;gap:12px">{player(t, 'Reference', 'follow')}{transport(t)}</div>
    {recipe_panel(t)}</div>
  {lanes(t)}
</div></div></body>"""


def compare_page(t):
    m = [("Overall", 86), ("Cuts", 97), ("Text", 90), ("Speed", 78), ("Look", 84), ("Shots", 80)]
    scores = "".join(f'<div class="col" style="gap:2px;min-width:72px"><div class="caption ink2">{n}</div><div class="{"title" if n == "Overall" else "heading"} num">{v}%</div></div>' for n, v in m)
    return f"""<!doctype html><meta charset="utf-8"><style>{css(t)}</style>
<body style="width:1280px;height:800px"><div class="row" style="height:100%;align-items:stretch">{rail(t)}
<div class="col grow" style="min-width:0">{topbar(t, 'Summer cut', 'Compare')}
  <div class="col grow" style="min-height:0;padding:16px;gap:12px;overflow:hidden">
    <div class="row" style="gap:24px">{scores}<div class="grow"></div>
      <div class="btn plain label">{icon('arrows-clockwise', 18)}Fix shot 2</div></div>
    <div class="row grow" style="gap:16px;min-height:0;align-items:stretch">{player(t, 'Reference', 'follow')}{player(t, 'Your edit', 'dolly_out')}</div>
    {transport(t)}</div>
  {lanes(t, scores=True)}
</div></div></body>"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    jobs = []
    for key in ["c", "a", "b", "d"]:
        t = THEMES[key]
        for name, html in [("recipe", recipe_page(t)), ("compare", compare_page(t))]:
            p = tmp / f"{name}_{key}.html"
            p.write_text(html)
            jobs.append(dict(html=p.as_uri(), png=str(OUT / f"{name}_{key}_1280x800.png"), w=1280, h=800))
    js = tmp / "shoot.js"
    js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
    subprocess.run(["node", str(js), json.dumps(jobs)], check=True, cwd=tmp)


if __name__ == "__main__":
    main()

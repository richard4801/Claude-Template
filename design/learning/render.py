"""Mocks of the Mac learning editor screens (workstream 3's spec, plans/learning-editor-ui.md) for the owner's approval,
before anyone builds: the Playbook (Rules, the rule editor, Suggestions), Recipes (grid, detail panel, gaps), the editor's
Claude panel with its Playbook tab, and a sheet of the states. All four themes, Soft Tactile first, at 1280 × 800, inside
the current Mac chrome (top bar, sidebar with Edit selected), as in plans/recreate/built_*.png.

    PHOSPHOR=<unpacked @phosphor-icons/core 2.1.1> python3 design/learning/render.py   # writes plans/learning/*.png
Tokens, fonts, icons and Playwright come from design/edit-layout/render.py. Stand-in pictures are the Blender preview
posters (design/previews/moves), no people. Data is invented but consistent with MUSE (the Recreate fixture "Summer cut").
"""
import importlib.util, json, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans" / "learning"
_spec = importlib.util.spec_from_file_location("editlayout", REPO / "design/edit-layout/render.py")
E = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(E)
icon, poster, THEMES = E.icon, E.poster, E.THEMES

W, H = 1280, 800
SHEET_H = 880

# Theme switcher dots in the top bar, as the built app draws them (two colours per theme).
DOTS = {"a": ("#F8F5EF", "#B5121B"), "b": ("#0D0E0F", "#F2A93B"), "c": ("#E7E2D9", "#4E6B45"), "d": ("#FFFFFF", "#FF7EB6")}


def css(t):
    d4 = t["display"] == "Bricolage Grotesque"
    sel_text = t["sel"]  # D: pink fails as text, its selection mark is ink
    return E.css(t) + f"""
.clamp3{{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}}
.clamp2{{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}}
.one{{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.tag{{height:28px;padding:0 12px;border-radius:{t['rp']}px;display:inline-flex;align-items:center;gap:6px;background:{t['field']};color:{t['ink']};white-space:nowrap}}
.tag.on{{background:transparent;box-shadow:inset 0 0 0 {2 if d4 else 1.5}px {t['sel']};color:{sel_text}}}
.link{{color:{'#1F4BFF' if d4 else t['accent']}}}
.input{{height:32px;border-radius:{t['rk']}px;background:{t['field']};border:1px solid {t['hair']};display:flex;align-items:center;gap:8px;padding:0 10px;color:{t['ink2']}}}
.tip{{position:absolute;padding:3px 8px;border-radius:6px;background:{t['raised']};border:1px solid {t['hair']};box-shadow:{'none' if t['float'] == 'none' else '0 4px 12px rgba(0,0,0,.12)'};white-space:nowrap;z-index:5}}
.skel{{background:{t['ink']};opacity:.09;border-radius:6px}}
.danger{{color:{ {'a': '#B5121B', 'b': '#FF6B5E', 'c': '#A8382F', 'd': '#C8102E'}[t['key']] }}}
.btn.dis{{opacity:.4}}
"""


# ---------- chrome: the built app's top bar and sidebar ----------

def topbar(t):
    dots = "".join(f'<div style="width:18px;height:18px;border-radius:9px;background:linear-gradient(135deg,{a} 50%,{b} 50%);'
                   f'box-shadow:0 0 0 1px {t["hair"]}{(",0 0 0 3px " + t["canvas"] + ",0 0 0 4.5px " + t["ink2"]) if k == t["key"] else ""}"></div>'
                   for k, (a, b) in DOTS.items())
    return f"""<div class="row" style="position:relative;height:52px;border-bottom:1px solid {t['hair']};padding:0 20px 0 96px;gap:12px;flex:none">
  <div class="label" style="width:200px">MUSE Studio</div><div class="grow"></div>
  <div class="row caption ink2" style="position:absolute;left:395px;top:11px;width:420px;height:30px;border-radius:{t['rk']}px;background:{t['field']};padding:0 12px;gap:8px">
    {icon('magnifying-glass', 16, t['ink2'])}<div class="grow">Search or jump to…</div><div class="micro">⌘K</div></div>
  <div class="grow"></div>
  <div class="row" style="gap:12px;width:200px;justify-content:flex-end"><div class="micro ink2">Theme</div>{dots}
    <div style="margin-left:8px">{icon('user-circle', 22, t['ink'])}</div></div>
</div>"""


def sidebar(t):
    groups = [["house", "user", "video-camera", "selection", "scissors", "list", "squares-four", "paper-plane-tilt"], ["plus", "user-plus"], ["users"]]
    html = ""
    for gi, g in enumerate(groups):
        if gi:
            html += f'<div style="width:56px;height:1px;background:{t["hair"]};margin:6px 0"></div>'
        for n in g:
            on = n == "scissors"
            html += (f'<div class="row" style="width:52px;height:30px;justify-content:center;border-radius:{min(t["rk"], 10)}px;position:relative;'
                     f'{"background:" + t["field"] + ";" if on else ""}">{icon(n, 18, t["ink"] if on else t["ink2"])}'
                     f'{"<div style=position:absolute;left:-10px;top:7px;width:3px;height:16px;border-radius:2px;background:" + t["accent"] + "></div>" if on else ""}</div>')
    return (f'<div class="col" style="width:72px;flex:none;align-items:center;gap:4px;padding-top:28px;border-right:1px solid {t["hair"]}">'
            f'<div class="display" style="font-size:28px;line-height:32px;margin-bottom:22px;font-weight:700">M</div>{html}'
            f'<div class="grow"></div><div style="margin-bottom:20px">{icon("sliders-horizontal", 18, t["ink2"])}</div></div>')


def shell(t, body, overlay=""):
    return f"""<!doctype html><meta charset="utf-8"><style>{css(t)}</style>
<body style="width:{W}px;height:{H}px"><div class="col" style="height:100%;position:relative">{topbar(t)}
<div class="row grow" style="min-height:0;align-items:stretch">{sidebar(t)}<div class="col grow" style="min-width:0;position:relative">{body}</div></div>
{overlay}</div></body>"""


def seg(opts, on, cls="label"):
    return f'<div class="seg {cls}">' + "".join(f'<div class="{"on" if o == on else ""}">{o}</div>' for o in opts) + "</div>"


def scrollbar(t, top, height, right=4):
    return f'<div style="position:absolute;right:{right}px;top:{top}px;width:5px;height:{height}px;border-radius:3px;background:{t["ink2"]};opacity:.35"></div>'


# ---------- Playbook ----------

RULES = [
    ("Captions", [
        dict(text="Keep captions in the middle third of the frame, never over her face or the product.", who="Yours", pin=True),
        dict(text="On the hook line, make the first caption bigger and hold it half a beat longer than the rest, then drop to the "
                  "normal size. Posts that did this kept people watching past the first two seconds; the ones that opened on small "
                  "captions lost most viewers before the first cut landed on the beat.",
             who="Learned · 2 posts", pin=True),
        dict(text="Use Word pop captions on talking clips, two or three words at a time.", who="From Claude · 3 corrections", pin=False),
    ]),
    ("Pacing", [
        dict(text="The first cut lands within 1.5 s. No opening shot runs longer than that.", who="Yours", pin=True),
        dict(text="On calm songs, cut once per bar, not on every beat.", who="From Claude · 4 corrections", pin=False, hover=True),
    ]),
    ("Look", [
        dict(text="Leave the look as I set it on the take. Only match colour between shots.", who="Yours", pin=True),
        dict(text="Warm, soft looks did better than high-contrast ones on the café clips.", who="Learned · 2 posts", pin=False),
    ]),
    ("Sound", [
        dict(text="Duck the music under her voice instead of muting it.", who="From Claude · 2 corrections", pin=False),
    ]),
]


def page_head(t, title, sub=None, right="", back="Back to Edit"):
    return f"""<div class="row" style="padding:28px 32px 0 20px;gap:12px;align-items:flex-start;flex:none">
  <div class="btn icon plain" title="{back}" style="margin-top:0">{icon('caret-left', 20)}</div>
  <div class="col grow" style="gap:4px"><div class="display">{title}</div>{f'<div class="caption ink2">{sub}</div>' if sub else ''}</div>
  {right}</div>"""


def add_rule(t, disabled=False):
    return f'<div class="btn action label{" dis" if disabled else ""}">{icon("plus", 18)}Add rule</div>'


def rule_row(t, r, width):
    hov = r.get("hover")
    pin_c = t["accent"] if r["pin"] else t["ink2"]
    if t["key"] == "d" and r["pin"]:
        pin_c = t["ink"]
    ctrls = ""
    if hov:
        ctrls = (f'<div class="btn icon plain" style="position:relative">{icon("pencil-simple", 18, t["ink2"])}'
                 f'<div class="tip micro" style="top:36px;left:-14px;color:{t["ink"]}">Edit rule</div></div>'
                 f'<div class="btn icon plain">{icon("trash", 18, t["ink2"])}</div>')
    return f"""<div class="row" style="gap:16px;padding:10px 8px 10px 12px;margin-left:-12px;border-radius:{t['rk']}px;align-items:flex-start;width:{width}px;
    {'background:' + t['raised'] + ';' if hov else ''}">
  <div class="col grow" style="gap:4px"><div class="clamp3">{r['text']}</div><div class="caption ink2">{r['who']}</div></div>
  <div class="row" style="gap:2px;flex:none">{ctrls}<div class="btn icon plain" title="{'Unpin rule' if r['pin'] else 'Pin rule'}">{icon('push-pin', 18, pin_c)}</div></div>
</div>"""


def rules_list(t, width=660):
    out = ""
    for gi, (area, rows) in enumerate(RULES):
        out += (f'<div class="col" style="gap:4px;{"margin-top:24px" if gi else ""}"><div class="heading" style="margin-bottom:4px">{area}</div>'
                + "".join(rule_row(t, r, width) for r in rows) + "</div>")
    return out


def playbook_page(t, segment, body, add_disabled=False, extra_head=""):
    return f"""{page_head(t, 'Playbook', 'Claude reads these before every edit.', add_rule(t, add_disabled))}
<div class="row" style="padding:24px 32px 0 64px;flex:none;gap:16px">{seg(['Rules', 'Suggestions', 'History'], segment)}{extra_head}</div>
<div class="col grow" style="padding:24px 32px 0 76px;min-height:0;overflow:hidden;position:relative">{body}</div>"""


def playbook_rules(t):
    return shell(t, playbook_page(t, "Rules", rules_list(t) + scrollbar(t, 8, 220)))


SUGGESTIONS = [
    ("You changed the look after Claude's Look 4 times (1 undo)", "Latest in Living room dance (2 days ago) and Kitchen walk (5 days ago)"),
    ("You moved Claude's captions higher 3 times", "Latest in Café counter (yesterday) and Rooftop turn (4 days ago)"),
    ("You shortened Claude's first shot 5 times (2 undos)", "Latest in Summer cut (today) and Kitchen walk (3 days ago)"),
    ("You swapped Claude's crossfades for hard cuts 3 times", "Latest in Mirror outfit swap (last week)"),
    ("You turned the music down after Claude's mix twice", "Latest in Living room dance (2 days ago) and Café counter (yesterday)"),
]


def suggestion_rows(t, width=660, focus=None):
    rows = ""
    for i, (a, b) in enumerate(SUGGESTIONS):
        btn_style = f"background:{t['field']};" if i == focus else ""
        rows += (f'<div class="row" style="gap:16px;padding:12px 0;width:{width}px;align-items:center">'
                 f'<div class="col grow" style="gap:4px"><div>{a}</div><div class="caption ink2">{b}</div></div>'
                 f'<div class="btn plain label link" id="mk{i}" style="{btn_style}">Make a rule</div></div>')
    return f'<div class="col" style="gap:8px">{rows}</div>'


def playbook_suggestions(t):
    return shell(t, playbook_page(t, "Suggestions", suggestion_rows(t)))


AREAS = ["Captions", "Text", "Pacing", "Transitions", "Look", "Motion", "Speed", "Timing", "Sound", "Shape", "Other"]
EVIDENCE = [
    "Correction · Changed the look after Claude's “Look Film” · 2 days ago",
    "Correction · Undid Claude's “Golden warmth” · 3 days ago",
    "Correction · Changed the look after Claude's “Look Film” · 5 days ago",
    "Correction · Changed the look after Claude's “Teal night” · 1 week ago",
]


ANCHOR_X = 756  # centre of the first row's "Make a rule" button (row 148–808 px)


def editor_panel(t):
    d4 = t["key"] == "d"
    area_seg = (f'<div style="display:grid;grid-template-columns:repeat(6,auto);background:{t["field"]};border-radius:{t["rk"]}px;padding:2px;gap:0">'
                + "".join(f'<div class="label" style="height:28px;padding:0 10px;display:flex;align-items:center;justify-content:center;border-radius:{max(t["rk"] - 2, 0)}px;'
                          f'{("background:" + t["raised"] + ";color:" + t["ink"] + (";outline:2px solid #111" if d4 else "")) if a == "Look" else "color:" + t["ink2"]}">{a}</div>'
                          for a in AREAS) + "</div>")
    ev = "".join(f'<div class="caption ink2 one">{e}</div>' for e in EVIDENCE)
    focus = "#111111" if d4 else t["accent"]
    shadow = f"box-shadow:{t['float']};" if t["float"] != "none" else ""
    return f"""<div class="col" style="position:absolute;left:470px;top:286px;width:520px;padding:20px;gap:16px;background:{t['raised']};
    border:1px solid {t['hair']};border-radius:{t['rc'] if t['rc'] < 20 else 20}px;{shadow}z-index:4">
  <div style="position:absolute;left:{ANCHOR_X - 470 - 9}px;top:-9px;width:16px;height:16px;background:{t['raised']};transform:rotate(45deg);
       border-left:1px solid {t['hair']};border-top:1px solid {t['hair']}"></div>
  <div class="title">New rule</div>
  <div style="height:72px;border-radius:{t['rk']}px;background:{t['field']};border:1px solid {t['hair']};box-shadow:0 0 0 2px {focus};padding:10px 12px;position:relative">
    <span style="display:inline-block;width:1.5px;height:19px;background:{t['ink']};vertical-align:-4px;margin-right:1px"></span><span class="ink2">Say what Claude should do instead</span></div>
  <div class="col" style="gap:8px"><div class="label">Area</div><div>{area_seg}</div></div>
  <div class="col" style="gap:6px"><div class="label">Evidence</div>{ev}
    <div><div class="btn plain label link" style="padding:0;margin-top:2px">{icon('plus', 16)}Add a note</div></div></div>
  <div class="row" style="gap:8px;justify-content:flex-end"><div class="btn label">Cancel</div><div class="btn action label dis">Save rule</div></div>
</div>"""


def playbook_editor(t):
    return shell(t, playbook_page(t, "Suggestions", suggestion_rows(t, focus=0)), editor_panel(t))


# ---------- Recipes ----------

TAGS = ["dance", "outfit change", "café", "talking", "golden hour", "trend audio", "slow-mo", "walk-in"]
TILES = [
    dict(name="Summer cut", origin="Reference", badge="4.4 s · 2 cuts", cap="Walk-in, hair flip, hold", p="follow"),
    dict(name="Living room dance", origin="Your edit", badge="15 s · 8 cuts", cap="1.2k views · 42% completion", p="dolly_in"),
    dict(name="Rooftop turn", origin="Your edit", badge="6 s · 4 cuts", cap="860 views · 51% completion", p="crane_down"),
    dict(name="Kitchen walk", origin="Reference", badge="9 s · 7 cuts", cap="Fast cuts, text hook", p="handheld"),
    dict(name="Mirror outfit swap", origin="Reference", badge="12 s · 9 cuts", cap="Spin cut, three outfits", p="orbit_360"),
    dict(name="Café counter", origin="Your edit", badge="8 s · 5 cuts", cap="Slow push-in, warm look", p="steadicam"),
]
GAPS = [
    ("Unknown transition · 4 references", "Latest: a spin blur between two outfits in Mirror outfit swap"),
    ("Lens flare · asked once", "“Add a flare when she turns”, in Rooftop turn"),
    ("Speed ramp on a drop · 2 references", "Latest: slows to a stop on the drop in Kitchen walk"),
]


def tile(t, x, w, selected=False):
    d4 = t["key"] == "d"
    ring = (f"outline:{2}px solid {t['sel']};outline-offset:3px;" if selected else "") if not d4 else ("outline:2px solid #111;outline-offset:3px;" if selected else "")
    edge = f"box-shadow:inset 0 0 0 1px {t['hair']};" if t["key"] != "b" else ""
    return f"""<div class="col" style="gap:8px;width:{w}px">
  <div style="width:{w}px;aspect-ratio:9/16;border-radius:{t['rc']}px;background:url({poster(x['p'])}) center/cover;position:relative;{ring}{edge}">
    <div class="micro num" style="position:absolute;right:8px;bottom:8px;padding:2px 8px;border-radius:{t['rp']}px;background:rgba(0,0,0,.6);color:#fff">{x['badge']}</div></div>
  <div class="col" style="gap:2px"><div class="label one">{x['name']}</div><div class="caption ink2 one">{x['cap']}</div></div></div>"""


def filters(t, wide=True):
    chips = "".join(f'<div class="tag label {"on" if c == "dance" else ""}">{c}</div>' for c in TAGS)
    return f"""<div class="col" style="gap:12px;flex:none">
  <div class="row" style="gap:12px"><div class="input caption" style="width:{240 if wide else 200}px">{icon('magnifying-glass', 16, t['ink2'])}Search recipes</div>
    {seg(['All', 'References', 'Your edits'], 'All')}{seg(['Newest', 'Most viewed'], 'Newest')}</div>
  <div class="row" style="gap:8px;flex-wrap:wrap">{chips}</div></div>"""


def gaps(t):
    rows = "".join(f'<div class="col" style="gap:2px;padding:8px 0"><div class="label">{a}</div><div class="caption ink2">{b}</div></div>' for a, b in GAPS)
    return f'<div class="col" style="margin-top:32px;gap:4px"><div class="heading" style="margin-bottom:4px">Effects MUSE can\'t make yet</div>{rows}</div>'


def recipes(t):
    grid = "".join(tile(t, x, 168) for x in TILES)
    body = f"""{page_head(t, 'Recipes')}
<div class="col grow" style="padding:24px 32px 0 64px;min-height:0;overflow:hidden;position:relative">{filters(t)}
  <div class="row" style="gap:16px;margin-top:24px;align-items:flex-start">{grid}</div>{gaps(t)}{scrollbar(t, 10, 380, 8)}</div>"""
    return shell(t, body)


SOFT_LOOK = ["#3F3A36", "#8A6A4A", "#C9A27A", "#E3CBA8", "#6E7F86"]  # Golden warmth: muted, like the approved Recreate swatches


def shape_strip(t):
    shots = [1.6, 1.2, 2.0, 1.4, 1.8, 1.1, 2.2, 1.5, 2.2]  # 15 s, 9 shots
    trans = {2: "arrows-left-right", 5: "circle-half", 7: "arrows-left-right"}
    tot = sum(shots)
    bars, x = "", 0
    for i, s in enumerate(shots):
        bars += f'<div style="position:absolute;left:{x / tot * 100:.2f}%;width:calc({s / tot * 100:.2f}% - 2px);top:0;bottom:0;background:{t["ink2"]};opacity:{.28 + (i % 3) * .1};border-radius:2px"></div>'
        x += s
        if i in trans:
            bars += f'<div style="position:absolute;left:calc({x / tot * 100:.2f}% - 9px);top:-22px">{icon(trans[i], 16, t["ink2"])}</div>'
    return f'<div style="position:relative;height:28px;margin-top:22px;background:{t["field"]};border-radius:4px">{bars}</div>'


def detail_panel(t):
    sw = "".join(f'<div style="flex:1;height:28px;background:{c}"></div>' for c in SOFT_LOOK)
    perf = [("Views", "1.2k"), ("Likes", "80"), ("Saves", "12"), ("Avg watch", "6.5 s"), ("Completion", "42%"), ("Posts", "1")]
    perf_html = "".join(f'<div class="row caption" style="gap:8px"><span class="ink2" style="width:84px">{k}</span><span class="num">{v}</span></div>' for k, v in perf)
    tags = "".join(f'<div class="tag caption" style="height:26px;padding:0 6px 0 10px">{c}<span title="Remove tag {c}" style="display:flex">{icon("x", 14, t["ink2"])}</span></div>'
                   for c in ["dance", "living room", "trend audio"])
    near = [("Summer cut", "Very close", "follow"), ("Kitchen walk", "Close", "handheld"), ("Café counter", "Different", "steadicam")]
    near_html = "".join(f'<div class="col" style="gap:4px;width:98px"><div style="height:72px;border-radius:{min(t["rk"], 12)}px;background:url({poster(p)}) center 30%/cover"></div>'
                        f'<div class="caption one">{n}</div><div class="micro ink2">{d}</div></div>' for n, d, p in near)
    return f"""<div class="col" style="width:392px;flex:none;background:{t['raised']};border-left:1px solid {t['hair']};position:relative">
  <div class="col grow" style="padding:20px 24px 0;gap:22px;overflow:hidden;min-height:0">
    <div class="col" style="gap:4px">
      <div class="row" style="gap:4px"><div class="title grow one">Living room dance</div>
        <div class="btn icon plain" title="Rename recipe">{icon('pencil-simple', 18, t['ink2'])}</div>
        <div class="btn icon plain" title="Close recipe">{icon('x', 18, t['ink2'])}</div></div>
      <div class="caption">Dance to the hook, quick cuts on the beat, one outfit.</div>
      <div class="caption ink2">Your edit</div></div>
    <div class="col" style="gap:8px"><div class="heading">Shape of the edit</div>{shape_strip(t)}
      <div class="caption ink2 num">9 shots · 32 cuts/min · 120 bpm · 3 text items</div></div>
    <div class="col" style="gap:8px"><div class="row"><div class="heading grow">Look</div><div class="caption ink2">Golden warmth</div></div>
      <div class="row" style="border-radius:{min(t['rk'], 10)}px;overflow:hidden">{sw}</div></div>
    <div class="col" style="gap:8px"><div class="heading">Performance</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;row-gap:4px;column-gap:16px">{perf_html}</div></div>
    <div class="col" style="gap:8px"><div class="heading">Tags</div>
      <div class="row" style="gap:6px;flex-wrap:wrap">{tags}<div class="btn plain caption link" style="height:26px;padding:0 6px">+ Tag</div></div></div>
    <div class="col" style="gap:8px"><div class="heading">Closest recipes</div><div class="row" style="gap:12px">{near_html}</div></div>
  </div>
  <div class="row" style="padding:12px 24px 16px;gap:8px;flex:none;border-top:1px solid {t['hair']}">
    <div class="btn plain label danger" style="padding:0 4px">Delete recipe</div><div class="grow"></div>
    <div class="btn action label">{icon('scissors', 18)}Open edit</div></div>
</div>"""


def recipes_detail(t):
    grid = "".join(tile(t, x, 170, selected=(x["name"] == "Living room dance")) for x in TILES[:4])
    body = f"""{page_head(t, 'Recipes')}
<div class="row grow" style="min-height:0;align-items:stretch;margin-top:0">
  <div class="col grow" style="padding:24px 24px 0 64px;min-height:0;overflow:hidden;position:relative;min-width:0">{filters(t, wide=False)}
    <div class="row" style="gap:16px;margin-top:24px;align-items:flex-start">{grid}</div>{gaps(t)}</div>
  {detail_panel(t)}</div>"""
    # the detail panel spans the full content height: put it beside the header too
    body = f"""<div class="row grow" style="min-height:0;align-items:stretch">
  <div class="col grow" style="min-width:0">{page_head(t, 'Recipes')}
    <div class="col grow" style="padding:24px 24px 0 64px;min-height:0;overflow:hidden">{filters(t, wide=False)}
      <div class="row" style="gap:16px;margin-top:24px;align-items:flex-start">{grid}</div>{gaps(t)}</div></div>
  {detail_panel(t)}</div>"""
    return shell(t, body)


# ---------- the editor's Claude panel, Playbook tab ----------

PINNED = [("Captions", "Keep captions in the middle third of the frame, never over her face or the product."),
          ("Captions", "On the hook line, make the first caption bigger and hold it half a beat longer than the rest."),
          ("Pacing", "The first cut lands within 1.5 s. No opening shot runs longer than that."),
          ("Look", "Leave the look as I set it on the take. Only match colour between shots."),
          ("Sound", "Keep the trend audio at full length; trim the video to it, not the other way round.")]


def claude_panel(t):
    rows, last = "", None
    for a, r in PINNED:
        rows += (f'<div class="micro ink2" style="margin-top:{0 if last is None else 6}px">{a}</div>' if a != last else "") + f'<div class="caption clamp2">{r}</div>'
        last = a
    return f"""<div class="col" style="width:328px;flex:none;border-left:1px solid {t['hair']};background:{t['raised']}">
  <div class="row" style="height:44px;padding:0 12px;gap:8px"><div class="caption ink2 grow">Shared with Claude</div>
    <div class="btn icon plain" title="Hide Claude" style="width:28px;height:28px">{icon('x', 16, t['ink2'])}</div></div>
  <div style="padding:0 12px 8px">{seg(['Chat', 'History', 'Playbook'], 'Playbook', 'caption')}</div>
  <div style="height:1px;background:{t['hair']}"></div>
  <div class="col grow" style="padding:16px;gap:8px;overflow:hidden;min-height:0">
    <div class="caption ink2">Claude reads these before every edit.</div>{rows}</div>
  <div style="padding:8px 12px 12px;border-top:1px solid {t['hair']}"><div class="btn plain label link" style="padding:0 4px">{icon('book-open-text', 18)}Open playbook</div></div>
</div>"""


def editor_topbar(t):
    return f"""<div class="row" style="height:56px;padding:0 16px;gap:12px;border-bottom:1px solid {t['hair']};flex:none">
  <div class="btn icon plain" title="Back">{icon('caret-left', 20)}</div>
  <div class="col" style="min-width:0"><div class="heading" style="white-space:nowrap">Living room dance</div>
    <div class="caption ink2" style="white-space:nowrap">v1 · not exported yet</div></div>
  <div class="grow"></div>{seg(['9:16', '1:1', '4:5', '16:9'], '9:16')}<div class="grow"></div>
  <div class="btn label" style="background:{t['field']}">{icon('chat-circle-text', 18)}Claude</div>
  <div class="btn plain label">{icon('stack', 18)}Templates</div>
  <div class="btn plain label">{icon('lightbulb', 18)}Hook ideas</div>
  <div class="btn action label">{icon('export', 18)}Export</div></div>"""


def editor_media(t):
    tabs = [("film-strip", "Takes", True), ("upload-simple", "Uploads", False), ("music-notes", "Music", False),
            ("text-aa", "Text", False), ("sticker", "Stickers", False), ("stack", "Templates", False)]
    tab_html = "".join(f'<div class="col" style="width:60px;height:52px;align-items:center;justify-content:center;gap:2px;border-radius:{t["rk"]}px;'
                       f'{"background:" + t["field"] + ";color:" + t["ink"] if on else "color:" + t["ink2"]}">{icon(i, 18)}<div class="micro">{l}</div></div>'
                       for i, l, on in tabs)
    tiles = "".join(f'<div class="col" style="gap:4px"><div style="height:96px;border-radius:{t["rk"]}px;background:url({poster(p)}) center/cover"></div>'
                    f'<div class="caption one">{c}</div><div class="micro ink2 num">{d}</div></div>'
                    for p, c, d in [("dolly_in", "Living room dance", "15.0 s"), ("follow", "Kitchen walk", "8.0 s")])
    return f"""<div class="row" style="width:288px;flex:none;border-right:1px solid {t['hair']};align-items:stretch;overflow:hidden">
  <div class="col" style="width:72px;padding:10px 4px;gap:4px;align-items:center;border-right:1px solid {t['hair']}">{tab_html}</div>
  <div class="col grow" style="padding:14px;gap:12px;min-width:0"><div class="heading">Takes</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">{tiles}</div></div></div>"""


def editor_viewer(t):
    return f"""<div class="col grow" style="min-width:0;padding:14px 16px;gap:10px">
  <div class="row" style="gap:8px"><div class="caption ink2">Safe area</div>{seg(['Off', 'TikTok', 'Reels', 'Shorts'], 'TikTok', 'caption')}
    <div class="grow"></div><div class="caption ink2 num">Fit · 100%</div></div>
  <div class="grow row" style="justify-content:center;background:{t['viewer']};border-radius:{t['rc']}px;min-height:0;overflow:hidden">
    <div style="height:92%;aspect-ratio:9/16;background:url({poster('dolly_in')}) center/cover;border-radius:4px"></div></div>
  <div class="row" style="gap:8px"><div class="label num" style="width:120px">0:03.2 / 0:15.0</div><div class="grow"></div>
    <div class="btn icon plain">{icon('skip-back', 20)}</div>
    <div class="btn icon" style="width:40px;height:40px;border-radius:999px;background:{t['ink']};color:{t['canvas']}">{icon('play', 20)}</div>
    <div class="btn icon plain">{icon('skip-forward', 20)}</div><div class="grow"></div><div style="width:120px"></div></div></div>"""


def editor_timeline(t):
    frames = "".join(f'<div style="flex:1;height:100%;background:url({poster(p)}) center/cover"></div>'
                     for p in ["dolly_in", "dolly_in", "follow", "follow", "crane_down", "crane_down", "handheld", "handheld"] * 2)
    ticks = "".join(f'<div class="micro ink2 num" style="position:absolute;left:{x * 100 / 16:.2f}%;top:7px">0:{x:02d}</div>' for x in range(0, 16, 2))
    cap = "".join(f'<div class="micro" style="position:absolute;left:{x}%;top:8px;height:24px;padding:0 8px;display:flex;align-items:center;'
                  f'border-radius:{min(t["rk"], 8)}px;background:{t["field"]}">{w}</div>' for x, w in [(2, "I always"), (18, "order the"), (36, "same thing"), (58, "every time")])

    def track(ic, label, body, h):
        return (f'<div class="row" style="height:{h}px;border-bottom:1px solid {t["hair"]}"><div class="row" style="width:176px;height:100%;padding:0 12px;gap:8px;'
                f'border-right:1px solid {t["hair"]}">{icon(ic, 18, t["ink2"])}<div class="label">{label}</div></div>'
                f'<div class="grow" style="height:100%;padding:6px 8px;position:relative">{body}</div></div>')
    tools = "".join(f'<div class="btn icon plain">{icon(i, 18)}</div>' for i in ["scissors", "trash", "gauge", "diamond", "crop"])
    vid = f'<div class="row" style="height:100%;border-radius:{min(t["rk"], 8)}px;overflow:hidden;width:94%">{frames}</div>'
    return f"""<div class="col" style="height:188px;flex:none;border-top:1px solid {t['hair']}">
  <div class="row" style="height:44px;padding:0 12px;gap:4px;border-bottom:1px solid {t['hair']}">{tools}
    <div class="btn on label" style="margin-left:12px">{icon('magnet', 18)}Ripple</div><div class="btn plain label">{icon('scissors', 18)}Cut silences</div></div>
  <div class="row" style="height:28px;border-bottom:1px solid {t['hair']}"><div style="width:176px;border-right:1px solid {t['hair']};height:100%"></div>
    <div class="grow" style="position:relative;height:100%">{ticks}<div style="position:absolute;left:20%;top:0;bottom:-116px;width:2px;background:{t['accent']}"></div></div></div>
  {track('closed-captioning', 'Captions', cap, 44)}{track('film-strip', 'Video', vid, 72)}</div>"""


def claude_playbook_tab(t):
    body = f"""{editor_topbar(t)}
<div class="row grow" style="min-height:0;align-items:stretch;overflow:hidden">{editor_media(t)}{editor_viewer(t)}{claude_panel(t)}</div>{editor_timeline(t)}"""
    return shell(t, body)


# ---------- states sheet ----------

def frame(t, label, inner, w=290, h=206):
    return f"""<div class="col" style="gap:8px"><div class="caption ink2">{label}</div>
  <div class="col" style="width:{w}px;height:{h}px;border:1px solid {t['hair']};border-radius:{t['rk']}px;overflow:hidden;padding:20px;gap:12px;background:{t['canvas']};position:relative">{inner}</div></div>"""


def states(t):
    sk = lambda w, h=12: f'<div class="skel" style="width:{w}px;height:{h}px"></div>'
    loading = "".join(f'<div class="col" style="gap:8px;margin-bottom:10px">{sk(240)}{sk(180)}{sk(90, 10)}</div>' for _ in range(3))
    head = lambda dis=False: f'<div class="row" style="gap:8px"><div class="heading grow">Playbook</div><div class="btn action label{" dis" if dis else ""}" style="height:28px">{icon("plus", 16)}Add rule</div></div>'
    empty_rules = f"""{head()}<div class="col grow" style="justify-content:center;gap:12px">
      <div class="caption" style="max-width:250px">No rules yet. Claude suggests some from the changes you make to its edits, and you can add your own.</div></div>"""
    empty_sugg = f"""<div class="caption ink2" style="margin-top:auto;margin-bottom:auto;max-width:300px">No suggestions yet. They appear after you change or undo a few of Claude's edits.</div>"""
    error = f"""<div class="col grow" style="justify-content:center;gap:12px"><div class="row caption" style="gap:8px">{icon('warning', 16, t['ink2'])}Couldn't load the playbook · check your connection</div>
      <div><div class="btn label">{icon('arrow-clockwise', 16)}Try again</div></div></div>"""
    full = f"""{head(True)}<div class="caption ink2" style="margin-top:-4px">The playbook holds 200 rules · delete some first</div>
      <div class="col" style="gap:4px"><div>Keep captions in the middle third of the frame.</div><div class="caption ink2">Yours</div></div>"""
    rgrid = "".join(f'<div class="skel" style="width:56px;height:100px;border-radius:{min(t["rc"], 12)}px"></div>' for _ in range(4))
    rloading = f'<div class="row" style="gap:8px">{rgrid}</div><div class="row" style="gap:8px">{sk(56, 10)}{sk(56, 10)}{sk(56, 10)}{sk(56, 10)}</div>'
    rempty = f"""<div class="col grow" style="justify-content:center;gap:12px"><div class="caption" style="max-width:300px">No recipes yet. Recreate an edit or finish one in Edit, and it's saved here.</div>
      <div><div class="btn action label">{icon('arrows-clockwise', 16)}Recreate an edit</div></div></div>"""
    noresults = f"""<div class="col grow" style="justify-content:center;gap:12px"><div class="caption">Nothing matches “dance”</div><div><div class="btn label">Clear filters</div></div></div>"""
    shadow = f"box-shadow:{t['float']};" if t["float"] != "none" else ""
    confirm = lambda title, btn, note: f"""<div class="col" style="margin:auto;width:248px;padding:18px;gap:10px;background:{t['raised']};border:1px solid {t['hair']};border-radius:{min(t['rc'], 16)}px;{shadow}">
      <div class="heading">{title}</div>{f'<div class="caption ink2">{note}</div>' if note else ''}
      <div class="row" style="gap:8px;justify-content:flex-end"><div class="btn label">Keep</div><div class="btn label" style="background:{ {'a': '#B5121B', 'b': '#FF6B5E', 'c': '#A8382F', 'd': '#C8102E'}[t['key']] };color:{'#1A0A08' if t['key'] == 'b' else '#FFFFFF'}">{btn}</div></div></div>"""
    hist = "".join(f'<div class="row" style="gap:12px"><div class="col grow" style="gap:2px"><div class="caption">{a}</div><div class="micro ink2">{b}</div></div><div class="micro ink2">{c}</div></div>'
                   for a, b, c in [("Changed the look after Claude's “Look Film”", "Look", "2 days ago"), ("Undid Claude's crossfade", "Transitions", "3 days ago"),
                                   ("Moved Claude's captions higher", "Captions", "4 days ago")])
    cells = [
        frame(t, "Playbook, loading", loading), frame(t, "Rules, empty", empty_rules), frame(t, "Suggestions, empty", empty_sugg),
        frame(t, "Playbook, error", error), frame(t, "Rules, full (200 rules)", full), frame(t, "History", hist),
        frame(t, "Recipes, loading", rloading), frame(t, "Recipes, empty", rempty), frame(t, "Recipes, no results", noresults),
        frame(t, "Delete a rule", confirm("Delete this rule?", "Delete rule", "")),
        frame(t, "Delete a recipe", confirm("Delete this recipe?", "Delete recipe", "The reference and the take stay.")),
    ]
    return f"""<!doctype html><meta charset="utf-8"><style>{css(t)}</style>
<body style="width:{W}px;height:{SHEET_H}px;padding:32px 36px;overflow:hidden"><div class="title" style="margin-bottom:20px">Playbook and Recipes: states</div>
<div style="display:grid;grid-template-columns:repeat(4,290px);gap:24px 16px">{''.join(cells)}</div></body>"""


# ---------- render ----------

SCREENS = [("playbook_rules", playbook_rules), ("playbook_editor", playbook_editor), ("playbook_suggestions", playbook_suggestions),
           ("recipes", recipes), ("recipes_detail", recipes_detail), ("claude_playbook_tab", claude_playbook_tab)]


def main():
    only = sys.argv[1:]
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    jobs = []
    for key in ["c", "a", "b", "d"]:
        t = dict(THEMES[key], key=key)
        for name, fn in SCREENS + [("states", states)]:
            if only and name not in only:
                continue
            p = tmp / f"{name}_{key}.html"
            p.write_text(fn(t))
            jobs.append(dict(html=p.as_uri(), png=str(OUT / f"{name}_{key}.png"), w=W, h=SHEET_H if name == "states" else H))
    js = tmp / "shoot.js"
    js.write_text("""const { chromium } = require('playwright');
(async () => { const jobs = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 1 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  await b.close(); })();""")
    subprocess.run(["node", str(js), json.dumps(jobs)], check=True, cwd=tmp)


if __name__ == "__main__":
    main()

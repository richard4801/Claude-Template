from base import *
from art import move_svg, MOVES, angle_svg, SHOTS, shot_svg, blocking_plan, greybox, mini_cam_glyph

BODIES = [('body-08-phone', 'Phone UGC', 'Phone · 24 mm · deep focus', 'UGC'), ('body-07-creator-cine', 'Creator Cine', 'FX3 look · FF · 4K 120', None),
          ('body-02-super35', 'Super 35 Digital', 'Alexa 35 look · S35 · 4.6K', None), ('body-01-large-format', 'Large Format', 'Alexa LF look · LF · 4.5K', None),
          ('body-04-fullframe', 'Full-Frame Cine', 'Venice 2 look · FF · 8.6K', None), ('body-03-modular8k', 'Modular 8K', 'V-Raptor look · VV · 8K', None),
          ('body-05-film35', '35mm Film', '4-perf · 500T look', None), ('body-06-film16', 'Super 16 Film', 'S16 · grain · doc', None),
          ('body-10-super8', 'Super 8', 'Home movie · 18 fps', None), ('body-09-dv-camcorder', 'DV Camcorder', 'MiniDV · 2000s · 480i', None)]
LENSES = [('lens-01-clean-prime', 'Clean Sharp Prime', 'Master Prime look · T1.3', None), ('lens-02-anamorphic', 'Anamorphic 2×', 'Oval bokeh · blue flares', None),
          ('lens-03-vintage-anamorphic', 'Vintage Anamorphic', '1970s · amber flares', None), ('lens-04-warm-vintage', 'Warm Vintage', 'Speed Panchro look', None),
          ('lens-05-halation', 'Halation Diffusion', '+ ¼ mist · bloom', None), ('lens-06-macro', 'Macro 100', '1:1 · product detail', 'AD'),
          ('lens-07-cine-zoom', 'Cine Zoom', '24–290 · crash zoom', None), ('lens-08-fisheye', 'Ultra-wide / Fisheye', '14 mm · skate & FPV', None)]
LIGHTS = [('light-01-soft-cross', 'Soft Cross', 'Two softboxes · flattering'), ('light-02-contre-jour', 'Contre-jour', 'Backlight through haze'),
          ('light-03-overhead', 'Overhead Fall', 'Butterfly silk · beauty'), ('light-04-window', 'Window', 'Soft daylight · calm'),
          ('light-05-practicals', 'Practicals', 'Lamps & neon · night'), ('light-06-ring-creator', 'Creator Ring', 'Ring + RGB · talking head')]
PALETTES = [('palette-01-naturalistic', 'Naturalistic Clean', 'True-to-life · neutral'), ('palette-02-teal-orange', 'Teal & Orange', 'Teal shadows · warm skin'),
            ('palette-03-hyper-neon', 'Hyper Neon', 'Magenta & cyan · night'), ('palette-04-bleached-warm', 'Bleached Warm', 'Sun-faded · nostalgic'),
            ('palette-05-sodium-decay', 'Sodium Decay', 'Street-lamp · gritty'), ('palette-06-classic-bw', 'Classic B&W', 'Silver · rich blacks')]


def cam_header(mode='Preset', tab='Rig', t='a'):
    tabs = ['Rig', 'Light & look', 'Move & angle'] if mode == 'Preset' else ['Blocking', 'Guides', 'History']
    th = ''.join(f'<div class="col" style="gap:9px"><span class="t14 {"b" if x == tab else "muted"}">{x}</span><div style="height:2px;background:{"var(--accent)" if x == tab else "transparent"}"></div></div>' for x in tabs)
    rigs = '' if mode != 'Preset' else ('<div class="row g8"><span class="lbl">Start from</span>' + chips(['Auto', 'Phone UGC', 'Vlog cam', 'Creator studio', 'Cinematic'], ['Cinematic']) + '</div>')
    return (f'<div class="col" style="padding:20px 28px 0;gap:14px;flex:none"><div class="row g16">'
            f'<div class="col g6"><span class="lbl">Shot 01 · Café morning · Camera</span><span class="h1" style="font-size:46px">Camera</span></div><div class="fill"></div>'
            + seg(['Preset', 'Directed · Blender'], mode if mode == 'Preset' else 'Directed · Blender', 'big') +
            f'<div class="fill"></div><span class="btn ghost">Cancel</span><span class="btn pri">Apply to shot</span></div>'
            f'<div class="row between" style="height:40px"><div class="row g28" style="align-self:flex-end">{th}</div>{rigs}</div></div><div class="hl"></div>')


def cam_footer(t='a'):
    return (f'<div class="row g16" style="height:60px;flex:none;border-top:1px solid var(--line);padding:0 28px;background:var(--surface)">'
            f'<span class="lbl ink">Your camera</span><span class="mono fill" style="color:var(--ink);white-space:nowrap;overflow:hidden">Super 35 · Anamorphic 40 mm · T2 · 180° · 24 fps · Soft Cross · Teal &amp; Orange · Dolly in 60% + Rack focus · Eye · MCU</span>'
            f'<span class="t12">Camera choices are free</span><span class="btn sm">Save as rig…</span></div>')


def shelf(title, items, on, w=128, h=None, count=None, landscape=False, visible=None):
    cards = []
    for it in items:
        name, tt, sp = it[0], it[1], it[2]
        t2 = it[3] if len(it) > 3 else None
        cards.append(hw_card(name, tt, sp, w, h, on=(tt == on), tag='In bag' if tt == on else None, tag2=t2))
    cnt = count or f'{len(items)}'
    return (f'<div class="col g10" style="min-width:0"><div class="row between"><span class="lbl ink">{title} <span class="muted">· {cnt}</span></span>'
            f'<div class="row g8"><span class="t12">Scroll or ← → to browse · click to put in the bag</span>{ic("chev-l",16)}{ic("chev-r",16)}</div></div>'
            f'<div style="position:relative;overflow:hidden"><div class="row g14 start" style="align-items:flex-start">{"".join(cards)}</div><div class="fade-r"></div></div></div>')


def rig_plate(t='a', w=300, h=232):
    return (f'<div class="plate" style="width:{w}px;height:{h}px;background:var(--plate)">'
            f'<img src="{img("body-02-super35")}" style="position:absolute;left:-18px;top:-6px;width:{int(w*.78)}px;height:{int(w*.78)}px;object-fit:cover">'
            f'<img src="{img("lens-02-anamorphic")}" style="position:absolute;right:-26px;bottom:-34px;width:{int(w*.62)}px;height:{int(w*.62)}px;object-fit:cover;opacity:.96">'
            f'<div style="position:absolute;left:12px;bottom:12px" class="pill" ><span style="color:#ECEAE5">Rig · Cinematic</span></div></div>')


def spec_rows(rows):
    return '<div class="col" style="border-top:1px solid var(--line)">' + ''.join(
        f'<div class="row between" style="height:31px;border-bottom:1px solid var(--line)"><span class="lbl">{a}</span><span class="mono" style="color:var(--ink)">{b}</span></div>' for a, b in rows) + '</div>'


def optics_row(t='a'):
    ruler = ''.join(f'<div style="width:1px;height:{14 if i % 4 == 0 else 7}px;background:{"var(--accent)" if i == 10 else "var(--muted)"};{"width:2px;height:22px;" if i == 10 else ""}"></div>' for i in range(33))
    focal = (f'<div class="box col g10" style="flex:1 1 0;padding:12px 16px;height:150px"><div class="row between"><span class="lbl ink">Focal length</span><span class="fig" style="font-size:26px">40 mm</span></div>'
             f'<div class="row between" style="align-items:flex-end;height:26px">{ruler}</div><div class="row between mono"><span>14</span><span>24</span><span>35</span><span>50</span><span>85</span><span>135</span></div>'
             f'<span class="t12">Anamorphic 40 mm: wide view, tight faces.</span></div>')
    stops = ''.join(f'<span class="chip{" red" if s == "T2" else ""}" style="height:24px;padding:0 7px;font-size:11px">{s}</span>' for s in ['T1.4', 'T2', 'T2.8', 'T4', 'T8', 'T11'])
    ap = (f'<div class="box row g14" style="flex:1.25 1 0;padding:12px 14px;height:150px;align-items:flex-start"><div class="plate" style="width:80px;height:80px;border-radius:40px"><img src="{img("optic-01-iris")}" style="width:100%;height:100%;object-fit:cover"></div>'
          f'<div class="col g10 fill"><div class="row between"><span class="lbl ink">Aperture · depth</span><span class="fig" style="font-size:26px">T2</span></div><div class="row g4 wrap">{stops}</div>'
          f'<div class="col g4"><div class="row" style="height:8px;background:var(--surface2);position:relative"><div style="position:absolute;left:38%;width:16%;top:0;bottom:0;background:var(--accent)"></div></div>'
          f'<div class="row between mono"><span>near</span><span>1.8–2.3 m</span><span>far</span></div></div></div></div>')
    sh = (f'<div class="box row g14" style="flex:1.25 1 0;padding:12px 14px;height:150px;align-items:flex-start"><div class="plate" style="width:80px;height:80px"><img src="{img("optic-02-shutter180")}" style="width:100%;height:100%;object-fit:cover"></div>'
          f'<div class="col g10 fill"><span class="lbl ink">Shutter · fps</span>{seg(["90°", "180°", "360°"], "180°", "sm")}{seg(["24", "25", "30", "48", "60"], "24", "sm")}'
          f'<span class="t12">180° · 24 fps = natural blur</span></div></div>')
    return f'<div class="row g14" style="align-items:stretch">{focal}{ap}{sh}</div>'


def camera_bag(t='a'):
    left = (f'<div class="col g14" style="width:300px;flex:none">{rig_plate(t)}'
            + spec_rows([('Body', 'Super 35 Digital'), ('Sensor', 'S35 · 4.6K · 14 stops'), ('Lens', 'Anamorphic 2× · 40 mm'), ('Aperture', 'T2 · shallow'),
                         ('Shutter / fps', '180° · 24 fps'), ('Stock', 'Clean digital')])
            + f'<span class="t12">Feels like: clean digital cinema with oval bokeh and blue streak flares. Lovely for night, neon and close-ups.</span></div>')
    right = (f'<div class="col g18 fill" style="gap:18px;min-width:0">{shelf("Camera bodies", BODIES, "Super 35 Digital")}'
             f'{shelf("Lenses", LENSES, "Anamorphic 2×")}{optics_row(t)}</div>')
    content = cam_header('Preset', 'Rig', t) + f'<div class="row g28 fill start" style="padding:20px 28px;min-height:0;align-items:flex-start">{left}{right}</div>' + cam_footer(t)
    return desktop(content, t, 'suite', 'shot', name=f'AI · Camera · Preset · Rig{" (dark)" if t == "b" else ""}')


def light_look(t='a'):
    prev = (f'<div class="col g12" style="width:300px;flex:none"><span class="lbl ink">Look preview</span>'
            + scene('palette-02-teal-orange', 300, 380, 'sienna', .55, scale=.86)
            + f'<div class="row g6 wrap"><span class="pill ink">Soft Cross</span><span class="pill ink">Teal &amp; Orange</span><span class="pill">Clean digital</span></div>'
            + slider(35, label='Grain', val='35') + slider(20, label='Halation', val='20') + slider(55, label='Contrast', val='+10') + '</div>')
    lights = shelf('Lighting', LIGHTS, 'Soft Cross', 196, 130)
    pals = shelf('Colour palette', PALETTES, 'Teal & Orange', 196, 130, count='6 of 52')
    stocks = ''.join(hw_card(n, a, b, 112, 112, on=(a == 'Digital sensor'), tag='In bag' if a == 'Digital sensor' else None) for n, a, b in
                     [('stock-03-sensor', 'Digital sensor', 'Clean · no grain'), ('stock-01-35mm', '35mm 500T', 'Tungsten · fine grain'), ('stock-02-16mm', '16mm reversal', 'Grain · halation')])
    film = (f'<div class="row g24 start" style="align-items:flex-start"><div class="col g10"><span class="lbl ink">Film &amp; sensor</span><div class="row g14 start" style="align-items:flex-start">{stocks}</div></div>'
            f'<div class="col g14 fill"><div class="col g8"><span class="lbl ink">Era</span>{chips(["1960s", "1980s", "1990s", "2000s", "Today"], ["Today"])}</div>'
            f'<div class="col g8"><span class="lbl ink">Light tweaks</span>{slider(60, label="Key softness", val="Soft")}{slider(40, label="Colour temp", val="4300 K")}</div></div></div>')
    content = cam_header('Preset', 'Light & look', t) + f'<div class="row g28 fill" style="padding:20px 28px;min-height:0;align-items:flex-start">{prev}<div class="col fill" style="gap:18px;min-width:0">{lights}{pals}{film}</div></div>' + cam_footer(t)
    return desktop(content, t, 'suite', 'shot', name='AI · Camera · Preset · Light & look')


def move_card(k, title, spec, tag, on=None, t='a'):
    sel = on is not None
    badge = f'<div style="position:absolute;top:8px;left:8px;width:22px;height:22px;background:var(--accent);color:#fff;display:flex;align-items:center;justify-content:center;font:600 11px var(--mono)">{on}</div>' if sel else ''
    tg = f'<span class="pill" style="height:18px;padding:0 6px;font-size:9.5px">{tag}</span>'
    return (f'<div class="box col" style="width:180px;flex:none;position:relative;{"outline:2px solid var(--ink);outline-offset:-1px;" if sel else ""}">'
            f'<div class="row center" style="height:80px;background:{"var(--surface)" if not sel else "var(--surface2)"};border-bottom:1px solid var(--line)">{move_svg(k, t, 144, 80)}</div>{badge}'
            f'<div class="col g2" style="padding:8px 10px 10px"><div class="row between"><span class="t13 b">{title}</span>{tg}</div><span class="sp mono" style="font-size:10.5px">{spec}</span></div></div>')


def move_angle(t='a'):
    sel = {'dolly_in': 1, 'rack': 2}
    cards = ''.join(move_card(k, a, b, c, sel.get(k), t) for k, a, b, c in MOVES)
    left = (f'<div class="col g14 fill" style="min-width:0"><div class="row between"><div class="row g8">{chips(["All 16", "UGC", "Cinematic", "Energy", "Subtle"], ["All 16"])}</div>'
            f'<div class="row g8"><span class="pill red">Mix · 2 of 2</span><span class="t12">Loops on hover</span></div></div>'
            f'<div class="row wrap" style="gap:10px;width:750px">{cards}</div></div>')

    def mv(n, title, pct, speed, rng):
        return (f'<div class="col g6" style="padding:9px 12px;border:1px solid var(--line);background:var(--surface)"><div class="row between"><div class="row g8"><span style="width:18px;height:18px;background:var(--accent);color:#fff;font:600 10px var(--mono);display:flex;align-items:center;justify-content:center">{n}</span><span class="t13 b">{title}</span></div><span class="mono">{rng}</span></div>'
                f'<div class="row g10"><span class="lbl" style="width:62px">Intensity</span>{slider(pct)}<span class="mono" style="color:var(--ink);width:34px;text-align:right">{pct}%</span></div>'
                f'<div class="row g10"><span class="lbl" style="width:62px">Speed</span>{seg(["Slow", "Normal", "Fast"], speed)}</div></div>')
    heights = ''.join(f'<div class="col g4 center" style="width:62px"><div style="border:1px solid {"var(--ink)" if k == "eye" else "var(--line)"};background:var(--surface)">{angle_svg(k, t, 60, 42)}</div><span class="mono" style="font-size:10px;color:{"var(--ink)" if k == "eye" else "var(--muted)"}">{n}</span></div>'
                      for k, n in [('ground', 'GROUND'), ('low', 'LOW'), ('eye', 'EYE'), ('high', 'HIGH'), ('over', 'OVERHEAD')])
    shots = ''.join(f'<div class="col g4 center">{shot_svg(vb, t, 38, 50, n == "MCU")}<span class="mono" style="font-size:9.5px;color:{"var(--ink)" if n == "MCU" else "var(--muted)"}">{n}</span></div>' for n, vb in SHOTS)
    right = (f'<div class="col g12" style="width:384px;flex:none"><div class="row g14 start" style="align-items:flex-start"><div class="stage" style="width:84px;height:150px">{greybox(84, 150, "grey", 1)}'
             f'<div style="position:absolute;left:6px;top:6px" class="pill ink">Loop</div></div><div class="col g8 fill"><span class="lbl ink">Greybox preview</span><span class="h3">Dolly in + Rack focus</span>'
             f'<span class="t12">5.0 s · 24 fps · 9:16. Pre-rendered once per move — no Blender needed for presets.</span><div class="row g8"><span class="btn sm">{ic("play",12)} Play</span><span class="btn sm">Swap order</span></div></div></div>'
             f'{mv(1, "Dolly in", 60, "Normal", "0.0–5.0 s")}{mv(2, "Rack focus", 40, "Slow", "2.0–3.0 s")}'
             f'<div class="col g8"><span class="lbl ink">Camera height</span><div class="row g8">{heights}</div></div>'
             f'<div class="col g8"><span class="lbl ink">Framing</span><div class="row g8">{shots}</div></div>'
             f'<div class="row g12"><span class="lbl" style="width:62px">Dutch</span>{slider(0)}<span class="mono" style="color:var(--ink)">0°</span></div></div>')
    content = cam_header('Preset', 'Move & angle', t) + f'<div class="row g24 fill" style="padding:18px 28px;min-height:0;align-items:flex-start">{left}<div class="vl"></div>{right}</div>' + cam_footer(t)
    return desktop(content, t, 'suite', 'shot', name='AI · Camera · Preset · Move & angle')


def status_row(led, title, sub):
    return f'<div class="row g10" style="height:26px"><span class="led {led}"></span><span class="t13 b">{title}</span><span class="t12 fill" style="text-align:right">{sub}</span></div>'


def chat_panel(t='a', w=404):
    def you(txt):
        return f'<div class="col g4" style="align-self:flex-end;max-width:300px"><span class="lbl" style="text-align:right">You · Mac app</span><div style="background:var(--ink);color:var(--bg);padding:10px 12px;font:400 13px/1.45 var(--body)">{txt}</div></div>'

    def tool(n):
        return f'<span class="pill" style="height:20px;font-size:9.5px">{ic("cube",11)} {n}</span>'
    guides = ''.join(f'<div class="col g4"><div class="stage" style="width:44px;height:78px">{greybox(44, 78, k, 0)}</div><span class="mono" style="font-size:9.5px">{n}</span></div>'
                     for k, n in [('grey', 'GREYBOX'), ('depth', 'DEPTH'), ('pose', 'POSE')])
    kfs = ''.join(f'<div class="col g4"><div class="stage" style="width:32px;height:56px">{greybox(32, 56, "grey", i)}</div><span class="mono" style="font-size:9.5px">{n}</span></div>' for i, n in enumerate(['START', 'MID', 'END']))
    return (f'<div class="col panel" style="width:{w}px;flex:none;min-height:0">'
            f'<div class="col g2" style="padding:12px 18px;border-bottom:1px solid var(--line)"><div class="row between"><span class="h3">Direct with Claude</span><span class="pill good">● Live</span></div>'
            f'{status_row("", "Claude session", "Connected · your Claude app")}{status_row("", "Blender 5.2", "Mac Studio · localhost")}{status_row("warn", "Renders", "Uploading 3 of 5 to MUSE")}</div>'
            f'<div class="col g14 fill" style="padding:16px 18px;min-height:0;overflow:hidden">'
            + you('Block a 6 s walk-and-talk: Sienna enters left, turns to camera at the counter at 3.5 s. Noor waits by the window. Push in, then orbit 90°.') +
            f'<div class="col g8"><span class="lbl">Claude</span><span class="t13">Built the café (6 × 4 m) and placed Sienna (1.72 m) and Noor (1.68 m) from their sheets. 35 mm, eye level; push 0.4 m, then orbit 90°.</span>'
            f'<div class="row g4 wrap">{tool("build_stage")}{tool("place_character ×2")}{tool("render_guides")}</div></div>'
            f'<div class="box col g10" style="padding:12px"><div class="row between"><span class="t13 b">Guides ready · rev 4</span><span class="mono">6.0 s · 24 fps</span></div><div class="row g8 start" style="align-items:flex-start">{guides}<div class="vl"></div>{kfs}</div>'
            f'<div class="row g8"><span class="btn sm pri" style="font-size:10.5px">Use for Shot 01</span><span class="btn sm">Compare rev 3</span></div></div>'
            f'</div><div class="col g6" style="padding:10px 18px;border-top:1px solid var(--line);background:var(--surface2)"><div class="row between"><span class="lbl ink">Claude · working on rev 5</span><span class="mono" style="color:var(--ink)">64%</span></div>'
            f'<span class="t12" style="color:var(--ink)">↳ “Slower orbit, keep Noor’s face” — easing the orbit to 45°/s around Noor</span>'
            f'<div class="row g10"><div class="slider"><div class="tr"></div><div class="fl" style="width:64%"></div></div><span class="mono">frame 92 / 144</span></div></div>'
            f'<div class="col g8" style="padding:10px 18px 14px;border-top:1px solid var(--line)"><div class="row g8"><div class="input ph fill">Direct the shot… “lower the camera, lens 50”</div><span class="btn pri" style="width:40px;padding:0">{ic("send",15)}</span></div>'
            f'<span class="t12">Claude never spends money. Generating waits for your tap · est. $1.92 at HD.</span></div></div>')


def directed(t='a'):
    strip = (f'<div class="row g12" style="height:40px"><span class="pill ink">cs_7Q2M</span><span class="t14 b">Café walk-and-talk</span><span class="mono">9:16 · 24 fps · 6.0 s · rev 4</span><div class="fill"></div>'
             f'{seg(["Plan", "Camera view", "Side"], "Plan")}<span class="btn sm">{ic("refresh",13)} Re-render</span></div>')
    px = 108
    ruler = ''.join(f'<div style="position:absolute;left:{110 + i*px}px;top:0;height:22px;border-left:1px solid var(--line);padding-left:4px" class="mono">{i}s</div>' for i in range(7))

    def lane(name, bars, kfs, top):
        b = ''.join(f'<div style="position:absolute;left:{110 + s*px}px;width:{(e-s)*px}px;top:{top+6}px;height:22px;background:{c};color:{tc};font:500 10.5px var(--mono);display:flex;align-items:center;padding-left:8px;white-space:nowrap;overflow:hidden">{lab}</div>' for s, e, lab, c, tc in bars)
        k = ''.join(f'<div class="kf" style="position:absolute;left:{110 + x*px - 5}px;top:{top+12}px"></div>' for x in kfs)
        return f'<div style="position:absolute;left:0;top:{top}px;width:110px;height:34px;display:flex;align-items:center;padding-left:14px" class="lbl ink">{name}</div><div style="position:absolute;left:110px;right:0;top:{top+33}px;height:1px;background:var(--line)"></div>{b}{k}'
    tl = (f'<div style="position:relative;height:178px;flex:none;border-top:1px solid var(--line);background:var(--surface)">{ruler}'
          + lane('Camera', [(0, 4.5, 'push 0.4 m · ease in-out', 'var(--surface2)', 'var(--ink)'), (4.5, 6, 'orbit 90°', '#F1D9D9', 'var(--accent)')], [0, 4.5, 6], 26)
          + lane('Sienna', [(0, 3.5, 'walk → counter · 1.1 m/s', 'var(--surface2)', 'var(--ink)'), (3.5, 6, 'turn · smile to camera', 'var(--surface2)', 'var(--ink)')], [0, 3.5], 62)
          + lane('Noor', [(0, 3.0, 'waits by window', 'var(--surface2)', 'var(--muted)'), (3.0, 6, 'looks at Sienna', 'var(--surface2)', 'var(--ink)')], [3.0], 98)
          + lane('Cuts', [], [], 134) + f'<div style="position:absolute;left:{110+6*px-70}px;top:142px" class="pill">end 6.0 s</div>'
          + f'<div style="position:absolute;left:{110 + 2.4*px}px;top:0;bottom:0;width:2px;background:var(--accent)"></div><div style="position:absolute;left:{110 + 2.4*px + 6}px;top:150px" class="pill red" >2.4 s</div></div>')
    leftc = (f'<div class="col fill" style="min-width:0;padding:14px 24px 0 28px;gap:10px">{strip}<div style="border:1px solid var(--line);align-self:flex-start">{blocking_plan(t, 760, 420, 740, 340)}</div>'
             f'<div class="row g16"><span class="row g6 t12"><span style="width:14px;height:3px;background:var(--accent)"></span>Sienna’s path</span><span class="row g6 t12"><span style="width:14px;height:3px;background:var(--ink)"></span>Noor</span>'
             f'<span class="row g6 t12">{mini_cam_glyph(t,16)} Camera path &amp; view</span><div class="fill"></div><span class="t12">Drag a token or the camera to adjust · Claude sees your edits</span></div></div>')
    content = cam_header('Directed', 'Blocking', t) + f'<div class="row fill" style="min-height:0;align-items:stretch"><div class="col fill" style="min-width:0">{leftc}{tl}</div>{chat_panel(t)}</div>'
    return desktop(content, t, 'suite', 'stage', name='AI · Camera · Directed (Blender)')


def camera_compact(t='a', mode='Preset'):
    plates = ''.join(f'<div class="plate" style="width:58px;height:58px"><img src="{img(n)}" style="width:100%;height:100%;object-fit:cover"></div>' for n in ['body-02-super35', 'lens-02-anamorphic', 'light-01-soft-cross', 'palette-02-teal-orange'])
    return (f'<div class="sec"><div class="row between"><span class="h3">Camera</span>{seg(["Preset", "Directed"], mode)}</div>'
            f'<div class="row g6">{plates}<span class="btn sm" style="height:58px;width:44px;padding:0">{ic("expand",16)}</span></div>'
            f'<span class="mono" style="color:var(--ink)">Super 35 · Anamorphic 40 mm · T2 · Soft Cross · Teal &amp; Orange</span>'
            f'<div class="row g10"><div style="border:1px solid var(--line);background:var(--surface)">{move_svg("dolly_in", t, 76, 42)}</div><div class="col g2 fill"><span class="t13 b">Dolly in · 60% <span class="muted">+ Rack focus</span></span><span class="t12">Eye level · MCU · 0°</span></div>{ic("chev-r",16)}</div></div>')


def quality_grid(on='HD', secs=8, takes=2):
    tiers = [('Draft', .02, '~1 min · check the idea'), ('Standard', .09, '~3 min · everyday'), ('HD', .24, '~5 min · sharp skin & light'), ('Cinema', .48, '~9 min · best motion')]
    cards = ''.join(f'<div class="col g4 box" style="width:166px;padding:10px 12px;{"outline:2px solid var(--ink);outline-offset:-1px;" if n == on else ""}"><div class="row between"><span class="t13 b">{n}</span><span class="price" style="font-size:22px">${p*secs:.2f}</span></div><span class="t12">{d}</span></div>' for n, p, d in tiers)
    return f'<div class="row wrap g8">{cards}</div>'


def take_thumb(state, w=96, h=170, img_name='palette-01-naturalistic', who='sienna', label=''):
    over = ''
    blur = 0
    if state == 'ready':
        over = f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center"><div style="width:34px;height:34px;border-radius:17px;background:rgba(248,245,239,.9);display:flex;align-items:center;justify-content:center;color:#141210">{ic("play",14)}</div></div>'
    elif state == 'render':
        blur = 8
        over = '<div class="frost"></div><div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px"><span style="font:400 30px/1 \'Instrument Serif\';color:#141210">62%</span></div>'
    elif state == 'queue':
        blur = 14
        over = '<div class="frost" style="background:rgba(239,235,227,.6)"></div><div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center"><span class="pill ink">#2 in line</span></div>'
    elif state == 'fail':
        over = '<div style="position:absolute;inset:0;background:rgba(20,18,16,.55);display:flex;align-items:center;justify-content:center"><span class="pill" style="background:#B5121B;color:#fff;border-color:#B5121B">Retry free</span></div>'
    return scene(img_name, w, h, who, .5, blur, extra=over)


def shot_builder(t='a', owner=False):
    cast = (f'<div class="sec"><div class="row between"><span class="lbl ink">Cast</span><span class="t12">Up to 3 · identity locked</span></div>'
            f'<div class="col g10" style="padding:10px;border:1px solid var(--ink);background:var(--surface)"><div class="row g10">{avatar("sienna", 44, 56)}<div class="col g2 fill"><span class="t14 b">Sienna Vale</span><span class="t12">Fashion · 24 · Lead</span></div><span class="pill good">Locked</span></div>'
            f'{sheet_strip("sienna", 32)}<div class="row g6 wrap"><span class="lbl" style="margin-right:4px">Outfit</span><span class="chip on">Green knit set</span><span class="chip">Denim jacket</span><span class="chip dash">+ New</span></div></div>'
            f'<div class="row g10" style="padding:8px 10px;border:1px solid var(--line);background:var(--surface)">{avatar("noor", 32, 40)}<div class="col fill"><span class="t13 b">Noor Adeyemi</span><span class="t12">Tap to add to shot</span></div>{ic("plus",16)}</div></div>')
    scenep = (f'<div class="sec"><div class="row between"><span class="lbl ink">Scene</span>{seg(["Text", "Image", "Refs"], "Text")}</div>'
              f'<div class="input" style="height:118px">Morning in a small Paris café. Sienna walks in from the rain, orders at the counter and turns to camera with a soft smile. Warm window light, steam from the cups.</div>'
              f'<div class="row g6">{chips(["✦ Improve", "Add a beat", "Emotion: warm"])}</div></div>')
    refs = (f'<div class="sec" style="border-bottom:0"><div class="row between"><span class="lbl ink">References</span><span class="t12">3 of 9</span></div><div class="row g8">'
            + ''.join(f'<div class="col g4"><div class="plate" style="width:64px;height:64px"><img src="{img(n)}" style="width:100%;height:100%;object-fit:cover"></div><span class="mono" style="font-size:9.5px">{l}</span></div>' for n, l in [('palette-01-naturalistic', 'LOCATION'), ('light-04-window', 'LIGHT')])
            + f'<div class="col g4"><div style="width:64px;height:64px;border:1px dashed var(--line);display:flex;align-items:center;justify-content:center;color:var(--muted)">{ic("plus",18)}</div><span class="mono" style="font-size:9.5px">START FRAME</span></div></div></div>')
    left = f'<div class="col" style="width:330px;flex:none;border-right:1px solid var(--line);min-height:0;overflow:hidden">{cast}{scenep}{refs}</div>'

    steps = ''.join(f'<div class="row g8"><span style="width:16px;color:{c}">{ic(i,14,2)}</span><span class="t13" style="color:{c2}">{s}</span></div>' for i, s, c, c2 in
                    [('check', 'Keyframe from Sienna’s sheet', 'var(--good)', 'var(--ink)'), ('chev-r', 'Motion &amp; camera', 'var(--accent)', 'var(--ink)'), ('clock', 'Sharpen &amp; finish', 'var(--muted)', 'var(--muted)')])
    over = (f'<div class="frost"></div><div style="position:absolute;left:0;right:0;top:0;bottom:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px">'
            f'<span class="lbl ink">Rendering take 2 of 2</span><span style="font:400 92px/0.9 \'Instrument Serif\';color:#141210">62%</span>'
            f'<div style="width:180px;height:3px;background:rgba(20,18,16,.15)"><div style="width:62%;height:3px;background:#B5121B"></div></div>'
            f'<div class="col g6" style="background:rgba(248,245,239,.86);padding:12px 14px;margin-top:8px">{steps}</div><span class="t12" style="color:#3c3732">About 2 min left · you can leave this screen</span></div>')
    preview = scene('palette-02-teal-orange', 306, 544, 'sienna', .52, 16, extra=over)
    takes = ''.join(f'<div class="col g6">{take_thumb(s, 74, 132, n, "sienna")}<span class="mono" style="font-size:10px">{l}</span></div>' for s, n, l in
                    [('ready', 'palette-02-teal-orange', 'TAKE 1 · 8.0 s'), ('render', 'palette-02-teal-orange', 'TAKE 2 · 62%')])
    centre = (f'<div class="col fill" style="min-width:0;align-items:center;padding:18px 24px;gap:14px;background:var(--surface2)">'
              f'<div class="row g10" style="align-self:stretch"><span class="pill ink">9:16</span><span class="pill">8 s</span><span class="pill">HD</span><div class="fill"></div><span class="btn sm">{ic("eye",13)} Compare</span><span class="btn sm">{ic("scissors",13)} Open in Edit</span></div>'
              f'<div class="row g20" style="align-items:flex-start">{preview}<div class="col g10" style="width:96px"><span class="lbl ink">Takes</span>{takes}<div style="width:74px;height:40px;border:1px dashed var(--line);display:flex;align-items:center;justify-content:center;color:var(--muted)">{ic("plus",16)}</div></div></div></div>')

    if owner:
        rows = [('Draft', 'H3 Lite 768P', '$0.0125/s', 'Replicate'), ('Standard', 'MiniMax H3 768P', '$0.08/s', 'Replicate'),
                ('HD', 'Kling 4.0 1080p', '$0.235/s', 'Replicate'), ('Cinema', 'Seedance 2.0 1080p', '$0.45/s', 'Replicate')]
        tab = ''.join(f'<div class="row g8" style="height:40px;border-bottom:1px solid var(--line)"><span class="t13 b" style="width:70px">{a}</span><span class="t13 fill">{b}</span><span class="mono" style="color:var(--ink)">{c}</span></div>' for a, b, c, d in rows)
        right = (f'<div class="col panel" style="width:380px;flex:none;min-height:0"><div class="sec"><div class="row between"><span class="h3">Engines</span><span class="pill red">Owner only</span></div>'
                 f'<span class="t12">Members only ever see Draft · Standard · HD · Cinema. This drawer shows what each tier runs today.</span></div>'
                 f'<div class="sec">{tab}<div class="row g8"><span class="t12 fill">Auto-route: HD → Kling 4.0 (takes your greybox as camera reference, 10 refs)</span></div></div>'
                 f'<div class="sec"><span class="lbl ink">Camera → prompt (compiled for Kling 4.0)</span><div class="input mono" style="font-size:11.5px;line-height:1.5;color:var(--ink);height:132px">clean digital cinema image, Super 35, anamorphic lens, oval bokeh, horizontal blue flares, 40 mm, shallow depth of field, 180° shutter motion blur · soft cross key light · teal-orange grade · camera: slow dolly in toward eyes, then rack focus to background · eye level, medium close-up · @video_1 = greybox camera reference</div></div>'
                 f'<div class="sec"><span class="lbl ink">Flags</span><div class="row g8"><span class="pill warn">H3 open weights · territory</span><span class="pill">Budget cap $25/day</span></div>'
                 f'<div class="row between"><span class="t13">Cost this shot (2 takes)</span><span class="price">$3.84</span></div><div class="row between"><span class="t12">Provider cost</span><span class="mono" style="color:var(--ink)">$3.76</span></div></div>'
                 f'<div class="sec" style="border-bottom:0">{opt_row("Keep add-on engine warm", "Owner indicator in the title bar", False)}</div></div>')
    else:
        right = (f'<div class="col panel tight" style="width:380px;flex:none;min-height:0">{camera_compact(t)}'
                 f'<div class="sec"><div class="row between"><span class="lbl ink">Length</span>{seg(["4s", "6s", "8s", "10s", "15s"], "8s")}</div>'
                 f'<div class="row between"><span class="lbl ink">Shape</span>{seg(["9:16", "1:1", "4:5", "16:9"], "9:16")}</div>{opt_row("Sound", "Café ambience + footsteps", True)}</div>'
                 f'<div class="sec"><div class="row between"><span class="lbl ink">Quality</span><span class="t12">per 8 s take</span></div>{quality_grid()}'
                 f'<div class="row between"><span class="lbl ink">Takes</span>{seg(["1", "2", "3", "4"], "2")}</div></div>'
                 f'<div class="col g8" style="padding:12px 18px 20px;margin-top:auto"><div class="row between"><span class="t13">8 s · HD · 2 takes</span><span class="price">$3.84</span></div>'
                 f'<div class="row between"><span class="t12">Balance after</span><span class="mono" style="color:var(--ink)">$39.76</span></div><span class="btn pri big">Generate · 2 takes · $3.84</span></div></div>')
    head = (f'<div class="row g16" style="padding:18px 28px 14px;border-bottom:1px solid var(--line);flex:none"><div class="col g6"><span class="lbl">Video suite · Shot</span><span class="h1" style="font-size:46px">Café morning</span></div><div class="fill"></div>'
            f'<span class="t12">Autosaved · 2 min ago</span><span class="btn sm">{ic("storyboard",13)} Add to storyboard</span></div>')
    content = head + f'<div class="row fill" style="min-height:0;align-items:stretch">{left}{centre}{right}</div>'
    return desktop(content, t, 'suite', 'shot', name='AI · Shot builder' + (' · Owner (Engines)' if owner else ''))


def hub(t='a'):
    modes = [('palette-01-naturalistic', 'Shot', 'Text or image → a video of your character, with a real camera.', '⌘N', 'sienna'),
             ('palette-04-bleached-warm', 'Character swap', 'Put your character into a real clip. Draft · Standard · HD.', '⌘⇧S', 'noor'),
             ('palette-02-teal-orange', 'Storyboard', 'A sequence of shots with the same cast, one look.', '⌘⇧B', 'sienna'),
             ('light-06-ring-creator', 'Talking · lipsync', 'Script → voice → talking clip, or re-dub a take.', '', None),
             ('grip-05-slider', 'UGC ad', 'Product refs or a link → review, unboxing, before/after.', '', None),
             ('stock-03-sensor', 'Extend & upscale', 'Longer, smoother, sharper. Finish any take.', '', None)]
    cards = ''.join(f'<div class="col box" style="width:180px;flex:none;overflow:hidden">{scene(n, 180, 132, who, .5, scale=.9)}<div class="col g4" style="padding:12px 12px 14px"><div class="row between"><span class="t14 b">{a}</span><span class="kbd">{k}</span></div><span class="t12" style="height:50px">{d}</span></div></div>' for n, a, d, k, who in modes)
    recents = ''.join(f'<div class="col g6">{take_thumb(s, 104, 184, n, w)}<div class="row between" style="width:104px"><span class="mono" style="font-size:10px;color:var(--ink)">{l}</span></div><span class="pill {pc}" style="align-self:flex-start">{p}</span></div>' for s, n, w, l, p, pc in
                      [('ready', 'palette-02-teal-orange', 'sienna', 'CAFÉ · T1', 'Ready', 'good'), ('render', 'palette-02-teal-orange', 'sienna', 'CAFÉ · T2', 'Rendering', 'red'),
                       ('queue', 'palette-03-hyper-neon', 'noor', 'NEON GRWM', '#2 in line', ''), ('fail', 'palette-05-sodium-decay', 'iris', 'NIGHT WALK', 'Failed', 'red'),
                       ])
    sess = ''.join(f'<div class="row g12" style="height:52px;border-bottom:1px solid var(--line)"><div class="stage" style="width:28px;height:44px">{greybox(28, 44, "grey", i)}</div><div class="col g2 fill"><span class="t13 b">{a}</span><span class="t12">{b}</span></div><span class="pill {c}">{d}</span>{ic("chev-r",16)}</div>' for i, (a, b, c, d) in enumerate(
        [('Café walk-and-talk', 'Sienna, Noor · 6.0 s · rev 4 · Blender connected', 'good', 'Guides ready'), ('Rooftop GRWM', 'Noor · 8.0 s · rev 1', '', 'Blocking'), ('Serum orbit (product)', 'Iris · 5.0 s · rev 7', 'ink', 'Generated')]))
    cast = ''.join(f'<div class="row g10" style="padding:10px 0;border-bottom:1px solid var(--line)">{avatar(k, 40, 50)}<div class="col g6 fill"><div class="row between"><span class="t13 b">{CHARS[k]["name"]}</span><span class="pill {c}">{p}</span></div>{sheet_strip(k, 20, 3)}</div></div>' for k, p, c in
                   [('sienna', 'Locked', 'good'), ('noor', 'Locked', 'good'), ('iris', 'Needs close-ups', 'warn')])
    rigs = ''.join(f'<div class="row g8" style="padding:6px;border:1px solid var(--line);background:var(--surface)"><div class="plate" style="width:36px;height:36px"><img src="{img(n)}" style="width:100%;height:100%;object-fit:cover"></div><span class="t13 b">{a}</span></div>' for n, a in
                   [('body-08-phone', 'Phone UGC'), ('body-07-creator-cine', 'Vlog cam'), ('light-06-ring-creator', 'Creator studio'), ('body-02-super35', 'Cinematic')])
    content = (f'<div class="row g24 start" style="padding:26px 32px 18px;align-items:flex-end;flex:none"><div class="col g8"><span class="lbl">MUSE Studio</span><span class="h1" style="font-size:64px">Video suite</span>'
               f'<span class="t14 muted">Make a shot, swap your character into a clip, or plan a whole story — with your cast and a real camera.</span></div><div class="fill"></div>'
               f'<span class="btn">{ic("bag",15)} Camera bag</span><span class="btn pri big">New shot · ⌘N</span></div>'
               f'<div class="row g12" style="padding:0 32px;flex:none">{cards}</div>'
               f'<div class="row g28 fill" style="padding:24px 32px;min-height:0;align-items:flex-start"><div class="col g16 fill" style="min-width:0">'
               f'<div class="row between"><span class="lbl ink">Recent takes</span><span class="t12">See all in Queue →</span></div><div class="row g14 start" style="align-items:flex-start">{recents}</div></div>'
               f'<div class="col g10" style="width:380px;flex:none"><div class="row between"><span class="lbl ink">Camera stage</span><span class="t12">{ic("cube",12)} Blender on Mac Studio · connected</span></div>{sess}'
               f'<div class="row between" style="margin-top:8px"><span class="lbl ink">Saved rigs</span><span class="t12">+ New</span></div><div class="row g8 wrap">{rigs}</div></div>'
               f'<div class="col g4" style="width:250px;flex:none"><div class="row between"><span class="lbl ink">Your cast</span><span class="t12">+ New model</span></div>{cast}</div></div>')
    return desktop(content, t, 'suite', None, job=None, name='AI · Suite hub')


def swap(t='a'):
    checks = ''.join(f'<div class="row g8"><span style="color:{c}">{ic(i,15,2)}</span><span class="t13">{s}</span></div>' for i, s, c in
                     [('check', 'One performer, face visible 94%', 'var(--good)'), ('check', '1080 × 1920 · 12.4 s · 30 fps', 'var(--good)'), ('check', 'Steady lighting', 'var(--good)'), ('clock', 'Fast spin at 0:07 — may soften', 'var(--warn)')])
    left = (f'<div class="col g14" style="width:300px;flex:none;padding:18px 20px;border-right:1px solid var(--line)"><div class="row between"><span class="lbl ink">Source clip</span><span class="t12">Change…</span></div>'
            f'{scene("palette-04-bleached-warm", 260, 300, "iris", .5, scale=.84)}<span class="t13 b">dance_trend_0412.mov</span>{checks}'
            f'<div class="col g8" style="margin-top:6px"><span class="lbl ink">Who to replace</span><div class="row g8"><span class="chip on">Performer A · centre</span><span class="chip">Performer B</span></div></div></div>')
    thumbs = ''.join(f'<div style="width:62px;height:40px;flex:none;overflow:hidden">{scene("palette-04-bleached-warm", 62, 40, "iris", .5)}</div>' for _ in range(9))
    centre = (f'<div class="col fill g14" style="min-width:0;padding:18px 24px;background:var(--surface2);align-items:center">'
              f'<div class="row g24" style="align-items:flex-start"><div class="col g8 center"><span class="lbl">Source</span>{scene("palette-04-bleached-warm", 250, 444, "iris", .5)}</div>'
              f'<div class="col center" style="height:444px;justify-content:center;color:var(--muted)">{ic("swap",22)}</div>'
              f'<div class="col g8 center"><span class="lbl ink">Sienna · preview (Draft)</span>{scene("palette-04-bleached-warm", 250, 444, "sienna", .5)}</div></div>'
              f'<div class="col g6" style="align-self:stretch"><div class="row between"><span class="mono">0:00</span><span class="mono" style="color:var(--ink)">Using 0:00–0:10 · 10 s</span><span class="mono">0:12</span></div>'
              f'<div class="row" style="gap:2px;position:relative;border:2px solid var(--ink);overflow:hidden">{thumbs}</div></div></div>')
    rend = [('Draft', '$0.20', '~3 min · check it'), ('Standard', '$0.67', '~10 min · Default'), ('HD', '$1.40', '~18 min · sharpest')]
    rcards = ''.join(f'<div class="col g2 box" style="flex:1 1 0;padding:8px 10px;{"outline:2px solid var(--ink);outline-offset:-1px;" if n == "Standard" else ""}"><span class="t13 b">{n}</span><span class="price" style="font-size:22px">{p}</span><span class="t12">{d}</span></div>' for n, p, d in rend)
    addons = ''.join(f'<div class="row g10" style="height:34px;border-bottom:1px solid var(--line)"><span class="t13 b fill">{a}</span><span class="t12">{b}</span><span class="mono" style="color:var(--ink);width:46px;text-align:right">{c}</span>{tog(o)}</div>' for a, b, c, o in
                     [('Edit', 'Fix hands & details after', '+$0.40', False), ('Fast · beta', 'Half the wait', '+$0.30', False), ('Upscale', '1080p → 4K', '+$0.25', True)])
    right = (f'<div class="col panel tight" style="width:380px;flex:none;min-height:0"><div class="sec"><span class="lbl ink">Character</span><div class="row g10">{avatar("sienna", 40, 50)}<div class="col g4 fill"><span class="t14 b">Sienna Vale</span>{sheet_strip("sienna", 20, 3)}</div>{ic("chev-d",16)}</div>'
             f'<div class="row g6"><span class="lbl" style="margin-right:4px">Outfit</span><span class="chip on">From the clip</span><span class="chip">Green knit set</span></div></div>'
             f'<div class="sec"><div class="row between"><span class="h3">Camera</span><span class="pill">{ic("lock",11)} Follows the clip</span></div><span class="t12">Moves come from the source. You can still change the look:</span>'
             f'<div class="row g6"><div class="plate" style="width:44px;height:44px"><img src="{img("lens-04-warm-vintage")}" style="width:100%;height:100%;object-fit:cover"></div><div class="plate" style="width:44px;height:44px"><img src="{img("palette-04-bleached-warm")}" style="width:100%;height:100%;object-fit:cover"></div><span class="t13 fill">Warm Vintage · Bleached Warm</span>{ic("chev-r",16)}</div></div>'
             f'<div class="sec"><span class="lbl ink">Render</span><div class="row g8">{rcards}</div><span class="lbl ink" style="margin-top:4px">Add-ons</span>{addons}</div>'
             f'<div class="sec" style="border-bottom:0"><div class="row between"><span class="t13 b">Keep the clip’s audio</span>{tog(True)}</div><div class="row between"><span class="t13 b">Lip sync <span class="t12">· +4 min</span></span>{tog(False)}</div></div>'
             f'<div class="col g8" style="padding:10px 18px 18px;margin-top:auto"><div class="row between"><span class="t13">10 s · Standard + Upscale</span><span class="price">$0.92</span></div><span class="btn pri big">Generate · 10 min · $0.92</span></div></div>')
    head = (f'<div class="row g16" style="padding:18px 28px 14px;border-bottom:1px solid var(--line);flex:none"><div class="col g6"><span class="lbl">Video suite · Character swap</span><span class="h1" style="font-size:46px">Swap into a clip</span></div><div class="fill"></div>'
            f'<span class="t12">Consent confirmed for this clip</span><span class="pill good">{ic("shield",12)} OK</span></div>')
    return desktop(head + f'<div class="row fill" style="min-height:0;align-items:stretch">{left}{centre}{right}</div>', t, 'suite', 'swap', name='AI · Character swap')


def storyboard(t='a'):
    shots = [(1, 'palette-01-naturalistic', 'sienna', 'Street → café door', 'Handheld UGC', 'handheld', '3 s', 'Ready', 'good', '“Okay, coffee first.”'),
             (2, 'light-04-window', 'sienna', 'Order at the counter', 'Dolly in', 'dolly_in', '4 s', 'Ready', 'good', '“Oat flat white please!”'),
             (3, 'palette-02-teal-orange', 'sienna', 'Turn to camera, smile', 'Orbit 90°', 'orbit', '5 s', 'Generating 40%', 'red', '“This place is unreal.”'),
             (4, 'palette-04-bleached-warm', 'noor', 'Noor joins at the window', 'Tracking follow', 'track', '4 s', 'Keyframe ✓', '', '—'),
             (5, 'palette-03-hyper-neon', 'sienna', 'Selfie review, close', 'Selfie walk-and-talk', 'selfie', '5 s', 'Needs keyframe', 'warn', '“10/10, go.”'),
             (6, 'palette-06-classic-bw', None, 'End card · logo space', 'Locked-off', 'static', '3 s', 'Draft', '', '—')]
    cards = []
    for n, im, who, title, mv, mk, dur, st, sc, line in shots:
        sel = n == 3
        cards.append(f'<div class="col box" style="width:172px;flex:none;{"outline:2px solid var(--ink);outline-offset:-1px;" if sel else ""}"><div style="position:relative">{scene(im, 172, 220, who, .5, 6 if "Generating" in st else 0, scale=.8)}'
                     f'<div style="position:absolute;left:8px;top:8px;width:26px;height:26px;background:var(--bg);display:flex;align-items:center;justify-content:center;font:400 18px \'Instrument Serif\'">{n}</div>'
                     f'<div style="position:absolute;right:8px;top:8px" class="pill {sc}" >{st}</div></div>'
                     f'<div class="col g6" style="padding:10px"><span class="t13 b">{title}</span><div class="row g6"><div style="border:1px solid var(--line)">{move_svg(mk, t, 54, 30)}</div><span class="t12 fill">{mv}</span><span class="mono" style="color:var(--ink)">{dur}</span></div>'
                     f'<span class="t12" style="font-style:italic">{line}</span></div></div>')
    ribbon = ''.join(f'<div style="width:{int(w*19)}px;height:30px;background:{c};border-right:2px solid var(--bg);display:flex;align-items:center;padding-left:8px;font:500 10.5px var(--mono);color:{tc}">{n}</div>' for n, w, c, tc in
                     [(1, 3, 'var(--ink)', 'var(--bg)'), (2, 4, 'var(--ink)', 'var(--bg)'), (3, 5, 'var(--accent)', '#fff'), (4, 4, 'var(--soft)', 'var(--ink)'), (5, 5, 'var(--soft)', 'var(--ink)'), (6, 3, 'var(--soft)', 'var(--ink)')])
    head = (f'<div class="row g16" style="padding:18px 28px 14px;border-bottom:1px solid var(--line);flex:none"><div class="col g6"><span class="lbl">Video suite · Storyboard</span><span class="h1" style="font-size:46px">Café GRWM · 24 s</span></div><div class="fill"></div>'
            f'<div class="row g8"><span class="lbl">Cast</span>{avatar("sienna", 28, 34)}{avatar("noor", 28, 34)}</div><div class="vl"></div>'
            f'<div class="row g8"><span class="lbl">Look lock</span><div class="plate" style="width:30px;height:30px"><img src="{img("body-02-super35")}" style="width:100%;height:100%;object-fit:cover"></div><div class="plate" style="width:30px;height:30px"><img src="{img("palette-02-teal-orange")}" style="width:100%;height:100%;object-fit:cover"></div><span class="t13 b">Cinematic · Teal &amp; Orange</span></div></div>')
    idea = (f'<div class="row g12" style="padding:14px 28px;flex:none"><div class="input fill" style="background:var(--surface)">Idea: Sienna’s rainy-morning café ritual, ending with a 10/10 selfie review. Noor cameos. Cosy, honest, UGC.</div>'
            f'<span class="btn">{ic("sparkle",14)} Rewrite shot list</span><span class="btn">{ic("plus",14)} Shot</span></div>')
    insp = (f'<div class="col panel" style="width:330px;flex:none"><div class="sec"><div class="row between"><span class="h3">Shot 3</span><span class="pill red">Generating 40%</span></div>'
            f'<div class="input" style="height:92px">Sienna turns from the counter to camera and smiles; steam rises; rain on the window behind.</div></div>'
            f'{camera_compact(t)}<div class="sec"><div class="row between"><span class="lbl ink">Length</span>{seg(["3s", "4s", "5s", "8s"], "5s")}</div><div class="row between"><span class="lbl ink">Quality</span>{seg(["Draft", "Std", "HD", "Cinema"], "HD")}</div></div>'
            f'<div class="sec" style="border-bottom:0"><span class="t12">Keyframe made with Sienna’s sheet. Same cast, look and lens across all shots.</span></div></div>')
    bottom = (f'<div class="row g16" style="height:78px;flex:none;border-top:1px solid var(--line);padding:0 28px;background:var(--surface)"><span class="lbl ink">Sequence</span><div class="row" style="border:1px solid var(--line)">{ribbon}</div>'
              f'<span class="mono" style="color:var(--ink)">24.0 s</span><div class="fill"></div><span class="t12">2 ready · 1 generating · 3 to go</span>'
              f'<span class="btn">{ic("scissors",14)} Assemble in Edit</span><span class="btn pri big">Generate 4 shots · HD · $4.32</span></div>')
    main = f'<div class="col fill" style="min-width:0">{idea}<div class="row g14" style="padding:4px 28px 18px;align-items:flex-start;overflow:hidden">{"".join(cards)}</div></div>'
    return desktop(head + f'<div class="row fill" style="min-height:0;align-items:stretch">{main}{insp}</div>' + bottom, t, 'suite', 'story', name='AI · Storyboard')


def states(t='a'):
    def st(title, sub, body, cap):
        return f'<div class="col g12" style="width:220px;flex:none"><span class="lbl ink">{title}</span>{body}<span class="t13 b">{sub}</span><span class="t12">{cap}</span></div>'
    empty = (f'<div style="width:220px;height:392px;border:1px dashed var(--line);background:var(--surface);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:20px;text-align:center">'
             f'{avatar("sienna", 64, 80)}<span style="font:400 26px/1.05 \'Instrument Serif\'">Your shot<br>appears here</span><span class="t12">Pick a character, describe the moment, press Generate.</span></div>')
    q = take_thumb('queue', 220, 392, 'palette-03-hyper-neon', 'noor')
    r = take_thumb('render', 220, 392, 'palette-02-teal-orange', 'sienna')
    ok = take_thumb('ready', 220, 392, 'palette-02-teal-orange', 'sienna')
    fail = scene('palette-05-sodium-decay', 220, 392, 'iris', .5, extra='<div style="position:absolute;inset:0;background:rgba(20,18,16,.62);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;padding:18px;text-align:center"><span style="font:400 24px/1.1 \'Instrument Serif\';color:#F8F5EF">Iris’s face drifted</span><span class="t12" style="color:#E7E1D6">We stopped early. You weren’t charged.</span><span class="pill" style="background:#B5121B;color:#fff;border-color:#B5121B">Retry free</span><span class="pill" style="color:#F8F5EF;border-color:#F8F5EF">Try Standard</span></div>')
    row = (st('1 · Empty', 'Nothing yet', empty, 'Friendly, shows who’s cast. Generate is the only loud thing.')
           + st('2 · Queued', '#2 in line · ~1 min', q, 'Heavy blur + line position. Leaving is safe; we notify.')
           + st('3 · Rendering', '62% · 3 named steps', r, 'Blur clears as % rises; steps say what’s happening, not how.')
           + st('4 · Ready', 'Plays inline · 8.0 s', ok, 'Loops muted on hover. Keep · Retake · Open in Edit.')
           + st('5 · Failed', 'Plain words · no charge', fail, 'Never blame the user. One-tap retry; cheaper tier offered.'))
    content = (f'<div class="col g8" style="padding:26px 32px 20px;flex:none"><span class="lbl">Video suite · Result pane</span><span class="h1">States</span><span class="t14 muted">The same 9:16 pane across Shot, Swap and Storyboard. Motion: blur eases out over the last 30% so the reveal feels like developing film.</span></div>'
               f'<div class="row g20" style="padding:0 32px;align-items:flex-start">{row}</div>')
    return desktop(content, t, 'suite', 'shot', name='AI · Result states')

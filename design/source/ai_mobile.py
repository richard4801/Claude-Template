from base import *
from art import move_svg, MOVES, angle_svg, SHOTS, shot_svg, blocking_plan, greybox
from ai_desktop import BODIES, LENSES, take_thumb


def m_hub(t='a'):
    modes = [('palette-01-naturalistic', 'Shot', 'Text/image → video', 'sienna'), ('palette-04-bleached-warm', 'Character swap', 'Into a real clip', 'noor'),
             ('palette-02-teal-orange', 'Storyboard', 'Shots, one cast', 'sienna'), ('light-06-ring-creator', 'Talking', 'Voice & lipsync', None),
             ('grip-05-slider', 'UGC ad', 'Product → ad', None), ('stock-03-sensor', 'Extend & upscale', 'Longer, sharper', None)]
    cards = ''.join(f'<div class="col box" style="width:171px;overflow:hidden">{scene(n, 171, 78, w, .5, scale=.95)}<div class="col g2" style="padding:8px 10px 10px"><span class="t13 b">{a}</span><span class="t12">{d}</span></div></div>' for n, a, d, w in modes)
    rec = ''.join(f'<div class="col g4">{take_thumb(s, 72, 128, n, w)}<span class="mono" style="font-size:9.5px">{l}</span></div>' for s, n, w, l in
                  [('ready', 'palette-02-teal-orange', 'sienna', 'CAFÉ · T1'), ('render', 'palette-02-teal-orange', 'sienna', '62%'), ('queue', 'palette-03-hyper-neon', 'noor', '#2'), ('ready', 'palette-04-bleached-warm', 'noor', 'SWAP')])
    c = (f'<div class="col g12" style="padding:10px 16px 0"><div class="row between"><span style="font:400 28px/1 \'Instrument Serif\';letter-spacing:3px">MUSE</span>{ic("bell",22)}</div>'
         f'<div class="row between" style="align-items:flex-end"><span class="h1" style="font-size:42px">Video suite</span><span class="pill">$43.60</span></div>'
         f'<div class="row wrap" style="gap:10px">{cards}</div>'
         f'<div class="row g10 box" style="padding:10px 12px"><div class="stage" style="width:30px;height:46px">{greybox(30, 46, "grey", 0)}</div><div class="col g2 fill"><span class="t13 b">Café walk-and-talk</span><span class="t12">Camera stage · guides ready · Mac connected</span></div>{ic("chev-r",18)}</div>'
         f'<div class="row between"><span class="lbl ink">Recent takes</span><span class="t12">All →</span></div><div class="row g8">{rec}</div></div>')
    return phone(c, t, 'AI · M1 Suite hub', nav='STUDIO')


def tooltabs(on):
    items = [('users', 'CAST'), ('type', 'SCENE'), ('camera', 'CAMERA'), ('clock', 'LENGTH'), ('sliders', 'QUALITY')]
    return '<div class="row" style="justify-content:space-around;height:62px;border-bottom:1px solid var(--line);flex:none">' + ''.join(
        f'<div class="col g4 center" style="color:{"var(--accent)" if n == on else "var(--muted)"}">{ic(i,20)}<span style="font:500 9.5px var(--mono);letter-spacing:.08em">{n}</span></div>' for i, n in items) + '</div>'


def m_shot(t='a'):
    over = ('<div class="frost"></div><div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px">'
            '<span class="lbl ink">Rendering take 2 of 2</span><span style="font:400 64px/0.9 \'Instrument Serif\';color:#141210">62%</span>'
            '<span class="t12" style="color:#3c3732">Motion &amp; camera · ~2 min</span></div>')
    plates = ''.join(f'<div class="col g4"><div class="plate" style="width:80px;height:80px"><img src="{img(n)}" style="width:100%;height:100%;object-fit:cover"></div><span class="mono" style="font-size:9.5px">{l}</span></div>' for n, l in
                     [('body-02-super35', 'BODY'), ('lens-02-anamorphic', 'LENS'), ('light-01-soft-cross', 'LIGHT'), ('palette-02-teal-orange', 'LOOK')])
    c = (scene('palette-02-teal-orange', 390, 286, 'sienna', .5, 14, extra=over) + tooltabs('CAMERA') +
         f'<div class="col g12" style="padding:14px 16px">{seg(["Preset", "Directed · Blender"], "Preset", "fillw")}'
         f'<div class="row g8">{plates}</div><span class="mono" style="color:var(--ink)">Super 35 · Anamorphic 40 mm · T2 · Soft Cross · Teal &amp; Orange</span>'
         f'<div class="row g10 box" style="padding:8px 10px"><div style="border:1px solid var(--line)">{move_svg("dolly_in", t, 72, 40)}</div><div class="col g2 fill"><span class="t13 b">Dolly in · 60%</span><span class="t12">+ Rack focus · Eye · MCU</span></div>{ic("chev-r",18)}</div>'
         f'<span class="btn" style="align-self:stretch">{ic("bag",15)} Open camera bag</span></div>')
    return phone(c, t, 'AI · M2 Shot', title='Shot', cta='Generate · 2 takes · $3.84')


def m_bag(t='a'):
    tabs = ''.join(f'<div class="col" style="gap:7px"><span class="t13 {"b" if x == "Body" else "muted"}">{x}</span><div style="height:2px;background:{"var(--accent)" if x == "Body" else "transparent"}"></div></div>' for x in ['Body', 'Lens', 'Optics', 'Light', 'Look', 'Move', 'Angle'])

    def car(title, items, on, w=96):
        cards = ''.join(hw_card(n, a, b, w, w, on=(a == on), tag='In' if a == on else None) for n, a, b, *_ in items)
        return (f'<div class="col g8"><div class="row between"><span class="lbl ink">{title}</span><span class="t12">{len(items)} · swipe</span></div>'
                f'<div style="position:relative;overflow:hidden;margin-right:-16px"><div class="row g10" style="align-items:flex-start">{cards}</div><div class="fade-r" style="width:50px"></div></div></div>')
    big = (f'<div class="plate" style="width:358px;height:176px;background:var(--plate)"><img src="{img("body-02-super35")}" style="position:absolute;left:-10px;top:-40px;width:250px;height:250px;object-fit:cover">'
           f'<img src="{img("lens-02-anamorphic")}" style="position:absolute;right:-30px;top:-10px;width:200px;height:200px;object-fit:cover">'
           f'<div style="position:absolute;left:12px;bottom:10px;display:flex;flex-direction:column;gap:2px"><span style="font:600 14px var(--body);color:#ECEAE5">Super 35 + Anamorphic 2×</span><span style="font:400 10.5px var(--mono);color:#A9A6A0">Alexa 35 look · S35 · 4.6K · 40 mm · T2</span></div></div>')
    c = (f'<div class="col g12" style="padding:12px 16px 0">{seg(["Preset", "Directed · Blender"], "Preset", "fillw")}<div class="row g20" style="border-bottom:1px solid var(--line)">{tabs}</div>{big}'
         f'{car("Camera bodies", BODIES, "Super 35 Digital")}{car("Lenses", LENSES, "Anamorphic 2×")}</div>')
    return phone(c, t, f'AI · M3 Camera bag{" (dark)" if t == "b" else ""}', title='Camera', right='x', back=False, cta='Apply to shot')


def m_move(t='a'):
    sel = {'dolly_in': 1, 'rack': 2}
    pick = [m for m in MOVES if m[0] in ('static', 'handheld', 'selfie', 'dolly_in', 'orbit', 'rack', 'crane_up', 'fpv')]
    cards = ''.join(f'<div class="col box" style="width:171px;position:relative;{"outline:2px solid var(--ink);outline-offset:-1px;" if k in sel else ""}"><div class="row center" style="height:66px;border-bottom:1px solid var(--line);background:{"var(--surface2)" if k in sel else "var(--surface)"}">{move_svg(k, t, 118, 66)}</div>'
                    + (f'<div style="position:absolute;top:6px;left:6px;width:20px;height:20px;background:var(--accent);color:#fff;font:600 10px var(--mono);display:flex;align-items:center;justify-content:center">{sel[k]}</div>' if k in sel else '')
                    + f'<div class="row between" style="padding:7px 9px"><span class="t13 b">{a}</span><span class="pill" style="height:17px;font-size:9px;padding:0 5px">{tg}</span></div></div>' for k, a, b, tg in pick)
    tabs = ''.join(f'<div class="col" style="gap:7px"><span class="t13 {"b" if x == "Move" else "muted"}">{x}</span><div style="height:2px;background:{"var(--accent)" if x == "Move" else "transparent"}"></div></div>' for x in ['Body', 'Lens', 'Optics', 'Light', 'Look', 'Move', 'Angle'])
    sheet = (f'<div class="sheet" style="bottom:0;padding:0 16px 104px"><div class="grab"></div><div class="col g10"><div class="row between"><span class="h3">1 · Dolly in</span><span class="t12">loops in preview</span></div>'
             f'<div class="row g10"><span class="lbl" style="width:64px">Intensity</span>{slider(60)}<span class="mono" style="color:var(--ink)">60%</span></div>'
             f'<div class="row g10"><span class="lbl" style="width:64px">Speed</span>{seg(["Slow", "Normal", "Fast"], "Normal", "fillw")}</div></div></div>')
    c = (f'<div class="col g12" style="padding:12px 16px 0"><div class="row g20" style="border-bottom:1px solid var(--line)">{tabs}</div>'
         f'<div class="row between">{chips(["All", "UGC", "Cinematic", "Energy"], ["All"])}<span class="pill red">Mix 2/2</span></div><div class="row wrap" style="gap:10px">{cards}</div></div>{sheet}')
    return phone(c, t, 'AI · M4 Move', title='Camera', right='x', back=False, cta='Apply to shot')


def m_directed(t='a'):
    st = ''.join(f'<div class="row g8" style="height:24px"><span class="led {l}"></span><span class="t13 b">{a}</span><span class="t12 fill" style="text-align:right">{b}</span></div>' for l, a, b in
                 [('', 'Claude session', 'Connected'), ('', 'Blender on Mac Studio', 'Connected'), ('warn', 'Renders', '64% · greybox')])
    plan = f'<div style="width:358px;height:196px;overflow:hidden;border:1px solid var(--line)"><div style="transform:scale(.47);transform-origin:0 0;width:760px">{blocking_plan(t, 760, 420)}</div></div>'
    c = (f'<div class="col g12" style="padding:12px 16px 0"><div class="row between"><div class="col g2"><span class="t14 b">Café walk-and-talk</span><span class="mono">cs_7Q2M · 6.0 s · rev 4</span></div><span class="pill good">Guides ready</span></div>'
         f'<div class="col box" style="padding:8px 12px">{st}</div>{plan}'
         f'<div class="col g4" style="align-self:flex-end;max-width:290px"><div style="background:var(--ink);color:var(--bg);padding:9px 11px;font:400 13px/1.4 var(--body)">Slower orbit, and keep Noor’s face visible at the end.</div></div>'
         f'<div class="col g6"><span class="lbl">Claude · working</span><span class="t13">Easing the orbit to 45°/s and pivoting around Noor…</span><div class="row g8"><div class="slider"><div class="tr"></div><div class="fl" style="width:64%"></div></div><span class="mono" style="color:var(--ink)">64%</span></div></div>'
         f'<div class="row g8">' + ''.join(f'<div class="stage" style="width:46px;height:82px">{greybox(46, 82, k, 0)}</div>' for k in ['grey', 'depth', 'pose']) + f'<div class="col g4 fill"><span class="t13 b">rev 4 guides</span><span class="t12">Greybox · depth · pose · 3 keyframes</span><span class="t12 acc">Use for Shot 01 →</span></div></div></div>')
    comp = (f'<div style="position:absolute;left:0;right:0;bottom:24px;padding:10px 16px;border-top:1px solid var(--line);background:var(--bg)" class="row g8"><div class="input ph fill">Direct the shot…</div>'
            f'<span class="btn pri" style="width:42px;padding:0">{ic("send",15)}</span></div>')
    return phone(c, t, 'AI · M5 Directed', title='Direct with Claude', extra=comp)


def m_swap(t='a'):
    rend = ''.join(f'<div class="col g2 box" style="flex:1 1 0;padding:9px 10px;{"outline:2px solid var(--ink);outline-offset:-1px;" if n == "Standard" else ""}"><span class="t13 b">{n}</span><span class="price" style="font-size:20px">{p}</span><span class="t12">{d}</span></div>' for n, p, d in [('Draft', '$0.20', '3 min'), ('Standard', '$0.67', '10 min'), ('HD', '$1.40', '18 min')])
    ad = ''.join(f'<div class="row g10" style="height:40px;border-bottom:1px solid var(--line)"><span class="t13 b fill">{a}</span><span class="mono" style="color:var(--ink)">{b}</span>{tog(o)}</div>' for a, b, o in [('Edit', '+$0.40', False), ('Fast · beta', '+$0.30', False), ('Upscale', '+$0.25', True)])
    c = (f'<div class="col g12" style="padding:12px 16px 0"><div class="row g10">{scene("palette-04-bleached-warm", 174, 300, "iris", .5)}{scene("palette-04-bleached-warm", 174, 300, "sienna", .5)}</div>'
         f'<div class="row between"><span class="mono">SOURCE · 12.4 s</span><span class="mono" style="color:var(--ink)">SIENNA · DRAFT PREVIEW</span></div>'
         f'<div class="row g8"><span class="pill">{ic("lock",11)} Camera follows the clip</span><span class="pill">Look: Warm Vintage</span></div>'
         f'<span class="lbl ink">Render</span><div class="row g8">{rend}</div><div class="col">{ad}</div></div>')
    return phone(c, t, 'AI · M6 Character swap', title='Character swap', cta='Generate · 10 min · $0.92')


def m_story(t='a'):
    rows = [(1, 'palette-01-naturalistic', 'sienna', 'Street → café door', 'handheld', 'Handheld UGC · 3 s', 'Ready', 'good'),
            (2, 'light-04-window', 'sienna', 'Order at the counter', 'dolly_in', 'Dolly in · 4 s', 'Ready', 'good'),
            (3, 'palette-02-teal-orange', 'sienna', 'Turn to camera, smile', 'orbit', 'Orbit 90° · 5 s', '40%', 'red'),
            (4, 'palette-04-bleached-warm', 'noor', 'Noor joins at the window', 'track', 'Tracking · 4 s', 'Keyframe ✓', ''),
            (5, 'palette-03-hyper-neon', 'sienna', 'Selfie review, close', 'selfie', 'Selfie · 5 s', 'Needs keyframe', 'warn')]
    items = ''.join(f'<div class="row g10" style="padding:8px 0;border-bottom:1px solid var(--line);align-items:flex-start">{scene(im, 62, 104, w, .5, 5 if s == "40%" else 0)}'
                    f'<div class="col g4 fill"><div class="row between"><span style="font:400 20px/1 \'Instrument Serif\'">{n}</span><span class="pill {pc}">{s}</span></div><span class="t13 b">{a}</span>'
                    f'<div class="row g6"><div style="border:1px solid var(--line)">{move_svg(k, t, 46, 26)}</div><span class="t12">{mv}</span></div></div></div>' for n, im, w, a, k, mv, s, pc in rows)
    c = (f'<div class="col g10" style="padding:12px 16px 0"><div class="row between"><span class="h2">Café GRWM · 24 s</span></div>'
         f'<div class="row g8"><div class="row g4">{avatar("sienna", 26, 32)}{avatar("noor", 26, 32)}</div><span class="pill ink">Look lock · Cinematic</span><span class="t12">6 shots</span></div><div class="col">{items}</div></div>')
    return phone(c, t, 'AI · M7 Storyboard', title='Storyboard', cta='Generate 4 shots · HD · $4.32')


def m_takes(t='a'):
    acts = ''.join(f'<div class="col g4 center" style="width:72px">{ic(i,20)}<span class="mono" style="font-size:9.5px">{l}</span></div>' for i, l in [('heart', 'KEEP'), ('refresh', 'RETAKE'), ('scissors', 'EDIT'), ('export', 'SHARE')])
    big = take_thumb('ready', 250, 444, 'palette-02-teal-orange', 'sienna')
    c = (f'<div class="col g12" style="padding:14px 16px 0;align-items:center"><div class="row g8" style="align-self:stretch"><span class="pill ink">Take 1</span><span class="pill">8.0 s · HD</span><div class="fill"></div><span class="t12">Ready · 4 min ago</span></div>{big}'
         f'<div class="row g8" style="align-self:stretch">{take_thumb("ready", 56, 100, "palette-02-teal-orange", "sienna")}{take_thumb("render", 56, 100, "palette-02-teal-orange", "sienna")}<div class="col g2 fill" style="padding-left:6px"><span class="t13 b">Take 2 · 62%</span><span class="t12">Motion &amp; camera · ~2 min</span></div></div>'
         f'<div class="row between" style="align-self:stretch;border-top:1px solid var(--line);padding-top:10px">{acts}</div></div>')
    return phone(c, t, 'AI · M8 Takes', title='Café morning', nav='STUDIO')


def page():
    boards = [
        ('M1', 'Suite hub', 'Modes as a 2-column grid, the live Camera stage session, recent takes.', m_hub(), [('Navigation', 'Studio tab → Video suite. The centre “+” starts a Shot; long-press shows all modes.')]),
        ('M2', 'Shot · Camera tab', 'The existing studio pattern (preview + tool tabs + panel) with the unified Camera control.', m_shot(), [('Preview', 'Blurred while rendering; the % is the only big number. Pull down on the preview to see takes.')]),
        ('M3', 'Camera bag', 'Full-screen sheet. Big rig plate on top, swipeable shelves of real hardware below.', m_bag('a'), [('Gestures', 'Swipe shelves sideways; tap to put in the bag (haptic tick); long-press a card for specs and a sample frame.')]),
        ('M3d', 'Camera bag · dark', 'Theme B variant of the same sheet.', m_bag('b'), []),
        ('M4', 'Move & angle', 'Two-column move library with looping diagrams; selected move tuned in a bottom sheet.', m_move(), [('Mix', 'Up to two moves (numbered). The sheet edits the active one; swipe the sheet to switch.')]),
        ('M5', 'Direct with Claude', 'Directed mode on the phone: talk to the camera session; Blender runs on the Mac.', m_directed(), [('Phone ↔ Mac', 'The phone never runs Blender. Messages go to the same camera session; the Mac relays to Blender and uploads renders. If the Mac is asleep, messages queue.')], ),
        ('M6', 'Character swap', 'Source vs. preview, camera locked to the clip, Draft/Standard/HD and add-ons.', m_swap(), []),
        ('M7', 'Storyboard', 'Vertical list of shots with keyframes, move pictograms and status.', m_story(), [('Reorder', 'Drag a shot by its number to reorder; swipe left to delete; tap to open its Shot sheet.')]),
        ('M8', 'Takes', 'Result screen: plays inline, takes strip, Keep · Retake · Edit · Share.', m_takes(), []),
    ]
    return ('AI Suite — Mobile', 'ai-suite-mobile', 'MUSE · AI Video Suite · Mobile (Android, 390 × 844, Theme A Editorial)',
            'The same suite on the phone: one-hand flows, sheets instead of side panels, the same Camera control, camera bag and Directed session.', boards)

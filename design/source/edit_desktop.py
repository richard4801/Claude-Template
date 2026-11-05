from base import *
from art import wave, speed_curve

PX = 66  # px per second on the desktop timeline
X0 = 150  # track header width


def canvas(w=252, h=448, cap=True, hook=True, safe=True, im='palette-01-naturalistic', who='sienna', style='pop'):
    hk = ''
    if hook:
        hk = (f'<div style="position:absolute;left:14px;right:14px;top:{int(h*.09)}px;display:flex;justify-content:center;text-align:center">'
              f'<span style="background:#fff;color:#141210;font:800 {int(w*.066)}px/1.25 Archivo;padding:4px 8px">3 things I wish I knew before my first café shoot</span></div>')
    cp = ''
    if cap:
        fs = int(w * .092)
        hlc = {'pop': 'background:#FFE14D;color:#141210;padding:0 4px', 'kara': 'color:#FF5A5F', 'hl': 'background:#FFE14D;color:#141210;padding:0 4px'}[style]
        cp = (f'<div style="position:absolute;left:10px;right:10px;top:{int(h*.62)}px;display:flex;justify-content:center;gap:6px;flex-wrap:wrap;text-align:center">'
              f'<span style="font:900 {fs}px/1.1 Archivo;color:#fff;text-shadow:0 2px 0 #000,0 0 8px rgba(0,0,0,.6);text-transform:uppercase">I</span>'
              f'<span style="font:900 {fs}px/1.1 Archivo;text-transform:uppercase;{hlc}">always</span>'
              f'<span style="font:900 {fs}px/1.1 Archivo;color:#fff;text-shadow:0 2px 0 #000,0 0 8px rgba(0,0,0,.6);text-transform:uppercase">order</span></div>')
    sf = ''
    if safe:
        sf = (f'<div style="position:absolute;right:0;top:{int(h*.36)}px;width:{int(w*.2)}px;height:{int(h*.5)}px;background:rgba(181,18,27,.16);border-left:1px dashed #ff6a6f"></div>'
              f'<div style="position:absolute;left:0;right:0;bottom:0;height:{int(h*.14)}px;background:rgba(181,18,27,.16);border-top:1px dashed #ff6a6f"></div>'
              f'<div style="position:absolute;left:0;right:0;top:0;height:{int(h*.06)}px;background:rgba(181,18,27,.12);border-bottom:1px dashed #ff6a6f"></div>'
              f'<div style="position:absolute;right:{int(w*.05)}px;top:{int(h*.45)}px;display:flex;flex-direction:column;gap:12px;color:rgba(255,255,255,.75)">{ic("heart",18)}{ic("msg",18)}{ic("send",18)}</div>')
    return scene(im, w, h, who, .45, extra=hk + cp + sf)


def caption_styles(on='Word pop', w=112):
    st = [('Word pop', '<span style="color:#fff">I </span><span style="background:#FFE14D;color:#141210;padding:0 3px">ALWAYS</span>'),
          ('Karaoke', '<span style="color:#fff">I </span><span style="color:#FF5A5F">ALWAYS</span><span style="color:#888"> ORDER</span>'),
          ('Bold box', '<span style="background:#fff;color:#141210;padding:1px 4px">I ALWAYS</span>'),
          ('Minimal', '<span style="color:#fff;font-weight:500;text-transform:none;font-size:11px">I always order the</span>'),
          ('Highlighter', '<span style="color:#fff">I </span><span style="background:linear-gradient(transparent 45%,#3BE38C 45%);color:#fff">ALWAYS</span>'),
          ('Neon', '<span style="color:#FF7EB6;text-shadow:0 0 6px #FF7EB6">I ALWAYS</span>')]
    return '<div class="row wrap g8">' + ''.join(
        f'<div class="col g4" style="width:{w}px"><div style="height:58px;background:#1C1A17;display:flex;align-items:center;justify-content:center;font:900 13px Archivo;text-transform:uppercase;{"outline:2px solid var(--accent);outline-offset:2px;" if n == on else ""}">{s}</div>'
        f'<span class="t12" style="color:{"var(--ink)" if n == on else "var(--muted)"};{"font-weight:600" if n == on else ""}">{n}</span></div>' for n, s in st) + '</div>'


def timeline(h=310, playhead=4.2):
    lanes = [('HOOK', 'type', 28), ('CAPTIONS', 'cc', 28), ('OVERLAY', 'layers', 34), ('VIDEO', 'video', 54), ('VOICE', 'mic', 34), ('MUSIC', 'music', 40), ('SFX', 'volume', 26)]
    y = 60
    out = []
    tops = {}
    for name, icn, lh in lanes:
        tops[name] = (y, lh)
        out.append(f'<div style="position:absolute;left:0;top:{y}px;width:{X0}px;height:{lh}px;border-bottom:1px solid var(--line);border-right:1px solid var(--line);display:flex;align-items:center;gap:8px;padding-left:12px;background:var(--surface)">'
                   f'{ic(icn,14)}<span class="lbl ink" style="font-size:10px">{name}</span><div class="fill"></div><span style="color:var(--muted);padding-right:8px;display:flex;gap:6px">{ic("eye",12)}{ic("lock",12)}</span></div>'
                   f'<div style="position:absolute;left:{X0}px;right:0;top:{y+lh-1}px;height:1px;background:var(--line)"></div>')
        y += lh

    def clip(lane, s, e, inner, bg, fg='var(--ink)', border='none'):
        t, lh = tops[lane]
        return f'<div class="clip" style="left:{X0 + s*PX}px;width:{(e-s)*PX - 2}px;top:{t+3}px;height:{lh-6}px;background:{bg};color:{fg};border:{border};padding-left:6px;font:500 10.5px var(--mono);white-space:nowrap">{inner}</div>'
    c = []
    c.append(clip('HOOK', 0, 2.6, '3 things I wish I knew…', '#F1D9D9', 'var(--accent)'))
    caps = [(0.4, 1.2, 'I always'), (1.25, 2.1, 'order the'), (2.15, 3.0, 'oat flat'), (3.05, 3.8, 'white'), (4.1, 5.0, 'and they'), (5.05, 5.9, 'remember'), (6.0, 6.9, 'my name'), (7.4, 8.4, 'this place'), (8.5, 9.3, 'is unreal'), (9.9, 10.9, 'honestly'), (11.0, 12.0, 'the light'), (12.6, 13.5, '10 out'), (13.55, 14.4, 'of 10'), (14.6, 15.6, 'go!')]
    c += [clip('CAPTIONS', s, e, tx, 'var(--surface2)', 'var(--ink)', '1px solid var(--line)') for s, e, tx in caps]
    c.append(clip('OVERLAY', 7.2, 10.4, f'<div class="plate" style="width:30px;height:24px;margin-right:6px"><img src="{img("lens-06-macro")}" style="width:100%;height:100%;object-fit:cover"></div>PiP · product', 'var(--surface2)', 'var(--ink)', '1px solid var(--line)'))
    vids = [(0, 3.0, 'palette-01-naturalistic', 'Take 1 · street'), (3.0, 7.2, 'light-04-window', 'Take 2 · counter'), (7.2, 12.4, 'palette-02-teal-orange', 'Take 3 · smile'), (12.4, 18, 'palette-03-hyper-neon', 'Take 5 · selfie')]
    for s, e, im, lab in vids:
        n = int((e - s) * PX / 34) + 1
        th = ''.join(f'<div style="width:34px;height:48px;flex:none;overflow:hidden">{scene(im, 34, 48, "sienna", .5, scale=.9)}</div>' for _ in range(n))
        t, lh = tops['VIDEO']
        c.append(f'<div class="clip" style="left:{X0 + s*PX}px;width:{(e-s)*PX - 2}px;top:{t+3}px;height:{lh-6}px;border:1.5px solid var(--ink);gap:0">{th}'
                 f'<span style="position:absolute;left:4px;top:3px;background:rgba(20,18,16,.75);color:#F8F5EF;font:500 9.5px var(--mono);padding:1px 4px">{lab}</span></div>')
    for x, lab in [(3.0, 'WHIP'), (7.2, 'X-FADE'), (12.4, 'ZOOM')]:
        t, lh = tops['VIDEO']
        c.append(f'<div style="position:absolute;left:{X0 + x*PX - 13}px;top:{t+15}px;width:24px;height:24px;background:var(--accent);color:#fff;display:flex;align-items:center;justify-content:center;transform:rotate(45deg)"><span style="transform:rotate(-45deg)">{ic("trans",12,2)}</span></div>')
    t, lh = tops['VOICE']
    c.append(f'<div class="clip" style="left:{X0 + .4*PX}px;width:{15.4*PX}px;top:{t+3}px;height:{lh-6}px;background:#E6E0F2;color:#4B3F86;padding:0 6px">{wave(330, 22, 3, "#4B3F86", 1, 1, 2)}</div>')
    t, lh = tops['MUSIC']
    c.append(f'<div class="clip" style="left:{X0}px;width:{18*PX-2}px;top:{t+3}px;height:{lh-6}px;background:#DCEBDD;color:#2F6B3A;padding:0 6px">{wave(390, 26, 7, "#2F6B3A", .9, 1, 2)}</div>')
    c.append(f'<svg style="position:absolute;left:{X0}px;top:{t+3}px" width="{18*PX}" height="{lh-6}"><path d="M0 6 L{.3*PX} 6 L{.6*PX} 20 L{15.6*PX} 20 L{16*PX} 6 L{18*PX} 6" fill="none" stroke="#141210" stroke-width="1.4" stroke-dasharray="3 2"/></svg>')
    beats = ''.join(f'<div style="position:absolute;left:{X0 + b*PX}px;top:{t-4}px;width:2px;height:6px;background:var(--accent)"></div>' for b in [i * .52 for i in range(35)])
    c.append(beats)
    for x, lab in [(2.85, 'whoosh'), (7.05, 'pop'), (12.3, 'ding'), (15.4, 'cash')]:
        c.append(clip('SFX', x, x + .8, lab, '#F6E2C0', '#5B3600'))
    ruler = ''.join(f'<div style="position:absolute;left:{X0 + i*PX}px;top:36px;height:{"24" if i % 2 == 0 else "10"}px;border-left:1px solid var(--line);padding-left:4px;font:400 10px var(--mono);color:var(--muted)">{f"0:{i:02d}" if i % 2 == 0 else ""}</div>' for i in range(19))
    ph = (f'<div style="position:absolute;left:{X0 + playhead*PX}px;top:36px;bottom:0;width:2px;background:var(--accent)"></div>'
          f'<div style="position:absolute;left:{X0 + playhead*PX - 22}px;top:36px;height:18px;padding:0 5px;background:var(--accent);color:#fff;font:500 10px var(--mono);display:flex;align-items:center">0:04.2</div>')
    tools = ''.join(f'<span class="btn sm ghost" style="border:0;padding:0 6px">{ic(i,15)}</span>' for i in ['scissors', 'trash', 'gauge', 'snow', 'mask', 'undo', 'redo'])
    tb = (f'<div class="row g6" style="position:absolute;left:0;right:0;top:0;height:36px;padding:0 12px;border-bottom:1px solid var(--line);background:var(--bg)">{tools}<div class="vl" style="margin:8px 4px"></div>'
          f'<span class="chip on">{ic("magnet",13)} Ripple</span><span class="chip">{ic("wand",13)} Cut silences</span><span class="chip">{ic("beat",13)} Snap to beat</span><span class="chip">{ic("cc",13)} Auto-captions</span><div class="fill"></div>'
          f'<span class="mono">0:18.0</span>{ic("search",14)}<div style="width:110px">{slider(45)}</div></div>')
    return f'<div style="position:relative;height:{h}px;flex:none;border-top:1px solid var(--line);background:var(--bg);overflow:hidden">{tb}{ruler}{"".join(out)}{"".join(c)}{ph}</div>'


def media_panel():
    tabs = ''.join(f'<div class="col g4 center" style="width:48px;color:{"var(--accent)" if n == "Takes" else "var(--muted)"}">{ic(i,18)}<span style="font:500 9px var(--mono);letter-spacing:.06em">{n.upper()}</span></div>' for i, n in
                   [('video', 'Takes'), ('upload', 'Uploads'), ('music', 'Music'), ('type', 'Text'), ('sparkle', 'Stickers'), ('storyboard', 'Templ.')])
    thumbs = ''.join(f'<div class="col g4"><div style="position:relative">{scene(im, 84, 132, w, .5)}<span style="position:absolute;right:4px;bottom:4px;background:rgba(20,18,16,.75);color:#F8F5EF;font:500 9.5px var(--mono);padding:1px 4px">{d}</span>'
                     + (f'<span style="position:absolute;left:4px;top:4px;width:16px;height:16px;background:var(--accent);color:#fff;display:flex;align-items:center;justify-content:center">{ic("check",10,2.4)}</span>' if u else '') + f'</div><span class="mono" style="font-size:9.5px">{l}</span></div>' for im, w, d, l, u in
                     [('palette-01-naturalistic', 'sienna', '3.0s', 'STREET', 1), ('light-04-window', 'sienna', '4.2s', 'COUNTER', 1), ('palette-02-teal-orange', 'sienna', '8.0s', 'SMILE', 1),
                      ('palette-04-bleached-warm', 'noor', '4.0s', 'NOOR', 0), ('palette-03-hyper-neon', 'sienna', '5.6s', 'SELFIE', 1), ('palette-06-classic-bw', None, '3.0s', 'END CARD', 0)])
    return (f'<div class="col" style="width:300px;flex:none;border-right:1px solid var(--line);background:var(--surface)"><div class="row" style="justify-content:space-around;height:58px;border-bottom:1px solid var(--line)">{tabs}</div>'
            f'<div class="col g10" style="padding:12px 14px"><div class="row between"><span class="lbl ink">From the AI suite</span><span class="t12">Storyboard · Café GRWM</span></div><div class="row wrap g8">{thumbs}</div>'
            f'<div class="row g8" style="border-top:1px solid var(--line);padding-top:10px"><span class="btn sm">{ic("upload",13)} Import</span><span class="btn sm">{ic("mic",13)} Record VO</span></div></div></div>')


def captions_inspector():
    return (f'<div class="col panel tight" style="width:376px;flex:none"><div class="row" style="height:42px;border-bottom:1px solid var(--line);padding:0 12px;gap:16px">'
            + ''.join(f'<span class="t13 {"b" if x == "Captions" else "muted"}" style="{"box-shadow:inset 0 -2px 0 var(--accent);padding:12px 0" if x == "Captions" else ""}">{x}</span>' for x in ['Captions', 'Text', 'Video', 'Audio', 'Speed', 'Anim'])
            + f'</div><div class="sec"><div class="row between"><span class="lbl ink">Style</span><span class="t12">Save as preset</span></div>{caption_styles()}</div>'
            f'<div class="sec"><div class="row g8"><div class="input fill" style="min-height:32px;padding:6px 10px">Archivo Black · 64</div>'
            + ''.join(f'<div style="width:30px;height:30px;background:{c};border:1px solid var(--line)"></div>' for c in ['#FFFFFF', '#FFE14D', '#141210']) + '</div>'
            f'<div class="row between"><span class="lbl ink">Position</span>{seg(["Top", "Middle", "Lower ⅓"], "Lower ⅓", "sm")}</div>'
            f'{opt_row("Word-by-word highlight", "Active word pops in yellow", True)}<div class="row between"><span class="t13 b">Words per line</span>{seg(["1", "2", "3", "4"], "3", "sm")}</div></div>'
            f'<div class="sec" style="border-bottom:0"><div class="row between"><span class="t13 b">Transcript</span><span class="t12">English · auto · 96%</span></div>'
            f'<div class="row g8"><span class="btn sm">{ic("scissors",13)} Remove 7 filler words</span><span class="btn sm">Edit text</span></div></div></div>')


def preview_area(cap=True):
    ctrls = ''.join(f'<span style="color:#E7E1D6">{ic(i,18)}</span>' for i in ['rewind', 'play', 'ffwd'])
    return (f'<div class="col fill" style="min-width:0;background:var(--stage)"><div class="row g10" style="height:38px;flex:none;padding:0 14px;color:#E7E1D6">'
            f'<span class="pill" style="color:#ff8a8f;border-color:#ff8a8f">{ic("tiktok",11)} TikTok safe area</span><span class="pill" style="color:#A9A6A0;border-color:#4a4642">Reels</span><span class="pill" style="color:#A9A6A0;border-color:#4a4642">Shorts</span><div class="fill"></div><span class="mono" style="color:#A9A6A0">Fit · 100%</span></div>'
            f'<div class="row center fill">{canvas(222, 394, cap=cap)}</div>'
            f'<div class="row g16 center" style="height:40px;flex:none;color:#E7E1D6"><span class="mono" style="color:#E7E1D6">0:04.2 / 0:18.0</span>{ctrls}<span style="color:#A9A6A0">{ic("volume",16)}</span><span style="color:#A9A6A0">{ic("expand",16)}</span></div></div>')


def editor_bar():
    return (f'<div class="row g12" style="height:50px;flex:none;padding:0 16px;border-bottom:1px solid var(--line)"><div class="col"><span class="t14 b">Morning café GRWM</span><span class="t12">v3 · saved just now</span></div>'
            f'<div class="fill"></div><span style="color:var(--muted)">{ic("undo",17)}</span><span style="color:var(--muted)">{ic("redo",17)}</span>{seg(["9:16", "1:1", "4:5", "16:9"], "9:16", "sm")}<div class="fill"></div>'
            f'<span class="btn sm">{ic("storyboard",13)} Templates</span><span class="btn sm">{ic("sparkle",13)} Hook ideas</span><span class="btn pri">{ic("export",14)} Export</span></div>')


def editor_main(name='Edit · E1 Editor', overlay=''):
    upper = f'<div class="row fill" style="min-height:0;align-items:stretch">{media_panel()}{preview_area()}{captions_inspector()}</div>'
    return desktop(editor_bar() + upper + timeline() + overlay, 'a', 'edit', None, job=None, compact=True, name=name)


def panel_card(title, tier, body, w=316):
    tp = '<span class="pill red">Must</span>' if tier == 'must' else '<span class="pill">Next</span>'
    return f'<div class="col box" style="width:{w}px;flex:none"><div class="row between" style="padding:12px 14px;border-bottom:1px solid var(--line)"><span class="h3">{title}</span>{tp}</div><div class="col g10" style="padding:12px 14px">{body}</div></div>'


def kf_row(lbl, val, kfs):
    lane = ''.join(f'<div class="kf" style="position:absolute;left:{x}%;top:3px"></div>' for x in kfs)
    return (f'<div class="row g8"><span class="lbl" style="width:60px">{lbl}</span><span class="mono" style="color:var(--ink);width:58px">{val}</span>'
            f'<div style="position:relative;height:15px;flex:1 1 0;border-bottom:1px solid var(--line)">{lane}</div><span class="kf ink" style="opacity:.35"></span></div>')


def panels_board():
    tr = panel_card('Transform & keyframes', 'must', kf_row('Position', '0, −40', [10, 60]) + kf_row('Scale', '112%', [10, 45, 90]) + kf_row('Rotation', '0°', []) + kf_row('Opacity', '100%', [85]) +
                    f'<div class="row between"><span class="lbl">Ease</span>{seg(["Linear", "In-out", "Bounce"], "In-out", "sm")}</div><span class="t12">◆ adds a keyframe at the playhead</span>')
    sp = panel_card('Speed', 'must', f'{seg(["Constant", "Curve"], "Curve", "fillw sm")}{speed_curve("a", 286, 104)}{chips(["Montage", "Hero", "Bullet", "Flash in", "Flash out", "Custom"], ["Hero"])}'
                    f'<div class="row between"><span class="t13">6.2 s → 4.1 s</span><span class="t12">Keep pitch · Smooth slow-mo</span></div>')
    luts = ''.join(f'<div class="col g4"><div class="plate" style="width:88px;height:58px;{"outline:2px solid var(--ink);outline-offset:2px;" if n == "Teal & Orange" else ""}"><img src="{img(im)}" style="width:100%;height:100%;object-fit:cover"></div><span class="t12" style="font-size:11px">{n}</span></div>' for im, n in
                   [('palette-01-naturalistic', 'Clean'), ('palette-02-teal-orange', 'Teal & Orange'), ('palette-04-bleached-warm', 'Bleached'), ('palette-03-hyper-neon', 'Neon'), ('palette-05-sodium-decay', 'Sodium'), ('palette-06-classic-bw', 'B&W')])
    fl = panel_card('Filters & LUTs', 'must', f'<div class="row wrap g8">{luts}</div>{slider(70, label="Intensity", val="70%")}<span class="t12">Same looks as the Camera bag palettes</span>')
    ad = panel_card('Adjust', 'must', ''.join(slider(p, label=l, val=v) for l, p, v in [('Exposure', 52, '+0.1'), ('Contrast', 58, '+8'), ('Saturation', 46, '−4'), ('Temperature', 62, '+6'), ('Highlights', 40, '−12'), ('Shadows', 55, '+5'), ('Grain', 20, '20')]))
    mk = panel_card('Mask & green screen', 'must', f'<span class="lbl ink">Mask</span>{chips(["Linear", "Mirror", "Circle", "Rect", "Heart", "Star"], ["Circle"])}{slider(30, label="Feather", val="30")}'
                    f'<div class="hl"></div><div class="row between"><span class="lbl ink">Chroma key</span><div class="row g6"><div style="width:22px;height:22px;background:#2BD15F"></div><span class="mono">#2BD15F</span></div></div>{slider(64, label="Strength", val="64")}'
                    f'{opt_row("Remove background", "No green screen needed", True)}')
    trans = ''.join(f'<div class="col g4 center" style="width:62px"><div style="width:54px;height:40px;border:1px solid {"var(--ink)" if n == "Whip" else "var(--line)"};background:var(--surface2);display:flex;align-items:center;justify-content:center">{ic(i,18)}</div><span class="t12" style="font-size:11px">{n}</span></div>' for n, i in
                    [('Cut', 'scissors'), ('X-fade', 'trans'), ('Zoom', 'expand'), ('Whip', 'ffwd'), ('Slide', 'chev-r'), ('Flash', 'sun'), ('Glitch', 'fx'), ('Spin', 'refresh')])
    tn = panel_card('Transitions', 'must', f'<div class="row wrap g6">{trans}</div>{slider(30, label="Duration", val="0.3 s")}<div class="row g8"><span class="btn sm">Apply to all cuts</span><span class="t12">Whip pans live here, not in the AI shot</span></div>')
    au = panel_card('Audio · clip', 'must', f'{slider(70, label="Volume", val="−3 dB")}<div class="row g10"><div class="fill">{slider(20, label="Fade in", val="0.5 s")}</div><div class="fill">{slider(35, label="Fade out", val="1.0 s")}</div></div>'
                    f'{opt_row("Noise reduction", "Removes café hum", True)}{opt_row("Voice enhance", "Clearer speech", True)}<span class="lbl ink">Voice effect</span>{chips(["None", "Warm", "Radio", "Phone", "Deep"], ["None"])}')
    mx = panel_card('Audio · mix & beats', 'must', f'{opt_row("Auto-duck music", "Under voice · −12 dB", True)}<div class="row g10"><div class="fill">{slider(30, label="Attack", val="0.2 s")}</div><div class="fill">{slider(50, label="Release", val="0.6 s")}</div></div>'
                    f'<div class="hl"></div><div class="row between"><span class="lbl ink">Beat markers</span><span class="t12">118 BPM</span></div><div style="height:30px;color:var(--good)">{wave(110, 28, 5, "#2F6B3A", 1, 1, 2)}</div>{seg(["Every beat", "Strong beats"], "Strong beats", "fillw sm")}{opt_row("Snap cuts to beats", "Auto-cut on the beat", False)}')
    row1 = f'<div class="row g14" style="align-items:flex-start">{tr}{sp}{fl}{ad}</div>'
    row2 = f'<div class="row g14" style="align-items:flex-start">{mk}{tn}{au}{mx}</div>'
    content = (f'<div class="row g20" style="padding:20px 28px 14px;flex:none;align-items:flex-end"><div class="col g6"><span class="lbl">Edit suite · Inspector</span><span class="h1" style="font-size:46px">Every panel, organised</span></div><div class="fill"></div>'
               f'<span class="t12" style="max-width:420px">The inspector shows one tab at a time (Captions · Text · Video · Audio · Speed · Anim). Here are all panels side by side. Must = first release; Next = after.</span></div>'
               f'<div class="col g14" style="padding:0 28px">{row1}{row2}</div>')
    return desktop(content, 'a', 'edit', None, job=None, compact=True, name='Edit · E2 Inspector panels')


def captions_hooks():
    words = [('I', 0), ('always', 0), ('um', 1), ('order', 0), ('the', 0), ('oat', 0), ('flat', 0), ('white', 0), ('⏸ 1.4 s', 2), ('and', 0), ('like', 1), ('they', 0), ('remember', 0), ('my', 0), ('name', 0), ('—', 0),
             ('you', 1), ('know', 1), ('this', 0), ('place', 0), ('is', 0), ('unreal', 0), ('⏸ 0.9 s', 2), ('honestly', 0), ('the', 0), ('light', 0), ('in', 0), ('here', 0), ('uh', 1), ('ten', 0), ('out', 0), ('of', 0), ('ten', 0), ('go', 0)]
    ws = ''.join(f'<span style="font:400 17px/1.9 var(--body);{"color:var(--accent);text-decoration:line-through;" if f == 1 else ""}{"background:var(--surface2);font:500 11px var(--mono);padding:3px 6px;color:var(--muted);" if f == 2 else ""}{"background:#FFE14D;" if w == "always" else ""}">{w}</span>' for w, f in words)
    left = (f'<div class="col g14" style="width:440px;flex:none;padding:18px 22px;border-right:1px solid var(--line)"><div class="row between"><span class="lbl ink">Transcript · word-timed</span><span class="t12">English · 96%</span></div>'
            f'<div class="row wrap" style="gap:2px 8px">{ws}</div><div class="hl"></div>'
            f'<div class="row g8"><span class="btn sm acc">{ic("scissors",13)} Remove 5 fillers</span><span class="btn sm">Cut 2 silences</span><span class="btn sm">Translate…</span></div>'
            f'<span class="t12">Red = filler words · grey = silences. Delete words here and the video cuts with them (jump cuts).</span></div>')
    centre = f'<div class="col fill center" style="background:var(--stage);min-width:0">{canvas(270, 480)}</div>'
    hooks = ''.join(f'<div class="row g10" style="height:46px;border-bottom:1px solid var(--line)"><span style="width:96px;height:30px;background:#1C1A17;color:#fff;display:flex;align-items:center;justify-content:center;font:{f};text-align:center">{s}</span><span class="t13 fill">{n}</span>{ic("plus",15)}</div>' for n, s, f in
                    [('POV: …', 'POV:', '800 12px Archivo'), ('3 things I wish…', '3 THINGS', '900 11px Archivo'), ('Stop scrolling if…', 'STOP', '900 13px Archivo'), ('Wait for it', 'wait…', 'italic 600 12px Archivo'), ('Rating it honestly', '10/10?', '800 12px Archivo'), ('Things that just make sense', 'just makes sense', '700 9.5px Archivo')])
    right = (f'<div class="col panel tight" style="width:390px;flex:none"><div class="sec"><span class="lbl ink">Caption style</span>{caption_styles("Word pop", 108)}</div>'
             f'<div class="sec" style="border-bottom:0"><div class="row between"><span class="lbl ink">Hook templates</span><span class="t12">First 2 seconds</span></div>{hooks}</div></div>')
    head = (f'<div class="row g12" style="height:50px;flex:none;padding:0 16px;border-bottom:1px solid var(--line)"><span class="t14 b">Captions &amp; hooks</span><span class="t12">Morning café GRWM</span><div class="fill"></div>{seg(["Transcript", "Timeline"], "Transcript", "sm")}<span class="btn pri">Done</span></div>')
    return desktop(head + f'<div class="row fill" style="min-height:0;align-items:stretch">{left}{centre}{right}</div>', 'a', 'edit', None, job=None, compact=True, name='Edit · E3 Captions & hooks')


def export_sheet():
    def shape(n, w, h, on):
        return (f'<div class="col g6 center" style="width:96px;padding:10px 0;border:1px solid {"var(--ink)" if on else "var(--line)"};background:{"var(--surface2)" if on else "var(--surface)"}">'
                f'<div style="width:{w}px;height:{h}px;border:2px solid var(--ink);{"background:var(--ink);" if on else ""}"></div><span class="mono" style="color:var(--ink)">{n}</span></div>')
    shapes = shape('9:16', 27, 48, True) + shape('1:1', 40, 40, False) + shape('4:5', 36, 45, False) + shape('16:9', 52, 29, False)
    modal = (f'<div class="dim"></div><div style="position:absolute;left:50%;top:50%;width:600px;margin-left:-300px;margin-top:-392px;background:var(--bg);border:1px solid var(--line);box-shadow:0 40px 90px rgba(0,0,0,.35)" class="col">'
             f'<div class="row between" style="padding:18px 22px;border-bottom:1px solid var(--line)"><span class="h2">Export</span>{ic("x",20)}</div>'
             f'<div class="col g16" style="padding:18px 22px"><div class="col g8"><span class="lbl ink">Shape</span><div class="row g10">{shapes}</div><span class="t12">Changing shape re-frames each clip to keep faces in view. Captions move with the safe area.</span></div>'
             f'<div class="row g16"><div class="col g8 fill"><span class="lbl ink">Resolution</span>{seg(["720p", "1080p", "4K"], "1080p", "fillw")}</div><div class="col g8 fill"><span class="lbl ink">Frame rate</span>{seg(["24", "30", "60"], "30", "fillw")}</div></div>'
             f'<div class="row g16"><div class="col g8 fill"><span class="lbl ink">Format</span>{seg(["MP4 · H.264", "HEVC"], "MP4 · H.264", "fillw")}</div><div class="col g8 fill"><span class="lbl ink">Captions</span>{seg(["Burn in", ".srt file"], "Burn in", "fillw")}</div></div>'
             f'<div class="col g10" style="padding:14px;border:1px solid var(--line);background:var(--surface)"><div class="row g8"><span style="color:var(--ink)">{ic("shield",16)}</span><span class="t13 b fill">Disclosure</span><span class="t12">Your choice, per export</span></div>'
             f'{opt_row("Label as AI-generated", "Adds the platform’s AI label when you post from MUSE", False)}{opt_row("Content Credentials (C2PA)", "Signed provenance inside the file", False)}'
             f'<span class="t12">Ads with realistic AI people may need a label in some places (EU, New York). We remind you when posting an ad.</span></div>'
             f'<div class="row between"><span class="t13">0:18 · 1080 × 1920 · 30 fps</span><span class="mono" style="color:var(--ink)">≈ 38 MB</span></div>'
             f'<div class="row g10"><span class="btn fill">Save to Gallery</span><span class="btn pri big fill">Export</span></div></div></div>')
    return editor_main('Edit · E4 Export sheet', modal)


def page():
    boards = [
        ('E1', 'Editor', 'Media from the AI suite, 9:16 preview with TikTok safe areas, Captions inspector, 7-track timeline with beats and ducking.', editor_main(), [
            ('Timeline', 'Tracks: Hook · Captions · Overlay (PiP) · Video · Voice · Music · SFX. Ripple on by default. Red ticks on Music are beat markers; the dashed line is auto-ducking under the voice.'),
            ('Safe areas', 'Toggle TikTok / Reels / Shorts. Red zones = where the app’s buttons and caption sit. Hook and captions snap inside.'),
            ('From the suite', '“Assemble in Edit” (Storyboard) drops the takes in order with transitions and auto-captions already on.')]),
        ('E2', 'Inspector panels', 'All 8 must-have panels side by side: transform/keyframes, speed curves, filters/LUTs, adjust, mask/green screen, transitions, audio clip, audio mix & beats.', panels_board(), [
            ('Tiering', 'Everything here is the research “must-have” tier. Nice-to-haves (tracking, stabilise, relight, voice changer, translate/dub) come later as extra tabs.')]),
        ('E3', 'Captions & hooks', 'Word-timed transcript with filler/silence removal, styled word-by-word captions, hook templates.', captions_hooks(), [
            ('Edit by text', 'Strike a word to cut it from the video. “Remove 5 fillers” and “Cut 2 silences” make jump cuts in one tap; undo restores.')]),
        ('E4', 'Export sheet', 'Shape, resolution, fps, format, captions; AI label and C2PA as user-controlled switches (off by default).', export_sheet(), [
            ('Disclosure', 'Per the studio rule, AI-label switches stay user-controlled and off by default. We explain where labels are required instead of forcing them — open question for the owner.')], ),
    ]
    return ('Edit Suite — Desktop', 'edit-suite-desktop', 'MUSE · Edit Suite · Desktop (Mac, 1440 × 900, Theme A Editorial)',
            'A CapCut-class editor built around what UGC creators do every day: hooks, styled word-by-word captions, music + voice with ducking, jump cuts, beat-synced edits, green screen and PiP — fed directly by the AI suite.', boards)

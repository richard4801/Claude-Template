from base import *
from art import wave, speed_curve
from edit_desktop import canvas, caption_styles


def m_timeline():
    px = 34
    vids = [('palette-01-naturalistic', 3.0), ('light-04-window', 4.2), ('palette-02-teal-orange', 5.2), ('palette-03-hyper-neon', 5.6)]
    x = 195 - int(4.2 * px)
    clips = []
    for im, d in vids:
        n = int(d * px / 40) + 1
        th = ''.join(f'<div style="width:40px;height:52px;flex:none;overflow:hidden">{scene(im, 40, 52, "sienna", .5, scale=.9)}</div>' for _ in range(n))
        clips.append(f'<div style="position:absolute;left:{x}px;top:30px;width:{int(d*px)-2}px;height:52px;overflow:hidden;display:flex;border-radius:4px">{th}</div>')
        x += int(d * px)
    x0 = 195 - int(4.2 * px)
    caps = ''.join(f'<div style="position:absolute;left:{x0 + int(s*px)}px;top:90px;width:{int((e-s)*px)-2}px;height:20px;background:var(--surface2);border:1px solid var(--line);font:500 9px var(--mono);padding:3px 4px;overflow:hidden;white-space:nowrap">{t}</div>' for s, e, t in
                   [(0.4, 1.2, 'I always'), (1.25, 2.1, 'order the'), (2.15, 3.0, 'oat flat'), (3.05, 3.8, 'white'), (4.1, 5.0, 'and they'), (5.05, 5.9, 'remember'), (6.0, 6.9, 'my name'), (7.4, 8.4, 'this place')])
    music = f'<div style="position:absolute;left:{x0}px;top:116px;width:{18*px}px;height:26px;background:#DCEBDD;border-radius:4px;padding:0 4px;overflow:hidden">{wave(300, 20, 7, "#2F6B3A", .9, 1, 2)}</div>'
    voice = f'<div style="position:absolute;left:{x0 + int(.4*px)}px;top:146px;width:{15*px}px;height:22px;background:#E6E0F2;border-radius:4px;padding:0 4px;overflow:hidden">{wave(260, 16, 3, "#4B3F86", 1, 1, 2)}</div>'
    hook = f'<div style="position:absolute;left:{x0}px;top:172px;width:{int(2.6*px)}px;height:20px;background:#F1D9D9;color:var(--accent);font:500 9px var(--mono);padding:3px 4px;white-space:nowrap;overflow:hidden">T 3 things…</div>'
    ruler = ''.join(f'<div style="position:absolute;left:{x0 + i*px}px;top:6px;font:400 9.5px var(--mono);color:var(--muted)">{"%d s" % i if i % 2 == 0 else "·"}</div>' for i in range(0, 14))
    beats = ''.join(f'<div style="position:absolute;left:{x0 + int(b*px)}px;top:112px;width:2px;height:4px;background:var(--accent)"></div>' for b in [i * .52 for i in range(25)])
    add = f'<div style="position:absolute;right:12px;top:40px;width:32px;height:32px;background:var(--surface);border:1px solid var(--line);display:flex;align-items:center;justify-content:center">{ic("plus",16)}</div>'
    ph = '<div style="position:absolute;left:194px;top:0;bottom:0;width:2px;background:var(--ink)"></div>'
    return f'<div style="position:relative;height:200px;flex:none;overflow:hidden;background:var(--bg)">{ruler}{"".join(clips)}{caps}{beats}{music}{voice}{hook}{ph}{add}</div>'


def m_toolbar(on=None):
    items = [('scissors', 'Edit'), ('music', 'Audio'), ('type', 'Text'), ('cc', 'Captions'), ('sparkle', 'Effects'), ('palette', 'Filters'), ('layers', 'Overlay'), ('ratio', 'Ratio')]
    return ('<div class="row" style="height:66px;flex:none;border-top:1px solid var(--line);justify-content:space-around;padding:0 4px">' + ''.join(
        f'<div class="col g4 center" style="width:46px;color:{"var(--accent)" if n == on else "var(--ink)"}">{ic(i,20)}<span style="font:500 9.5px var(--body)">{n}</span></div>' for i, n in items) + '</div>')


def m_editor(name, sheet='', prev_h=360, tool=None, cap_style='pop'):
    top = (f'<div class="row between" style="height:50px;flex:none;padding:0 14px">{ic("x",22)}<span class="t14 b">Morning café</span><span class="btn sm pri" style="font-size:10.5px">Export</span></div>')
    cw = int((prev_h - 24) * 9 / 16)
    prev = f'<div class="stage row center" style="height:{prev_h}px">{canvas(cw, prev_h - 24, style=cap_style)}</div>'
    play = (f'<div class="row g14" style="height:42px;flex:none;padding:0 14px;border-bottom:1px solid var(--line)"><span class="mono" style="color:var(--ink)">0:04.2 / 0:18.0</span><div class="fill"></div>'
            f'<span>{ic("play",20)}</span><div class="fill"></div><span style="color:var(--muted)">{ic("undo",18)}</span><span style="color:var(--muted)">{ic("redo",18)}</span><span style="color:var(--muted)">{ic("expand",18)}</span></div>')
    c = top + prev + play + m_timeline() + m_toolbar(tool)
    return f'<div class="frame m theme-a" data-name="{name}"><div class="sbar"><span>9:41</span><span class="ic"><i></i><i></i><i style="width:24px"></i></span></div>{c}{sheet}<div class="home-ind"></div></div>'


def sheet(title, body, h):
    return (f'<div class="dim" style="background:rgba(20,18,16,.25)"></div><div class="sheet" style="height:{h}px;padding:0 16px 36px"><div class="grab"></div>'
            f'<div class="row between" style="height:44px"><span class="h3">{title}</span><span class="row g12">{ic("check",20,2)}</span></div><div class="col g14">{body}</div></div>')


def em_captions():
    tabs = ''.join(f'<span class="t13 {"b" if x == "Style" else "muted"}" style="{"box-shadow:inset 0 -2px 0 var(--accent);padding-bottom:8px" if x == "Style" else "padding-bottom:8px"}">{x}</span>' for x in ['Style', 'Font', 'Animation', 'Words'])
    body = (f'<div class="row g20" style="border-bottom:1px solid var(--line)">{tabs}</div>{caption_styles("Word pop", 110)}'
            f'{opt_row("Word-by-word highlight", "Active word pops", True)}<div class="row between"><span class="t13 b">Position</span>{seg(["Top", "Mid", "Lower ⅓"], "Lower ⅓", "sm")}</div>'
            f'<span class="btn">{ic("scissors",14)} Remove 7 filler words</span>')
    return m_editor('Edit · EM2 Captions', sheet('Captions', body, 470), tool='Captions')


def em_audio():
    body = (f'{slider(70, label="Volume · voice", val="−3 dB")}<div class="row g12"><div class="fill">{slider(20, label="Fade in", val="0.5 s")}</div><div class="fill">{slider(35, label="Fade out", val="1.0 s")}</div></div>'
            f'{opt_row("Auto-duck music", "Under voice · −12 dB", True)}{opt_row("Noise reduction", "Removes café hum", True)}'
            f'<span class="lbl ink">Voice effect</span>{chips(["None", "Warm", "Radio", "Phone", "Deep"], ["None"])}'
            f'<div class="row between"><span class="t13 b">Beat markers · 118 BPM</span>{seg(["All", "Strong"], "Strong", "sm")}</div>')
    return m_editor('Edit · EM3 Audio', sheet('Audio', body, 470), tool='Audio')


def em_speed():
    body = (f'{seg(["Normal", "Curve"], "Curve", "fillw")}{speed_curve("a", 358, 120)}{chips(["Montage", "Hero", "Bullet", "Flash in", "Flash out", "Custom"], ["Hero"])}'
            f'<div class="row between"><span class="t13">6.2 s → 4.1 s</span><span class="t12">Drag points · double-tap to add</span></div>{opt_row("Smooth slow-mo", "Fills in frames (AI) · +$0.05", False)}')
    return m_editor('Edit · EM4 Speed curve', sheet('Speed', body, 430), tool='Edit')


def em_export():
    shapes = ''.join(f'<div class="col g6 center" style="flex:1 1 0;padding:10px 0;border:1px solid {"var(--ink)" if n == "9:16" else "var(--line)"};background:{"var(--surface2)" if n == "9:16" else "var(--surface)"}"><div style="width:{w}px;height:{h}px;border:2px solid var(--ink);{"background:var(--ink);" if n == "9:16" else ""}"></div><span class="mono" style="color:var(--ink)">{n}</span></div>' for n, w, h in [('9:16', 20, 36), ('1:1', 30, 30), ('4:5', 27, 34), ('16:9', 38, 22)])
    body = (f'<div class="row g8">{shapes}</div><div class="row g10"><div class="col g6 fill"><span class="lbl ink">Resolution</span>{seg(["720p", "1080p", "4K"], "1080p", "fillw sm")}</div><div class="col g6 fill"><span class="lbl ink">FPS</span>{seg(["24", "30", "60"], "30", "fillw sm")}</div></div>'
            f'{opt_row("Label as AI-generated", "Your choice, per export", False)}{opt_row("Content Credentials (C2PA)", "Signed provenance in the file", False)}'
            f'<div class="row between"><span class="t13">0:18 · 1080p · 30 fps</span><span class="mono" style="color:var(--ink)">≈ 38 MB</span></div><span class="btn pri big">Export</span>')
    return m_editor('Edit · EM5 Export', sheet('Export', body, 520))


def page():
    boards = [
        ('EM1', 'Editor', 'Preview with safe areas, fixed centre playhead, compact multitrack timeline, bottom toolbar.', m_editor('Edit · EM1 Editor'), [
            ('Phone timeline', 'The playhead stays in the centre; the timeline scrolls under it (CapCut convention). Pinch to zoom. Tap a clip → the toolbar switches to that clip’s tools.')]),
        ('EM2', 'Captions sheet', 'Style presets, word highlight, position, filler removal.', em_captions(), []),
        ('EM3', 'Audio sheet', 'Volume, fades, auto-duck, noise reduction, voice effects, beat markers.', em_audio(), []),
        ('EM4', 'Speed curve sheet', 'Constant or curve with presets; smooth slow-mo is an AI add-on.', em_speed(), []),
        ('EM5', 'Export sheet', 'Shape, resolution, fps; AI label & C2PA user-controlled, off by default.', em_export(), []),
    ]
    return ('Edit Suite — Mobile', 'edit-suite-mobile', 'MUSE · Edit Suite · Mobile (Android, 390 × 844, Theme A Editorial)',
            'The phone version of the same editor: bottom toolbar, compact timeline with a fixed playhead, and sheets for every panel.', boards)

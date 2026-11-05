import os
from base import *

MAN = {}
with open(os.path.join(ROOT, 'hardware', 'manifest.tsv')) as f:
    next(f)
    for line in f:
        fn, node, grp, name, spec = line.rstrip('\n').split('\t')
        MAN[fn.replace('.png', '')] = (node, grp, name, spec)

RECIPE = {
    'body-08-phone': 'shot on a smartphone, 24 mm, deep focus, natural HDR', 'body-07-creator-cine': 'full-frame cinema mirrorless, clean 4K, soft highlight roll-off',
    'body-02-super35': 'clean digital cinema image, Super 35, natural skin', 'body-01-large-format': 'large-format digital cinema, shallow depth, wide yet intimate',
    'body-04-fullframe': 'full-frame cinema camera, rich colour, creamy falloff', 'body-03-modular8k': 'crisp 8K digital cinema, high detail, punchy contrast',
    'body-05-film35': '35 mm motion picture film, 500T, fine grain, halation', 'body-06-film16': 'Super 16 film, visible grain, documentary texture',
    'body-10-super8': 'Super 8 home movie, heavy grain, gate weave, warm fade', 'body-09-dv-camcorder': 'early-2000s DV camcorder look, interlaced texture',
    'lens-01-clean-prime': 'modern spherical prime, clinically sharp, round bokeh', 'lens-02-anamorphic': 'anamorphic lens, oval bokeh, horizontal blue flares',
    'lens-03-vintage-anamorphic': 'vintage 1970s anamorphic, amber flares, soft edges', 'lens-04-warm-vintage': 'vintage warm prime, gentle contrast, golden glow',
    'lens-05-halation': 'diffusion filter, highlight bloom, halation', 'lens-06-macro': 'macro lens, extreme detail, razor-thin focus',
    'lens-07-cine-zoom': 'cinema zoom lens, optional crash zoom, 70s zoom feel', 'lens-08-fisheye': 'ultra-wide fisheye, barrel distortion, skate energy',
    'optic-01-iris': 'T1.4 shallow depth of field ↔ T11 deep focus', 'optic-02-shutter180': '180° natural motion blur · 90° crisp · 360° smear',
    'stock-01-35mm': '35 mm 500T tungsten film look', 'stock-02-16mm': '16 mm reversal film, grain, halation', 'stock-03-sensor': 'clean digital, no grain',
    'light-01-soft-cross': 'two soft key lights crossing, even flattering light', 'light-02-contre-jour': 'strong backlight through haze, rim light, glow',
    'light-03-overhead': 'overhead butterfly beauty light, soft top-light', 'light-04-window': 'soft window daylight, gentle falloff',
    'light-05-practicals': 'practical lamps and neon in frame, low-key night', 'light-06-ring-creator': 'ring-light catchlights, RGB accent, creator setup',
    'grip-01-dolly': 'moves: dolly in / out · push-in · tracking', 'grip-02-jib': 'moves: crane up / down · top-down reveal',
    'grip-03-gimbal': 'moves: handheld smooth · selfie walk-and-talk · follow', 'grip-04-fpv': 'moves: FPV fly-through · dive · bank',
    'grip-05-slider': 'moves: short parallax slide · product reveal',
    'palette-01-naturalistic': 'naturalistic clean grade, true colours', 'palette-02-teal-orange': 'teal-and-orange grade, warm skin, teal shadows',
    'palette-03-hyper-neon': 'hyper neon grade, magenta and cyan, deep blacks', 'palette-04-bleached-warm': 'bleached warm grade, lifted shadows, nostalgic',
    'palette-05-sodium-decay': 'sodium-vapour grade, yellow-green cast, gritty', 'palette-06-classic-bw': 'classic black and white, rich silver tones, grain',
}


def lib_card(key, w, h):
    node, grp, name, spec = MAN[key]
    return (f'<div class="col g10" style="width:{w}px;flex:none"><div class="plate" style="width:{w}px;height:{h}px"><img src="{img(key)}" style="width:100%;height:100%;object-fit:cover"></div>'
            f'<div class="col g4"><div class="row between"><span class="t14 b">{name}</span><span class="mono" style="font-size:10px">#{node}</span></div><span class="mono" style="color:var(--ink);font-size:11px">{spec}</span>'
            f'<span class="t12" style="font-style:italic">“{RECIPE[key]}”</span></div></div>')


def section(title, desc, keys, w, h, per_row, height, num):
    rows = [keys[i:i + per_row] for i in range(0, len(keys), per_row)]
    body = ''.join(f'<div class="row g24" style="align-items:flex-start">{"".join(lib_card(k, w, h) for k in r)}</div>' for r in rows)
    return (f'<div class="frame theme-a" data-name="Library · {title}" data-w="1440" data-h="{height}" style="width:1440px;height:{height}px;flex-direction:column;padding:40px 48px;gap:28px">'
            f'<div class="row g20" style="align-items:flex-end"><div class="col g6"><span class="lbl">Hardware library · {num}</span><span class="h1" style="font-size:52px">{title}</span></div><div class="fill"></div>'
            f'<span class="t13 muted" style="max-width:560px">{desc}</span></div><div class="col g28">{body}</div></div>')


def page():
    B = ['body-08-phone', 'body-07-creator-cine', 'body-02-super35', 'body-01-large-format', 'body-04-fullframe', 'body-03-modular8k', 'body-05-film35', 'body-06-film16', 'body-10-super8', 'body-09-dv-camcorder']
    L = ['lens-01-clean-prime', 'lens-02-anamorphic', 'lens-03-vintage-anamorphic', 'lens-04-warm-vintage', 'lens-05-halation', 'lens-06-macro', 'lens-07-cine-zoom', 'lens-08-fisheye']
    O = ['optic-01-iris', 'optic-02-shutter180', 'stock-01-35mm', 'stock-02-16mm', 'stock-03-sensor']
    LI = ['light-01-soft-cross', 'light-02-contre-jour', 'light-03-overhead', 'light-04-window', 'light-05-practicals', 'light-06-ring-creator']
    G = ['grip-01-dolly', 'grip-02-jib', 'grip-03-gimbal', 'grip-04-fpv', 'grip-05-slider']
    PA = ['palette-01-naturalistic', 'palette-02-teal-orange', 'palette-03-hyper-neon', 'palette-04-bleached-warm', 'palette-05-sodium-decay', 'palette-06-classic-bw']
    boards = [
        ('H1', 'Camera bodies', '10 bodies, ordered UGC-first.', section('Camera bodies', 'Phone and creator bodies first, then digital cinema, then film and retro. Captions name the “look” a body evokes — never a logo on the hardware.', B, 248, 248, 5, 880, 'H1'), [
            ('Assets', 'All images: Figma AI (gpt-image-2.5-flare), 1024² (bodies, lenses, optics) or 1536×1024 (light, grip, palettes). #89:x = the original generated node in this file.'),
            ('Recipe', 'The italic line is what the Preset compiler adds to the prompt for that choice (starting point for workstream 1).')]),
        ('H2', 'Lenses', '8 lens families: spherical, anamorphic, vintage, diffusion, macro, zoom, fisheye.', section('Lenses', 'Lens “characters”, named by the look they give. Focal length and T-stop are set separately in the Optics row.', L, 248, 248, 5, 880, 'H2'), []),
        ('H3', 'Optics, film & sensor', 'Iris (aperture), rotary shutter, 35 mm, 16 mm, digital sensor.', section('Optics, film & sensor', 'Visual anchors for aperture/depth, shutter angle and the recording medium.', O, 248, 248, 5, 540, 'H3'), []),
        ('H4', 'Lighting rigs', '6 lighting setups shown as empty sets — the light is the subject.', section('Lighting', 'Soft Cross · Contre-jour · Overhead Fall · Window · Practicals · Creator Ring. Shown on an empty stage so the light is the subject.', LI, 420, 280, 3, 940, 'H4'), []),
        ('H5', 'Grip (move families)', 'Dolly, jib, gimbal, FPV, slider — headers for the move library.', section('Grip', 'Each grip item heads a family of camera moves in Move &amp; angle.', G, 420, 280, 3, 940, 'H5'), []),
        ('H6', 'Colour palettes', 'One café scene, six grades.', section('Colour palettes', 'The same empty café corner graded six ways, so the swatch shows the grade, not the picture. Also used as people-free location plates in the mock-ups.', PA, 420, 280, 3, 940, 'H6'), []),
    ]
    return ('Hardware Library', 'hardware-library', 'MUSE · Hardware Library · 40 generated images',
            'Every camera, lens, optic, film stock, lighting rig, grip and palette used in the camera bag — photoreal studio renders on a dark sweep, no logos. Make each card a component (name + spec + recipe) when the file is unlocked.', boards)

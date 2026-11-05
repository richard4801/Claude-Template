"""SVG illustrations: camera-move diagrams, angle/shot-size pictograms, blocking plan, guide renders, curves, waveforms."""
import math, random
from base import SIL

TH = {
    'a': dict(ink='#141210', acc='#B5121B', mut='#6E675E', line='#CFC7BA', bg='#F8F5EF', soft='#E7E1D6', grid='#E2DBCF'),
    'b': dict(ink='#ECEAE5', acc='#F2A93B', mut='#A9A6A0', line='#3A3F43', bg='#17191B', soft='#212427', grid='#24282B'),
}


def cam(x, y, ang=0, op=1, c='#141210', s=1, reels=True):
    r = (f'<circle cx="-6" cy="-10" r="3.2" fill="none" stroke="{c}" stroke-width="1.5"/><circle cx="1" cy="-10" r="3.2" fill="none" stroke="{c}" stroke-width="1.5"/>' if reels else '')
    return (f'<g transform="translate({x} {y}) rotate({ang}) scale({s})" opacity="{op}"><rect x="-10" y="-6" width="14" height="12" rx="1.5" fill="{c}"/>'
            f'<path d="M4 -3.5 L11 -7 L11 7 L4 3.5 Z" fill="{c}"/>{r}</g>')


def fig(x, ybottom, h=54, c='#141210', op=1):
    s = h / 300
    return f'<g transform="translate({x - 50*s:.1f} {ybottom - 300*s:.1f}) scale({s:.4f})" fill="{c}" opacity="{op}">{SIL}</g>'


def head(x, y, ang, c, s=1):
    return f'<path d="M0 0 L-8 -4.2 L-8 4.2 Z" transform="translate({x} {y}) rotate({ang}) scale({s})" fill="{c}"/>'


def dot_top(x, y, c, face=0, r=7, label=''):
    fx, fy = x + math.cos(math.radians(face)) * (r + 4), y + math.sin(math.radians(face)) * (r + 4)
    return (f'<circle cx="{x}" cy="{y}" r="{r}" fill="{c}"/>' + head(fx, fy, face, c, .7))


def move_svg(kind, t='a', w=180, h=100):
    k = TH[t]; I, A, M, L = k['ink'], k['acc'], k['mut'], k['line']
    g = f'<line x1="8" y1="84" x2="172" y2="84" stroke="{L}" stroke-width="1.2"/>'
    s = ''
    if kind == 'static':
        s = g + fig(128, 84, 56, I) + cam(56, 46, 0, 1, I) + f'<path d="M56 54 L44 84 M56 54 L68 84 M56 54 L56 84" stroke="{M}" stroke-width="1.4"/>' \
            + f'<path d="M30 30h14M30 36h10" stroke="{A}" stroke-width="1.6"/>'
    elif kind == 'handheld':
        s = g + fig(130, 84, 56, I) + cam(62, 48, -6, .22, I) + cam(58, 44, 5, .4, I) + cam(60, 46, 0, 1, I) + \
            f'<path d="M34 46 l6-7 6 9 6-8 6 10 6-9 6 8" fill="none" stroke="{A}" stroke-width="1.7"/>'
    elif kind == 'selfie':
        s = g + fig(118, 84, 56, I) + f'<path d="M110 50 L82 46" stroke="{I}" stroke-width="2.4"/>' + cam(76, 45, 0, 1, I, 1, False) + \
            f'<path d="M150 92 L60 92" stroke="{A}" stroke-width="1.8" stroke-dasharray="4 4"/>' + head(54, 92, 180, A)
    elif kind == 'dolly_in':
        s = g + f'<path d="M18 88h112M18 91h112" stroke="{M}" stroke-width="1"/>' + fig(152, 84, 56, I) + \
            cam(34, 62, 0, .16, I) + cam(60, 62, 0, .32, I) + cam(86, 62, 0, .55, I) + cam(112, 62, 0, 1, I) + \
            f'<path d="M30 40 L120 40" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(128, 40, 0, A)
    elif kind == 'dolly_out':
        s = g + f'<path d="M30 88h112M30 91h112" stroke="{M}" stroke-width="1"/>' + fig(156, 84, 56, I) + \
            cam(120, 62, 0, .16, I) + cam(94, 62, 0, .32, I) + cam(68, 62, 0, .55, I) + cam(42, 62, 0, 1, I) + \
            f'<path d="M120 40 L40 40" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(32, 40, 180, A)
    elif kind == 'push':
        s = (f'<rect x="22" y="10" width="136" height="80" fill="none" stroke="{L}" stroke-width="1.4"/>'
             f'<rect x="44" y="20" width="92" height="60" fill="none" stroke="{M}" stroke-width="1.2" opacity=".6"/>'
             f'<rect x="62" y="28" width="56" height="44" fill="none" stroke="{A}" stroke-width="1.8"/>' + fig(90, 90, 66, I) +
             f'<path d="M26 14 L56 26 M154 14 L124 26 M26 86 L56 74 M154 86 L124 74" stroke="{A}" stroke-width="1.3" stroke-dasharray="3 3"/>')
    elif kind == 'orbit':
        cx, cy, R = 90, 54, 36
        pts = []
        for i, a in enumerate([200, 240, 280, 320]):
            x, y = cx + R * math.cos(math.radians(a)), cy + R * math.sin(math.radians(a)) * .9
            pts.append(cam(round(x, 1), round(y, 1), a + 180, [.16, .32, .55, 1][i], I, .9, False))
        arc = f'<path d="M{cx + R*math.cos(math.radians(190)):.1f} {cy + R*.9*math.sin(math.radians(190)):.1f} A{R} {R*.9} 0 0 1 {cx + R*math.cos(math.radians(335)):.1f} {cy + R*.9*math.sin(math.radians(335)):.1f}" fill="none" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>'
        ex, ey = cx + R * math.cos(math.radians(338)), cy + R * .9 * math.sin(math.radians(338))
        s = f'<ellipse cx="{cx}" cy="{cy}" rx="{R}" ry="{R*.9}" fill="none" stroke="{L}" stroke-width="1"/>' + arc + head(round(ex, 1), round(ey, 1), 70, A) + dot_top(cx, cy, I, 90, 8) + ''.join(pts)
    elif kind in ('crane_up', 'crane_down'):
        up = kind == 'crane_up'
        ys = [72, 52, 30] if up else [30, 52, 72]
        rs = [0, 12, 26] if up else [26, 12, 0]
        s = g + fig(134, 84, 56, I) + f'<path d="M62 84 L62 22" stroke="{M}" stroke-width="1.4"/>' + \
            ''.join(cam(66, y, r, op, I) for y, r, op in zip(ys, rs, [.18, .45, 1])) + \
            f'<path d="M40 {78 if up else 22} L40 {28 if up else 72}" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(40, 20 if up else 80, -90 if up else 90, A)
    elif kind == 'track':
        s = g + fig(122, 84, 56, I) + fig(108, 84, 56, I, .14) + cam(52, 58, 0, 1, I) + \
            f'<path d="M100 18 L146 18" stroke="{A}" stroke-width="1.8"/>' + head(152, 18, 0, A) + \
            f'<path d="M36 32 L82 32" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(88, 32, 0, A)
    elif kind == 'fpv':
        s = (f'<path d="M14 84 C 58 -6, 110 104, 168 22" fill="none" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(170, 20, -40, A) +
             cam(40, 46, -48, .25, I, .9, False) + cam(88, 52, 26, .5, I, .9, False) + cam(134, 52, -36, 1, I, .9, False) +
             f'<path d="M150 70 h16 M146 76 h12 M154 64 h10" stroke="{M}" stroke-width="1.2"/>')
    elif kind == 'whip':
        s = (dot_top(36, 30, I, 90, 7) + dot_top(146, 30, I, 90, 7) + cam(91, 78, -90, 1, I, 1, False) +
             f'<path d="M44 54 Q 91 6 138 54" fill="none" stroke="{A}" stroke-width="2"/>' + head(140, 57, 50, A) +
             f'<path d="M56 62 Q 91 26 126 62" fill="none" stroke="{A}" stroke-width="1.2" opacity=".5"/><path d="M66 70 Q 91 44 116 70" fill="none" stroke="{A}" stroke-width="1" opacity=".3"/>')
    elif kind == 'dutch':
        s = (f'<g transform="rotate(-14 90 50)"><rect x="34" y="14" width="112" height="72" fill="none" stroke="{I}" stroke-width="1.6"/>'
             f'<line x1="34" y1="64" x2="146" y2="64" stroke="{L}" stroke-width="1.2"/>{fig(90, 86, 62, I)}</g>'
             f'<path d="M150 84 A 30 30 0 0 0 158 62" fill="none" stroke="{A}" stroke-width="1.8"/>' + head(158, 58, -78, A))
    elif kind == 'rack':
        s = (g + cam(20, 58, 0, 1, I) + fig(66, 84, 50, I, .28) + fig(140, 84, 56, I) +
             f'<line x1="66" y1="14" x2="66" y2="84" stroke="{M}" stroke-width="1" stroke-dasharray="3 3"/>'
             f'<line x1="140" y1="14" x2="140" y2="84" stroke="{A}" stroke-width="1.6"/>'
             f'<path d="M72 16 L128 16" stroke="{A}" stroke-width="1.8" stroke-dasharray="5 4"/>' + head(134, 16, 0, A))
    elif kind == 'crash':
        s = (f'<rect x="20" y="8" width="140" height="84" fill="none" stroke="{L}" stroke-width="1.4"/>'
             f'<rect x="70" y="36" width="40" height="30" fill="none" stroke="{A}" stroke-width="2"/>' + fig(90, 92, 80, I) +
             ''.join(f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{A}" stroke-width="1.4"/>' for x1, y1, x2, y2 in
                     [(24, 12, 60, 32), (156, 12, 120, 32), (24, 88, 60, 70), (156, 88, 120, 70), (40, 50, 62, 50), (140, 50, 118, 50)]))
    elif kind == 'topdown':
        s = (g + f'<path d="M90 22 L52 84 L128 84 Z" fill="{A}" opacity=".10"/><path d="M90 22 L52 84 M90 22 L128 84" stroke="{A}" stroke-width="1.2" stroke-dasharray="4 3"/>'
             + cam(90, 14, 90, 1, I) + f'<ellipse cx="90" cy="82" rx="20" ry="4" fill="{I}" opacity=".85"/>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 180 100" fill="none">{s}</svg>'


MOVES = [
    ('static', 'Locked-off', 'Tripod · talking head', 'UGC'),
    ('handheld', 'Handheld UGC', 'Friend-filmed · subtle shake', 'UGC'),
    ('selfie', 'Selfie walk-and-talk', 'Arm’s length · walking', 'UGC'),
    ('dolly_in', 'Dolly in', 'Rail push toward eyes', 'Cinematic'),
    ('dolly_out', 'Dolly out · reveal', 'Pull back to reveal', 'Cinematic'),
    ('push', 'Slow push-in', 'Barely-there creep', 'Subtle'),
    ('orbit', 'Orbit / arc', '60°–180° around subject', 'Cinematic'),
    ('crane_up', 'Crane up', 'Rise & tilt down', 'Cinematic'),
    ('crane_down', 'Crane down', 'Descend into scene', 'Cinematic'),
    ('track', 'Tracking follow', 'Constant distance', 'Energy'),
    ('fpv', 'FPV fly-through', 'Dives & banks', 'Energy'),
    ('whip', 'Whip pan', 'Fast pan between beats', 'Energy'),
    ('dutch', 'Dutch angle', 'Canted 12°–20°', 'Subtle'),
    ('rack', 'Rack focus', 'Pull focus near → far', 'Subtle'),
    ('crash', 'Crash zoom', '24 → 70 mm in 0.3 s', 'Energy'),
    ('topdown', 'Top-down', 'Straight overhead', 'Subtle'),
]


def angle_svg(kind, t='a', w=64, h=46):
    k = TH[t]; I, A, L = k['ink'], k['acc'], k['line']
    pos = {'ground': (12, 40, -18), 'low': (12, 34, -12), 'eye': (12, 20, 0), 'high': (14, 8, 18), 'over': (44, 5, 90)}[kind]
    x, y, r = pos
    sx, sy = (44, 14)
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 64 46" fill="none"><line x1="2" y1="44" x2="62" y2="44" stroke="{L}"/>'
            f'{fig(48, 44, 34, I)}<line x1="{x+6}" y1="{y}" x2="{sx+4}" y2="{sy}" stroke="{A}" stroke-width="1.2" stroke-dasharray="2.5 2"/>'
            f'{cam(x, y, r, 1, I, .62, False)}</svg>')


SHOTS = [('ECU', '38.6 20 22.7 30'), ('CU', '30.3 8 39.4 52'), ('MCU', '19 6 62 82'), ('MS', '2.5 4 95 125'),
         ('COWBOY', '-22 2 144 190'), ('FULL', '-65 -6 230 304'), ('WIDE', '-147 -214 394 520')]


def shot_svg(vb, t='a', w=40, h=52, on=False):
    k = TH[t]
    bg = k['soft'] if not on else k['ink']
    fc = k['ink'] if not on else k['bg']
    return (f'<svg width="{w}" height="{h}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" style="background:{bg}">'
            f'<g fill="{fc}">{SIL}</g></svg>')


def blocking_plan(t='a', w=760, h=420, dw=None, dh=None):
    k = TH[t]; I, A, M, L, G = k['ink'], k['acc'], k['mut'], k['line'], k['grid']
    grid = ''.join(f'<line x1="{x}" y1="0" x2="{x}" y2="{h}" stroke="{G}"/>' for x in range(0, w, 40)) + \
           ''.join(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}" stroke="{G}"/>' for y in range(0, h, 40))
    room = (f'<rect x="60" y="40" width="620" height="340" fill="none" stroke="{I}" stroke-width="4"/>'
            f'<rect x="60" y="120" width="6" height="120" fill="{k["bg"]}"/><path d="M66 120 A 70 70 0 0 1 120 160" stroke="{M}" stroke-width="1.2" fill="none" stroke-dasharray="4 3"/>'
            f'<rect x="300" y="40" width="200" height="6" fill="#8FB3D9"/><text x="400" y="62" text-anchor="middle" font-family="IBM Plex Mono" font-size="10" fill="{M}">WINDOW</text>'
            f'<rect x="520" y="200" width="150" height="60" fill="{k["soft"]}" stroke="{I}" stroke-width="1.6"/><text x="595" y="234" text-anchor="middle" font-family="IBM Plex Mono" font-size="10" fill="{M}">COUNTER</text>'
            f'<circle cx="250" cy="300" r="26" fill="{k["soft"]}" stroke="{I}" stroke-width="1.4"/><circle cx="380" cy="300" r="26" fill="{k["soft"]}" stroke="{I}" stroke-width="1.4"/>'
            f'<text x="72" y="114" font-family="IBM Plex Mono" font-size="10" fill="{M}">DOOR</text>')
    sienna = (f'<path d="M84 180 C 200 170, 330 230, 500 222" fill="none" stroke="{A}" stroke-width="2.4" stroke-dasharray="7 5"/>'
              + ''.join(f'<circle cx="{x}" cy="{y}" r="3.5" fill="{A}"/><text x="{x}" y="{y-10}" text-anchor="middle" font-family="IBM Plex Mono" font-size="10" fill="{A}">{tt}</text>'
                        for x, y, tt in [(84, 180, '0.0s'), (210, 186, '1.2s'), (350, 214, '2.4s'), (500, 222, '3.5s')])
              + f'<circle cx="500" cy="222" r="15" fill="{A}"/><text x="500" y="226" text-anchor="middle" font-family="Archivo" font-weight="700" font-size="11" fill="#fff">SV</text>'
              + head(500, 247, 90, A, .9) + f'<text x="510" y="276" font-family="Archivo" font-size="11" fill="{A}">turns to camera</text>')
    noor = (f'<circle cx="392" cy="96" r="15" fill="{I}"/><text x="392" y="100" text-anchor="middle" font-family="Archivo" font-weight="700" font-size="11" fill="{k["bg"]}">NA</text>'
            + head(392, 121, 90, I, .9) + f'<path d="M410 104 C 440 130, 470 170, 488 206" fill="none" stroke="{I}" stroke-width="1.4" stroke-dasharray="2 4"/>'
            f'<text x="412" y="88" font-family="Archivo" font-size="11" fill="{I}">Noor · waits, looks at 3.0s</text>')
    camp = (f'<path d="M300 360 L300 300 A 150 150 0 0 0 430 240" fill="none" stroke="{I}" stroke-width="2" stroke-dasharray="2 5"/>'
            f'<path d="M300 352 L395 205 L245 205 Z" fill="{A}" opacity=".08"/>'
            + cam(300, 352, -90, .3, I, 1.3) + cam(300, 302, -82, .55, I, 1.3) + cam(430, 240, -150, 1, I, 1.3)
            + f'<path d="M430 240 L560 160 L560 300 Z" fill="{A}" opacity=".10"/>'
            + f'<rect x="310" y="318" width="132" height="22" fill="{k["bg"]}" stroke="{L}"/><text x="318" y="333" font-family="IBM Plex Mono" font-size="10" fill="{I}">CAM A · 35 mm · 1.5 m</text>'
            + f'<text x="186" y="352" font-family="IBM Plex Mono" font-size="10" fill="{M}">push 0.4 m · 0–4.5s</text>'
            + f'<text x="452" y="306" font-family="IBM Plex Mono" font-size="10" fill="{M}">orbit 90° · 4.5–6s</text>')
    scale = f'<path d="M600 398 h80" stroke="{I}" stroke-width="1.4"/><path d="M600 394 v8 M680 394 v8" stroke="{I}"/><text x="640" y="414" text-anchor="middle" font-family="IBM Plex Mono" font-size="10" fill="{M}">1 m</text>'
    return f'<svg width="{dw or w}" height="{dh or h}" viewBox="0 0 {w} {h}" preserveAspectRatio="xMidYMid meet" style="background:{k["bg"]}">{grid}{room}{sienna}{noor}{camp}{scale}</svg>'


def greybox(w=90, h=160, kind='grey', variant=0):
    """Guide renders returned from Blender: greybox / depth / pose."""
    if kind == 'grey':
        bg = '<defs><linearGradient id="gw{v}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9c9c9a"/><stop offset="1" stop-color="#c9c9c6"/></linearGradient></defs>'.replace('{v}', str(variant))
        s = (bg + f'<rect width="90" height="160" fill="url(#gw{variant})"/><path d="M0 108 L90 102 L90 160 L0 160Z" fill="#d6d6d3"/>'
             f'<rect x="56" y="92" width="34" height="24" fill="#a9a9a6"/><ellipse cx="{36+variant*6}" cy="140" rx="12" ry="3" fill="#8a8a87" opacity=".6"/>'
             f'<g transform="translate({22+variant*6} 64) scale(.26)" fill="#7d7d7a">{SIL}</g><g transform="translate(66 72) scale(.2)" fill="#8d8d8a">{SIL}</g>')
    elif kind == 'depth':
        s = (f'<defs><linearGradient id="dp{variant}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#050505"/><stop offset="1" stop-color="#5a5a5a"/></linearGradient></defs>'
             f'<rect width="90" height="160" fill="url(#dp{variant})"/><rect x="56" y="92" width="34" height="24" fill="#3a3a3a"/>'
             f'<g transform="translate(24 64) scale(.26)" fill="#e8e8e8">{SIL}</g><g transform="translate(66 72) scale(.2)" fill="#7a7a7a">{SIL}</g>')
    else:
        lines = [(37, 72, 37, 98), (37, 78, 28, 96), (37, 78, 46, 96), (37, 98, 31, 130), (37, 98, 43, 130), (31, 130, 30, 150), (43, 130, 45, 150)]
        cols = ['#ff4d4d', '#ffb84d', '#ffe14d', '#4dff88', '#4dc3ff', '#6b4dff', '#ff4dd2']
        s = '<rect width="90" height="160" fill="#060606"/>' + ''.join(
            f'<line x1="{a}" y1="{b}" x2="{c}" y2="{d}" stroke="{cols[i]}" stroke-width="2.4" stroke-linecap="round"/>' for i, (a, b, c, d) in enumerate(lines)) + \
            '<circle cx="37" cy="66" r="5" fill="none" stroke="#ff4d4d" stroke-width="2"/>' + \
            ''.join(f'<line x1="{a+36}" y1="{b+6}" x2="{c+36}" y2="{d+6}" stroke="{cols[i]}" stroke-width="1.8" stroke-linecap="round" opacity=".8"/>' for i, (a, b, c, d) in enumerate(lines))
    return f'<svg width="{w}" height="{h}" viewBox="0 0 90 160" preserveAspectRatio="xMidYMid slice">{s}</svg>'


def wave(n=120, h=28, seed=1, color='currentColor', amp=1.0, gap=2, bw=2):
    random.seed(seed)
    bars = []
    for i in range(n):
        v = (math.sin(i / 5.0 + seed) * .35 + .5 + random.random() * .35) * amp
        bars.append(f'<i style="height:{max(2, int(h * min(v, 1)))}px;width:{bw}px"></i>')
    return f'<div class="wf" style="gap:{gap}px;color:{color}">' + ''.join(bars) + '</div>'


def speed_curve(t='a', w=280, h=120, preset='hero'):
    k = TH[t]; I, A, M, L = k['ink'], k['acc'], k['mut'], k['line']
    grid = ''.join(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}" stroke="{L}" stroke-dasharray="2 4"/>' for y in (h * .25, h * .5, h * .75))
    pts = {'hero': [(0, .45), (.3, .45), (.42, .9), (.58, .9), (.7, .45), (1, .45)],
           'montage': [(0, .3), (.2, .75), (.4, .3), (.6, .75), (.8, .3), (1, .75)],
           'bullet': [(0, .35), (.35, .35), (.45, .92), (.55, .92), (.65, .35), (1, .35)]}[preset]
    P = [(x * w, (1 - y) * h) for x, y in pts]
    d = f'M{P[0][0]:.0f} {P[0][1]:.0f} ' + ' '.join(f'S{(P[i][0]+P[i-1][0])/2:.0f} {P[i][1]:.0f} {P[i][0]:.0f} {P[i][1]:.0f}' for i in range(1, len(P)))
    knobs = ''.join(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="5" fill="{k["bg"]}" stroke="{A}" stroke-width="2"/>' for x, y in P[1:-1])
    lab = (f'<text x="4" y="12" font-family="IBM Plex Mono" font-size="9" fill="{M}">10×</text><text x="4" y="{h*.5-3:.0f}" font-family="IBM Plex Mono" font-size="9" fill="{M}">1×</text>'
           f'<text x="4" y="{h-4}" font-family="IBM Plex Mono" font-size="9" fill="{M}">0.1×</text>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" style="background:{k["bg"]}">{grid}{lab}<path d="{d}" fill="none" stroke="{A}" stroke-width="2.2"/>{knobs}<line x1="{w*.5:.0f}" y1="0" x2="{w*.5:.0f}" y2="{h}" stroke="{I}" stroke-width="1"/></svg>'


def mini_cam_glyph(t='a', size=22):
    k = TH[t]
    return f'<svg width="{size}" height="{size}" viewBox="-14 -16 28 28">{cam(0, 0, 0, 1, k["ink"], 1)}</svg>'

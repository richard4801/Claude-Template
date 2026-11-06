"""Video composer review mockups (plans/video-composer.md).
One composer shell with Auto chips, one picker shell, hardware wheels, model-driven slots and presets as the beginner path.
Desktop C1–C6 (1440 × 900, Theme A Editorial; pickers in Theme B Camera Body), phone P1–P5 (390 × 844, Editorial with dark sheets).

Usage: python3 composer.py [filter]   -> design/screens/composer__C1…C6.jpg, composer__P1…P5.jpg and composer__overview.jpg
build.py also picks up page() for the Figma / review pages."""
import os, sys, math, subprocess, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base
from base import *
from art import cam, SIL
from ai_desktop import take_thumb

HW = os.path.join(ROOT, 'hardware')
SCREENS = os.path.join(ROOT, 'screens')
AMB = '#F2A93B'


def ensure_imgs():
    """base.img() reads JPGs from build/img (+ sm/); make them from the WebP renders when missing."""
    from PIL import Image
    os.makedirs(os.path.join(base.IMG_DIR, 'sm'), exist_ok=True)
    for f in sorted(os.listdir(HW)):
        if not f.endswith('.webp'):
            continue
        stem = f[:-5]
        big, sm = os.path.join(base.IMG_DIR, stem + '.jpg'), os.path.join(base.IMG_DIR, 'sm', stem + '.jpg')
        if os.path.exists(big) and os.path.exists(sm):
            continue
        im = Image.open(os.path.join(HW, f)).convert('RGB')
        im.save(big, quality=88)
        s = im.copy()
        s.thumbnail((320, 320))
        s.save(sm, quality=86)


_SW = {}


def swatches(name, n=10):
    """10 colours from a palette render, dark → light (the strip drawn under each palette still)."""
    if name not in _SW:
        from PIL import Image
        im = Image.open(os.path.join(HW, name + '.webp')).convert('RGB')
        im.thumbnail((180, 180))
        q = im.quantize(colors=n, method=Image.Quantize.MEDIANCUT)
        pal = q.getpalette()[:n * 3]
        cols = sorted((tuple(pal[i * 3:i * 3 + 3]) for i in range(n)), key=lambda c: .2126 * c[0] + .7152 * c[1] + .0722 * c[2])
        _SW[name] = ['#%02X%02X%02X' % c for c in cols]
    return _SW[name]


# CSS-tinted variants of the renders (palettes we have no still for yet)
GOLD = 'sepia(.8) saturate(1.9) hue-rotate(-14deg) brightness(1.08) contrast(1.04)'
TINTS = {
    'golden': ('palette-01-naturalistic', GOLD, ['#24170B', '#3D2812', '#5C3B18', '#7E521F', '#A06A29', '#BE8436', '#D49D4B', '#E3B568', '#EDCB8E', '#F6E3BD']),
    'moody': ('palette-06-classic-bw', 'sepia(1) hue-rotate(172deg) saturate(1.9) brightness(.86) contrast(1.12)', ['#070B12', '#0D1522', '#142034', '#1D2D47', '#29405F', '#38557A', '#4D6C93', '#6A88AA', '#93AAC4', '#C3D0DF']),
    'pastel': ('palette-04-bleached-warm', 'saturate(.55) brightness(1.14) hue-rotate(-28deg) contrast(.9)', ['#6B6466', '#857A7F', '#9C9096', '#B0A3AA', '#C1B4BC', '#CFC3CB', '#DAD0D7', '#E4DCE2', '#EDE7EB', '#F6F2F4']),
    'steel': ('palette-01-naturalistic', 'grayscale(.65) hue-rotate(12deg) brightness(.95) contrast(1.15)', ['#0C0F12', '#171C21', '#232A31', '#313A43', '#414C56', '#54606B', '#6A7680', '#848F98', '#A3ACB3', '#C9CFD3']),
    'fade': ('palette-02-teal-orange', 'sepia(.45) contrast(.82) brightness(1.12) saturate(.8)', ['#2C2723', '#3E3631', '#524840', '#675B50', '#7C6F61', '#928473', '#A89A87', '#BEB19C', '#D3C8B4', '#E8E0CF']),
}

TIERS = [('Draft', .16, '~1 min', 'Start + end frame · refs · clips'), ('Standard', .72, '~3 min', 'Start, middle, end · refs · clips'),
         ('HD', 1.92, '~5 min', 'Start, middle, end · refs · clips'), ('Cinema', 3.84, '~9 min', 'Start, middle, end · refs · clips')]

PRESETS = [('Phone UGC', 'palette-04-bleached-warm', 'noor'), ('Talking head', 'light-06-ring-creator', 'iris'), ('Selfie vlog', 'palette-01-naturalistic', 'iris'),
           ('Creator studio', 'light-01-soft-cross', 'noor'), ('Cinematic', 'palette-02-teal-orange', 'noor'), ('Product hero', 'light-03-overhead', None)]

CSS_C = r"""
.dk{background:var(--bg);color:var(--ink);font-family:var(--body)}
/* composer (Theme A) */
.cmp{background:var(--surface);border:1px solid var(--line);box-shadow:0 26px 70px rgba(40,30,10,.12),0 2px 6px rgba(40,30,10,.04);display:flex;flex-direction:column;flex:none;position:relative}
.toolrow{height:58px;flex:none;display:flex;align-items:center;gap:12px;padding:0 16px 0 12px;border-bottom:1px solid var(--line)}
.toolrow .nm{font:500 11px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ink)}
.toolrow .tg{font:400 13.5px var(--body);color:var(--muted)}
.toolrow .dotsep{width:3px;height:3px;border-radius:2px;background:var(--line)}
.sc{height:34px;display:inline-flex;align-items:center;gap:7px;padding:0 11px 0 5px;border:1px solid var(--line);background:var(--bg);white-space:nowrap;flex:none}
.sc .th{width:24px;height:24px;flex:none;overflow:hidden;background:var(--plate);position:relative}
.sc .th img{width:100%;height:100%;object-fit:cover}
.sc .th0{width:24px;height:24px;flex:none;border:1px dashed #B9AF9F;display:flex;align-items:center;justify-content:center;color:var(--muted)}
.sc .k{font:500 9.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.sc .v{font:600 12.5px var(--body);color:var(--ink);white-space:nowrap}
.sc.auto .v{font-weight:400;color:#4A443D}
.sc.auto .th img{filter:grayscale(1) brightness(.92)}
.slot{border:1px dashed #B9AF9F;background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:5px;position:relative;flex:none;text-align:center}
.slot:not(.full){padding-top:14px}
.slot .pl{width:30px;height:30px;border-radius:15px;border:1px solid var(--line);background:var(--surface);display:flex;align-items:center;justify-content:center;color:var(--ink);margin-bottom:3px}
.slot .sl{font:500 10px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--ink)}
.slot .cap{font:400 10.5px/1.25 var(--body);color:var(--muted);padding:0 6px}
.slot .opt{position:absolute;top:6px;right:6px;height:16px;padding:0 5px;display:flex;align-items:center;font:500 8.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);border:1px solid var(--line);background:var(--surface)}
.slot.off{background:transparent;border-color:#D5CDC0}
.slot.off .pl,.slot.off .sl,.slot.off .cap{opacity:.42}
.slot.full{border:0;overflow:hidden;justify-content:flex-end;align-items:stretch}
.slot.full .scr{position:absolute;left:0;right:0;bottom:0;height:58%;background:linear-gradient(180deg,rgba(0,0,0,0),rgba(14,12,10,.78))}
.slot.full .meta{position:relative;display:flex;flex-direction:column;gap:1px;padding:0 8px 7px;text-align:left}
.slot .x{position:absolute;top:5px;right:5px;width:20px;height:20px;border-radius:10px;background:rgba(14,12,10,.55);color:#F8F5EF;display:flex;align-items:center;justify-content:center}
.prompt{font:400 16px/1.6 var(--body);color:var(--ink)}
.prompt .ph{color:#8C847A}
.caret{display:inline-block;width:2px;height:21px;background:var(--accent);vertical-align:-5px;margin-right:3px}
.tok{display:inline-flex;align-items:center;gap:6px;height:27px;padding:0 9px 0 3px;background:var(--surface2);border:1px solid var(--line);vertical-align:1px;font:600 14px var(--body);color:var(--ink);margin:0 2px;line-height:1}
.tok .ti{width:21px;height:21px;flex:none;display:flex;align-items:center;justify-content:center;overflow:hidden}
.tok.mv .ti{background:var(--ink);color:#F8F5EF}
.tok .hash,.tok .at{color:var(--accent);font:500 13px var(--mono);margin-right:-3px}
.cbar{height:62px;flex:none;display:flex;align-items:center;gap:8px;padding:0 12px 0 16px;border-top:1px solid var(--line)}
.bp{height:34px;display:inline-flex;align-items:center;gap:7px;padding:0 11px;border:1px solid var(--line);background:var(--bg);font:500 12.5px var(--body);color:var(--ink);white-space:nowrap;flex:none}
.bp svg{color:var(--muted)}
.bp .mu{color:var(--muted);font-weight:400}
.bp.open{border-color:var(--ink);background:var(--surface);box-shadow:inset 0 0 0 1px var(--ink)}
.gen{height:44px;padding:0 22px;background:var(--cta);color:var(--cta-ink);display:inline-flex;align-items:center;gap:10px;font:500 12.5px var(--mono);letter-spacing:.14em;text-transform:uppercase;white-space:nowrap;flex:none}
.pop{position:absolute;background:var(--surface);border:1px solid var(--line);box-shadow:0 24px 60px rgba(40,30,10,.20),0 2px 8px rgba(40,30,10,.06);display:flex;flex-direction:column;z-index:5}
.qrow{display:flex;align-items:center;gap:12px;padding:11px 16px 11px 12px;border-top:1px solid var(--line)}
.qrow .ck{width:18px;flex:none;color:var(--accent);display:flex}
.qrow.on{background:var(--bg);box-shadow:inset 3px 0 0 var(--ink)}
.acc-l{font:400 10.5px var(--mono);color:var(--muted);letter-spacing:.01em}
.ptile{position:relative;overflow:hidden;flex:none}
.ptile .nm{position:absolute;left:10px;bottom:8px;font:400 22px/1 'Instrument Serif';color:#F8F5EF;letter-spacing:.005em}
.ptile .scr{position:absolute;left:0;right:0;bottom:0;height:60%;background:linear-gradient(180deg,rgba(0,0,0,0),rgba(10,9,8,.72))}
.ptile .pg{position:absolute;right:7px;top:7px;width:20px;height:20px;border-radius:10px;background:rgba(248,245,239,.88);color:#141210;display:flex;align-items:center;justify-content:center}
.ptile.on{outline:2px solid var(--ink);outline-offset:3px}
.shape{border:1px solid var(--line);background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;flex:none}
.shape .r{border:1.5px solid var(--ink)}
.shape .sl{font:500 11px var(--mono);letter-spacing:.1em;color:var(--ink)}
.shape.on{background:var(--surface);outline:2px solid var(--ink);outline-offset:-2px}
.shape.on .r{background:var(--ink)}
/* picker shell (Theme B) */
.mdl{position:absolute;border:1px solid #2C3033;border-radius:18px;overflow:hidden;box-shadow:0 50px 140px rgba(0,0,0,.55),0 0 0 1px rgba(0,0,0,.35);display:flex;flex-direction:column}
.mhd{height:62px;flex:none;display:flex;align-items:center;gap:14px;padding:0 14px 0 24px;border-bottom:1px solid var(--line)}
.mtitle{font:700 24px/1 'Barlow Condensed';letter-spacing:.08em;text-transform:uppercase;color:var(--ink)}
.msub{font:400 13px var(--body);color:var(--muted)}
.xbtn{width:34px;height:34px;border-radius:17px;background:var(--surface2);display:flex;align-items:center;justify-content:center;color:var(--ink);flex:none}
.ghost{height:32px;padding:0 12px;border-radius:16px;border:1px solid var(--line);font:600 13px var(--body);color:var(--muted);display:flex;align-items:center;gap:6px;flex:none}
.rail{width:176px;flex:none;border-right:1px solid var(--line);padding:14px 12px;display:flex;flex-direction:column;gap:4px}
.ri{height:42px;border-radius:10px;display:flex;align-items:center;gap:11px;padding:0 12px;font:600 15px var(--body);color:var(--muted)}
.ri.on{background:var(--surface2);color:var(--ink)}
.ri .dot{width:6px;height:6px;border-radius:3px;background:var(--accent);margin-left:auto}
.ri .own{margin-left:auto;height:18px;padding:0 6px;border-radius:9px;border:1px solid var(--line);font:500 9px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);display:flex;align-items:center}
.whw{position:relative;flex:none}
.wc{position:absolute;left:0;display:flex;flex-direction:column}
.wc .wp{border-radius:10px;overflow:hidden;background:#101112;position:relative;flex:none}
.wc .wp img{width:100%;height:100%;object-fit:cover}
.wc .wn{font:600 14px/1.2 var(--body);color:var(--ink);margin-top:10px;white-space:nowrap}
.wc .wl{font:400 12px/1.3 var(--body);color:var(--muted);margin-top:2px}
.wc.side{opacity:.4}
.wc.on .wp{outline:2px solid var(--accent);outline-offset:3px;box-shadow:0 0 0 7px rgba(242,169,59,.09),0 16px 36px rgba(242,169,59,.14)}
.wc .ok{position:absolute;left:7px;top:7px;width:20px;height:20px;border-radius:10px;background:var(--accent);color:#1A1205;display:flex;align-items:center;justify-content:center}
.band{position:absolute;border-radius:14px;background:rgba(255,255,255,.028);border:1px solid rgba(255,255,255,.045)}
.dchip{height:30px;display:inline-flex;align-items:center;padding:0 12px;border-radius:15px;background:var(--surface2);font:600 13px var(--body);color:var(--muted);white-space:nowrap;flex:none}
.dchip.on{background:var(--ink);color:#0D0E0F}
.dsearch{height:34px;display:flex;align-items:center;gap:8px;padding:0 12px;border-radius:17px;background:var(--surface2);color:var(--muted);font:400 13px var(--body);flex:none}
.dsearch .kk{margin-left:auto;font:500 11px var(--mono);border:1px solid var(--line);border-radius:5px;padding:1px 6px;color:var(--muted)}
.mvt{display:flex;flex-direction:column;gap:9px;flex:none}
.mvp{border-radius:10px;overflow:hidden;position:relative;background:#0b0c0d;flex:none}
.mvp .camv{position:absolute;inset:0}
.mvp .camv img{width:100%;height:100%;object-fit:cover}
.mvn{font:600 14px/1.2 var(--body);color:var(--ink)}
.badge{position:absolute;left:8px;top:8px;height:20px;padding:0 8px 0 6px;border-radius:10px;background:rgba(13,14,15,.74);color:#ECEAE5;font:500 9.5px 'JetBrains Mono';letter-spacing:.06em;text-transform:uppercase;display:flex;align-items:center;gap:5px;border:1px solid rgba(255,255,255,.08)}
.playg{position:absolute;right:8px;bottom:8px;width:24px;height:24px;border-radius:12px;background:rgba(13,14,15,.62);border:1px solid rgba(255,255,255,.2);display:flex;align-items:center;justify-content:center;color:#fff}
.lt{display:flex;flex-direction:column;flex:none}
.lt .lp{border-radius:10px 10px 0 0;overflow:hidden;position:relative;background:#101112}
.lt .lp img{width:100%;height:100%;object-fit:cover}
.lt .sw{display:flex;height:10px;border-radius:0 0 10px 10px;overflow:hidden}
.lt .sw i{flex:1 1 0}
.lt .ln{font:600 14px/1.2 var(--body);color:var(--ink);margin-top:9px}
.lt .ll{font:400 12px/1.3 var(--body);color:var(--muted);margin-top:1px}
.lt.on .frame2{outline:2px solid var(--accent);outline-offset:3px;border-radius:10px;box-shadow:0 0 0 7px rgba(242,169,59,.09)}
.mft{height:58px;flex:none;display:flex;align-items:center;gap:14px;padding:0 24px;border-top:1px solid var(--line);background:var(--surface)}
/* phone */
.pcmp{position:absolute;left:0;right:0;bottom:0;background:var(--surface);border-top:1px solid var(--line);box-shadow:0 -18px 44px rgba(40,30,10,.10);display:flex;flex-direction:column;gap:12px;padding:12px 16px 32px}
.rgen{width:62px;height:62px;border-radius:31px;background:var(--cta);color:var(--cta-ink);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;flex:none;box-shadow:0 8px 20px rgba(20,18,16,.25)}
.rgen span{font:500 11px var(--mono);letter-spacing:.04em}
.ibtn{width:40px;height:40px;border:1px solid var(--line);background:var(--bg);display:flex;align-items:center;justify-content:center;color:var(--ink);flex:none}
.psheet{position:absolute;left:0;right:0;bottom:0;border-radius:22px 22px 0 0;display:flex;flex-direction:column;box-shadow:0 -24px 60px rgba(0,0,0,.4);overflow:hidden}
.psheet .grab{background:#3A3F43;margin:9px 0 2px}
.phd{height:50px;flex:none;display:flex;align-items:center;gap:10px;padding:0 14px 0 20px}
.pseg{display:flex;padding:3px;gap:3px;background:var(--surface2);border-radius:11px;margin:0 16px;flex:none}
.pseg span{flex:1 1 0;height:34px;border-radius:8px;display:flex;align-items:center;justify-content:center;font:600 14px var(--body);color:var(--muted)}
.pseg span.on{background:var(--ink);color:#0D0E0F}
.drow{display:flex;align-items:center;gap:12px;padding:12px 14px;border-radius:12px;background:var(--surface)}
.drow.on{box-shadow:inset 0 0 0 2px var(--accent)}
.dprice{font:600 17px var(--mono);color:var(--ink)}
.stp{display:flex;align-items:center;border-radius:10px;background:var(--surface2);flex:none}
.stp span{width:38px;height:36px;display:flex;align-items:center;justify-content:center;color:var(--ink)}
.stp b{width:30px;text-align:center;font:600 16px var(--mono)}
.dseg{display:flex;padding:3px;gap:3px;background:var(--surface2);border-radius:10px;flex:none}
.dseg span{height:30px;padding:0 14px;border-radius:7px;display:flex;align-items:center;font:600 13px var(--body);color:var(--muted)}
.dseg span.on{background:var(--ink);color:#0D0E0F}
.dshape{flex:1 1 0;height:70px;border-radius:12px;background:var(--surface);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:9px}
.dshape .r{border:1.5px solid var(--muted);border-radius:2px}
.dshape span{font:500 11px var(--mono);color:var(--muted);letter-spacing:.06em}
.dshape.on{box-shadow:inset 0 0 0 2px var(--accent)}
.dshape.on .r{border-color:var(--accent);background:rgba(242,169,59,.18)}
.dshape.on span{color:var(--ink)}
.dcta{height:54px;border-radius:27px;background:var(--accent);color:#1A1205;display:flex;align-items:center;justify-content:center;font:700 16px var(--body);flex:none}
"""


# ---------------------------------------------------------------- small pieces
def thumb(name, w, h, flt='', pos='center', extra='', radius=None):
    st = f'filter:{flt};' if flt else ''
    r = f'border-radius:{radius}px;' if radius is not None else ''
    return (f'<div class="plate" style="width:{w}px;height:{h}px;{r}"><img src="{img(name, max(w, h) <= 150)}" '
            f'style="width:100%;height:100%;object-fit:cover;object-position:{pos};{st}">{extra}</div>')


def figure(w, h, rim='#F0C79A', color='#17120e', op=.93):
    return sil(w, h, color, op, rim=rim)


def stage_scene(name, w, h, who=True, pos=.5, scale=.8, blur=0, extra='', flt=''):
    """A dark render with a rim-lit character silhouette (our cast placeholder on sets the base helper would lose)."""
    s = ''
    if who:
        sh = int(h * scale)
        sw = int(sh / 3)
        s = f'<div class="sil" style="left:{int(w * pos - sw / 2)}px;bottom:-{int(sh * .02)}px">{figure(sw, sh)}</div>'
    bl = f'filter:blur({blur}px){(" " + flt) if flt else ""};transform:scale(1.08);' if blur else (f'filter:{flt};' if flt else '')
    return (f'<div class="plate" style="width:{w}px;height:{h}px"><img src="{img(name, max(w, h) <= 150)}" style="width:100%;height:100%;object-fit:cover;{bl}">'
            f'{s}{extra}</div>')


def schip(label, value='Auto', im=None, flt='', maxw=None, auto=True):
    if im:
        th = thumb(im, 24, 24, flt='' if auto else flt)
        th = th.replace('class="plate"', 'class="plate th"', 1)
    else:
        th = f'<div class="th0">{ic("image", 13)}</div>'
    mv = f'max-width:{maxw}px;overflow:hidden;text-overflow:ellipsis;' if maxw else ''
    return f'<div class="sc{" auto" if auto else ""}">{th}<span class="k">{label}</span><span class="v" style="{mv}">{value}</span></div>'


def chips_auto():
    return (schip('References', '0/9') + schip('Style', 'Auto', 'stock-02-16mm') + schip('Camera', 'Auto', 'body-05-film35')
            + schip('Look', 'Auto', 'palette-02-teal-orange') + schip('Lighting', 'Auto', 'light-04-window'))


def chips_filled():
    return (schip('References', '0/9') + schip('Style', 'UGC, Calm', 'stock-02-16mm', auto=False)
            + schip('Camera', '35mm film, Anamorphic, …', 'body-05-film35', auto=False)
            + schip('Look', 'Golden warmth', TINTS['golden'][0], flt=GOLD, auto=False) + schip('Lighting', 'Window light', 'light-04-window', auto=False))


def slot(label, cap, opt=False, off=False, w=104, h=104):
    o = '<span class="opt">Optional</span>' if opt else ''
    return (f'<div class="slot{" off" if off else ""}" style="width:{w}px;height:{h}px">{o}<div class="pl">{ic("plus", 14, 1.8)}</div>'
            f'<span class="sl">{label}</span><span class="cap">{cap}</span></div>')


def slot_char(w=104, h=104, outfit='Cream linen set'):
    c = CHARS['noor']
    return (f'<div class="slot full" style="width:{w}px;height:{h}px;background:linear-gradient(180deg,{c["tone"]},{c["tone2"]})">'
            f'<div style="position:absolute;left:0;right:0;bottom:0;display:flex;justify-content:center">{sil(int(w * .66), int(h * .98), "#2a211b", .8, "0 0 100 150")}</div>'
            f'<div class="scr"></div><div class="x">{ic("x", 11, 2)}</div>'
            f'<div class="meta"><span style="font:600 13px var(--body);color:#F8F5EF">Noor</span><span style="font:400 10.5px var(--body);color:#E7E1D6;white-space:nowrap">{outfit} ▾</span></div></div>')


def slot_frame(w=104, h=104):
    return (f'<div class="slot full" style="width:{w}px;height:{h}px"><div style="position:absolute;inset:0">{scene("light-04-window", w, h, "noor", .56, scale=.86)}</div>'
            f'<div class="scr"></div><div class="x">{ic("x", 11, 2)}</div>'
            f'<div class="meta"><span style="font:500 9.5px var(--mono);letter-spacing:.1em;color:#F8F5EF">START FRAME</span><span style="font:400 10.5px var(--body);color:#E7E1D6">Sets the shape</span></div></div>')


def tool_row(name='Shot', tag='Your character in a scene', im='palette-04-bleached-warm', who='noor', right=''):
    th = stage_scene(im, 34, 42, who, .5, .86) if im not in DARK_PLATES else scene(im, 34, 42, who, .5, scale=.86)
    return (f'<div class="toolrow">{th}<span class="nm">{name}</span><span class="dotsep"></span><span class="tg">{tag}</span>'
            f'<span class="btn sm" style="margin-left:6px">{ic("swap", 13)} Change</span><div class="fill"></div>'
            f'<span class="t12">{right}</span></div>')


def bar(q='Draft', price='$0.16', open_q=False):
    p = [('gauge', q + f' {ic("chev-d", 12)}', 'Quality'), ('ratio', '9:16', 'Shape'), ('clock', '8s', 'Length'),
         ('volume', 'Sound <span class="mu">On</span>', 'Sound'), ('talk', 'Speaking <span class="mu">Auto</span>', 'Speaking'), ('layers', '1<span class="mu">/4</span>', 'Takes')]
    pills = ''.join(f'<span class="bp{" open" if (open_q and i == 0) else ""}">{ic(icn, 15)}{t}</span>' for i, (icn, t, _) in enumerate(p))
    return f'<div class="cbar">{pills}<div class="fill"></div><span class="gen">Generate · {price}</span></div>'


def prompt_empty():
    return ('<div class="prompt fill" style="padding:4px 2px"><span class="caret"></span><span class="ph">Describe the scene · type @ for your characters, # for a camera move</span></div>')


def prompt_filled():
    noor = f'<span class="tok"><span class="ti">{avatar("noor", 21, 21, letter=False)}</span><span class="at">@</span>Noor</span>'
    mv = f'<span class="tok mv"><span class="ti">{ic("move", 13)}</span><span class="hash">#</span>Dolly in</span>'
    return (f'<div class="prompt fill" style="padding:2px 2px;line-height:1.75">{noor} walks into a quiet café at golden hour, orders at the counter, '
            f'then turns to camera with a soft smile. {mv}<span class="caret" style="margin-left:3px"></span></div>')


def composer(filled=False, w=960, open_q=False, prompt_h=None):
    chips = chips_filled() if filled else chips_auto()
    if filled:
        slots = slot_char() + slot_frame() + slot('End frame', 'Where it lands', opt=True)
    else:
        slots = slot('Character', 'Your models') + slot('Start frame', 'Sets the shape', opt=True) + slot('End frame', 'After a start frame', opt=True, off=True)
    q, price = ('HD', '$1.92') if filled else ('Draft', '$0.16')
    pop = q_popover() if open_q else ''
    mh = f'min-height:{prompt_h}px;' if prompt_h else ''
    return (f'<div class="cmp" style="width:{w}px">{tool_row(right="Autosaved" if filled else "")}'
            f'<div class="col" style="padding:14px 16px 16px;gap:14px"><div class="row g6">{chips}</div>'
            f'<div class="row g16" style="align-items:flex-start;{mh}">{prompt_filled() if filled else prompt_empty()}<div class="row g10">{slots}</div></div></div>'
            f'{bar(q, price, open_q)}{pop}</div>')


def q_popover(w=580):
    boxes = ''
    for n, p, t, acc in TIERS:
        on = n == 'HD'
        a1, a2 = (acc.split(' · ', 1) + [''])[:2]
        ck = f'<span style="color:var(--accent);display:flex">{ic("check", 15, 2.4)}</span>' if on else ''
        boxes += (f'<div class="col" style="flex:1 1 0;min-width:0;padding:10px 12px 11px;border:1px solid var(--line);background:{"var(--surface)" if on else "var(--bg)"};gap:3px;'
                  f'{"outline:2px solid var(--ink);outline-offset:-1px;" if on else ""}"><div class="row between"><span class="row g6"><span class="t13 b">{n}</span>{ck}</span>'
                  f'<span class="price" style="font-size:23px">${p:.2f}</span></div><span class="t12">{t}</span>'
                  f'<span class="acc-l" style="line-height:1.4;margin-top:3px;font-size:10px;letter-spacing:0;white-space:nowrap">{a1}<br>{a2}</span></div>')
    return (f'<div class="pop" style="left:16px;bottom:72px;width:{w}px;padding:12px 12px 12px"><div class="row between" style="padding:0 2px 10px">'
            f'<span class="row g8"><span class="lbl ink">Quality</span><span class="t12">per 8 s take · slots follow what each accepts</span></span>'
            f'<span class="t12" style="color:var(--ink);text-decoration:underline;text-underline-offset:3px;text-decoration-color:var(--line)">How is this priced?</span></div>'
            f'<div class="row g8" style="align-items:stretch">{boxes}</div>'
            f'<div style="position:absolute;left:30px;bottom:-7px;width:12px;height:12px;background:var(--surface);border-right:1px solid var(--line);border-bottom:1px solid var(--line);transform:rotate(45deg)"></div></div>')


def head():
    return (f'<div class="row" style="padding:22px 0 0;flex:none;align-items:flex-end;width:960px;align-self:center">'
            f'<div class="col g6"><span class="lbl">Video suite</span><span class="h1" style="font-size:44px">Shot</span></div><div class="fill"></div></div>')


def recents(n=6, w=100, h=178):
    items = [('ready', 'palette-04-bleached-warm', 'noor', 'MORNING · T1'), ('render', 'palette-02-teal-orange', 'noor', 'CAFÉ · T2'),
             ('ready', 'light-04-window', 'iris', 'WINDOW · T1'), ('ready', 'palette-01-naturalistic', 'iris', 'STREET · T1'),
             ('ready', 'palette-03-hyper-neon', 'noor', 'NEON · T1'), ('ready', 'palette-05-sodium-decay', 'iris', 'NIGHT · T2')][:n]
    th = ''.join(f'<div class="col g6">{take_thumb(s, w, h, im, who)}<span class="mono" style="font-size:10px">{l}</span></div>' for s, im, who, l in items)
    return (f'<div class="col g10" style="width:960px;align-self:center;flex:none"><div class="row between"><span class="lbl ink">Recent takes</span>'
            f'<span class="t12">See all in Queue →</span></div><div class="row g20" style="align-items:flex-start">{th}</div></div>')


def preset_tile(name, im, who, w=150, h=96, on=False):
    if who:
        sc = stage_scene(im, w, h, True, .5, .9) if im not in DARK_PLATES else scene(im, w, h, who, .5, scale=.9)
    else:
        sc = thumb(im, w, h)
    return (f'<div class="ptile{" on" if on else ""}" style="width:{w}px;height:{h}px"><div style="position:absolute;inset:0">{sc}</div>'
            f'<div class="scr"></div><div class="pg">{ic("play", 9)}</div><span class="nm">{name}</span></div>')


def presets_row(on=None, w=150, h=96):
    tiles = ''.join(preset_tile(n, im, who, w, h, n == on) for n, im, who in PRESETS)
    return (f'<div class="col g10" style="width:960px;align-self:center;flex:none"><div class="row between"><span class="lbl ink">Start from a preset</span>'
            f'<span class="t12">All 11 presets →</span></div><div class="row g12">{tiles}</div></div>')


def desk(content, name, extra=''):
    return (f'<div class="frame d theme-a" data-name="{name}"><style>{CSS_C}</style>{titlebar("62%")}'
            f'<div class="body">{sidebar("suite", "shot")}<div class="fill col" style="min-width:0;position:relative">{content}</div></div>{extra}</div>')


def page_empty(on_preset=None, collapsed=False):
    comp = composer_preset() if collapsed else composer()
    return (f'<div class="col fill" style="min-height:0;gap:0">{head()}<div style="height:20px"></div>{recents()}'
            f'<div style="flex:1 1 0;min-height:24px"></div><div class="row" style="justify-content:center">{comp}</div>'
            f'<div style="height:26px"></div>{presets_row(on_preset)}<div style="height:30px"></div></div>')


# ---------------------------------------------------------------- C1, C5, C6
def c1():
    return desk(page_empty(), 'Composer · C1 empty')


def c5():
    content = (f'<div class="col fill" style="min-height:0">{head()}<div style="height:20px"></div>{recents(6, 100, 178)}'
               f'<div class="fill"></div><div class="row" style="justify-content:center;padding-bottom:28px">{composer(True, open_q=True, prompt_h=230)}</div></div>')
    return desk(content, 'Composer · C5 filled')


def shape_tile(lbl, rw, rh, on=False, s=108):
    return f'<div class="shape{" on" if on else ""}" style="width:{s}px;height:{s}px"><div class="r" style="width:{rw}px;height:{rh}px"></div><span class="sl">{lbl}</span></div>'


def composer_preset(w=960):
    shapes = shape_tile('9:16', 34, 60, True) + shape_tile('1:1', 52, 52) + shape_tile('16:9', 72, 40)
    body = (f'<div class="row" style="padding:20px 20px 22px 16px;gap:28px;align-items:flex-end">'
            f'<div class="col g8"><span class="lbl">Who</span>{slot("Character", "Your models", w=108, h=108)}</div>'
            f'<div class="col g8"><span class="lbl">Shape</span><div class="row g10">{shapes}</div></div><div class="fill"></div>'
            f'<div class="col g12" style="align-items:flex-end"><span class="t12" style="text-align:right">Draft · 8 s · film look, slow push</span>'
            f'<span class="gen" style="height:52px;padding:0 28px">Generate · $0.16</span>'
            f'<span class="t13" style="color:var(--ink);text-decoration:underline;text-underline-offset:3px;text-decoration-color:var(--line)">Edit settings</span></div></div>')
    return (f'<div class="cmp" style="width:{w}px">{tool_row("Cinematic", "Film look, shallow focus, slow push", "palette-02-teal-orange", "noor")}{body}</div>')


def c6():
    return desk(page_empty('Cinematic', collapsed=True), 'Composer · C6 preset')


# ---------------------------------------------------------------- picker shell (desktop)
def modal(title, sub, body, w=840, h=540, right='', left=300, top=180):
    return (f'<div class="dim" style="background:rgba(16,14,12,.52)"></div>'
            f'<div class="theme-b dk mdl" style="left:{left}px;top:{top}px;width:{w}px;height:{h}px">'
            f'<div class="mhd"><span class="mtitle">{title}</span><span class="msub">{sub}</span><div class="fill"></div>{right}'
            f'<span class="ghost">{ic("refresh", 13)} Reset all</span><span class="xbtn">{ic("x", 16, 1.8)}</span></div>{body}</div>')


def cam_rail(on):
    items = [('sliders', 'Setup', True), ('eye', 'Angle', False), ('move', 'Movement', False), ('cube', 'Directed', None)]
    rows = ''
    for i, t, dot in items:
        tail = '<span class="dot"></span>' if dot else ('<span class="own">Owner</span>' if dot is None else '')
        rows += f'<div class="ri{" on" if t == on else ""}">{ic(i, 17)}<span>{t}</span>{tail}</div>'
    return (f'<div class="rail">{rows}<div class="fill"></div><div class="col g4" style="padding:0 6px 4px"><span class="lbl">Your camera</span>'
            f'<span style="font:400 12px/1.45 var(--body);color:var(--ink)">35mm film · Anamorphic · 50 mm · f/2.8</span></div></div>')


def fov_svg(mm, on, w, h, uid=''):
    half = {35: 27, 50: 20, 85: 12}[mm]
    cx, cy, L = w / 2, h - 13, h - 26
    dx = L * math.tan(math.radians(half))
    col = AMB if on else '#ECEAE5'
    fill = 'rgba(242,169,59,.16)' if on else 'rgba(236,234,229,.08)'
    r = 22
    a1, a2 = math.radians(-90 - half), math.radians(-90 + half)
    arc = f'M{cx + r * math.cos(a1):.1f} {cy + r * math.sin(a1):.1f} A{r} {r} 0 0 1 {cx + r * math.cos(a2):.1f} {cy + r * math.sin(a2):.1f}'
    grid = ''.join(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}" stroke="#ECEAE5" stroke-opacity=".05"/>' for y in range(8, int(h), 12))
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}"><rect width="{w}" height="{h}" fill="#121315"/>{grid}'
            f'<path d="M{cx} {cy} L{cx - dx:.1f} {cy - L} L{cx + dx:.1f} {cy - L} Z" fill="{fill}"/>'
            f'<path d="M{cx - dx:.1f} {cy - L} L{cx} {cy} L{cx + dx:.1f} {cy - L}" fill="none" stroke="{col}" stroke-width="1.5" stroke-opacity=".9"/>'
            f'<path d="{arc}" fill="none" stroke="{col}" stroke-width="1" stroke-opacity=".7"/>'
            f'<circle cx="{cx}" cy="{cy - L + 9}" r="4.5" fill="#ECEAE5"/>'
            f'<text x="{cx + dx + 6:.1f}" y="{cy - L + 12}" font-family="JetBrains Mono" font-size="9.5" fill="#A9A6A0">{2 * half}°</text>'
            f'{cam(cx, cy + 1, -90, 1, "#ECEAE5", .75, False)}</svg>')


def iris_plate(stop, w, h):
    r = {1.4: .40, 2.8: .27, 5.6: .15}[stop] * h
    cx, cy = w / 2, h / 2
    hexp = ' '.join(f'{cx + r * math.cos(math.radians(30 + k * 60)):.1f},{cy + r * math.sin(math.radians(30 + k * 60)):.1f}' for k in range(6))
    return (f'<img src="{img("optic-01-iris")}" style="width:100%;height:100%;object-fit:cover;transform:scale(1.25)">'
            f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" style="position:absolute;inset:0"><path fill-rule="evenodd" fill="rgba(8,8,9,.58)" d="M0 0H{w}V{h}H0Z M{hexp.replace(" ", " L")}Z"/>'
            f'<polygon points="{hexp}" fill="none" stroke="#ECEAE5" stroke-opacity=".55" stroke-width="1"/></svg>')


def wcard(kind, val, name, line, w, ph, on=False, side=None, top=0, scale=.8, left=0):
    if kind == 'img':
        plate = f'<img src="{img(val)}">'
    elif kind == 'fov':
        plate = fov_svg(val, on, w, ph)
    else:
        plate = iris_plate(val, w, ph)
    ok = f'<span class="ok">{ic("check", 11, 2.6)}</span>' if on else ''
    st = f'left:{left}px;top:{top}px;width:{w}px;'
    if side == 'prev':
        st += f'transform-origin:50% 100%;transform:scale({scale});'
    elif side == 'next':
        st += f'transform-origin:50% 0;transform:scale({scale});'
    return (f'<div class="wc{" on" if on else ""}{" side" if side else ""}" style="{st}"><div class="wp" style="width:{w}px;height:{ph}px">{plate}{ok}</div>'
            f'<span class="wn">{name}</span><span class="wl" style="height:31px">{line}</span></div>')


WHEELS = [
    ('Camera', 'img', [('body-02-super35', 'Cinema camera', 'Clean digital cinema'), ('body-05-film35', '35mm film', 'Grain, halation, organic colour'), ('body-06-film16', '16mm film', 'Grainy, documentary')], '5 / 11'),
    ('Lens', 'img', [('lens-04-warm-vintage', 'Warm vintage', 'Warm, gentle falloff'), ('lens-02-anamorphic', 'Anamorphic', 'Oval bokeh, blue flares'), ('lens-03-vintage-anamorphic', 'Vintage anamorphic', 'Amber flares, soft edges')], '4 / 10'),
    ('Focal', 'fov', [(35, '35 mm', 'Everyday, a touch wide'), (50, '50 mm · Natural', 'Like your eye sees'), (85, '85 mm · Portrait', 'Flattering, tighter faces')], '5 / 7'),
    ('Aperture', 'iris', [(1.4, 'f/1.4 · Dreamy blur', 'Background melts away'), (2.8, 'f/2.8 · Soft background', 'Subject pops, gentle blur'), (5.6, 'f/5.6 · Natural', 'Most of the scene sharp')], '3 / 5'),
]


def wheels(w=143, ph=84, H=404, gap=15, label_h=30, mobile=False):
    hc = ph + 10 + 17 + 2 + 31
    tc = (H - hc) // 2
    cols = []
    for title, kind, items, idx in WHEELS:
        (pv, pn, pl), (cv, cn, cl), (nv, nn, nl) = items
        cards = (wcard(kind, pv, pn, pl, w, ph, side='prev', top=tc - 14 - hc, left=14) + wcard(kind, cv, cn, cl, w, ph, on=True, top=tc, left=14)
                 + wcard(kind, nv, nn, nl, w, ph, side='next', top=tc + hc + 14, left=14))
        cols.append(f'<div class="col" style="width:{w}px;flex:none;gap:0"><div class="row between" style="height:{label_h - 12}px;margin-bottom:12px"><span class="lbl ink">{title}</span>'
                    f'<span class="row g4" style="color:var(--muted)"><span class="mono" style="font-size:10.5px;margin-right:4px">{idx}</span>{ic("chev-d", 14)}</span></div>'
                    f'<div class="whw" style="width:{w + 28}px;margin:0 -14px;height:{H}px;-webkit-mask-image:linear-gradient(180deg,rgba(0,0,0,.55),#000 16%,#000 84%,rgba(0,0,0,.55))">{cards}</div></div>')
    band = f'<div class="band" style="left:-10px;right:-10px;top:{label_h + tc - 10}px;height:{hc + 14}px"></div>'
    return f'<div class="row" style="gap:{gap}px;align-items:flex-start;position:relative">{band}{"".join(cols)}</div>'


def c2():
    body = f'<div class="row fill" style="min-height:0;align-items:stretch">{cam_rail("Setup")}<div class="col fill" style="padding:18px 22px 0;min-width:0">{wheels()}</div></div>'
    return desk(page_empty(), 'Composer · C2 Camera setup', modal('Camera', 'Scroll a wheel · applies instantly', body))


# ---------------------------------------------------------------- moves
def mannequin(w, h, uid):
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 100 300" preserveAspectRatio="xMidYMax meet"><defs><linearGradient id="mq{uid}" x1="0" y1="0" x2="1" y2="0">'
            f'<stop offset="0" stop-color="#55524d"/><stop offset=".48" stop-color="#bdb8b0"/><stop offset="1" stop-color="#625e58"/></linearGradient></defs>'
            f'<g fill="url(#mq{uid})" stroke="#efe9df" stroke-opacity=".28" stroke-width="1.2">{SIL}</g></svg>')


def ah(x, y, ang, s=1.0):
    return f'<path d="M0 0 L-10 -5.5 L-10 5.5 Z" transform="translate({x:.1f} {y:.1f}) rotate({ang}) scale({s})" fill="{AMB}"/>'


def move_overlay(k, w, h):
    S = f'stroke="{AMB}" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"'
    if k == 'handheld':
        s = (f'<rect x="14" y="14" width="115" height="114" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="1.2" transform="rotate(-3 71 71)"/>'
             f'<rect x="14" y="14" width="115" height="114" fill="none" stroke="#fff" stroke-opacity=".2" stroke-width="1.2" transform="rotate(2.5 71 71)"/>'
             f'<path d="M18 118 l7 -7 7 8 7 -7 7 9 7 -8" {S}/>')
    elif k == 'selfie':
        s = (f'<path d="M57 104 l14 10 14 -10" {S}/><path d="M57 116 l14 10 14 -10" {S} stroke-opacity=".6"/>'
             f'<path d="M100 60 C 116 70, 122 88, 120 104" {S} stroke-dasharray="4 4" stroke-width="1.8"/>')
    elif k == 'micro':
        c = [(32, 42, 1, 1), (111, 42, -1, 1), (32, 108, 1, -1), (111, 108, -1, -1)]
        s = ''.join(f'<path d="M{x} {y + dy * 12} L{x} {y} L{x + dx * 12} {y}" {S}/><path d="M{x + dx * 7} {y + dy * 7} L{x + dx * 14} {y + dy * 14}" {S} stroke-width="1.8"/>' for x, y, dx, dy in c)
    elif k == 'dolly':
        s = (f'<path d="M34 142 L60 96 M109 142 L83 96" stroke="#fff" stroke-opacity=".45" stroke-width="1.4"/>'
             f'<path d="M71 136 L71 104" {S}/>' + ah(71, 98, -90))
    elif k == 'orbit':
        s = (f'<path d="M30 90 A41 12 0 0 1 112 90" fill="none" stroke="{AMB}" stroke-opacity=".45" stroke-width="1.6" stroke-dasharray="3 4"/>'
             f'<path d="M112 90 A41 12 0 0 1 36 96" {S}/>' + ah(32, 94, 196))
    elif k == 'crane':
        s = (f'<path d="M24 120 L24 40" {S}/>' + ah(24, 32, -90) + ''.join(f'<path d="M19 {y} h10" stroke="#fff" stroke-opacity=".4" stroke-width="1.2"/>' for y in (60, 80, 100)))
    elif k == 'track':
        s = (f'<path d="M30 62 L110 62" {S}/>' + ah(118, 62, 0) + ''.join(f'<path d="M{x} 62 h6" stroke="{AMB}" stroke-opacity=".5" stroke-width="2"/>' for x in (12, 21)))
    else:  # fpv
        s = f'<path d="M14 130 C 44 70, 86 132, 120 34" {S}/>' + ah(122, 28, -70)
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 143 142" preserveAspectRatio="none" style="position:absolute;inset:0;filter:drop-shadow(0 1px 2px rgba(0,0,0,.65))">{s}</svg>')


MOVES_F = [('handheld', 'Handheld UGC', True, 'rotate(-2deg) scale(1.1)'), ('selfie', 'Selfie walk-and-talk', True, 'scale(1.55) translateY(14%)'),
           ('micro', 'Micro push', True, 'scale(1.14)'), ('dolly', 'Dolly in', False, 'scale(1.22) translateY(4%)'),
           ('orbit', 'Orbit left', False, 'scale(1.06) translateX(-3%)'), ('crane', 'Crane up', False, 'translateY(-7%) scale(1.02)'),
           ('track', 'Tracking follow', False, 'translateX(-9%) scale(1.06)'), ('fpv', 'FPV drone', False, 'rotate(-8deg) scale(1.3)')]


def move_tile(k, name, talk, tf, w=143, h=142, uid=0):
    mh = int(h * .74)
    camv = (f'<div class="camv" style="transform:{tf}"><img src="{img("light-01-soft-cross")}" style="filter:brightness(.92)">'
            f'<div style="position:absolute;left:0;right:0;bottom:{int(h * .03)}px;display:flex;justify-content:center">{mannequin(int(mh / 3), mh, f"{uid}{k}")}</div></div>')
    badge = f'<span class="badge">{ic("talk", 10, 2)}Talk-safe</span>' if talk else ''
    return (f'<div class="mvt" style="width:{w}px"><div class="mvp" style="width:{w}px;height:{h}px">{camv}{move_overlay(k, w, h)}{badge}'
            f'<span class="playg">{ic("play", 9)}</span></div><span class="mvn">{name}</span></div>')


CATS = ['Featured', 'UGC', 'Push', 'Pan & tilt', 'Orbit', 'Crane', 'Follow', 'Aerial', 'Special']


def c3():
    tiles = [move_tile(k, n, t, tf, uid=i) for i, (k, n, t, tf) in enumerate(MOVES_F)]
    grid = f'<div class="col" style="gap:16px"><div class="row" style="gap:15px;align-items:flex-start">{"".join(tiles[:4])}</div><div class="row" style="gap:15px;align-items:flex-start">{"".join(tiles[4:])}</div></div>'
    chips_ = ''.join(f'<span class="dchip{" on" if c == "Featured" else ""}">{c}</span>' for c in CATS)
    teach = (f'<div class="row g8" style="height:20px"><span class="msub" style="color:var(--ink)">Tap to add to your prompt</span><span class="msub">·</span>'
             f'<span class="msub">or type <span class="kc" style="color:var(--ink);border-color:var(--line)">#</span></span><span class="msub">·</span><span class="msub">up to 2 moves</span></div>')
    body = (f'<div class="row fill" style="min-height:0;align-items:stretch">{cam_rail("Movement")}<div class="col fill" style="padding:16px 22px 0;min-width:0;gap:14px">'
            f'{teach}<div class="row" style="gap:6px">{chips_}</div>{grid}</div></div>')
    search = f'<span class="dsearch" style="width:210px">{ic("search", 14)}<span>Search 37 moves</span></span>'
    return desk(page_empty(), 'Composer · C3 Movement', modal('Camera', '', body, right=search))


# ---------------------------------------------------------------- look
LOOKS = [('auto', None, 'Auto', 'Matches the scene'), ('golden', None, 'Golden warmth', 'Honey and amber'),
         ('palette-01-naturalistic', None, 'Naturalistic', 'True colour'), ('palette-02-teal-orange', None, 'Teal & orange', 'Blockbuster contrast'),
         ('palette-04-bleached-warm', None, 'Bleached warm', 'Sun-bleached warmth'), ('palette-03-hyper-neon', None, 'Hyper neon', 'Electric saturated neon'),
         ('palette-05-sodium-decay', None, 'Sodium decay', 'Urban orange streetlight'), ('moody', None, 'Moody blue', 'Deep blue shadows'),
         ('palette-06-classic-bw', None, 'Classic B&W', 'Monochrome'), ('pastel', None, 'Pastel dream', 'Soft pastels'),
         ('steel', None, 'Cold steel', 'Blue-grey and hard'), ('fade', None, 'Vintage fade', 'Faded 70s colour')]


def look_tile(key, name, line, w, ph, on=False):
    if key == 'auto':
        plate = (f'<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;background:linear-gradient(180deg,#1b1d20,#141518);color:var(--muted)">'
                 f'{ic("sparkle", 24, 1.4)}</div>')
        sw = ''.join(f'<i style="background:{c}"></i>' for c in ['#1E2023', '#26292C', '#2F3236', '#383C40', '#42464A', '#4D5155', '#585C60', '#64686C', '#707478', '#7D8185'])
    elif key in TINTS:
        src, flt, cols = TINTS[key]
        plate = f'<img src="{img(src)}" style="filter:{flt}">'
        sw = ''.join(f'<i style="background:{c}"></i>' for c in cols)
    else:
        plate = f'<img src="{img(key)}">'
        sw = ''.join(f'<i style="background:{c}"></i>' for c in swatches(key))
    ok = f'<span class="ok" style="position:absolute;left:8px;top:8px;width:22px;height:22px;border-radius:11px;background:var(--accent);color:#1A1205;display:flex;align-items:center;justify-content:center">{ic("check", 12, 2.6)}</span>' if on else ''
    return (f'<div class="lt{" on" if on else ""}" style="width:{w}px"><div class="frame2"><div class="lp" style="width:{w}px;height:{ph}px">{plate}{ok}</div><div class="sw">{sw}</div></div>'
            f'<span class="ln">{name}</span><span class="ll">{line}</span></div>')


def look_grid(cols, w, ph, gap, rows_full=2, peek=True):
    out = []
    items = LOOKS if peek else LOOKS[:cols * rows_full]
    for r in range(0, len(items), cols):
        row = ''.join(look_tile(k, n, l, w, ph, on=(n == 'Golden warmth')) for k, _, n, l in items[r:r + cols])
        out.append(f'<div class="row" style="gap:{gap}px;align-items:flex-start">{row}</div>')
    return out


def grade_toggle(compact=False):
    return (f'<div class="row g12" style="flex:1 1 0;min-width:0">{tog(True)}<div class="col g2"><span style="font:600 14px var(--body);color:var(--ink)">Grade the take with this look</span>'
            f'<span class="t12">Exact colour, reversible in Edit</span></div></div>')


def c4():
    rows = look_grid(4, 187, 96, 16)
    grid = (f'<div style="position:relative;flex:1 1 0;min-height:0;overflow:hidden;padding-top:5px;margin-top:-5px"><div class="col" style="gap:18px">{"".join(rows)}</div>'
            f'<div style="position:absolute;left:0;right:0;bottom:0;height:46px;background:linear-gradient(180deg,rgba(13,14,15,0),var(--bg))"></div></div>')
    top = (f'<div class="row between" style="flex:none"><div class="dseg"><span class="on">Palette</span><span>Film stock</span></div>'
           f'<span class="t12">28 palettes · each with an exact grade</span></div>')
    body = (f'<div class="col fill" style="padding:18px 22px 0;gap:16px;min-height:0">{top}{grid}</div>'
            f'<div class="mft">{grade_toggle()}<span class="t12">Golden warmth · applied</span></div>')
    return desk(page_empty(), 'Composer · C4 Look', modal('Look', 'Applies instantly', body))


# ---------------------------------------------------------------- phone
def ph(content, name, extra='', dark_home=True, title='Shot'):
    top = f'<div class="ptop">{ic("chev-l", 22)}<span class="t">{title}</span>{ic("more", 22)}</div>'
    hi = '<div class="home-ind"></div>' if dark_home else '<div class="home-ind" style="background:#ECEAE5;z-index:9"></div>'
    return (f'<div class="frame m theme-a" data-name="{name}"><style>{CSS_C}</style><div class="sbar"><span>9:41</span><span class="ic"><i></i><i></i><i style="width:24px"></i></span></div>'
            f'{top}<div class="fill col" style="min-height:0;position:relative;overflow:hidden">{content}</div>{extra}{hi}</div>')


def phone_composer():
    tr = (f'<div class="row g10">{scene("palette-04-bleached-warm", 30, 38, "noor", .5, scale=.86)}<div class="col g2 fill"><span class="lbl ink" style="font-size:10.5px;letter-spacing:.14em">Shot</span>'
          f'<span class="t12">Your character in a scene</span></div><span class="btn sm">{ic("swap", 13)} Change</span></div>')
    chips_ = (f'<div style="margin-right:-16px;overflow:hidden;position:relative"><div class="row g6">{chips_auto()}</div>'
              f'<div style="position:absolute;right:0;top:0;bottom:0;width:36px;background:linear-gradient(90deg,rgba(248,245,239,0),var(--surface))"></div></div>')
    pr = '<div class="prompt" style="font-size:15px;line-height:1.55;height:48px"><span class="caret" style="height:19px"></span><span class="ph">Describe the scene · type @ for your characters, # for a camera move</span></div>'
    sw = 108
    slots = f'<div class="row" style="gap:17px">{slot("Character", "Your models", w=sw, h=100)}{slot("Start frame", "Sets the shape", True, w=sw, h=100)}{slot("End frame", "After a start frame", True, True, w=sw, h=100)}</div>'
    bottom = (f'<div class="row g8"><span class="bp" style="height:40px">{ic("gauge", 15)}Draft {ic("chev-d", 12)}</span><span class="ibtn">{ic("sliders", 18)}</span>'
              f'<div class="fill"></div><span class="t12" style="text-align:right;line-height:1.35">8 s · 9:16<br>1 take</span><span class="rgen">{ic("sparkle", 18, 1.6)}<span>$0.16</span></span></div>')
    return f'<div class="pcmp">{tr}{chips_}{pr}{slots}{bottom}</div>'


def phone_top():
    over = ('<div class="frost"></div><div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px">'
            '<span class="lbl ink">Take 2 of 2</span><span style="font:400 54px/0.9 \'Instrument Serif\';color:#141210">62%</span>'
            '<div style="width:90px;height:3px;background:rgba(20,18,16,.15)"><div style="width:62%;height:3px;background:#B5121B"></div></div></div>')
    big = scene('palette-02-teal-orange', 162, 288, 'noor', .5, 12, extra=over)
    small = take_thumb('ready', 92, 164, 'palette-04-bleached-warm', 'noor')
    return (f'<div class="col g10" style="padding:14px 16px 0"><div class="row between"><span class="lbl ink">Recent takes</span><span class="t12">All →</span></div>'
            f'<div class="row g12" style="align-items:flex-end;justify-content:center">{small}{big}{take_thumb("ready", 92, 164, "light-04-window", "iris")}</div>'
            f'<span class="t12" style="align-self:center">Café · rendering · about 2 min left</span></div>')


def p1():
    return ph(phone_top() + phone_composer(), 'Composer · P1 phone')


def psheet(title, body, h=717, right_reset=True):
    rs = f'<span class="ghost" style="height:30px">{ic("refresh", 12)} Reset all</span>' if right_reset else ''
    return (f'<div class="dim" style="background:rgba(16,14,12,.55);z-index:3"></div>'
            f'<div class="theme-b dk psheet" style="height:{h}px;z-index:4"><div class="grab"></div><div class="phd"><span class="mtitle" style="font-size:21px">{title}</span>'
            f'<div class="fill"></div>{rs}<span class="xbtn" style="width:32px;height:32px">{ic("x", 15, 1.8)}</span></div>{body}</div>')


def pseg(items, on):
    return '<div class="pseg">' + ''.join(f'<span class="{"on" if i == on else ""}">{i}</span>' for i in items) + '</div>'


def p_wheel_row(title, kind, items, idx, cw=128, ph_=58):
    (pv, pn, pl), (cv, cn, cl), (nv, nn, nl) = items
    gap = 12
    cx = (390 - cw) // 2
    hc = ph_ + 8 + 16 + 2 + 28

    def card(kind, v, n, l, on, left):
        if kind == 'img':
            plate = f'<img src="{img(v)}">'
        elif kind == 'fov':
            plate = fov_svg(v, on, cw, ph_)
        else:
            plate = iris_plate(v, cw, ph_)
        ok = f'<span class="ok">{ic("check", 10, 2.6)}</span>' if on else ''
        return (f'<div class="wc{" on" if on else " side"}" style="left:{left}px;top:4px;width:{cw}px"><div class="wp" style="width:{cw}px;height:{ph_}px">{plate}{ok}</div>'
                f'<span class="wn" style="font-size:13px;margin-top:8px">{n}</span><span class="wl" style="font-size:11px;line-height:1.25;height:28px">{l}</span></div>')
    cards = card(kind, pv, pn, pl, False, cx - gap - cw) + card(kind, cv, cn, cl, True, cx) + card(kind, nv, nn, nl, False, cx + cw + gap)
    return (f'<div class="col" style="gap:6px;flex:none"><div class="row between" style="padding:0 20px"><span class="lbl ink">{title}</span><span class="mono" style="font-size:10.5px">{idx}</span></div>'
            f'<div class="whw" style="width:390px;height:{hc + 6}px;-webkit-mask-image:linear-gradient(90deg,rgba(0,0,0,.5),#000 14%,#000 86%,rgba(0,0,0,.5))">{cards}</div></div>')


def p2():
    rows = ''.join(p_wheel_row(t, k, it, idx) for t, k, it, idx in WHEELS)
    body = (f'{pseg(["Setup", "Angle", "Movement"], "Setup")}<div class="col" style="gap:10px;padding:14px 0 0">{rows}</div>')
    return ph(phone_top() + phone_composer(), 'Composer · P2 Camera sheet', psheet('Camera', body, 742), dark_home=False)


def p3():
    w, h = 171, 128
    tiles = [move_tile(k, n, t, tf, w, h, uid=f'p{i}') for i, (k, n, t, tf) in enumerate(MOVES_F)]
    grid = ''.join(f'<div class="row" style="gap:16px;align-items:flex-start">{"".join(tiles[i:i + 2])}</div>' for i in range(0, 8, 2))
    chips_ = ''.join(f'<span class="dchip{" on" if c == "Featured" else ""}">{c}</span>' for c in CATS)
    body = (f'{pseg(["Setup", "Angle", "Movement"], "Movement")}'
            f'<div class="col" style="padding:14px 16px 0;gap:12px;min-height:0;flex:1 1 0"><span class="msub" style="font-size:12.5px;flex:none"><span style="color:var(--ink)">Tap to add to your prompt</span> · or type # · up to 2 moves</span>'
            f'<div style="margin-right:-16px;overflow:hidden;flex:none"><div class="row g6"><span class="dchip" style="padding:0 9px">{ic("search", 14)}</span>{chips_}</div></div>'
            f'<div class="col" style="gap:16px">{grid}</div></div>')
    return ph(phone_top() + phone_composer(), 'Composer · P3 Movement sheet', psheet('Camera', body, 742), dark_home=False)


def p4():
    q = ''
    for n, p, t, acc in TIERS:
        on = n == 'Draft'
        q += (f'<div class="drow{" on" if on else ""}" style="padding:0 14px;height:46px"><span style="font:600 15px var(--body);width:84px">{n}</span><span class="t12 fill">{t}</span>'
              f'<span class="dprice">${p:.2f}</span><span style="width:20px;color:var(--accent);display:flex">{ic("check", 18, 2.4) if on else ""}</span></div>')
    shapes = ''.join(f'<div class="dshape{" on" if l == "9:16" else ""}"><div class="r" style="width:{a}px;height:{b}px"></div><span>{l}</span></div>' for l, a, b in [('9:16', 19, 33), ('1:1', 28, 28), ('16:9', 40, 23)])
    length = (f'<div class="col g10"><div class="row between"><span class="lbl ink">Length</span><span style="font:600 15px var(--mono)">8 s</span></div>'
              f'{slider(57)}<div class="row between"><span class="mono" style="font-size:10.5px">4 s</span><span class="mono" style="font-size:10.5px">10 s</span></div></div>')
    sound = (f'<div class="row between"><div class="col g2"><span style="font:600 15px var(--body)">Sound</span><span class="t12">Ambience and effects</span></div>{tog(True)}</div>')
    speak = (f'<div class="row between"><div class="col g2"><span style="font:600 15px var(--body)">Speaking</span><span class="t12">Lips move to the words</span></div>'
             f'<div class="dseg"><span class="on">Auto</span><span>On</span><span>Off</span></div></div>')
    takes = (f'<div class="row between"><div class="col g2"><span style="font:600 15px var(--body)">Takes</span><span class="t12">Up to 4 at once</span></div>'
             f'<div class="stp"><span>−</span><b>1</b><span>+</span></div></div>')
    body = (f'<div class="col" style="padding:4px 16px 0;gap:16px;flex:1 1 0;min-height:0">'
            f'<div class="col g8"><div class="row between"><span class="lbl ink">Quality</span><span class="t12">per 8 s take</span></div><div class="col" style="gap:6px">{q}</div></div>'
            f'<div class="col g8"><span class="lbl ink">Shape</span><div class="row" style="gap:8px">{shapes}</div></div>'
            f'{length}<div class="hl"></div>{sound}{speak}{takes}</div>'
            f'<div style="padding:10px 16px 34px"><div class="dcta">Generate · $0.16</div></div>')
    return ph(phone_top() + phone_composer(), 'Composer · P4 Settings sheet', psheet('Settings', body, 760, right_reset=False), dark_home=False)


def p5():
    rows = look_grid(2, 171, 92, 16)
    grid = (f'<div style="position:relative;flex:1 1 0;min-height:0;overflow:hidden;padding:5px 16px 0;margin-top:-5px"><div class="col" style="gap:16px">{"".join(rows[:4])}</div>'
            f'<div style="position:absolute;left:0;right:0;bottom:0;height:40px;background:linear-gradient(180deg,rgba(13,14,15,0),var(--bg))"></div></div>')
    body = (f'{pseg(["Palette", "Film stock"], "Palette")}<div class="row between" style="padding:12px 20px 12px"><span class="t12">28 palettes · each with an exact grade</span></div>{grid}'
            f'<div class="row g12" style="padding:14px 20px 34px;border-top:1px solid var(--line);background:var(--surface)">{grade_toggle()}</div>')
    return ph(phone_top() + phone_composer(), 'Composer · P5 Look sheet', psheet('Look', body, 742), dark_home=False)


# ---------------------------------------------------------------- boards / build
def boards():
    return [
        ('C1', 'Composer · empty, all Auto', 'Prompt-first. Defaults are a complete one-tap state; presets sit under the empty composer.', c1(), [
            ('One shell', 'Shot, Character swap, Recast, Talking, UGC ad, Storyboard and Extend are this composer with another tool card. Change switches tool without leaving the page.'),
            ('Slots follow the quality', 'Slots appear only when the quality’s engine accepts them. End frame stays greyed until there is a start frame. Every slot states its limit.')]),
        ('C2', 'Camera picker · Setup', 'Four wheels, three cards each. The centre card is the choice; scroll, drag, ↑ ↓ or chevrons.', c2(), [
            ('Calm by design', 'Ten bodies, nine lenses, six focal lengths and four apertures, but only three cards per wheel are ever visible. Choices apply instantly; no OK button.')]),
        ('C3', 'Camera picker · Movement', 'Looping previews (same mannequin, same set). Tap inserts a #move into the prompt and closes the picker.', c3(), [
            ('Placeholders', 'Tiles show a still with a motion arrow until the Blender loops are rendered. Talk-safe appears when Speaking is on.')]),
        ('C4', 'Look picker', 'Palettes as stills with a 10-colour strip; the grade toggle makes colour exact and reversible.', c4(), [
            ('MUSE’s edge', 'With the toggle on, the matching look is applied after the render as an editable Look in the Edit suite.')]),
        ('C5', 'Composer · filled', 'Chips show only what is not Auto; tokens live in the prompt; the Quality list says what each tier accepts.', c5(), [
            ('Price', 'Live on the button: 8 s · HD · 1 take = $1.92. “—” until it can be computed, “~” for estimates.')]),
        ('C6', 'Composer · preset', 'Picking a preset collapses the composer to who, shape and Generate.', c6(), [
            ('Edit settings', 'Reopens the full composer with the preset’s values already in the chips.')]),
        ('P1', 'Phone · composer', 'Docked composer; chips scroll sideways; Quality, Settings and a round Generate with the price.', p1(), []),
        ('P2', 'Phone · Camera sheet', 'Four snap rows, each centring its choice with three cards visible.', p2(), []),
        ('P3', 'Phone · Movement sheet', 'Category chips over a two-column grid of loops (stills until the loops exist).', p3(), []),
        ('P4', 'Phone · Settings sheet', 'Quality, shape, length, sound, speaking and takes, with Generate at the bottom.', p4(), []),
        ('P5', 'Phone · Look sheet', 'Palette grid with swatch strips and the grade toggle.', p5(), []),
    ]


def page():
    ensure_imgs()
    return ('Video composer', 'composer', 'MUSE · Video suite · Composer (replaces the camera-bag screens D2–D5, M2–M4)',
            'One composer with Auto chips, one picker shell, hardware as three-card wheels, slots that follow the chosen quality, and presets for first-timers.', boards())


def frame_html(frame):
    css = base.CSS + 'body{padding:0;gap:0;background:#fff}.frame{box-shadow:none}'
    return f"<!doctype html><html><head><meta charset='utf-8'><title>f</title><style>{base.font_css()}\n{css}</style></head><body>{frame}</body></html>"


def render(flt=None, out_dir=None):
    from PIL import Image
    tmp = os.path.join(base.ROOT, 'build', 'composer')
    os.makedirs(tmp, exist_ok=True)
    out_dir = out_dir or SCREENS
    done = []
    for num, title, d, frame, notes in page()[4]:
        if flt and not re.search(flt, num):
            continue
        desktop_ = 'class="frame d' in frame
        w, h = (1440, 900) if desktop_ else (390, 844)
        hp = os.path.join(tmp, f'{num}.html')
        with open(hp, 'w') as f:
            f.write(frame_html(frame))
        png = os.path.join(tmp, f'{num}.png')
        if os.path.exists(png):
            os.remove(png)
        subprocess.run(['google-chrome', '--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
                        '--virtual-time-budget=4000', f'--window-size={w},{h}', f'--screenshot={png}', 'file://' + hp], capture_output=True, timeout=240)
        im = Image.open(png).convert('RGB')
        if desktop_:
            im = im.resize((1600, 1000), Image.LANCZOS)
        jp = os.path.join(out_dir, f'composer__{num}.jpg')
        im.save(jp, quality=90, optimize=True, progressive=True)
        done.append((num, title, jp))
        print('shot', num, im.size)
    return done


def overview(out_dir=None):
    """Contact sheet of all composer screens, labelled."""
    from PIL import Image, ImageDraw, ImageFont
    out_dir = out_dir or SCREENS
    B = page()[4]
    W, pad, gap = 1600, 40, 24
    serif = ImageFont.truetype(os.path.join(FONT_DIR, 'InstrumentSerif-Regular.ttf'), 54)
    mono = ImageFont.truetype(os.path.join(FONT_DIR, 'IBMPlexMono-Medium.ttf'), 15)
    body = ImageFont.truetype(os.path.join(FONT_DIR, 'IBMPlexMono-Regular.ttf'), 13)
    dw = (W - 2 * pad - 2 * gap) // 3
    dh = int(dw * 900 / 1440)
    pw = (W - 2 * pad - 4 * gap) // 5
    phh = int(pw * 844 / 390)
    lab = 46
    H = pad + 110 + 2 * (dh + lab + gap) + phh + lab + pad
    sheet = Image.new('RGB', (W, H), '#DCD6CB')
    dr = ImageDraw.Draw(sheet)
    dr.text((pad, pad - 6), 'MUSE · VIDEO SUITE · REVIEW MOCKUPS · 6 NOV 2026', font=mono, fill='#6E675E')
    dr.text((pad, pad + 18), 'Video composer', font=serif, fill='#141210')
    y0 = pad + 110
    for i, (num, title, *_r) in enumerate(B):
        src = Image.open(os.path.join(out_dir, f'composer__{num}.jpg')).convert('RGB')
        if num.startswith('C'):
            k = i
            x = pad + (k % 3) * (dw + gap)
            y = y0 + (k // 3) * (dh + lab + gap)
            t = src.resize((dw, dh), Image.LANCZOS)
        else:
            k = i - 6
            x = pad + k * (pw + gap)
            y = y0 + 2 * (dh + lab + gap)
            t = src.resize((pw, phh), Image.LANCZOS)
        sheet.paste(t, (x, y))
        dr.rectangle([x - 1, y - 1, x + t.size[0], y + t.size[1]], outline='#C9C0B2')
        dr.text((x, y + t.size[1] + 10), num, font=mono, fill='#B5121B')
        dr.text((x + 34, y + t.size[1] + 11), title, font=body, fill='#141210')
    p = os.path.join(out_dir, 'composer__overview.jpg')
    sheet.save(p, quality=90, optimize=True, progressive=True)
    print('overview', sheet.size)
    return p


if __name__ == '__main__':
    flt = sys.argv[1] if len(sys.argv) > 1 else None
    render(flt)
    if not flt:
        overview()

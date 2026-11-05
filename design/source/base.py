"""MUSE suites design generator: shared tokens, CSS, icons and components.
Theme A (Editorial) is MUSE's default theme (ThemeId.fromKey -> A); Theme B (Camera Body) is used for the dark camera bag.
Layout is flexbox only so html_to_figma produces auto-layout frames."""
import base64, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_DIR = os.path.join(ROOT, 'build', 'img')
FONT_DIR = '/home/user/Claude-Template/mac/Muse/Resources/Fonts'
MODE = {'img': 'data'}  # 'data' (Figma push / local render) or 'file' (artifact)
_cache = {}


def img(name, small=False):
    sub = 'sm/' if small else ''
    if MODE['img'] == 'file':
        return f'img/{sub}{name}.jpg'
    key = sub + name
    if key not in _cache:
        with open(os.path.join(IMG_DIR, sub + name + '.jpg'), 'rb') as f:
            _cache[key] = 'data:image/jpeg;base64,' + base64.b64encode(f.read()).decode()
    return _cache[key]


FONTS = [
    ('Instrument Serif', 'InstrumentSerif-Regular.ttf', '400'),
    ('Archivo', 'Archivo-VF.ttf', '100 900'),
    ('IBM Plex Mono', 'IBMPlexMono-Regular.ttf', '400'),
    ('IBM Plex Mono', 'IBMPlexMono-Medium.ttf', '500 700'),
    ('Barlow', 'Barlow-Regular.ttf', '400'),
    ('Barlow', 'Barlow-Medium.ttf', '500'),
    ('Barlow', 'Barlow-SemiBold.ttf', '600'),
    ('Barlow', 'Barlow-Bold.ttf', '700 900'),
    ('Barlow Condensed', 'BarlowCondensed-Medium.ttf', '400 500'),
    ('Barlow Condensed', 'BarlowCondensed-SemiBold.ttf', '600'),
    ('Barlow Condensed', 'BarlowCondensed-Bold.ttf', '700 900'),
    ('JetBrains Mono', 'JetBrainsMono-VF.ttf', '100 900'),
]


def font_css():
    if MODE['img'] == 'file':
        return ("@import url('https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700;800&family=Barlow+Condensed:wght@500;600;700"
                "&family=Barlow:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&family=Instrument+Serif&family=JetBrains+Mono:wght@400;500;700&display=swap');")
    out = []
    for fam, file, w in FONTS:
        with open(os.path.join(FONT_DIR, file), 'rb') as f:
            b = base64.b64encode(f.read()).decode()
        out.append(f"@font-face{{font-family:'{fam}';src:url(data:font/ttf;base64,{b}) format('truetype');font-weight:{w};font-style:normal}}")
    return '\n'.join(out)


CSS = r"""
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:var(--canvas,#DCD6CB)}
body{font-family:'Archivo',sans-serif;color:#141210;padding:96px;display:flex;flex-direction:column;gap:140px;-webkit-font-smoothing:antialiased}
svg{display:block;flex:none}
img{display:block}
.pagehead{display:flex;flex-direction:column;gap:14px;max-width:1500px}
.pagehead .k{font:500 13px 'IBM Plex Mono';letter-spacing:.14em;text-transform:uppercase;color:#6E675E}
.pagehead h1{font:400 120px/0.95 'Instrument Serif';letter-spacing:-.01em}
.pagehead p{font:400 20px/1.5 'Archivo';color:#3c3732;max-width:1100px}
.boards{display:flex;flex-direction:column;gap:120px}
.board{display:flex;gap:40px;align-items:flex-start;flex:none}
.board .cap{display:flex;flex-direction:column;gap:6px;width:320px;flex:none}
.board .cap .n{font:500 12px 'IBM Plex Mono';letter-spacing:.12em;color:#6E675E;text-transform:uppercase}
.board .cap .t{font:400 40px/1 'Instrument Serif'}
.board .cap .cd{font:400 15px/1.5 'Archivo';color:#3c3732}
.notes{display:flex;flex-direction:column;gap:18px;width:320px;flex:none}
.note{background:#FFE47A;color:#2B2410;padding:16px 18px 18px;display:flex;flex-direction:column;gap:8px;box-shadow:0 10px 24px rgba(60,45,0,.16),0 1px 0 rgba(0,0,0,.06)}
.note b{font:600 12px 'IBM Plex Mono';letter-spacing:.08em;text-transform:uppercase}
.note span{font:400 14.5px/1.45 'Archivo'}
.note.blue{background:#CFE3FF}
.frame{position:relative;overflow:hidden;flex:none;background:var(--bg);color:var(--ink);font-family:var(--body);display:flex;box-shadow:0 30px 80px rgba(40,30,10,.18)}
.d{width:1440px;height:900px;flex-direction:column}
.m{width:390px;height:844px;flex-direction:column}
.theme-a{--bg:#EFEBE3;--surface:#F8F5EF;--surface2:#E7E1D6;--ink:#141210;--muted:#6E675E;--line:#CFC7BA;--accent:#B5121B;--accent-ink:#fff;--cta:#141210;--cta-ink:#F8F5EF;--good:#2F6B3A;--warn:#9A5B00;--warn-bg:#F6E2C0;--warn-ink:#5B3600;--r:0px;--rl:0px;--display:'Instrument Serif';--body:'Archivo';--mono:'IBM Plex Mono';--plate:#151413;--sel:#141210;--stage:#1C1A17;--soft:#DDD6C9}
.theme-b{--bg:#0D0E0F;--surface:#17191B;--surface2:#212427;--ink:#ECEAE5;--muted:#A9A6A0;--line:#2C3033;--accent:#F2A93B;--accent-ink:#1A1205;--cta:#F2A93B;--cta-ink:#1A1205;--good:#7BD88F;--warn:#F2A93B;--warn-bg:#3A2B14;--warn-ink:#F2B45A;--r:10px;--rl:14px;--display:'Barlow Condensed';--body:'Barlow';--mono:'JetBrains Mono';--plate:#101112;--sel:#F2A93B;--stage:#08090A;--soft:#2A2E31}
/* type */
.lbl{font:500 11px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}
.lbl.ink{color:var(--ink)}
.mono{font:400 12px var(--mono);color:var(--muted)}
.h1{font:400 56px/1 var(--display);letter-spacing:-.005em}
.theme-b .h1,.theme-b .h2{font-weight:700;text-transform:uppercase;letter-spacing:.02em}
.h2{font:400 30px/1.05 var(--display)}
.h3{font:700 15px/1.25 var(--body)}
.t13{font:400 13px/1.4 var(--body)}
.t14{font:400 14px/1.45 var(--body)}
.t12{font:400 12px/1.4 var(--body);color:var(--muted)}
.b{font-weight:600}
.muted{color:var(--muted)}
.acc{color:var(--accent)}
.fig{font:400 34px/1 var(--display)}
.theme-b .fig{font:600 26px/1 var(--mono)}
/* layout */
.row{display:flex;flex-direction:row;align-items:center}
.col{display:flex;flex-direction:column}
.g4{gap:4px}.g6{gap:6px}.g8{gap:8px}.g10{gap:10px}.g12{gap:12px}.g14{gap:14px}.g16{gap:16px}.g20{gap:20px}.g24{gap:24px}.g28{gap:28px}.g32{gap:32px}
.fill{flex:1 1 0;min-width:0}
.between{justify-content:space-between}
.center{align-items:center;justify-content:center}
.start{align-items:flex-start}
.wrap{flex-wrap:wrap}
.hl{height:1px;background:var(--line);flex:none;align-self:stretch}
.vl{width:1px;background:var(--line);flex:none;align-self:stretch}
/* chrome */
.tb{height:52px;flex:none;display:flex;align-items:center;gap:14px;padding:0 16px 0 18px;border-bottom:1px solid var(--line);background:var(--bg)}
.lights{display:flex;gap:8px;width:64px}
.lights i{width:12px;height:12px;border-radius:6px;background:#E2DBCF;border:1px solid #CFC7BA}
.theme-b .lights i{background:#2C3033;border-color:#3a3f43}
.search{width:420px;height:32px;display:flex;align-items:center;gap:8px;padding:0 10px;background:var(--surface2);border:1px solid var(--line);border-radius:var(--r);color:var(--muted);font:400 13px var(--body)}
.kc{font:500 10.5px var(--mono);padding:2px 6px;border:1px solid var(--line);color:var(--muted);border-radius:4px}
.jobchip{height:30px;display:flex;align-items:center;gap:8px;padding:0 10px;background:var(--surface2);border-radius:15px;font:400 12px var(--mono);color:var(--ink)}
.led{width:7px;height:7px;border-radius:4px;background:var(--good);flex:none}
.led.red{background:var(--accent)} .led.off{background:var(--line)} .led.warn{background:#D98A1C}
.track{width:60px;height:4px;background:var(--line);position:relative;border-radius:2px;overflow:hidden}
.track i{position:absolute;left:0;top:0;bottom:0;background:var(--accent)}
.dots{display:flex;gap:6px}
.dots i{width:12px;height:12px;border-radius:6px}
.body{flex:1 1 0;display:flex;min-height:0}
.sb{width:228px;flex:none;border-right:1px solid var(--line);padding:18px 12px 14px;display:flex;flex-direction:column;gap:2px;background:var(--bg)}
.sb.compact{width:72px;align-items:center;padding:18px 8px 14px}
.wm{font:400 40px/1 'Instrument Serif';letter-spacing:4.8px;padding:4px 10px 18px}
.theme-b .wm{font:700 30px/1 'Barlow Condensed';letter-spacing:6px}
.nav{height:32px;display:flex;align-items:center;gap:10px;padding:0 10px;color:var(--muted);font:500 12px var(--mono);letter-spacing:.08em;text-transform:uppercase}
.nav.on{color:var(--ink);box-shadow:inset 2px 0 0 var(--accent)}
.theme-b .nav{font:600 15px 'Barlow Condensed';letter-spacing:.1em}
.theme-b .nav.on{background:#24282B;border-radius:8px;box-shadow:none}
.nav .k{margin-left:auto;font:400 10.5px var(--mono);opacity:.7;letter-spacing:0}
.nav.sub{height:28px;padding-left:34px;font:400 12.5px var(--body);letter-spacing:0;text-transform:none}
.nav.sub.on{box-shadow:none;color:var(--ink);font-weight:600}
.nav.sub.on::before{content:'';width:6px;height:6px;background:var(--accent);margin-left:-16px;margin-right:4px}
.sbh{font:500 10.5px var(--mono);letter-spacing:.1em;color:var(--muted);padding:16px 10px 6px}
.bal{margin-top:auto;border-top:1px solid var(--line);padding:12px 10px 0;display:flex;flex-direction:column;gap:4px}
/* controls */
.btn{height:36px;display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:0 14px;border:1px solid var(--line);background:var(--surface);color:var(--ink);font:600 13px var(--body);border-radius:var(--r);white-space:nowrap;flex:none}
.btn.sm{height:28px;padding:0 10px;font-size:12px}
.btn.pri{background:var(--cta);color:var(--cta-ink);border-color:var(--cta);font:500 12.5px var(--mono);letter-spacing:.12em;text-transform:uppercase}
.theme-b .btn.pri{font:700 14px var(--body);letter-spacing:.02em;text-transform:none}
.btn.big{height:52px;font-size:13.5px;padding:0 22px}
.btn.ghost{background:transparent}
.btn.acc{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.chip{height:28px;display:inline-flex;align-items:center;gap:6px;padding:0 10px;border:1px solid var(--line);background:var(--surface);font:500 12px var(--body);color:var(--ink);border-radius:var(--r);white-space:nowrap;flex:none}
.chip.on{background:var(--sel);color:var(--bg);border-color:var(--sel)}
.theme-b .chip{border-radius:14px}
.theme-b .chip.on{color:#1A1205}
.chip.red{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.chip.dash{border-style:dashed;background:transparent;color:var(--muted)}
.seg{display:flex;border:1px solid var(--line);background:var(--surface);border-radius:var(--r);overflow:hidden;flex:none}
.seg span{height:30px;padding:0 14px;display:flex;align-items:center;justify-content:center;font:500 11.5px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--muted);border-right:1px solid var(--line);white-space:nowrap}
.seg span:last-child{border-right:0}
.seg span.on{background:var(--sel);color:var(--bg)}
.theme-b .seg{border-radius:10px;padding:3px;gap:3px;background:var(--surface2);border:0}
.theme-b .seg span{border:0;border-radius:8px;font:600 13px var(--body);letter-spacing:.02em;text-transform:none}
.theme-b .seg span.on{color:#1A1205}
.seg.big span{height:40px;padding:0 22px;font-size:12px}
.seg.sm span{height:26px;padding:0 9px;font-size:10.5px}
.tight .sec{padding:12px 18px;gap:9px}
.seg.fillw{align-self:stretch}.seg.fillw span{flex:1 1 0}
.pill{height:22px;display:inline-flex;align-items:center;gap:6px;padding:0 8px;font:500 10.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;border:1px solid var(--line);color:var(--muted);white-space:nowrap;flex:none;border-radius:var(--r)}
.pill.good{color:var(--good);border-color:var(--good)}
.pill.warn{color:var(--warn-ink);background:var(--warn-bg);border-color:var(--warn-bg)}
.pill.red{color:var(--accent);border-color:var(--accent)}
.pill.ink{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.slider{height:18px;position:relative;display:flex;align-items:center;flex:1 1 0}
.slider .tr{position:absolute;left:0;right:0;height:3px;background:var(--line)}
.slider .fl{position:absolute;left:0;height:3px;background:var(--accent)}
.slider .kn{position:absolute;width:16px;height:16px;border-radius:8px;background:var(--surface);border:2px solid var(--accent);margin-left:-8px}
.tog{width:38px;height:22px;border-radius:11px;background:var(--line);position:relative;flex:none}
.tog i{position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:8px;background:#fff}
.tog.on{background:var(--ink)}
.theme-b .tog.on{background:var(--accent)}
.tog.on i{left:19px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:var(--rl)}
.panel{background:var(--surface);border-left:1px solid var(--line)}
.field{display:flex;flex-direction:column;gap:8px}
.input{min-height:38px;padding:9px 12px;border:1px solid var(--line);background:var(--surface);font:400 13.5px/1.45 var(--body);color:var(--ink);border-radius:var(--r)}
.input.ph{color:var(--muted)}
/* plates & hardware */
.plate{background:var(--plate);position:relative;overflow:hidden;flex:none;border-radius:var(--r)}
.plate img{width:100%;height:100%;object-fit:cover}
.hw{display:flex;flex-direction:column;gap:8px;flex:none;position:relative}
.hw .cp{display:flex;flex-direction:column;gap:2px}
.hw .nm{font:600 13px/1.2 var(--body)}
.hw .sp{font:400 10.5px/1.35 var(--mono);color:var(--muted);letter-spacing:.02em}
.hw.on .plate{outline:2px solid var(--sel);outline-offset:3px}
.theme-b .hw.on .plate{outline:2px solid var(--accent);box-shadow:0 0 0 6px rgba(242,169,59,.12),0 18px 40px rgba(242,169,59,.18)}
.hw .tag{position:absolute;top:8px;left:8px;height:20px;padding:0 7px;display:flex;align-items:center;gap:5px;background:var(--accent);color:var(--accent-ink);font:500 10px var(--mono);letter-spacing:.1em;text-transform:uppercase}
.theme-b .hw .tag{border-radius:10px}
.hw .tag2{position:absolute;top:8px;right:8px;height:20px;padding:0 7px;display:flex;align-items:center;background:rgba(255,255,255,.12);color:#ECEAE5;font:500 10px var(--mono);letter-spacing:.08em;text-transform:uppercase}
.fade-r{position:absolute;right:0;top:0;bottom:0;width:90px;background:linear-gradient(90deg,rgba(239,235,227,0),var(--bg))}
.theme-b .fade-r{background:linear-gradient(90deg,rgba(13,14,15,0),var(--bg))}
.arrowbtn{position:absolute;right:14px;width:36px;height:36px;border-radius:18px;background:var(--surface);border:1px solid var(--line);display:flex;align-items:center;justify-content:center;color:var(--ink)}
/* phone */
.sbar{height:44px;flex:none;display:flex;align-items:center;justify-content:space-between;padding:0 24px 0 28px;font:600 15px 'Barlow';color:var(--ink)}
.sbar .ic{display:flex;gap:5px}.sbar .ic i{width:17px;height:10px;border-radius:3px;background:var(--ink)}
.ptop{height:52px;flex:none;display:flex;align-items:center;justify-content:space-between;padding:0 16px;border-bottom:1px solid var(--line)}
.ptop .t{font:700 17px var(--body)}
.theme-b .ptop .t{font:600 15px var(--mono);letter-spacing:.2em;text-transform:uppercase}
.bnav{height:84px;flex:none;border-top:1px solid var(--line);display:flex;align-items:flex-start;justify-content:space-around;padding-top:10px;background:var(--bg)}
.bnav .it{display:flex;flex-direction:column;align-items:center;gap:5px;font:500 10px var(--mono);letter-spacing:.08em;color:var(--muted);width:56px}
.bnav .it.on{color:var(--accent)}
.bnav .plus{width:48px;height:42px;background:var(--cta);color:var(--cta-ink);display:flex;align-items:center;justify-content:center}
.home-ind{position:absolute;bottom:8px;left:50%;margin-left:-67px;width:134px;height:5px;border-radius:3px;background:var(--ink)}
.pcta{position:absolute;left:16px;right:16px;bottom:30px;height:54px;background:var(--cta);color:var(--cta-ink);display:flex;align-items:center;justify-content:center;font:500 13.5px var(--mono);letter-spacing:.12em;text-transform:uppercase;border-radius:var(--r)}
.theme-b .pcta{border-radius:27px;font:700 16px var(--body);letter-spacing:0;text-transform:none}
.sheet{position:absolute;left:0;right:0;bottom:0;background:var(--bg);border-top:1px solid var(--line);display:flex;flex-direction:column;box-shadow:0 -20px 50px rgba(20,18,16,.18)}
.grab{width:40px;height:4px;border-radius:2px;background:var(--line);align-self:center;margin:8px 0 4px}
.stage{background:var(--stage);position:relative;overflow:hidden;flex:none}
.sil{position:absolute}
.scrim{position:absolute;left:0;right:0;bottom:0;height:45%;background:linear-gradient(180deg,rgba(0,0,0,0),rgba(0,0,0,.55))}
.frost{position:absolute;inset:0;background:rgba(239,235,227,.28)}
.dim{position:absolute;inset:0;background:rgba(20,18,16,.46)}
.kbd{font:500 10.5px var(--mono);color:var(--muted)}
.dia{color:var(--ink)}
.box{border:1px solid var(--line);background:var(--surface);border-radius:var(--rl)}
.sec{padding:16px 18px;display:flex;flex-direction:column;gap:10px;border-bottom:1px solid var(--line)}
.price{font:400 28px/1 var(--display)}
.theme-b .price{font:600 22px/1 var(--mono)}
.wf{display:flex;align-items:center;gap:2px;height:100%;overflow:hidden}
.wf i{width:2px;background:currentColor;flex:none;border-radius:1px}
.clip{position:absolute;top:3px;bottom:3px;overflow:hidden;display:flex;align-items:center;border-radius:3px}
.kf{width:9px;height:9px;transform:rotate(45deg);background:var(--accent);flex:none}
.kf.ink{background:var(--ink)}
"""


def page_html(title, body):
    return (f"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>"
            f"<title>{title}</title><style>{font_css()}\n{CSS}</style></head><body>{body}</body></html>")


# ---------------- icons (24x24 stroke) ----------------
P = {
    'home': '<path d="M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z"/>',
    'user': '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',
    'users': '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 3-5.5 6.5-5.5s6.5 1.9 6.5 5.5"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14.6c2 .7 3.5 2.4 3.5 5.4"/>',
    'video': '<rect x="2.5" y="6" width="13.5" height="12"/><path d="m16 10.5 5.5-3v9l-5.5-3z"/>',
    'camera': '<path d="M3 7.5h4l1.8-3h6.4l1.8 3h4V20H3z"/><circle cx="12" cy="13.5" r="3.8"/>',
    'list': '<path d="M8 6h13M8 12h13M8 18h13"/><path d="M3.5 6h.5M3.5 12h.5M3.5 18h.5"/>',
    'grid': '<rect x="3" y="3" width="7.5" height="7.5"/><rect x="13.5" y="3" width="7.5" height="7.5"/><rect x="3" y="13.5" width="7.5" height="7.5"/><rect x="13.5" y="13.5" width="7.5" height="7.5"/>',
    'send': '<path d="M21 3 10.5 13.5M21 3l-6.5 18-4-7.5L3 9.5z"/>',
    'sliders': '<path d="M4 20v-6M4 10V4M12 20v-8M12 8V4M20 20v-4M20 12V4M1.5 14h5M9.5 8h5M17.5 16h5"/>',
    'plus': '<path d="M12 5v14M5 12h14"/>',
    'play': '<path d="M7 4.5v15l12.5-7.5z" fill="currentColor"/>',
    'pause': '<path d="M7 4.5h3.5v15H7zM13.5 4.5H17v15h-3.5z" fill="currentColor" stroke="none"/>',
    'scissors': '<circle cx="6" cy="6" r="2.8"/><circle cx="6" cy="18" r="2.8"/><path d="M20 4 8.2 15.8M14.5 14.5 20 20M8.2 8.2 12 12"/>',
    'wand': '<path d="m4 20 11-11M14 5l1-2 1 2 2 1-2 1-1 2-1-2-2-1zM19 12l.6-1.2L21 10l-1.4-.8L19 8l-.6 1.2L17 10l1.4.8z"/>',
    'mic': '<rect x="9" y="2.5" width="6" height="12" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    'music': '<path d="M9 18V5.5l11-2V16"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
    'type': '<path d="M4.5 7V4.5h15V7M12 4.5v15M9 19.5h6"/>',
    'cc': '<rect x="2.5" y="5" width="19" height="14"/><path d="M10.5 10.2a2.4 2.4 0 1 0 0 3.6M17.5 10.2a2.4 2.4 0 1 0 0 3.6"/>',
    'sparkle': '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 16v4M17 18h4"/>',
    'chev-r': '<path d="m9 6 6 6-6 6"/>', 'chev-l': '<path d="m15 6-6 6 6 6"/>', 'chev-d': '<path d="m6 9 6 6 6-6"/>',
    'search': '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
    'check': '<path d="M4.5 12.5 9.5 17.5 19.5 7"/>',
    'lock': '<rect x="4.5" y="11" width="15" height="10"/><path d="M8 11V7.5a4 4 0 0 1 8 0V11"/>',
    'eye': '<path d="M2 12s3.8-6.5 10-6.5S22 12 22 12s-3.8 6.5-10 6.5S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    'volume': '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9.5a3.5 3.5 0 0 1 0 5M18.5 6.5a7.5 7.5 0 0 1 0 11"/>',
    'film': '<rect x="3.5" y="3" width="17" height="18"/><path d="M7.5 3v18M16.5 3v18M3.5 8h4M3.5 12h4M3.5 16h4M16.5 8h4M16.5 12h4M16.5 16h4"/>',
    'sun': '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    'palette': '<path d="M12 3a9 9 0 1 0 0 18c1.4 0 2-.9 2-1.9s-1-1.6-1-2.6 1-1.5 2-1.5h2.2A3.8 3.8 0 0 0 21 11.2C21 6.6 17 3 12 3z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10" cy="7" r="1"/><circle cx="15" cy="7.5" r="1"/>',
    'aperture': '<circle cx="12" cy="12" r="9"/><path d="M14.3 3.3 9 12.4M20.7 9.5H10.2M18.4 18.2l-5.2-9.1M9.7 20.7 15 11.6M3.3 14.5h10.5M5.6 5.8l5.2 9.1"/>',
    'move': '<path d="M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3M21 12l-3-3M21 12l-3 3"/>',
    'clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
    'export': '<path d="M12 15V3.5M7.5 8 12 3.5 16.5 8M4 14v6.5h16V14"/>',
    'msg': '<path d="M4 4.5h16v11.5H9l-5 4z"/>',
    'cube': '<path d="M12 2.5 3.5 7v10l8.5 4.5 8.5-4.5V7z"/><path d="m3.5 7 8.5 4.5L20.5 7M12 11.5v10"/>',
    'monitor': '<rect x="2.5" y="4" width="19" height="13"/><path d="M8 21h8M12 17v4"/>',
    'more': '<circle cx="5.5" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="18.5" cy="12" r="1.2" fill="currentColor"/>',
    'x': '<path d="M6 6l12 12M18 6 6 18"/>',
    'undo': '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
    'redo': '<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13"/>',
    'magnet': '<path d="M6 3.5v8a6 6 0 0 0 12 0v-8h-4v8a2 2 0 0 1-4 0v-8z"/><path d="M6 7.5h4M14 7.5h4"/>',
    'layers': '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    'gauge': '<path d="M3.5 17.5a9 9 0 1 1 17 0"/><path d="M12 13.5 16 9"/>',
    'mask': '<rect x="3" y="3" width="18" height="18"/><circle cx="12" cy="12" r="5"/>',
    'drop': '<path d="M12 3s6.5 7 6.5 11.3a6.5 6.5 0 0 1-13 0C5.5 10 12 3 12 3z"/>',
    'trans': '<rect x="3" y="6" width="11" height="12"/><rect x="10" y="6" width="11" height="12"/>',
    'bell': '<path d="M6 9a6 6 0 0 1 12 0c0 6.5 2.5 8 2.5 8h-17S6 15.5 6 9z"/><path d="M10 20.5h4"/>',
    'refresh': '<path d="M20 11.5a8 8 0 1 0-2.3 5.8M20 4.5v7h-7"/>',
    'link': '<path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1.2 1.2M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1.2-1.2"/>',
    'upload': '<path d="M12 16V4.5M7.5 9 12 4.5 16.5 9M4 15v5.5h16V15"/>',
    'image': '<rect x="3" y="4" width="18" height="16"/><circle cx="9" cy="9.5" r="1.8"/><path d="m3 17 5.5-5 4.5 4 3-2.5L21 18"/>',
    'storyboard': '<rect x="2.5" y="5" width="5.5" height="7"/><rect x="9.25" y="5" width="5.5" height="7"/><rect x="16" y="5" width="5.5" height="7"/><path d="M2.5 15.5h19M2.5 19h12"/>',
    'swap': '<path d="M4 8h14l-3.5-3.5M20 16H6l3.5 3.5"/>',
    'talk': '<path d="M4 4.5h16v11.5H9l-5 4z"/><path d="M8.5 9h7M8.5 12h4.5"/>',
    'bag': '<path d="M3.5 8h17v12.5h-17z"/><path d="M8.5 8V5.5a3.5 3.5 0 0 1 7 0V8"/>',
    'expand': '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
    'dice': '<rect x="3.5" y="3.5" width="17" height="17"/><circle cx="8.5" cy="8.5" r="1" fill="currentColor"/><circle cx="15.5" cy="15.5" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/>',
    'trash': '<path d="M4 6.5h16M9.5 6.5V4h5v2.5M6 6.5l1 14h10l1-14"/>',
    'split': '<path d="M12 3v18M7 7l-4 5 4 5M17 7l4 5-4 5"/>',
    'snow': '<path d="M12 2.5v19M4 7l16 10M20 7 4 17"/>',
    'rewind': '<path d="M11 6.5 4.5 12l6.5 5.5zM19.5 6.5 13 12l6.5 5.5z"/>',
    'ffwd': '<path d="M13 6.5 19.5 12 13 17.5zM4.5 6.5 11 12l-6.5 5.5z"/>',
    'heart': '<path d="M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z"/>',
    'tiktok': '<path d="M14 3.5v11a3.5 3.5 0 1 1-3.5-3.5M14 3.5c.5 2.5 2.2 4 4.5 4.3"/>',
    'beat': '<path d="M3 12h3l2-6 4 12 3-9 2 3h4"/>',
    'shield': '<path d="M12 3 4.5 6v6c0 4.5 3.2 7.6 7.5 9 4.3-1.4 7.5-4.5 7.5-9V6z"/><path d="m8.8 12.2 2.2 2.2 4.4-4.6"/>',
    'ratio': '<rect x="7" y="3" width="10" height="18"/>',
    'fx': '<path d="M5 20 9 4h6M7 11h6M14 13l5 6M19 13l-5 6"/>',
}


def ic(name, size=18, sw=1.6, color='currentColor', style=''):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" stroke-width="{sw}" '
            f'stroke-linecap="square" stroke-linejoin="miter" style="{style}">{P[name]}</svg>')


# ---------------- silhouettes & characters ----------------
SIL = ('<circle cx="50" cy="31" r="16.5"/>'
       '<path d="M50 50c-17 0-24 8-26.5 24L18 146c-1 8 9 10 11 2l6.5-48 1 60L33 292h15l2.5-112 2.5 112h15l-3.5-132 1-60 6.5 48c2 8 12 6 11-2l-5.5-72C74.5 58 67 50 50 50z"/>')


def sil(w, h, color='#1a1714', op=1.0, vb='0 0 100 300', style='', rim=None):
    st = f' stroke="{rim}" stroke-width="1.6" stroke-opacity=".75"' if rim else ''
    return f'<svg width="{w}" height="{h}" viewBox="{vb}" fill="{color}" opacity="{op}" style="{style}" preserveAspectRatio="xMidYMax meet"><g{st}>{SIL}</g></svg>'


CHARS = {
    'sienna': dict(name='Sienna Vale', short='Sienna', meta='Fashion · 24', ini='S', tone='#D9C7B4', tone2='#B79B82'),
    'noor': dict(name='Noor Adeyemi', short='Noor', meta='Beauty · 27', ini='N', tone='#CDBFB0', tone2='#8E7563'),
    'iris': dict(name='Iris Calder', short='Iris', meta='Lifestyle · 31', ini='I', tone='#D5CDBF', tone2='#A6927D'),
}


def avatar(key, w=56, h=56, letter=True, fs=None):
    c = CHARS[key]
    fs = fs or int(h * .62)
    lt = f'<div style="position:absolute;left:0;right:0;top:{int(h*.04)}px;text-align:center;font:400 {fs}px/1 \'Instrument Serif\';color:rgba(20,18,16,.18)">{c["ini"]}</div>' if letter else ''
    return (f'<div class="plate" style="width:{w}px;height:{h}px;background:linear-gradient(180deg,{c["tone"]},{c["tone2"]})">{lt}'
            f'<div style="position:absolute;left:0;right:0;bottom:0;display:flex;justify-content:center">{sil(int(w*.62), int(h*.92), "#2a211b", .78, "0 0 100 150")}</div></div>')


def sheet_strip(key, size=30, gap=4):
    """7-image character sheet: 3 face crops + 4 full-body angles (silhouettes)."""
    c = CHARS[key]
    out = []
    for i in range(7):
        face = i < 3
        vb = '0 0 100 150' if face else '0 0 100 300'
        bg = f'linear-gradient(180deg,{c["tone"]},{c["tone2"]})'
        sw = 0.95 if face else 0.9
        out.append(f'<div class="plate" style="width:{size}px;height:{int(size*1.25)}px;background:{bg}"><div style="position:absolute;left:0;right:0;bottom:0;display:flex;justify-content:center">'
                   f'{sil(int(size*sw), int(size*1.2*(1.25 if face else 1.0)), "#2a211b", .75, vb, "transform:scaleX(" + ("-1" if i in (4,) else "1") + ")")}</div></div>')
    return f'<div class="row g{gap}">' + ''.join(out) + '</div>'


DARK_PLATES = {'palette-02-teal-orange', 'palette-03-hyper-neon', 'palette-05-sodium-decay', 'palette-06-classic-bw', 'light-04-window', 'palette-01-naturalistic'}


def scene(name, w, h, who=None, pos=.5, blur=0, scale=.78, dark=.82, extra=''):
    """A scene plate (palette/lighting image) with an optional character silhouette = our demo character placeholder."""
    s = ''
    if who:
        sh = int(h * scale)
        sw = int(sh / 3)
        left = int(w * pos - sw / 2)
        rim = '#F0C79A' if name in DARK_PLATES else None
        s = f'<div class="sil" style="left:{left}px;bottom:-{int(sh*.02)}px">{sil(sw, sh, "#1b1410" if rim else "#120f0c", .92 if rim else dark, rim=rim)}</div>'
    bl = f'filter:blur({blur}px);transform:scale(1.08);' if blur else ''
    return (f'<div class="plate" style="width:{w}px;height:{h}px"><img src="{img(name, max(w, h) <= 150)}" style="width:100%;height:100%;object-fit:cover;{bl}">'
            f'{s}{extra}</div>')


# ---------------- chrome ----------------
def titlebar(job='62%', theme_b=False):
    jc = f'<div class="jobchip"><span class="led"></span>{job}<div class="track"><i style="width:62%"></i></div></div>' if job else ''
    return (f'<div class="tb"><div class="lights"><i></i><i></i><i></i></div>'
            f'<span class="t13 b muted">MUSE Studio</span><div class="fill"></div>'
            f'<div class="search">{ic("sparkle",14)}<span class="fill">Search or jump to…</span><span class="kc">⌘K</span></div>'
            f'<div class="fill"></div>{jc}'
            f'<div class="dots"><i style="background:#141210;outline:2px solid #B5121B;outline-offset:2px"></i><i style="background:#0D0E0F;border:2px solid #F2A93B"></i><i style="background:#6E8465"></i><i style="background:#FF7EB6"></i></div>'
            f'<div style="width:34px;height:34px;display:flex;align-items:center;justify-content:center">{ic("user",18)}</div></div>')


SUITE_SUB = [('shot', 'Shot'), ('swap', 'Character swap'), ('story', 'Storyboard'), ('talk', 'Talking · lipsync'),
             ('ugc', 'UGC ad'), ('extend', 'Extend & upscale'), ('stage', 'Camera stage')]


def sidebar(on='suite', sub=None, owner=True, compact=False):
    if compact:
        items = [('home', 'home'), ('user', 'models'), ('video', 'suite'), ('camera', 'shoot'), ('scissors', 'edit'), ('list', 'queue'), ('grid', 'gallery')]
        rows = ''.join(f'<div class="nav{" on" if k == on else ""}" style="width:44px;justify-content:center;padding:0">{ic(i,18)}</div>' for i, k in items)
        return f'<div class="sb compact"><div class="wm" style="font-size:30px;letter-spacing:0;padding:4px 0 18px">M</div>{rows}<div style="margin-top:auto">{ic("sliders",18)}</div></div>'
    main = [('home', 'Home', 'home', '⌘1'), ('models', 'Models', 'user', '⌘2'), ('suite', 'Video suite', 'video', '⌘3'),
            ('shoot', 'Photoshoot', 'camera', '⌘4'), ('edit', 'Edit', 'scissors', '⌘E'), ('queue', 'Queue', 'list', None),
            ('gallery', 'Gallery', 'grid', '⌘6'), ('posts', 'Posts', 'send', '⌘7')]
    rows = []
    for k, t, i, key in main:
        trail = f'<span class="k">{key}</span>' if key else '<span class="k" style="opacity:1"><span class="pill red" style="height:18px;padding:0 6px;background:var(--accent);color:#fff;border-color:var(--accent)">2</span></span>'
        rows.append(f'<div class="nav{" on" if k == on else ""}">{ic(i,16)}<span>{t}</span>{trail}</div>')
        if k == 'suite' and on == 'suite':
            for sk, st in SUITE_SUB:
                rows.append(f'<div class="nav sub{" on" if sk == sub else ""}">{st}</div>')
    own = '<div class="sbh">STUDIO</div><div class="nav">' + ic('users', 16) + '<span>Members</span><span class="k">⌘8</span></div>' if owner else ''
    return (f'<div class="sb"><div class="wm">MUSE</div>{"".join(rows)}'
            f'<div class="sbh">CREATE</div><div class="nav">{ic("plus",16)}<span>New video</span><span class="k">⌘N</span></div>{own}'
            f'<div class="bal"><span class="lbl">Balance</span><span class="fig" style="font-size:30px">$43.60</span><span class="t12">≈ 64 Draft videos</span></div></div>')


def desktop(content, theme='a', on='suite', sub=None, job='62%', compact=False, name=''):
    return (f'<div class="frame d theme-{theme}" data-name="{name}">{titlebar(job)}'
            f'<div class="body">{sidebar(on, sub, compact=compact)}<div class="fill col" style="min-width:0;position:relative">{content}</div></div></div>')


def phone(content, theme='a', name='', nav=None, cta=None, title=None, back=True, right='more', extra=''):
    top = ''
    if title is not None:
        top = (f'<div class="ptop">{ic("chev-l",22) if back else "<span></span>"}<span class="t">{title}</span>'
               f'{ic(right,22) if right else "<span style=width:22px></span>"}</div>')
    bn = ''
    if nav:
        items = [('home', 'HOME'), ('video', 'STUDIO'), ('+', ''), ('list', 'QUEUE'), ('user', 'YOU')]
        cells = []
        for i, t in items:
            if i == '+':
                cells.append(f'<div class="plus">{ic("plus",22)}</div>')
            else:
                cells.append(f'<div class="it{" on" if t == nav else ""}">{ic(i,22)}<span>{t}</span></div>')
        bn = f'<div class="bnav">{"".join(cells)}</div>'
    c = f'<div class="pcta">{cta}</div>' if cta else ''
    return (f'<div class="frame m theme-{theme}" data-name="{name}"><div class="sbar"><span>9:41</span><span class="ic"><i></i><i></i><i style="width:24px"></i></span></div>'
            f'{top}<div class="fill col" style="min-height:0;position:relative;overflow:hidden">{content}</div>{bn}{c}{extra}<div class="home-ind"></div></div>')


def note(title, text, color=''):
    return f'<div class="note {color}"><b>{title}</b><span>{text}</span></div>'


def board(frame, notes=(), num='', title='', desc=''):
    cap = ''
    if title:
        cap = f'<div class="cap"><span class="n">{num}</span><span class="t">{title}</span><span class="cd">{desc}</span></div>'
    ns = ''.join(note(*n) for n in notes)
    return f'<div class="board" data-board="{num}">{frame}<div class="col g24" style="width:320px;flex:none">{cap}<div class="notes">{ns}</div></div></div>'


def slider(pct, w=None, label=None, val=None):
    st = f'style="width:{w}px;flex:none"' if w else ''
    s = f'<div class="slider" {st}><div class="tr"></div><div class="fl" style="width:{pct}%"></div><div class="kn" style="left:{pct}%"></div></div>'
    if label:
        return f'<div class="col g6"><div class="row between"><span class="lbl">{label}</span><span class="mono" style="color:var(--ink)">{val}</span></div>{s}</div>'
    return s


def seg(items, on, cls=''):
    return f'<div class="seg {cls}">' + ''.join(f'<span class="{"on" if i == on else ""}">{i}</span>' for i in items) + '</div>'


def chips(items, on=(), cls=''):
    return f'<div class="row g6 wrap {cls}">' + ''.join(f'<span class="chip{" on" if i in on else ""}">{i}</span>' for i in items) + '</div>'


def tog(on=True):
    return f'<div class="tog{" on" if on else ""}"><i></i></div>'


def opt_row(title, hint, on=True):
    return (f'<div class="row g12 between"><div class="col g2"><span class="t13 b">{title}</span><span class="t12">{hint}</span></div>{tog(on)}</div>')


def hw_card(name, title, spec, w=150, h=None, on=False, tag=None, tag2=None):
    h = h or w
    t = f'<div class="tag">{ic("check",11,2.4)}{tag}</div>' if tag else ''
    t2 = f'<div class="tag2">{tag2}</div>' if tag2 else ''
    return (f'<div class="hw{" on" if on else ""}" style="width:{w}px"><div class="plate" style="width:{w}px;height:{h}px"><img src="{img(name)}" style="width:100%;height:100%;object-fit:cover">{t}{t2}</div>'
            f'<div class="cp"><span class="nm">{title}</span><span class="sp">{spec}</span></div></div>')

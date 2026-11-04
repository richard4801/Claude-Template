#!/usr/bin/env python3
"""Generate the MUSE app screens in 4 themes as self-contained HTML (one file per theme).
Each .screen is a 390x844 mobile frame; html_to_figma captures each .screen as its own Figma frame."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
IMG = json.load(open(os.path.join(HERE, "imgs.json")))

THEMES = {
 "a": dict(name="Editorial", fonts="family=Six+Caps&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500",
   css="""--bg:#EFEBE3;--surface:#F8F5EF;--surface2:#E7E1D6;--ink:#141210;--muted:#6E675E;--line:#CFC7BA;--accent:#B5121B;--accent-ink:#FFFFFF;
   --cta:#141210;--cta-ink:#F8F5EF;--good:#2F6B3A;--warn:#9A5B00;--r:2px;--r-lg:2px;--r-pill:999px;--display:'Six Caps',Impact,sans-serif;--body:'Archivo',Arial,sans-serif;--mono:'IBM Plex Mono',monospace;--stroke:1px;"""),
 "b": dict(name="Camera Body", fonts="family=Barlow:wght@400;500;600;700&family=Barlow+Condensed:wght@500;600;700&family=JetBrains+Mono:wght@400;500;700",
   css="""--bg:#0D0E0F;--surface:#17191B;--surface2:#212427;--ink:#ECEAE5;--muted:#8E8B85;--line:#2C3033;--accent:#F2A93B;--accent-ink:#1A1205;
   --cta:#F2A93B;--cta-ink:#1A1205;--good:#7BD88F;--warn:#F2A93B;--rec:#E5483B;--r:10px;--r-lg:14px;--r-pill:999px;--display:'Barlow Condensed',Arial Narrow,sans-serif;--body:'Barlow',Arial,sans-serif;--mono:'JetBrains Mono',monospace;--stroke:1px;"""),
 "c": dict(name="Soft Tactile", fonts="family=Outfit:wght@300;400;500;600;700&family=DM+Mono:wght@400;500",
   css="""--bg:#E7E2D9;--surface:#F3F0EA;--surface2:#EAE5DC;--ink:#23262A;--muted:#6E6C67;--line:#D9D3C8;--accent:#6E8465;--accent-ink:#FFFFFF;
   --cta:#6E8465;--cta-ink:#FFFFFF;--good:#4E6B45;--warn:#9A6B2A;--r:18px;--r-lg:28px;--r-pill:999px;--display:'Outfit',sans-serif;--body:'Outfit',sans-serif;--mono:'DM Mono',monospace;--stroke:1px;"""),
 "d": dict(name="Creator Pop", fonts="family=Bricolage+Grotesque:opsz,wght@12..96,700;12..96,800&family=Figtree:wght@400;500;600;700;800&family=Permanent+Marker",
   css="""--bg:#FFF6EC;--surface:#FFFFFF;--surface2:#FFEBD8;--ink:#111111;--muted:#55504A;--line:#111111;--accent:#FF7EB6;--accent-ink:#111111;
   --cta:#FF7EB6;--cta-ink:#111111;--good:#0E8A4F;--warn:#B45A00;--blue:#1F4BFF;--yellow:#FFE14D;--mint:#39D98A;--r:14px;--r-lg:20px;--r-pill:999px;--display:'Bricolage Grotesque',Arial Black,sans-serif;--body:'Figtree',sans-serif;--mono:'Figtree',sans-serif;--stroke:2.5px;"""),
}

ICON = {
 "home":'<path d="M4 11l8-7 8 7v9h-5v-6H9v6H4z"/>',
 "studio":'<rect x="3" y="6" width="13" height="12" rx="2"/><path d="M16 10l5-3v10l-5-3z"/>',
 "queue":'<path d="M4 6h16M4 12h10M4 18h7"/><circle cx="18" cy="16" r="3"/>',
 "user":'<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4-6 8-6s7 2 8 6"/>',
 "plus":'<path d="M12 5v14M5 12h14"/>',
 "back":'<path d="M15 5l-7 7 7 7"/>',
 "more":'<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
 "model":'<circle cx="12" cy="7" r="3.5"/><path d="M5 21c.8-4.5 3.4-7 7-7s6.2 2.5 7 7"/>',
 "outfit":'<path d="M8 4l4 3 4-3 4 4-3 3v9H7v-9L4 8z"/>',
 "camera":'<path d="M4 8h3l2-2.5h6L17 8h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
 "light":'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',
 "bg":'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 16l5-5 4 4 3-3 6 6"/>',
 "quality":'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
 "audio":'<path d="M4 9v6h4l5 4V5L8 9z"/><path d="M16 9c1 1 1 5 0 6M18.5 7c2 2.5 2 7.5 0 10"/>',
 "check":'<path d="M5 12.5l4.5 4.5L19 7.5"/>',
 "lock":'<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
 "bell":'<path d="M6 16V11a6 6 0 0112 0v5l2 2H4z"/><path d="M10 20a2 2 0 004 0"/>',
 "play":'<path d="M8 5v14l11-7z"/>',
 "upload":'<path d="M12 16V4M7 9l5-5 5 5M4 20h16"/>',
 "spark":'<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/>',
 "google":'<path d="M20 12.2c0-.6-.1-1.2-.2-1.7H12v3.3h4.5a3.9 3.9 0 01-1.7 2.5v2.1h2.7c1.6-1.5 2.5-3.6 2.5-6.2z"/><path d="M12 20.5c2.3 0 4.2-.8 5.5-2.1l-2.7-2.1c-.8.5-1.7.8-2.8.8a4.9 4.9 0 01-4.6-3.4H4.6v2.2A8.5 8.5 0 0012 20.5z"/>',
 "apple":'<path d="M16 3c-1 .1-2.2.7-2.8 1.5-.6.7-1.1 1.8-.9 2.8 1.1 0 2.2-.6 2.8-1.4.6-.8 1-1.8.9-2.9zM19.5 16.8c-.5 1.1-.8 1.6-1.4 2.6-.9 1.4-2.2 3-3.7 3-1.4 0-1.7-.9-3.6-.9s-2.3.9-3.6.9c-1.5 0-2.7-1.5-3.6-2.9C1.1 15.7.8 11 2.4 8.6c1.1-1.7 2.9-2.7 4.6-2.7 1.7 0 2.8.9 4.2.9 1.4 0 2.2-.9 4.2-.9 1.5 0 3.1.8 4.2 2.2-3.7 2-3.1 7.3-.1 8.7z"/>',
 "mail":'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
 "export":'<path d="M12 3v12M7 8l5-5 5 5"/><path d="M5 14v6h14v-6"/>',
 "retry":'<path d="M4 12a8 8 0 0114-5.3L20 9M20 4v5h-5"/><path d="M20 12a8 8 0 01-14 5.3L4 15M4 20v-5h5"/>',
 "wallet":'<rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18M16 14.5h2"/>',
 "palette":'<path d="M12 3a9 9 0 100 18c1.2 0 1.8-1 1.3-2-.6-1.2.2-2.5 1.5-2.5H17a4 4 0 004-4c0-5-4-9.5-9-9.5z"/><circle cx="7.5" cy="11" r="1.2"/><circle cx="10.5" cy="7.5" r="1.2"/><circle cx="15" cy="8" r="1.2"/>',
 "shield":'<path d="M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z"/>',
 "chev":'<path d="M9 5l7 7-7 7"/>',
 "grid":'<rect x="4" y="4" width="7" height="7"/><rect x="13" y="4" width="7" height="7"/><rect x="4" y="13" width="7" height="7"/><rect x="13" y="13" width="7" height="7"/>',
}
def ic(name, size=22, cls=""):
    fill = ' fill="currentColor" stroke="none"' if name in ("play","apple","google") else ' fill="none" stroke="currentColor"'
    return f'<svg class="ic {cls}" width="{size}" height="{size}" viewBox="0 0 24 24"{fill} stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">{ICON[name]}</svg>'

def status(t, dark_over=False):
    return f'<div class="sb{" sb-over" if dark_over else ""}"><span>9:41</span><span class="sb-r"><i class="sig"></i><i class="wifi"></i><i class="bat"></i></span></div>'

def tabbar(t, active):
    items=[("home","Home"),("studio","Studio"),("plus",""),("queue","Queue"),("user","You")]
    out=[]
    for k,l in items:
        if k=="plus": out.append(f'<div class="tb-plus">{ic("plus",24)}</div>'); continue
        out.append(f'<div class="tb-i{" on" if k==active else ""}">{ic(k,22)}<span>{l}</span></div>')
    return f'<nav class="tabbar">{"".join(out)}</nav><div class="homebar"></div>'

def topbar(t, title, left="back", right=None, over=False):
    l = f'<span class="tb-btn">{ic(left,22)}</span>' if left else '<span class="tb-btn ghost"></span>'
    r = f'<span class="tb-btn">{ic(right,22)}</span>' if right else '<span class="tb-btn ghost"></span>'
    return f'<header class="top{" over" if over else ""}">{l}<h1 class="top-t">{title}</h1>{r}</header>'

def sticker(t, text, color="yellow", rot=-6, style=""):
    return f'<span class="stk stk-{color}" style="transform:rotate({rot}deg);{style}">{text}</span>' if t=="d" else ""

def vf(t):  # viewfinder corners (Camera Body)
    return '<i class="vf tl"></i><i class="vf tr"></i><i class="vf bl"></i><i class="vf br"></i>' if t=="b" else ""

def wordmark(t):
    return '<span class="wm">MUSE</span>'

def pill(text, kind=""):
    return f'<span class="pill {kind}">{text}</span>'

# ---------------- Screens ----------------
def s_splash(t):
    extra = {"a":'<p class="sp-sub mono">THE FACE OF YOUR VISION</p>',
             "b":'<p class="sp-sub mono">● REC &nbsp; 00:00:00:00</p>',
             "c":'<p class="sp-sub">Direct your AI model</p>',
             "d":'<p class="sp-sub hand">make her move!</p>'}[t]
    return f'''<section class="screen splash" data-name="01 Splash">{status(t)}
    <div class="sp-photo" style="background-image:url({IMG["hero"]})">{vf(t)}</div>
    <div class="sp-mark"><span class="wm wm-xl">MUSE</span>{extra}</div>
    {sticker(t,"AI model studio","yellow",-8,"position:absolute;left:28px;top:140px")}
    <div class="homebar"></div></section>'''

def s_welcome(t):
    return f'''<section class="screen" data-name="02 Welcome">{status(t)}
    <div class="wel-grid">
      <div class="wel-img big" style="background-image:url({IMG["g_front"]})">{vf(t)}</div>
      <div class="wel-img" style="background-image:url({IMG["c_face"]})"></div>
      <div class="wel-img" style="background-image:url({IMG["vid_living"]})"></div>
    </div>
    {sticker(t,"identity locked 🔒".replace(" 🔒",""),"pink",6,"position:absolute;right:26px;top:300px")}
    <div class="pad stack-16 wel-copy">
      <h2 class="hero-t">Create your AI model.<br>Direct every shot.</h2>
      <p class="muted">Build an original persona, lock her identity, then put her into real clips with the motion kept frame for frame.</p>
      <div class="dots"><i class="on"></i><i></i><i></i></div>
      <div class="cta">Get started</div>
      <div class="link-c">I already have an account</div>
    </div><div class="homebar"></div></section>'''

def s_signin(t):
    return f'''<section class="screen" data-name="03 Sign in">{status(t)}{topbar(t,"",left="back")}
    <div class="pad stack-20">
      <div><span class="wm wm-md">MUSE</span><h2 class="h2" style="margin-top:14px">Welcome back</h2><p class="muted">Sign in to your studio.</p></div>
      <label class="fld"><span class="lbl">Email</span><span class="inp">jenne@studio.com</span></label>
      <label class="fld"><span class="lbl">Password</span><span class="inp">••••••••••</span><span class="fld-r">Forgot?</span></label>
      <div class="cta">Sign in</div>
      <div class="or"><i></i><span>or</span><i></i></div>
      <div class="sso">{ic("apple",20)} Continue with Apple</div>
      <div class="sso">{ic("google",20)} Continue with Google</div>
      <p class="tiny muted center">New here? <b class="acc">Create an account</b></p>
    </div><div class="homebar"></div></section>'''

def s_signup(t):
    return f'''<section class="screen" data-name="04 Create account">{status(t)}{topbar(t,"",left="back")}
    <div class="pad stack-20">
      <div><h2 class="h2">Create your studio</h2><p class="muted">One account for all your models.</p></div>
      <label class="fld"><span class="lbl">Studio name</span><span class="inp">Jenne Studio</span></label>
      <label class="fld"><span class="lbl">Email</span><span class="inp">jenne@studio.com</span></label>
      <label class="fld"><span class="lbl">Password</span><span class="inp">••••••••••</span></label>
      <div class="chk">{ic("check",16)}<span>I'm 18 or older and I'll only create original characters, never real people.</span></div>
      <div class="chk">{ic("check",16)}<span>I'll label AI content when I post it.</span></div>
      <div class="cta">Create account</div>
      <p class="tiny muted center">By continuing you agree to the Terms and the MiniMax H3 acceptable use policy.</p>
    </div><div class="homebar"></div></section>'''

def model_card(t, img, name, sub, state, kind):
    return f'''<div class="mcard"><div class="mc-img" style="background-image:url({img})">{vf(t)}</div>
      <div class="mc-meta"><b>{name}</b><span class="tiny muted">{sub}</span>{pill(state,kind)}</div></div>'''

def s_home(t):
    hello = {"a":"YOUR MODELS","b":"MODELS","c":"Good morning, Jenne","d":"Your crew"}[t]
    return f'''<section class="screen" data-name="05 Home">{status(t)}
    <header class="top">{wordmark(t)}<span class="grow"></span><span class="tb-btn">{ic("bell",22)}</span></header>
    <div class="pad stack-16 scroll">
      <div class="row-b"><h2 class="h2 home-t">{hello}</h2><span class="bal mono">$6.07</span></div>
      <div class="feature" style="background-image:url({IMG["g_front"]})">{vf(t)}
        <div class="feat-cap"><span class="lbl lbl-inv">Featured</span><b class="feat-name">Sienna Vale</b><span class="tiny">Identity locked · 2 outfits</span></div>
        {sticker(t,"ready to shoot","mint",-5,"position:absolute;right:14px;top:14px")}</div>
      <div class="quick">
        <div class="qa">{ic("studio",22)}<span>New video</span></div>
        <div class="qa">{ic("camera",22)}<span>Photoshoot</span></div>
        <div class="qa">{ic("model",22)}<span>New model</span></div>
      </div>
      <div class="row-b"><h3 class="h3">All models</h3><span class="tiny acc">See all</span></div>
      <div class="mgrid">{model_card(t,IMG["c_front"],"Sienna Vale","Fashion · 24","Locked","good")}
        <div class="mcard empty"><div class="mc-img init">N</div><div class="mc-meta"><b>Noor Adeyemi</b><span class="tiny muted">Beauty · 27</span>{pill("Needs close-ups","warn")}</div></div></div>
    </div>{tabbar(t,"home")}</section>'''

def s_profile(t):
    name_block = {"a":'<div class="prof-name a-name">SIENNA<br>VALE</div>',"b":'<div class="prof-name">Sienna Vale</div>',
                  "c":'<div class="prof-name">Sienna Vale</div>',"d":'<div class="prof-name">Sienna<br>Vale</div>'}[t]
    refs = [("face","Face"),("profile","Profile"),("g_front","Front"),("g_tq","¾"),("g_side","Side"),("g_back","Back")]
    return f'''<section class="screen" data-name="06 Model profile">
    <div class="prof-hero" style="background-image:url({IMG["hero"]})">{status(t, True)}{topbar(t,"",left="back",right="more",over=True)}{vf(t)}
      {name_block}{sticker(t,"identity locked","pink",-7,"position:absolute;right:20px;bottom:120px")}</div>
    <div class="sheet-up pad stack-14">
      <div class="row-b"><div><b class="h3">Sienna Vale</b><div class="tiny muted">Fashion & lifestyle · 24</div></div>{pill(ic("lock",12)+" Identity 6/6","good")}</div>
      <div class="row-b"><span class="lbl">Identity shots</span><span class="tiny acc">Edit</span></div>
      <div class="refrow">{"".join(f'<div class="ref"><div class="ref-img" style="background-image:url({IMG[k]})"></div><span>{l}</span></div>' for k,l in refs)}</div>
      <div class="row-b"><span class="lbl">Outfits</span><span class="tiny acc">+ Add</span></div>
      <div class="refrow">
        <div class="ofit on"><div class="ref-img tall" style="background-image:url({IMG["g_front"]})"></div><span>Green set</span></div>
        <div class="ofit"><div class="ref-img tall" style="background-image:url({IMG["c_front"]})"></div><span>Crystal dress</span></div>
        <div class="ofit add"><div class="ref-img tall init">+</div><span>New outfit</span></div></div>
      <p class="never"><span class="lbl">Never add</span> &nbsp;<b>Tattoos · Rings · Necklaces</b></p>
    </div>
    <div class="dock"><div class="cta grow">Make a video</div><div class="cta-2">{ic("camera",20)}</div></div><div class="homebar"></div></section>'''

def steps_head(t, n, title):
    bars = "".join(f'<i class="{"on" if i<n else ""}"></i>' for i in range(4))
    return f'<div class="pad stack-8"><div class="stepbars">{bars}</div><span class="lbl">Step {n} of 4</span><h2 class="h2">{title}</h2></div>'

def s_create1(t):
    return f'''<section class="screen" data-name="07 Create · Basics">{status(t)}{topbar(t,"New model",left="back")}
    {steps_head(t,1,"Who is she?")}
    <div class="pad stack-16">
      <label class="fld"><span class="lbl">Name</span><span class="inp">Noor Adeyemi</span></label>
      <div class="fld"><span class="lbl">Age · <b class="mono">27</b></span><div class="slider"><i style="width:33%"></i><b style="left:33%"></b></div><div class="scale mono"><span>18</span><span>45</span></div></div>
      <div class="fld"><span class="lbl">Niche</span><div class="chips">{"".join(f'<span class="chip{" on" if x=="Beauty" else ""}">{x}</span>' for x in ["Fashion","Beauty","Fitness","Travel","Food","Tech"])}</div></div>
      <label class="fld"><span class="lbl">Personality & voice</span><span class="inp area">Warm and playful. Talks to camera like a best friend. Loves skincare routines.</span></label>
      <div class="note-box">{ic("shield",18)}<span>Models are always 18+ and original. No lookalikes of real people.</span></div>
    </div>
    <div class="dock"><div class="cta grow">Next: Look</div></div><div class="homebar"></div></section>'''

def s_create2(t):
    rows=[("Skin tone",None),("Face shape",["Oval","Heart","Round","Square"]),("Eyes",["Green","Hazel","Brown","Blue"]),
          ("Hair",["Honey blonde","Brunette","Black","Auburn"]),("Texture",["Straight","Wavy","Curly","Coily"]),("Body",["Slim","Athletic","Curvy"]),("Makeup",["Bare","Soft glam","Full glam"])]
    sel={"Face shape":"Oval","Eyes":"Brown","Hair":"Black","Texture":"Curly","Body":"Curvy","Makeup":"Soft glam"}
    out=[]
    for k,opts in rows:
        if opts is None:
            sw="".join(f'<i class="sw{" on" if i==4 else ""}" style="background:{c}"></i>' for i,c in enumerate(["#F3D9C4","#E8C09C","#D4A275","#B07A50","#8A5A38","#5E3B24"]))
            out.append(f'<div class="fld"><span class="lbl">{k}</span><div class="sws">{sw}</div></div>')
        else:
            chips = "".join(f'<span class="chip{" on" if o==sel[k] else ""}">{o}</span>' for o in opts)
            out.append(f'<div class="fld"><span class="lbl">{k}</span><div class="chips nowrap">{chips}</div></div>')
    return f'''<section class="screen" data-name="08 Create · Look">{status(t)}{topbar(t,"New model",left="back")}
    {steps_head(t,2,"Her look")}
    <div class="pad stack-14">{"".join(out)}<p class="tiny muted">13 settings · 6 more under Brows, Lips, Height, Vibe, Skin details, Freckles.</p></div>
    <div class="dock"><div class="cta grow">Generate portraits · $0.08</div></div><div class="homebar"></div></section>'''

def s_create3(t):
    slots=[("Face · front","face",True),("Face · profile","profile",True),("Body · front","g_front",False),("Body · ¾",None,False),("Body · side",None,False),("Body · back",None,False)]
    cells="".join(f'<div class="slot{" filled" if k else ""}">{f"<div class=ref-img style=background-image:url({IMG[k]})></div>" if k else "<div class=slot-e>"+ic("upload",20)+"</div>"}<span>{n}{" · required" if req and not k else ""}</span></div>' for n,k,req in slots)
    return f'''<section class="screen" data-name="09 Create · Identity">{status(t)}{topbar(t,"New model",left="back")}
    {steps_head(t,3,"Lock her identity")}
    <div class="pad stack-14">
      <p class="muted">Six separate shots keep her the same person in every video. Face close-ups matter most.</p>
      <div class="slots">{cells}</div>
      <div class="note-box warn">{ic("shield",18)}<span>3 of 6 added. Upload separate images, not a character sheet.</span></div>
    </div>
    <div class="dock"><div class="cta-2 wide">{ic("upload",18)} Upload</div><div class="cta grow">Next: Never add</div></div><div class="homebar"></div></section>'''

def toolstrip(t, active):
    tools=[("model","Model"),("outfit","Outfit"),("camera","Camera"),("light","Light"),("bg","Background"),("quality","Quality")]
    return '<div class="tools">'+"".join(f'<div class="tool{" on" if k==active else ""}">{ic(k,20)}<span>{l}</span></div>' for k,l in tools)+'</div>'

def s_shoot(t):
    return f'''<section class="screen" data-name="10 Photoshoot · Camera">{status(t)}{topbar(t,"Photoshoot",left="back",right="more")}
    <div class="canvas short" style="background-image:url({IMG["c_tq"]})">{vf(t)}{"<span class='readout tl-r mono'>35MM · F/2.8 · 4300K</span>" if t=="b" else ""}
      {sticker(t,"rooftop · golden hour","yellow",-4,"position:absolute;left:12px;bottom:12px")}</div>
    {toolstrip(t,"camera")}
    <div class="bsheet stack-14"><i class="grab"></i>
      <div class="row-b"><b class="h3">Camera</b><span class="tiny acc">Reset</span></div>
      <div class="fld"><span class="lbl">Shot</span><div class="seg">{"".join(f'<span class="{"on" if x=="Medium" else ""}">{x}</span>' for x in ["Close","Medium","Full","Wide"])}</div></div>
      <div class="fld"><span class="lbl">Lens · <b class="mono">35mm</b></span><div class="ruler">{"".join(f'<i class="{"big" if i%5==0 else ""}{" on" if i==10 else ""}"></i>' for i in range(31))}</div><div class="scale mono"><span>16</span><span>24</span><span>35</span><span>50</span><span>85</span></div></div>
      <div class="fld"><span class="lbl">Aperture</span><div class="chips">{"".join(f'<span class="chip{" on" if x=="f/2.8" else ""}">{x}</span>' for x in ["f/1.4","f/2.8","f/5.6","f/11"])}</div></div>
    </div>
    <div class="dock tight"><div class="cta grow">Shoot 4 · ~32s · $0.12</div></div><div class="homebar"></div></section>'''

def s_source(t):
    checks=[("One person in frame","Yes","good"),("Watermark","None","good"),("1080×1920 · 30fps","OK","good"),("Length 9.4s","Max 15s","good"),("Performer talking","No","warn")]
    return f'''<section class="screen" data-name="11 Video · Source clip">{status(t)}{topbar(t,"New video",left="back")}
    <div class="pad stack-16">
      <div class="clipcard"><div class="clip-th" style="background-image:url({IMG["src_clip"]})">{ic("play",18,"play-ov")}</div>
        <div class="stack-8 grow">{"".join(f'<div class="row-b tiny"><span>{a}</span>{pill(b,k)}</div>' for a,b,k in checks)}</div></div>
      <div class="fld"><span class="lbl">Use</span><div class="seg"><span class="on">First 5.2s</span><span>Full 9.4s</span></div></div>
      <div class="fld"><span class="lbl">Performer consent</span>
        <div class="opt on"><b>On file · tests only</b><span class="tiny muted">Results stay in the test gallery</span></div>
        <div class="opt"><b>On file · posting allowed</b><span class="tiny muted">Can be exported for TikTok</span></div></div>
      {sticker(t,"clip looks good!","mint",-3,"align-self:flex-start")}
    </div>
    <div class="dock"><div class="cta grow">Next: Direct</div></div><div class="homebar"></div></section>'''

def steps_control(t):
    if t=="b":
        ticks="".join(f'<i class="{"big" if i%5==0 else ""}{" on" if i==6 else ""}"></i>' for i in range(27))
        return f'''<div class="dialbox"><div class="dial-read"><span class="lbl">Steps</span><b class="mono dial-n">10</b><span class="tiny acc">Recommended</span></div>
          <div class="dial"><i class="dial-mark"></i></div><div class="ruler">{ticks}</div><div class="scale mono"><span>4</span><span>10</span><span>20</span><span>30</span></div></div>'''
    big = '<b class="mono stepnum">10</b>' if t in "ac" else '<b class="stepnum">10</b>'
    return f'''<div class="fld"><div class="row-b"><span class="lbl">Steps</span>{pill("Recommended","good")}</div>{big}
      <div class="slider"><i style="width:23%"></i><b style="left:23%"></b></div><div class="scale mono"><span>4</span><span>10</span><span>20</span><span>30</span></div>
      <p class="tiny muted">10, 15 and 20 steps looked the same in testing. More steps only add time.</p></div>'''

def s_video(t):
    readout = "<span class='readout tl-r mono'><i class='rec'></i> 00:00:05:04</span><span class='readout br-r mono'>768×1344 · 24 FPS</span>" if t=="b" else ""
    return f'''<section class="screen" data-name="12 Video · Direct">{status(t)}{topbar(t,"Video studio",left="back",right="more")}
    <div class="canvas" style="background-image:url({IMG["vid_living"]})">{vf(t)}{readout}
      <div class="canvas-bar">{ic("play",16)}<div class="track"><i style="width:38%"></i></div><span class="mono tiny">0:02 / 0:05</span></div>
      {sticker(t,"make her move","yellow",-7,"position:absolute;left:12px;top:12px")}</div>
    {toolstrip(t,"quality")}
    <div class="bsheet stack-12"><i class="grab"></i>
      <div class="row-b"><b class="h3">Quality</b><div class="seg sm"><span class="on">H3</span><span>Viggle β</span></div></div>
      {steps_control(t)}
      <div class="row-b"><span>Lip sync</span><span class="tog"></span></div>
    </div>
    <div class="dock tight"><div class="cta grow">Generate · 10 min · $0.67</div></div><div class="homebar"></div></section>'''

def s_bg(t):
    return f'''<section class="screen" data-name="13 Video · Background">{status(t)}{topbar(t,"Video studio",left="back",right="more")}
    <div class="canvas short" style="background-image:url({IMG["vid_living2"]})">{vf(t)}</div>
    {toolstrip(t,"bg")}
    <div class="bsheet stack-14"><i class="grab"></i>
      <b class="h3">Background</b>
      <div class="opt on"><b>Keep the real room</b><span class="tiny muted">Best realism. Uses the clip's own background.</span></div>
      <div class="opt"><b>New background photo</b><span class="tiny muted">Vertical photo, same camera height, similar light.</span></div>
      <div class="fld"><span class="lbl">Background motion</span><div class="seg"><span>Still</span><span class="on">Subtly alive</span><span>Busy</span></div></div>
      <div class="row-b"><span>Keep original audio</span><span class="tog on"></span></div>
    </div>
    <div class="dock tight"><div class="cta grow">Generate · 10 min · $0.67</div></div><div class="homebar"></div></section>'''

def s_queue(t):
    jobs=[("vid_living","Living-room dance","H3 · 10 steps",60,"step 6/10 · 4 min left","$0.65","Rendering"),
          ("vid_kick","Kick test","Viggle β",100,"done in 1m 35s","$0.13","Done"),
          ("vid_bath","Bathroom trend","H3 · 30 steps",100,"done in 46m","$3.05","Done"),
          ("c_tq","Rooftop shoot · 4","Photoshoot",0,"queued","$0.12","Queued")]
    big = f'<div class="count"><span class="lbl">Now rendering</span><b class="count-n">04:12</b><span class="tiny muted">Living-room dance · step 6 of 10</span></div>' if t in "cb" else ""
    rows="".join(f'''<div class="job"><div class="job-th" style="background-image:url({IMG[k]})"></div><div class="grow stack-4"><div class="row-b"><b>{n}</b><span class="mono tiny">{c}</span></div>
        <span class="tiny muted">{e}</span><div class="bar"><i style="width:{p}%"></i></div><div class="row-b tiny"><span class="muted">{s}</span>{pill(st,"good" if st=="Done" else "warn" if st=="Rendering" else "")}</div></div></div>''' for k,n,e,p,s,c,st in jobs)
    return f'''<section class="screen" data-name="14 Render queue">{status(t)}
    <header class="top">{wordmark(t)}<span class="grow"></span><span class="gpu">{pill("● H100 on","good")}</span></header>
    <div class="pad stack-14 scroll"><h2 class="h2">Queue</h2>{big}
      <div class="kpis"><div><span class="lbl">Today</span><b class="mono">$3.95</b></div><div><span class="lbl">Month</span><b class="mono">$18.93</b></div><div><span class="lbl">Balance</span><b class="mono">$6.07</b></div></div>
      {sticker(t,"good models take time","yellow",-3,"align-self:flex-start")}
      <div class="stack-10">{rows}</div></div>{tabbar(t,"queue")}</section>'''

def s_result(t):
    return f'''<section class="screen" data-name="15 Result">
    <div class="full" style="background-image:url({IMG["vid_living2"]})">{status(t, True)}{topbar(t,"Take 1 of 2",left="back",right="more",over=True)}{vf(t)}
      <div class="res-side"><div class="rs">{ic("retry",22)}<span>Retry</span></div><div class="rs">{ic("export",22)}<span>Export</span></div></div>
      {sticker(t,"she ate!","pink",-8,"position:absolute;left:18px;top:140px")}</div>
    <div class="res-sheet stack-12">
      <div class="row-b"><div><b class="h3">Living-room dance</b><div class="tiny muted">H3 · 10 steps · 9m 30s · $0.65</div></div>{pill("Test","")}</div>
      <div class="note-box">{ic("shield",18)}<span>Export adds the AI-generated label. Brand posts also need #ad.</span></div>
      <div class="row-g"><div class="cta-2 grow">Reject</div><div class="cta grow">Approve</div></div>
    </div><div class="homebar"></div></section>'''

def s_gallery(t):
    tiles=[("vid_living","10 steps"),("vid_kick","Viggle β"),("vid_bath","30 steps"),("c_front","Shoot"),("vid_living2","15 steps"),("c_tq","Shoot")]
    return f'''<section class="screen" data-name="16 Gallery">{status(t)}
    <header class="top">{wordmark(t)}<span class="grow"></span><span class="tb-btn">{ic("grid",22)}</span></header>
    <div class="pad stack-14"><h2 class="h2">Gallery</h2>
      <div class="seg"><span class="on">Tests · 6</span><span>Final · 0</span></div>
      <div class="gal">{"".join(f'<div class="gt" style="background-image:url({IMG[k]})"><span class="gt-l">{l}</span></div>' for k,l in tiles)}</div>
      <p class="tiny muted">Tests never fill your final gallery. Approve a take to move it to Final.</p>
    </div>{tabbar(t,"studio")}</section>'''

def s_settings(t):
    th=[("a","Editorial","#EFEBE3","#141210","#B5121B"),("b","Camera Body","#0D0E0F","#ECEAE5","#F2A93B"),("c","Soft Tactile","#E7E2D9","#23262A","#6E8465"),("d","Creator Pop","#1F4BFF","#FFF6EC","#FF7EB6")]
    cards="".join(f'''<div class="thm{" on" if k==t else ""}"><div class="thm-sw" style="background:{b}"><i style="background:{f}"></i><i style="background:{a}"></i></div><span>{n}</span>{"<b class='thm-c'>"+ic("check",14)+"</b>" if k==t else ""}</div>''' for k,n,b,f,a in th)
    rows=[("wallet","Credits & billing","$6.07"),("bell","Notifications","On"),("shield","Consent records","2"),("lock","Privacy & data",""),("user","Account","jenne@…")]
    return f'''<section class="screen" data-name="17 Settings · Theme">{status(t)}{topbar(t,"Settings",left="back")}
    <div class="pad stack-16">
      <div class="fld"><span class="lbl">Theme</span><div class="thms">{cards}</div></div>
      <div class="list">{"".join(f'<div class="li">{ic(i,20)}<span class="grow">{n}</span><span class="tiny muted">{v}</span>{ic("chev",16)}</div>' for i,n,v in rows)}</div>
      <p class="tiny muted center">Video model: MiniMax H3 · Lip sync: LatentSync</p>
    </div>{tabbar(t,"user")}</section>'''

def s_billing(t):
    return f'''<section class="screen" data-name="18 Credits & billing">{status(t)}{topbar(t,"Credits",left="back")}
    <div class="pad stack-16">
      <div class="balcard"><span class="lbl lbl-inv">GPU balance</span><b class="bal-n mono">$6.07</b><span class="tiny">≈ 9 videos at 10 steps</span>{sticker(t,"top up!","yellow",-6,"position:absolute;right:16px;top:16px")}</div>
      <div class="fld"><span class="lbl">Top up</span><div class="seg"><span>$10</span><span class="on">$25</span><span>$50</span><span>$100</span></div></div>
      <div class="kpis"><div><span class="lbl">This month</span><b class="mono">$18.93</b></div><div><span class="lbl">Per video</span><b class="mono">~$0.65</b></div><div><span class="lbl">Videos</span><b class="mono">11</b></div></div>
      <div class="fld"><span class="lbl">Spend limits</span>
        <div class="li">{ic("shield",20)}<span class="grow">Per job</span><span class="mono tiny">$5.00</span></div>
        <div class="li">{ic("shield",20)}<span class="grow">Per day</span><span class="mono tiny">$15.00</span></div></div>
    </div>
    <div class="dock"><div class="cta grow">Add $25 · USDT or card</div></div><div class="homebar"></div></section>'''

SCREENS=[s_splash,s_welcome,s_signin,s_signup,s_home,s_profile,s_create1,s_create2,s_create3,s_shoot,s_source,s_video,s_bg,s_queue,s_result,s_gallery,s_settings,s_billing]

BASE_CSS = open(os.path.join(HERE,"base.css")).read()
THEME_CSS = open(os.path.join(HERE,"themes.css")).read()

def build(t, only=None):
    th=THEMES[t]
    screens=[f(t) for f in SCREENS]
    if only: screens=[s for s in screens if any(o in s[:120] for o in only)]
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>MUSE · {th["name"]}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?{th["fonts"]}&display=swap">
<style>:root{{{th["css"]}}}{BASE_CSS}{THEME_CSS}</style></head>
<body class="t-{t}"><div class="board">{"".join(screens)}</div></body></html>'''

if __name__=="__main__":
    os.makedirs(os.path.join(HERE,"out"),exist_ok=True)
    for t in THEMES:
        open(os.path.join(HERE,"out",f"muse_{t}.html"),"w").write(build(t))
    print("ok", len(SCREENS), "screens x", len(THEMES))

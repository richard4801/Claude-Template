#!/usr/bin/env python3
"""Bundle the clickable MUSE prototype into one self-contained HTML page."""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen  # reuses THEMES (tokens) and ICON (paths)

theme_vars = "\n".join(f".t-{k}{{{v['css']}}}" for k, v in gen.THEMES.items())
base = open(os.path.join(HERE, "base.css")).read()
base = re.sub(r"body\{[^}]*\}", "", base, count=1).replace(".board{display:flex;flex-wrap:wrap;gap:60px;padding:60px;width:2400px}", "")
themes = open(os.path.join(HERE, "themes.css")).read()
proto = open(os.path.join(HERE, "proto.css")).read()
extra = """
.fx>*{flex-shrink:0}.fx .li{height:auto;min-height:54px;padding-top:9px;padding-bottom:9px}
.t-a .ap-photo{height:376px}.t-d .cutout{height:296px}
.pex{display:grid;grid-template-columns:1fr 1fr;gap:8px;padding:0 16px;margin:10px 0 0}
.pe{display:flex;gap:8px;align-items:center;padding:9px 10px;border:var(--stroke) solid var(--line);border-radius:var(--r);background:var(--surface);color:var(--ink);font-size:13px;line-height:1.2;min-height:52px}
.pe>span{display:flex;flex-direction:column;gap:2px;min-width:0}.pe .tiny{font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.t-b .pe{background:#17191B}.t-d .pe{border-width:2.5px;box-shadow:3px 3px 0 #111}
.pbadge{display:inline-grid;place-items:center;border-radius:28%;color:#fff;font-weight:800;font-family:Arial,sans-serif;flex:none;letter-spacing:-.02em}
.lora-hero{height:180px;border-radius:var(--r-lg);background-size:cover;background-position:center 20%;position:relative;overflow:hidden}
.lh-cap{position:absolute;left:0;right:0;bottom:0;padding:30px 14px 12px;color:#fff;display:flex;flex-direction:column;background:linear-gradient(transparent,rgba(0,0,0,.65))}
.steps3{display:grid;gap:8px}.steps3 span{display:flex;gap:10px;align-items:center;font-size:13px}.steps3 b{width:24px;height:24px;border-radius:50%;display:grid;place-items:center;background:var(--accent);color:var(--accent-ink);font-size:12px;flex:none}
.lgrid{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.lt{aspect-ratio:3/4;border-radius:calc(var(--r) * .6);background-size:cover;background-position:center 15%;position:relative;overflow:hidden;background-color:var(--surface2)}
.lt.tall{aspect-ratio:3/4}
.lt.out{filter:grayscale(1) brightness(.55)}
.lchk{position:absolute;right:4px;top:4px;width:20px;height:20px;border-radius:50%;background:var(--accent);color:var(--accent-ink);display:grid;place-items:center;font-size:11px;font-weight:700}
.lt.out .lchk{background:#fff;color:#111}
.lflag{position:absolute;left:4px;bottom:4px;background:#F6E2C0;color:#6B3F00;font-size:10px;font-weight:700;padding:1px 6px;border-radius:999px}
.pbar{height:6px;border-radius:3px;background:var(--surface2);overflow:hidden}.pbar i{display:block;height:100%;background:var(--accent);transition:width .3s}
.cmp2{flex:1;display:flex;flex-direction:column;gap:6px}
.pthumb{width:54px;height:72px;border-radius:calc(var(--r) * .6);background-size:cover;background-position:center;flex:none}
.prow{display:flex;gap:12px;align-items:center;padding:10px;border:var(--stroke) solid var(--line);border-radius:var(--r);background:var(--surface)}
.pchip{gap:8px;padding-left:6px}
/* Editorial type scale: Instrument Serif (a true condensed serif), no stretching */
.t-a{--display:'Instrument Serif',Didot,'Times New Roman',serif}
.t-a .cond,.t-a .h2,.t-a .hero-t,.t-a .wm,.t-a .feat-name,.t-a .count-n,.t-a .stepnum,.t-a .prof-name{transform:none;font-family:'Instrument Serif',Didot,serif;font-weight:400;letter-spacing:0}
.t-a .cond{display:inline-block;text-transform:uppercase;white-space:normal;line-height:.88}
.t-a .h2{display:block;font-size:42px;line-height:.95;text-transform:uppercase;white-space:normal}
.t-a .home-t{font-size:inherit}
.t-a .wm{font-size:28px;letter-spacing:.08em}
.t-a .wm-md{font-size:44px}.t-a .wm-xl{font-size:118px;letter-spacing:.02em;line-height:.85}
.t-a .ap-name{font-size:108px;line-height:.82;left:14px;bottom:44px}
.t-a .renders-t{font-size:58px;line-height:.9}
.t-a .feat-name{font-size:40px;text-transform:uppercase;line-height:.9}
.t-a .stepnum{font-size:84px;line-height:.85;display:block;text-align:center}
.t-a .count-n{font-size:76px}
.t-a .hero-t{font-size:56px;line-height:.9}
.slider::before{content:"";position:absolute;left:0;right:0;top:-14px;bottom:-14px}
.t-a .slider{height:2px;background:var(--line)}
.view .screen .scroll{overflow:auto}
.view .bsheet{overflow-y:auto}
.t-c .tabbar.three .tb-i{width:80px}
.t-d .tool:nth-child(5) svg{background:#fff}
.t-d .acc,.t-d .fld-r{color:var(--blue)}
.full{height:560px}
.t-c .ccard{height:290px}
/* ---- review fixes: legibility, targets, contrast, state cues ---- */
.tb-i{font-size:11.5px;width:60px}.t-a .tb-i,.t-a .tool{font-size:11px;letter-spacing:.06em}
.tool{font-size:11.5px;width:62px}.tool span{white-space:nowrap}
.slot,.ref,.ofit{font-size:12px}.ref span,.ofit span{font-size:11.5px}
.gt-l{font-size:11.5px}.scale{font-size:11.5px}
.t-a .rj .meta,.t-a .strip,.t-a .under,.t-a .ap-tag{font-size:11.5px}
.t-b .ro,.readout{font-size:11.5px}
.tb-btn{width:44px;height:44px}
.t-a .arrow{width:44px;height:44px}
.fld-r{padding:12px 4px;margin:-12px -4px;bottom:4px}
.t-a .slider b{width:22px;height:22px;margin:-11px 0 0 -11px}
.pill.warn{background:#F6E2C0;color:#6B3F00}
.t-b .pill.warn{background:#3A2B14;color:#F2B45A}
.t-b .muted,.t-b .tiny.muted,.t-b .tool,.t-b .tb-i{color:#A9A6A0}
.t-c{--muted:#5E5C57}
.t-c .cta,.t-c .tb-plus,.t-c .balcard{background:#5A6E52}
.chk .ic{background:transparent;color:transparent;border:1.5px solid var(--line)}
.chk.on .ic{background:var(--accent);color:var(--accent-ink);border-color:var(--accent)}
.is-off{opacity:.45}
.opt.on b{color:var(--ink)}
.t-d .tool.on span{text-decoration:underline;text-underline-offset:3px;text-decoration-thickness:2px}
.t-d .tool:not(.on) svg{box-shadow:none;opacity:.75}
.t-b .tool.on span{text-decoration:underline;text-underline-offset:4px}
.bsheet{padding-bottom:140px!important}
.t-b .knob{width:80px;height:80px}.t-b .plate{padding:10px 14px 8px;gap:6px}.t-b .stepsbadge{font-size:24px}
.view .screen .scroll{padding-bottom:120px}
#ssheet .slots,.screen .slots{grid-template-columns:repeat(3,1fr)}
.slot-e{flex-direction:column;gap:4px}
.mi.danger{color:#B3261E}
textarea.inp{font:inherit;color:var(--ink);resize:none;width:100%;outline:none;line-height:1.45;user-select:text;-webkit-user-select:text}
textarea.inp:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
.pbox{border:var(--stroke) solid var(--line);border-radius:var(--r);background:var(--surface2);padding:10px 12px;display:flex;flex-direction:column;gap:6px;font-size:12.5px;line-height:1.4;max-height:190px;overflow:auto}
.pbox .pk{display:inline-block;min-width:68px;margin-right:6px;font-family:var(--mono);font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.slot .ref-img.shimmer{background:var(--surface2)}
.thm-prev{height:150px;border-radius:calc(var(--r) * .6);background-size:cover;background-position:top center;border:1px solid rgba(0,0,0,.12)}
.menu-scrim{position:absolute;inset:0;z-index:80}
.menu{position:absolute;z-index:81;min-width:220px;background:var(--surface);color:var(--ink);border:var(--stroke) solid var(--line);border-radius:var(--r);box-shadow:0 14px 40px rgba(0,0,0,.22);padding:6px;transform-origin:top right}
.mi{display:flex;align-items:center;gap:12px;height:44px;padding:0 12px;border-radius:calc(var(--r) * .6);font-size:14.5px;cursor:pointer}
.mi:hover,.mi:active{background:var(--surface2)}
.mi.danger{color:#C2362B;border-top:var(--stroke) solid var(--line);border-radius:0;margin-top:4px}
.t-a .menu{border-radius:2px;box-shadow:0 10px 30px rgba(0,0,0,.15)}.t-a .mi{font-family:var(--mono);font-size:12px;letter-spacing:.06em;text-transform:uppercase}
.t-b .menu{background:#1B1E20;border-color:#33373a;box-shadow:0 16px 40px rgba(0,0,0,.7)}
.t-c .menu{border-color:transparent;border-radius:20px;box-shadow:0 16px 40px rgba(80,70,55,.22)}
.t-d .menu{border:2.5px solid #111;box-shadow:5px 5px 0 #111;border-radius:16px}.t-d .mi{font-weight:700}
"""
fonts = ("family=Instrument+Serif&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500"
         "&family=Barlow:wght@400;500;600;700&family=Barlow+Condensed:wght@500;600;700&family=JetBrains+Mono:wght@400;500;700"
         "&family=Outfit:wght@300;400;500;600;700&family=DM+Mono:wght@400;500"
         "&family=Bricolage+Grotesque:opsz,wght@12..96,700;12..96,800&family=Figtree:wght@400;500;600;700;800&family=Permanent+Marker")
app = (open(os.path.join(HERE, "app.js")).read() + "\n" + open(os.path.join(HERE, "features.js")).read()).replace("__ICONS__", json.dumps(gen.ICON))
imgs = open(os.path.join(HERE, "imgs.json")).read()

html = f"""<title>MUSE Studio Prototype</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?{fonts}&display=swap">
<style>
{theme_vars}
{base}
{themes}
{proto}
{extra}
</style>
<div class="stage">
  <aside class="side-panel" id="side">
    <h1>MUSE</h1>
    <p>Clickable prototype of the AI model studio. Sample data from our tests. Renders run 24× faster than real time.</p>
    <span class="lbl" style="color:var(--page-muted)">Theme</span>
    <div class="sp-row"><button data-side="theme:a">Editorial</button><button data-side="theme:b">Camera Body</button><button data-side="theme:c">Soft Tactile</button><button data-side="theme:d">Creator Pop</button></div>
    <span class="lbl" style="color:var(--page-muted)">Jump to</span>
    <div class="sp-row"><button data-side="go:splash">Splash</button><button data-side="go:signin">Sign in</button><button data-side="go:home">Home</button><button data-side="go:profile">Model</button><button data-side="go:create1">Create</button><button data-side="go:shoot">Photoshoot</button><button data-side="go:direct">Video studio</button><button data-side="go:queue">Queue</button><button data-side="go:settings">Settings</button></div>
    <div class="sp-row"><button data-side="sound">Notification sound</button></div>
    <p>Tip: in the video studio, drag the steps slider (or turn the dial in Camera Body), then tap Generate.</p>
  </aside>
  <div class="device"><div class="phone" id="phone"><div class="toast" id="toast"></div><div class="flash" id="flash"></div></div></div>
</div>
<script>window.__IMG = {imgs};</script>
<script>
{app}
</script>
"""
out = os.path.join(HERE, "muse-prototype.html")
open(out, "w").write(html)
js = html[html.rindex("<script>") + 8: html.rindex("</script>")]
open(os.path.join(HERE, "check_app.js"), "w").write(js)
print("ok", round(len(html) / 1024), "KB")

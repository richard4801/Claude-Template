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
textarea.inp{font:inherit;color:var(--ink);resize:none;width:100%;outline:none;line-height:1.45;user-select:text;-webkit-user-select:text}
textarea.inp:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
.pbox{border:var(--stroke) solid var(--line);border-radius:var(--r);background:var(--surface2);padding:10px 12px;display:flex;flex-direction:column;gap:6px;font-size:12.5px;line-height:1.4;max-height:190px;overflow:auto}
.pbox .pk{display:inline-block;min-width:68px;margin-right:6px;font-family:var(--mono);font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.slot .ref-img.shimmer{background:var(--surface2)}
"""
fonts = ("family=Instrument+Serif&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500"
         "&family=Barlow:wght@400;500;600;700&family=Barlow+Condensed:wght@500;600;700&family=JetBrains+Mono:wght@400;500;700"
         "&family=Outfit:wght@300;400;500;600;700&family=DM+Mono:wght@400;500"
         "&family=Bricolage+Grotesque:opsz,wght@12..96,700;12..96,800&family=Figtree:wght@400;500;600;700;800&family=Permanent+Marker")
app = open(os.path.join(HERE, "app.js")).read().replace("__ICONS__", json.dumps(gen.ICON))
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
    <div class="sp-row"><button data-side="sound">Sound</button></div>
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

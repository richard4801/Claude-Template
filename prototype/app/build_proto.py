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
.t-a .h2{display:inline-block;transform:scaleX(.62);transform-origin:left bottom;white-space:nowrap;font-size:50px;line-height:.95;text-transform:uppercase;font-weight:500}
.t-a .home-t{transform:none}
.t-a .stepnum{font-size:76px;line-height:.9;display:block;text-align:center}
.slider::before{content:"";position:absolute;left:0;right:0;top:-14px;bottom:-14px}
.t-a .ap-name{line-height:.86}
.t-a .feat-name{font-size:40px}
.t-a .count-n{font-size:72px}
.t-a .wm-md{font-size:56px}
.t-a .wm-xl{font-size:150px}
.view .screen .scroll{overflow:auto}
.t-c .tabbar.three .tb-i{width:70px}
"""
fonts = ("family=Bodoni+Moda:opsz,wght@6..96,400;6..96,500;6..96,600&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500"
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

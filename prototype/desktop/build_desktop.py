#!/usr/bin/env python3
"""Bundle the MUSE desktop (Mac) prototype into one self-contained HTML page.

Usage: build_desktop.py <imgs.json> <out.html> [desktop_thumbs.json]
Theme tokens and icons come from prototype/screens/gen.py, sounds from prototype/app/app.js.
imgs.json holds the base64 sample images and is kept out of git (some frames come from test footage).
"""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
imgs_path, out = sys.argv[1], sys.argv[2]
# gen.py reads imgs.json from its own folder, so import it from a folder that has both
gdir = os.path.dirname(os.path.abspath(imgs_path))
sys.path.insert(0, gdir if os.path.exists(os.path.join(gdir, "gen.py")) else os.path.join(ROOT, "screens"))
import gen  # THEMES (tokens) and ICON (paths)
imgs = json.load(open(imgs_path))
if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
    imgs.update(json.load(open(sys.argv[3])))

theme_vars = "\n".join(f".t-{k}{{{v['css']}}}" for k, v in gen.THEMES.items())
css = open(os.path.join(HERE, "desktop.css")).read()
phone_js = open(os.path.join(ROOT, "app", "app.js")).read()
sound = phone_js[phone_js.index("let AC = null;"): phone_js.index("const snd")] + "const snd = k => {};"
js = ((open(os.path.join(HERE, "desktop.js")).read() + "\n" + open(os.path.join(HERE, "features.js")).read())
      .replace("__ICONS__", json.dumps(gen.ICON))
      .replace("__SOUND__", sound))
fonts = ("family=Instrument+Serif&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500"
         "&family=Barlow:wght@400;500;600;700&family=Barlow+Condensed:wght@500;600;700&family=JetBrains+Mono:wght@400;500;700"
         "&family=Outfit:wght@300;400;500;600;700&family=DM+Mono:wght@400;500"
         "&family=Bricolage+Grotesque:opsz,wght@12..96,700;12..96,800&family=Figtree:wght@400;500;600;700;800&family=Permanent+Marker")
html = f"""<meta charset="utf-8">
<title>MUSE Desktop Prototype</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?{fonts}&display=swap">
<style>
{theme_vars}
{css}
@keyframes popin{{from{{opacity:0;transform:scale(.94)}}to{{opacity:1;transform:none}}}}
.pop{{animation:popin .4s cubic-bezier(.2,1.3,.4,1) both}}
</style>
<div class="stage"><div class="scaler" id="scaler"></div></div>
<script>window.__IMG = {json.dumps(imgs)};</script>
<script>
{js}
</script>
"""
open(out, "w").write(html)
print("ok", round(len(html) / 1024), "KB")

"""Build the review page (artifact) from the same frames: images as files, fonts from Google Fonts, page chrome theme-aware."""
import os, sys, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base
base.MODE['img'] = 'file'
import build

REVIEW_CSS = r"""
:root{--pg:#E4DED3;--fg:#141210;--mut:#5F584F;--rule:#C9C0B2;--acc:#B5121B;--card:#EFEAE1;--canvas:#E4DED3}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--pg:#121110;--fg:#ECE7DF;--mut:#A39C92;--rule:#34302B;--acc:#E5484F;--card:#1C1A18;--canvas:#121110;color-scheme:dark}}
:root[data-theme="dark"]{--pg:#121110;--fg:#ECE7DF;--mut:#A39C92;--rule:#34302B;--acc:#E5484F;--card:#1C1A18;--canvas:#121110;color-scheme:dark}
html,body{background:var(--pg)}
body{display:block;padding:0;gap:0;color:var(--fg);font-family:'Archivo',system-ui,sans-serif}
.rv{max-width:1880px;margin:0 auto;padding-block:28px 96px;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));display:flex;flex-direction:column;gap:56px}
.top{display:flex;flex-direction:column;gap:14px;max-width:980px}
.top .k{font:500 12px 'IBM Plex Mono',ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:var(--mut)}
.top h1{font:400 clamp(44px,8vw,104px)/.95 'Instrument Serif',Georgia,serif;text-wrap:balance}
.top p{font:400 17px/1.55 'Archivo',system-ui,sans-serif;color:var(--fg);max-width:68ch}
.status{border:1px solid var(--rule);background:var(--card);padding:14px 16px;display:flex;flex-direction:column;gap:6px;max-width:980px}
.status b{font:600 12px 'IBM Plex Mono',ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--acc)}
.status span{font:400 14.5px/1.5 'Archivo',system-ui,sans-serif;color:var(--fg)}
nav.toc{position:sticky;top:env(safe-area-inset-top,0px);z-index:5;background:var(--pg);border-block:1px solid var(--rule);display:flex;gap:4px 18px;flex-wrap:wrap;padding-block:10px}
nav.toc a{font:500 12px 'IBM Plex Mono',ui-monospace,monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--fg);text-decoration:none;padding:4px 0}
nav.toc a:hover,nav.toc a:focus-visible{color:var(--acc);outline:none;text-decoration:underline}
body::before{content:"";position:fixed;inset:0 0 auto;height:env(safe-area-inset-top,0px);z-index:10;background:var(--pg)}
section.pg{display:flex;flex-direction:column;gap:40px;scroll-margin-top:60px}
section.pg>header{display:flex;flex-direction:column;gap:10px;border-top:2px solid var(--fg);padding-top:18px;max-width:1100px}
section.pg>header .k{font:500 12px 'IBM Plex Mono',ui-monospace,monospace;letter-spacing:.12em;text-transform:uppercase;color:var(--mut)}
section.pg>header h2{font:400 clamp(36px,5vw,64px)/1 'Instrument Serif',Georgia,serif}
section.pg>header p{font:400 16px/1.55 'Archivo',system-ui,sans-serif;max-width:72ch}
.rb{display:grid;grid-template-columns:minmax(0,1fr) minmax(240px,320px);gap:24px 32px;align-items:start}
.rb-m{grid-template-columns:minmax(0,390px) minmax(240px,340px)}
.rb-d .sbx,.rb-l .sbx{max-width:1440px}
.rb .side{display:flex;flex-direction:column;gap:14px;min-width:0}
.rb .side .n{font:500 12px 'IBM Plex Mono',ui-monospace,monospace;letter-spacing:.12em;color:var(--mut)}
.rb .side .t{font:400 32px/1.05 'Instrument Serif',Georgia,serif}
.rb .side .cd{font:400 14.5px/1.5 'Archivo',system-ui,sans-serif;color:var(--fg)}
.rb .note{box-shadow:0 8px 20px rgba(0,0,0,.18)}
.sbx{position:relative;overflow:hidden;width:100%;min-width:0}
.sbx>.frame{transform-origin:0 0;position:absolute;left:0;top:0}
@media (max-width:1180px){.rb,.rb-m{grid-template-columns:minmax(0,1fr)}.rb-m .sbx{max-width:390px}}
@media (prefers-reduced-motion: reduce){*{scroll-behavior:auto}}
"""

JS = """<script>
(function(){
  function fit(){
    document.querySelectorAll('.sbx').forEach(function(b){
      var f=b.firstElementChild, w=+b.dataset.w, h=+b.dataset.h;
      var s=Math.min(1,b.clientWidth/w);
      f.style.transform='scale('+s+')'; b.style.height=Math.round(h*s)+'px';
    });
  }
  fit();
  if (window.ResizeObserver) { new ResizeObserver(fit).observe(document.body); } else { window.addEventListener('resize', fit); }
})();
</script>"""


def main():
    P = build.pages()
    secs, toc = [], []
    total = 0
    for name, slug, kicker, desc, boards in P:
        toc.append(f'<a href="#{slug}">{name}</a>')
        rows = []
        for num, title, d, frame, notes, *rest in boards:
            total += 1
            m = re.search(r'data-w="(\d+)" data-h="(\d+)"', frame)
            if m:
                w, h, kind = int(m.group(1)), int(m.group(2)), 'l'
            elif 'class="frame m' in frame:
                w, h, kind = 390, 844, 'm'
            else:
                w, h, kind = 1440, 900, 'd'
            ns = ''.join(base.note(*n) for n in notes)
            rows.append(f'<div class="rb rb-{kind}"><div class="sbx" data-w="{w}" data-h="{h}" style="height:{round(h*0.5)}px">{frame}</div>'
                        f'<div class="side"><span class="n">{num}</span><span class="t">{title}</span><span class="cd">{d}</span>{ns}</div></div>')
        secs.append(f'<section class="pg" id="{slug}"><header><span class="k">{kicker}</span><h2>{name}</h2><p>{desc}</p></header>{"".join(rows)}</section>')
    head = ('<div class="top"><span class="k">MUSE · design review · 5 Nov 2026</span><h1>Video &amp; Edit Suites</h1>'
            '<p>Our own Higgsfield-style AI video suite with a real camera bag, plus a CapCut-class editor. These are the designs to review before anything is built: '
            f'{total} screens across desktop (Mac, 1440 × 900) and phone (Android, 390 × 844) in MUSE’s Editorial theme, a dark Camera Body variant of the camera bag, '
            'and the 40-piece hardware library. Yellow notes explain how things behave.</p></div>'
            '<div class="status"><b>Figma status</b><span>The 40 hardware renders are already in the MUSE Figma file. The screens are built and waiting to go in: the Figma plan’s monthly MCP tool quota ran out mid-session, so the page push is queued for when it resets or the plan is upgraded.</span></div>')
    body = (f'<div class="rv">{head}<nav class="toc" aria-label="Pages">{"".join(toc)}</nav>{"".join(secs)}</div>{JS}')
    html = (f'<title>MUSE Video &amp; Edit Suites</title><meta name="claude:viewport-fit-sides" content="cover">'
            f'<style>{base.font_css()}\n{base.CSS}\n{REVIEW_CSS}</style>{body}')
    out = os.path.join(base.ROOT, 'build', 'review')
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'index.html'), 'w') as f:
        f.write(html)
    print('review', len(html) // 1024, 'KB', total, 'frames')


if __name__ == '__main__':
    main()

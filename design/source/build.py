"""Build Figma-ready HTML pages (one per Figma page), single-frame previews, and the review page.
Usage: python3 build.py [figma|preview|review|all] [frame-filter]"""
import os, sys, re, subprocess, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import base
from base import page_html, board, MODE

OUT = os.path.join(base.ROOT, 'build')


def pages():
    import ai_desktop as A
    import importlib
    P = []
    P.append(('AI Suite — Desktop', 'ai-suite-desktop', 'MUSE · AI Video Suite · Desktop (Mac, 1440 × 900, Theme A Editorial)',
              'Our Higgsfield: one suite for Shot, Character swap, Storyboard, Talking, UGC ads and Extend — sharing one Cast picker, one Camera control and one quality ladder. Members see Draft · Standard · HD · Cinema; engines are owner-only.', [
        ('D1', 'Suite hub', 'Modes, recent takes, Camera stage sessions, saved rigs and cast.', A.hub(), [
            ('Navigation', 'Video suite becomes a sidebar group (⌘3) with seven modes. Camera, Cast and Quality are shared components, so a rig or a directed session can be reused in any mode.'),
            ('Recent takes', 'Each thumbnail carries its live state (ready / rendering / queued / failed) — the same states as the result pane (D9).')]),
        ('D2', 'Shot builder', 'Cast → scene → references on the left, the 9:16 result in the middle, Camera + length + quality + live price on the right.', A.shot_builder(), [
            ('Live price', 'Price updates as length, quality and takes change; “Balance after” prevents surprises. Generate is the only black button on screen.'),
            ('Camera control', 'The compact Camera card shows the rig as real hardware photos. Click anywhere on it (or ⤢) to open the full camera bag (D3–D5). Preset / Directed is the same control.'),
            ('Rendering', 'The preview blurs while rendering and clears as % rises (“developing film”). Steps are named in plain words; members never see engine names.')]),
        ('D3', 'Camera · Preset · Rig (camera bag)', 'Bodies and lenses chosen by sight — photoreal hardware on a dark sweep, specs as captions.', A.camera_bag('a'), [
            ('Choosing by sight', 'Shelves scroll horizontally (trackpad / ← →). Click a body or lens to put it “in the bag”; the rig plate on the left re-composes body + lens. Hover lifts a card 2 px with a soft shadow.'),
            ('Specs', 'Captions use real model names as “look” references (e.g. “Alexa 35 look”) — never logos. Optics row: focal ruler, T-stop with a depth bar, shutter angle + fps.'),
            ('Presets', '“Start from” fills everything at once: Auto · Phone UGC · Vlog cam · Creator studio · Cinematic. Any change after that is remembered as “Custom”.')]),
        ('D3d', 'Camera bag · dark', 'The same screen in Theme B “Camera Body” — the hardware disappears into the dark like a rental-house shelf.', A.camera_bag('b'), [
            ('Dark theme', 'Theme B tokens (amber #F2A93B on #0D0E0F, Barlow Condensed). Selected gear glows amber; the dark sweep of the renders melts into the UI.')]),
        ('D4', 'Camera · Preset · Light & look', 'Lighting rigs, colour palettes (6 of 52), film/sensor and era.', A.light_look(), [
            ('Look preview', 'The preview on the left re-grades instantly from a cached keyframe of the current shot (no generation, no cost).'),
            ('Palettes', 'Each palette is shown on the same café scene so the difference is the grade, not the picture. “6 of 52” opens the full palette library.')]),
        ('D5', 'Camera · Preset · Move & angle', '16 moves as looping motion diagrams, mix up to two, intensity & speed, height and framing.', A.move_angle(), [
            ('Moves', 'Diagrams loop on hover (ghost cameras show the path). Pick up to 2 (numbered); the greybox preview plays the combination. UGC moves come first.'),
            ('Angle & framing', 'Camera height uses side-view pictograms; framing uses the silhouette cropped ECU → WIDE. Dutch 0–25°.')]),
        ('D6', 'Camera · Directed (Blender)', 'Full-clip previs: blocking plan with character paths, camera path & pans, keyframe timeline, and “Direct with Claude”.', A.directed(), [
            ('Same control, advanced mode', 'Directed is the second mode of the Camera control. Claude builds the shot in Blender on the owner’s Mac; the session id (cs_…) can also be opened from the owner’s own Claude app — both see the same transcript.'),
            ('Status', 'Three live rows: Claude session, Blender connection, renders. If the Mac is offline the chat queues and says so.'),
            ('Outputs', 'Greybox / depth / pose guides + start/mid/end keyframes come back into the chat and the plan. “Use for Shot 01” attaches them as the camera reference. Claude never spends — Generate stays the owner’s tap.')], 'blue'),
        ('D7', 'Character swap', 'Our existing swap, now a suite mode: source checks, who to replace, Draft/Standard/HD, add-ons, look-only camera.', A.swap(), [
            ('Camera in Swap', 'Motion comes from the source clip, so Camera shows “Follows the clip” and only the Look (lens character + palette) is editable.'),
            ('Ladder', 'Render: Draft · Standard (default) · HD. Add-ons: Edit · Fast (beta) · Upscale, each with its own price. Owner decides the Edit path (licence).')]),
        ('D8', 'Storyboard', 'Popcorn-style sequence: same cast and look lock across shots, per-shot camera, batch generate, assemble in Edit.', A.storyboard(), [
            ('Consistency', 'Cast + Look lock sit in the header and apply to every shot; each keyframe is made from the character sheet before video (“keyframe first”).'),
            ('Flow', 'Rewrite shot list → approve keyframes → Generate remaining shots → Assemble in Edit (drops the shots onto a timeline with captions ready).')]),
        ('D9', 'Owner view · Engines', 'Same Shot builder; the inspector swaps to an owner-only Engines drawer with routing, compiled camera prompt and flags.', A.shot_builder(owner=True), [
            ('Owner only', 'Engine names, provider cost and licence flags appear only here. Members see the tier ladder in D2.')]),
        ('D10', 'Result states', 'Empty, queued, rendering, ready, failed — one pane everywhere.', A.states(), []),
    ]))
    for mod, key in [('ai_mobile', 'AI Suite — Mobile'), ('edit_desktop', 'Edit Suite — Desktop'), ('edit_mobile', 'Edit Suite — Mobile'), ('library', 'Hardware Library')]:
        try:
            m = importlib.import_module(mod)
            P.append(m.page())
        except ModuleNotFoundError:
            pass
    return P


def render_page(p):
    name, slug, kicker, desc, boards = p
    bs = ''.join(board(frame, notes, num, title, d) for num, title, d, frame, notes, *rest in boards)
    head = f'<div class="pagehead"><span class="k">{kicker}</span><h1>{name}</h1><p>{desc}</p></div>'
    return page_html(name, head + f'<div class="boards">{bs}</div>')


def frame_only(frame, w, h):
    css = base.CSS + 'body{padding:0;gap:0;background:#fff}.frame{box-shadow:none}'
    return (f"<!doctype html><html><head><meta charset='utf-8'><title>f</title><style>{base.font_css()}\n{css}</style></head><body>{frame}</body></html>")


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else 'all'
    flt = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(f'{OUT}/figma', exist_ok=True)
    os.makedirs(f'{OUT}/preview', exist_ok=True)
    P = pages()
    if what in ('figma', 'all'):
        for p in P:
            html = render_page(p)
            with open(f'{OUT}/figma/{p[1]}.html', 'w') as f:
                f.write(html)
            print('page', p[1], len(html) // 1024, 'KB', len(p[4]), 'boards')
    if what in ('preview', 'all'):
        for p in P:
            for num, title, d, frame, notes, *rest in p[4]:
                fid = f'{p[1]}__{num}'
                if flt and not re.search(flt, fid):
                    continue
                m = re.search(r'class="frame (d|m)', frame)
                w, h = (1440, 900) if m and m.group(1) == 'd' else (390, 844)
                mw = re.search(r'data-w="(\d+)" data-h="(\d+)"', frame)
                if mw:
                    w, h = int(mw.group(1)), int(mw.group(2))
                path = f'{OUT}/preview/{fid}.html'
                with open(path, 'w') as f:
                    f.write(frame_only(frame, w, h))
                png = f'{OUT}/preview/{fid}.png'
                subprocess.run(['google-chrome', '--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                                f'--window-size={w},{h}', f'--screenshot={png}', 'file://' + path], capture_output=True, timeout=120)
                print('shot', fid, os.path.exists(png))


if __name__ == '__main__':
    main()

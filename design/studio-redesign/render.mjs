// Renders the Video Studio (Suite) redesign mockups for the owner (plans/studio-redesign.md).
// Camera Body (B, dark) tokens from plans/design-direction.md, Barlow, Phosphor Regular, the Blender preview stills.
//   node design/studio-redesign/render.mjs      -> design/studio-redesign/*.png
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const PV = (p) => pathToFileURL(path.join(REPO, 'design/previews', p)).href;
const FONT = (f) => pathToFileURL(path.join(REPO, 'android/app/src/main/res/font', f + '.ttf')).href;
const ic = (name, size = 16, color = 'currentColor') =>
  readFileSync(path.join(REPO, 'design/icons/phosphor', name + '.svg'), 'utf8')
    .replace('<svg ', `<svg width="${size}" height="${size}" style="color:${color};flex:none;display:block" aria-hidden="true" `);

const CSS = `
@font-face{font-family:Barlow;src:url(${FONT('barlow_400')});font-weight:400}
@font-face{font-family:Barlow;src:url(${FONT('barlow_500')});font-weight:500}
@font-face{font-family:Barlow;src:url(${FONT('barlow_600')});font-weight:600}
:root{--canvas:#0D0E0F;--raised:#17191B;--field:#212427;--ink:#ECEAE5;--ink2:#A9A6A0;--hair:#2C3033;--accent:#F2A93B;--action:#F2A93B;--onaction:#1A1205;--side:#111214;--rc:14px;--rk:10px;--rp:8px}
*{box-sizing:border-box;margin:0;padding:0}
body{background:#000;color:var(--ink);font:400 15px/21px Barlow,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased;overflow:hidden}
.row{display:flex;align-items:center}.col{display:flex;flex-direction:column}.grow{flex:1;min-width:0}
.title{font:600 20px/26px Barlow}.heading{font:600 16px/22px Barlow}.body{font:400 15px/21px Barlow}.label{font:500 14px/18px Barlow}
.cap{font:400 13px/18px Barlow;color:var(--ink2)}.micro{font:500 11px/14px Barlow}
.win{position:relative;background:var(--canvas);border-radius:10px;overflow:hidden;display:flex;flex-direction:column}
.tbar{height:38px;flex:none;display:flex;align-items:center;padding:0 14px;gap:8px;border-bottom:1px solid var(--hair);background:var(--side)}
.dot{width:12px;height:12px;border-radius:50%}
.side{background:var(--side);border-right:1px solid var(--hair);flex:none;padding:12px 10px;display:flex;flex-direction:column;gap:2px}
.nav{height:32px;display:flex;align-items:center;gap:10px;padding:0 10px;border-radius:var(--rp);color:var(--ink2);font:500 14px/18px Barlow}
.nav.on{background:var(--field);color:var(--ink)}
.quiet{height:28px;display:flex;align-items:center;gap:6px;padding:0 10px;border-radius:var(--rp);color:var(--ink2);font:500 13px/18px Barlow;white-space:nowrap}
.quiet.on{color:var(--ink);background:var(--field)}
.pill{height:28px;display:flex;align-items:center;gap:6px;padding:0 10px;border-radius:var(--rp);background:var(--field);color:var(--ink);font:500 13px/18px Barlow;white-space:nowrap}
.pill .k{color:var(--ink2)}
.go{height:36px;padding:0 18px;border-radius:var(--rk);background:var(--action);color:var(--onaction);font:600 14px/18px Barlow;display:flex;align-items:center;white-space:nowrap}
.media{border-radius:var(--rc);overflow:hidden;background:var(--field);position:relative}
.media img{width:100%;height:100%;object-fit:cover;display:block}
.sec{display:flex;align-items:center;gap:6px;height:28px;font:600 14px/18px Barlow}
.sec .sum{margin-left:auto;font:400 13px/18px Barlow;color:var(--ink2)}
.srow{height:32px;display:flex;align-items:center;gap:10px;font:400 13px/18px Barlow;padding:0 8px;margin:0 -8px;border-radius:var(--rp)}
.srow .k{color:var(--ink2);width:72px;flex:none}.srow .v{flex:1;min-width:0;text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.srow .v.auto{color:var(--ink2)}
.tile{width:56px;height:56px;border-radius:var(--rp);overflow:hidden;flex:none;background:var(--field)}
.tile img{width:100%;height:100%;object-fit:cover;display:block}
.empty{border:1px dashed #5b5955;background:transparent;display:grid;place-items:center;color:var(--ink2)}
.chip{display:inline-flex;align-items:center;gap:3px;height:24px;padding:0 7px 0 3px;border-radius:var(--rp);background:var(--field);border:1px solid var(--hair);font:600 13px/18px Barlow;vertical-align:-5px;margin:0 1px}
.chip .av{width:18px;height:18px;border-radius:50%;overflow:hidden}.chip .av img{width:100%;height:100%;object-fit:cover}
.chip .mv{width:18px;height:18px;border-radius:4px;background:var(--ink);display:grid;place-items:center}
.chip .sg{color:var(--accent);font-weight:500}
.ibtn{width:28px;height:28px;display:grid;place-items:center;color:var(--ink2);border-radius:var(--rp)}
.strip img{width:100%;height:100%;object-fit:cover;display:block}
.sel{outline:2px solid var(--accent);outline-offset:2px}
.note{position:absolute;background:#2a2410;color:#F2C14E;border:1px solid #5a4a1a;border-radius:6px;font:500 12px/16px Barlow;padding:5px 8px;max-width:220px;z-index:50}
.badge{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;border-radius:9px;background:#F2A93B;color:#1A1205;font:700 11px Barlow;position:absolute}
`;

// ------------------------------------------------------------------ parts
const ZEL = 'angles/mcu.webp';
const chipAt = (name) => `<span class="chip"><span class="av"><img src="${PV(ZEL)}"></span><span class="sg">@</span>${name}</span>`;
const chipMv = (name) => `<span class="chip"><span class="mv">${ic('arrows-out-cardinal', 12, '#17191B')}</span><span class="sg">#</span>${name}</span>`;

function titlebar(w) {
  return `<div class="tbar"><div class="dot" style="background:#FF5F57"></div><div class="dot" style="background:#FEBC2E"></div><div class="dot" style="background:#28C840"></div>
  <div class="grow" style="text-align:center;font:600 13px Barlow;color:var(--ink2)">MUSE</div><div style="width:52px"></div></div>`;
}

function sidebar(compact) {
  const items = [['house', 'Home'], ['video-camera', 'Suite', 1], ['scissors', 'Edit'], ['squares-four', 'Library'], ['users-three', 'Cast'], ['stack', 'Queue'], ['sliders-horizontal', 'Settings']];
  if (compact) {
    return `<div class="side" style="width:56px;align-items:center;padding:12px 0">${items.map(([i, , on]) =>
      `<div class="nav ${on ? 'on' : ''}" style="width:36px;height:36px;padding:0;justify-content:center">${ic(i, 20)}</div>`).join('')}</div>`;
  }
  return `<div class="side" style="width:200px">${items.map(([i, l, on]) => `<div class="nav ${on ? 'on' : ''}">${ic(i, 18)}${l}</div>`).join('')}
   <div class="grow"></div><div class="cap" style="padding:0 10px">Wallet $41.20</div></div>`;
}

function header(tool, { compact = false, setupToggle = false, takes = 12, presets = true, active = '' } = {}) {
  return `<div class="row" style="height:40px;gap:4px;flex:none">
    <div class="row" style="gap:6px"><div class="title">${tool}</div>${ic('caret-down', 14, 'var(--ink2)')}</div>
    <div class="grow"></div>
    ${presets ? `<div class="quiet ${active === 'presets' ? 'on' : ''}">Presets</div>` : ''}
    <div class="quiet ${active === 'takes' ? 'on' : ''}">Takes <span style="color:var(--ink2)">${takes}</span></div>
    ${setupToggle ? `<div class="quiet">${ic('sidebar-simple', 16)}${compact ? '' : 'Setup'}</div>` : ''}
  </div>`;
}

// The viewer: aspect-fitted, capped height, its own quiet actions underneath; the takes strip next to them.
function viewer({ img, w, h, label = 'Take 3', meta = '8 s · 16:9', strip = true, playing = true }) {
  const thumbs = ['lighting/golden_hour.webp', 'genres/romance.jpg', img, 'lighting/window.webp'].slice(0, 4);
  return `<div class="col" style="gap:10px;align-items:center">
    <div class="media" style="width:${w}px;height:${h}px"><img src="${PV(img)}">
      ${playing ? `<div style="position:absolute;left:0;right:0;bottom:0;height:40px;background:linear-gradient(transparent,rgba(0,0,0,.55));display:flex;align-items:center;gap:10px;padding:0 12px;color:#fff">
        ${ic('play', 16, '#fff')}<div style="flex:1;height:3px;border-radius:2px;background:rgba(255,255,255,.3)"><div style="width:38%;height:100%;background:#fff;border-radius:2px"></div></div><div class="micro">0:03 / 0:08</div></div>` : ''}
    </div>
    <div class="row" style="width:${w}px;gap:8px">
      <div class="label">${label}</div><div class="cap">${meta}</div><div class="grow"></div>
      <div class="ibtn" title="Download">${ic('download-simple', 16)}</div>
      <div class="ibtn">${ic('scissors', 16)}</div>
      <div class="ibtn">${ic('arrow-counter-clockwise', 16)}</div>
      <div class="ibtn">${ic('dots-three', 16)}</div>
    </div>
    ${strip ? `<div class="row strip" style="width:${w}px;gap:8px">${thumbs.map((t, i) =>
      `<div class="media ${i === 2 ? 'sel' : ''}" style="width:72px;height:40px;border-radius:6px">${`<img src="${PV(t)}">`}</div>`).join('')}
      <div class="media" style="width:72px;height:40px;border-radius:6px;display:grid;place-items:center;background:var(--raised)"><div class="micro" style="color:var(--ink2)">Rendering 64%</div></div>
      <div class="grow"></div><div class="cap">4 takes</div></div>` : ''}
  </div>`;
}

const ROWS = [['Camera', '35 mm film, anamorphic'], ['Light', 'Golden hour'], ['Look', 'Auto'], ['Style', 'Auto'], ['Move', 'Dolly in, slow']];

function inspector({ w = 280, setupOpen = true, inputsOpen = true, rows = ROWS, inputs = null, setupNote = null, extra = '' }) {
  const set = rows.filter(([, v]) => v !== 'Auto').length;
  const setup = setupNote ? `<div class="cap" style="padding:4px 0 0">${setupNote}</div>` : (setupOpen ? rows.map(([k, v]) =>
    `<div class="srow"><div class="k">${k}</div><div class="v ${v === 'Auto' ? 'auto' : ''}">${v}</div>${ic('caret-right', 12, 'var(--ink2)')}</div>`).join('') : '');
  const ins = inputs || [['Character', ZEL, 'Zelphira'], ['Start frame', null, ''], ['End frame', null, 'Optional']];
  return `<div class="col" style="width:${w}px;flex:none;gap:4px">
    <div class="sec">${ic(setupOpen ? 'caret-down' : 'caret-right', 12, 'var(--ink2)')}Setup<span class="sum">${setupNote ? '' : `${set} set, ${rows.length - set} on Auto`}</span>${ic('dots-three', 16, 'var(--ink2)')}</div>
    ${setup}
    <div style="height:16px"></div>
    <div class="sec">${ic(inputsOpen ? 'caret-down' : 'caret-right', 12, 'var(--ink2)')}Inputs<span class="sum">${ins.filter(i => i[1]).length} of ${ins.length}</span></div>
    ${inputsOpen ? `<div class="row" style="gap:10px;align-items:flex-start;padding-top:6px">${ins.map(([n, src, sub]) =>
      `<div style="width:62px">${src ? `<div class="tile"><img src="${PV(src)}"></div>` : `<div class="tile empty">${ic('plus', 16)}</div>`}
       <div class="micro" style="margin-top:6px;color:${src ? 'var(--ink)' : 'var(--ink2)'}">${n}</div><div class="micro" style="font-weight:400;color:var(--ink2)">${sub}</div></div>`).join('')}</div>
      <div class="srow" style="margin-top:6px"><div class="k">References</div><div class="v auto">None</div>${ic('plus', 12, 'var(--ink2)')}</div>` : ''}
    ${extra}
  </div>`;
}

const PROMPT_SHORT = `${chipAt('Zelphira')} walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile. ${chipMv('Dolly in')}`;
const PROMPT_LONG = `${chipAt('Zelphira')} walks into a quiet café at golden hour, warm light spilling across the counter. She orders, waits, and taps her fingers on the wood while the barista works. Steam rises from the cup as it lands in front of her. She lifts it, takes a slow sip, then turns to camera with a soft, knowing smile. ${chipMv('Dolly in')} The background stays soft and busy, people passing behind her out of focus.`;

function composer({ prompt = PROMPT_SHORT, lines = 2, pills = null, price = '$0.64', go = 'Generate' }) {
  const ph = 21 * lines + 8;
  const ps = pills || [['', 'Kling 2.1'], ['', 'HD'], ['', '16:9'], ['', '8 s'], ['', '1 take'], ['icon', 'speaker-high']];
  return `<div style="background:var(--raised);border-radius:var(--rk);padding:12px 12px 10px 16px;flex:none">
    <div class="row" style="align-items:flex-start;gap:8px">
      <div class="grow body" style="height:${ph}px;overflow:hidden;line-height:21px;padding-top:4px">${prompt}</div>
      <div class="ibtn" title="Open the prompt in a larger editor">${ic('arrows-out', 16)}</div>
    </div>
    <div class="row" style="gap:6px;margin-top:10px">
      ${ps.map(([k, v]) => k === 'icon' ? `<div class="pill" style="padding:0 7px">${ic(v, 16)}</div>` : `<div class="pill">${k ? `<span class="k">${k}</span>` : ''}${v}</div>`).join('')}
      <div class="grow"></div><div class="quiet" style="padding:0 4px">${ic('question', 16)}</div>
      <div class="go">${go} · ${price}</div>
    </div>
  </div>`;
}

function claudePanel(h) {
  return `<div class="col" style="width:380px;flex:none;border-left:1px solid var(--hair);background:var(--raised);height:100%">
    <div class="row" style="height:48px;padding:0 12px 0 16px;gap:8px;border-bottom:1px solid var(--hair)">
      <div class="heading">Claude</div><div class="pill" style="height:24px">Opus</div><div class="grow"></div>
      <div class="ibtn">${ic('plus', 16)}</div><div class="ibtn">${ic('clock-counter-clockwise', 16)}</div><div class="ibtn">${ic('x', 16)}</div></div>
    <div class="col grow" style="padding:16px;gap:14px;overflow:hidden">
      <div style="align-self:flex-end;max-width:280px;background:var(--field);border-radius:12px;padding:8px 12px" class="body">Make it warmer and slower, and keep her face sharp.</div>
      <div class="body" style="color:var(--ink)">I set Light to <b style="font-weight:600">Golden hour</b> and the move to a slow dolly in, and added her front face as the start frame so her face stays locked.</div>
      <div class="cap">Changed in Setup: Light, Move. Inputs: Start frame.</div>
      <div class="row" style="gap:8px"><div class="pill">Undo changes</div></div>
      <div class="body">The price stays $0.64. Press Generate when you're happy with the prompt.</div>
    </div>
    <div style="padding:12px;border-top:1px solid var(--hair)"><div class="row" style="background:var(--field);border-radius:var(--rk);padding:10px 12px;gap:8px">
      <div class="grow cap">Ask Claude</div>${ic('paperclip', 16, 'var(--ink2)')}${ic('paper-plane-right', 16, 'var(--ink2)')}</div></div>
  </div>`;
}

function win(W, H, inner) {
  return `<!doctype html><meta charset="utf-8"><style>${CSS}</style><body style="width:${W}px;height:${H}px;padding:0">
  <div class="win" style="width:${W}px;height:${H}px">${titlebar(W)}<div class="row grow" style="align-items:stretch;min-height:0">${inner}</div></div></body>`;
}

// One page body: header, then [stage | inspector], then the composer; padding 24.
function page({ tool, stage, insp, comp, hdr = {}, gap = 24 }) {
  return `<div class="col grow" style="padding:16px 24px 20px;gap:16px;min-width:0">
    ${header(tool, hdr)}
    <div class="row grow" style="align-items:flex-start;gap:${gap}px;min-height:0">
      <div class="col grow" style="align-items:center;justify-content:center;min-width:0;align-self:stretch">${stage}</div>
      ${insp}
    </div>
    ${comp}
  </div>`;
}

// ------------------------------------------------------------------ screens
const S = {};

// 1. Shot, MacBook Pro 14" (1512 x 982), Claude closed.
S['01-shot-14in'] = win(1512, 982, sidebar(false) + page({
  tool: 'Shot',
  stage: viewer({ img: 'genres/romance.jpg', w: 784, h: 441 }),
  insp: inspector({}),
  comp: composer({}),
}));

// 2. The same with the Claude panel open: the sidebar becomes the icon rail, Setup folds to its summary.
S['02-shot-claude-open'] = win(1512, 982, sidebar(true) + page({
  tool: 'Shot',
  stage: viewer({ img: 'genres/romance.jpg', w: 656, h: 369 }),
  insp: inspector({ w: 264, setupOpen: true, rows: ROWS, inputs: [['Character', ZEL, 'Zelphira'], ['Start frame', 'angles/cu.webp', 'Her face'], ['End frame', null, 'Optional']] }),
  comp: composer({}),
  hdr: { setupToggle: true },
}) + claudePanel(982));

// 3. Smaller window (MacBook Air 13" at 1280 x 800) with Claude open: Setup becomes a row of chips over the prompt,
// the prompt has grown to 5 lines (grows upward, the picture gives up height).
const chipsRow = `<div class="row" style="gap:6px;flex-wrap:nowrap;overflow:hidden">
  ${[['Camera', '35 mm film'], ['Light', 'Golden hour'], ['Look', 'Auto'], ['Style', 'Auto'], ['Move', 'Dolly in']].map(([k, v]) =>
    `<div class="pill"><span class="k">${k}</span>${v === 'Auto' ? `<span style="color:var(--ink2)">${v}</span>` : v}${ic('caret-down', 12, 'var(--ink2)')}</div>`).join('')}
  <div class="grow"></div>
  <div class="row" style="gap:6px">${['angles/mcu.webp', 'angles/cu.webp'].map(s => `<div class="tile" style="width:28px;height:28px;border-radius:6px"><img src="${PV(s)}"></div>`).join('')}
  <div class="tile empty" style="width:28px;height:28px;border-radius:6px">${ic('plus', 12)}</div></div></div>`;
S['03-small-window-claude-open'] = win(1280, 800, sidebar(true) + `<div class="col grow" style="padding:14px 20px 16px;gap:12px;min-width:0">
    ${header('Shot', { compact: true, setupToggle: true })}
    <div class="col grow" style="align-items:center;min-height:0">${viewer({ img: 'genres/romance.jpg', w: 472, h: 266, strip: false })}</div>
    ${chipsRow}
    ${composer({ prompt: PROMPT_LONG, lines: 5, pills: [['', 'Kling 2.1'], ['', 'HD'], ['', '16:9 · 8 s'], ['icon', 'speaker-high']] })}
  </div>` + claudePanel(800));

// 4. The same frame for every tool: Photo, Talking, Swap, Extend (each a 1512 x 982 window at half size).
const tools = {
  Photo: page({ tool: 'Photo', hdr: { takes: 24 },
    stage: `<div class="col" style="gap:10px;align-items:center"><div class="row" style="gap:8px">${['angles/ms.webp', 'angles/cowboy.webp', 'angles/mcu.webp', 'angles/full.webp'].map((s, i) =>
      `<div class="media ${i === 0 ? 'sel' : ''}" style="width:186px;height:248px"><img src="${PV(s)}"></div>`).join('')}</div>
      <div class="row" style="width:768px;gap:8px"><div class="label">4 photos</div><div class="cap">3:4</div><div class="grow"></div><div class="ibtn">${ic('download-simple', 16)}</div><div class="ibtn">${ic('dots-three', 16)}</div></div></div>`,
    insp: inspector({ rows: [['Camera', '85 mm portrait'], ['Light', 'Window'], ['Look', 'Auto'], ['Style', 'Editorial']], inputs: [['Character', ZEL, 'Zelphira'], ['Outfit', 'angles/full.webp', 'Linen set'], ['Pose', null, 'Optional']] }),
    comp: composer({ prompt: `${chipAt('Zelphira')} seated by a tall window, linen set, relaxed hands, soft morning light on her face.`, pills: [['', 'HD'], ['', '3:4'], ['', '4 photos']], price: '$0.32' }) }),
  Talking: page({ tool: 'Talking', hdr: { presets: false, takes: 5 },
    stage: viewer({ img: 'angles/mcu.webp', w: 784, h: 441, meta: '12 s · 16:9' }),
    insp: inspector({ rows: [['Camera', 'Auto'], ['Light', 'Natural'], ['Look', 'Auto']], inputs: [['Character', ZEL, 'Zelphira'], ['Voice', null, 'Audio or text'], ['Start frame', null, 'Optional']] }),
    comp: composer({ prompt: `${chipAt('Zelphira')} talks to camera, warm and direct: "Three things I wish I knew before my first shoot."`, pills: [['', 'HD'], ['', '16:9'], ['', '12 s'], ['icon', 'microphone']], price: '$0.90' }) }),
  Swap: page({ tool: 'Character swap', hdr: { presets: false, takes: 3 },
    stage: viewer({ img: 'genres/music_video.jpg', w: 784, h: 441, label: 'Your clip', meta: '9 s · 16:9' }),
    insp: inspector({ setupNote: 'Camera, light and style come from your clip.', inputs: [['Clip', 'genres/music_video.jpg', '9 s'], ['Character', ZEL, 'Zelphira'], ['Outfit', 'angles/full.webp', 'Linen set']] }),
    comp: composer({ prompt: `<span style="color:var(--ink2)">Your character takes over the clip: its motion, camera, framing and cuts stay as they are.</span>`, pills: [['', 'Standard'], ['', 'Keep sound']], price: '$1.35' }) }),
  Extend: page({ tool: 'Extend', hdr: { presets: false, takes: 2 },
    stage: viewer({ img: 'lighting/golden_hour.webp', w: 784, h: 441, label: 'Take 3', meta: '8 s, adds 5 s' }),
    insp: inspector({ setupNote: 'Continues the take with its own camera and light.', inputs: [['Take', 'lighting/golden_hour.webp', 'Take 3'], ['End frame', null, 'Optional']],
      extra: `<div style="height:16px"></div><div class="sec">Direction</div><div class="row" style="gap:6px;padding-top:6px"><div class="pill" style="outline:1px solid var(--accent)">Forward</div><div class="pill">Backward</div></div>` }),
    comp: composer({ prompt: 'She sets the cup down, stands and walks out into the street.', pills: [['', 'HD'], ['', '+5 s']], price: '$0.40' }) }),
};
const quarter = (name, body) => `<div class="col" style="gap:10px"><div class="label" style="color:var(--ink2)">${name}</div>
  <div style="width:756px;height:491px;overflow:hidden;border-radius:10px"><div style="width:1512px;height:982px;transform:scale(.5);transform-origin:0 0">
  <div class="win" style="width:1512px;height:982px">${titlebar()}<div class="row grow" style="align-items:stretch;min-height:0">${sidebar(false)}${body}</div></div></div></div></div>`;
S['04-every-tool-same-frame'] = `<!doctype html><meta charset="utf-8"><style>${CSS}</style><body style="width:1560px;height:1100px;background:#08090A;padding:24px">
  <div style="display:grid;grid-template-columns:756px 756px;gap:24px 0;justify-content:space-between">${Object.entries(tools).map(([n, b]) => quarter(n, b)).join('')}</div></body>`;

// 5. Takes: the stage becomes a grid; the right column shows the chosen take's settings with one action.
const takesGrid = `<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:16px;width:100%">${[
  ['genres/romance.jpg', 'Take 3', '8 s · 16:9', 1], ['lighting/golden_hour.webp', 'Take 2', '8 s · 16:9'], ['lighting/window.webp', 'Take 1', '8 s · 16:9'],
  ['genres/music_video.jpg', 'Swap 1', '9 s · 16:9'], ['angles/ms.webp', 'Photo 4', '3:4'], ['angles/cowboy.webp', 'Photo 3', '3:4'],
  ['genres/drama.jpg', 'Take 2', '6 s · 9:16'], ['genres/fashion.jpg', 'Take 1', '6 s · 9:16'], ['genres/noir.jpg', 'Take 4', '8 s · 16:9'],
  ['lighting/neon.webp', 'Take 3', '8 s · 16:9'], ['angles/full.webp', 'Photo 2', '3:4'], ['lighting/candle.webp', 'Take 1', '5 s · 16:9']].map(([s, n, m, sel]) =>
  `<div><div class="media ${sel ? 'sel' : ''}" style="aspect-ratio:16/10"><img src="${PV(s)}"></div><div class="row" style="margin-top:8px;gap:8px"><div class="label">${n}</div><div class="cap">${m}</div></div></div>`).join('')}</div>`;
const takeInfo = `<div class="col" style="width:280px;flex:none;gap:4px">
  <div class="sec">Take 3<span class="sum">Today 14:02</span></div>
  ${[['Model', 'Kling 2.1'], ['Quality', 'HD'], ['Camera', '35 mm film, anamorphic'], ['Light', 'Golden hour'], ['Move', 'Dolly in, slow'], ['Cost', '$0.64']].map(([k, v]) =>
    `<div class="srow"><div class="k">${k}</div><div class="v">${v}</div></div>`).join('')}
  <div class="cap" style="margin-top:8px">${chipAt('Zelphira')} walks into a quiet café at golden hour, orders at the counter, then turns to camera…</div>
  <div class="row" style="gap:8px;margin-top:16px"><div class="pill">Reuse settings</div><div class="pill">${ic('scissors', 14)}Open in Edit</div></div>
</div>`;
S['05-takes'] = win(1512, 982, sidebar(false) + `<div class="col grow" style="padding:16px 24px 20px;gap:16px;min-width:0">
  ${header('Shot', { active: 'takes', takes: 12 })}
  <div class="row" style="gap:6px"><div class="quiet on">All tools</div><div class="quiet">Shot</div><div class="quiet">Photo</div><div class="quiet">Swap</div><div class="grow"></div><div class="quiet">Newest first ${ic('caret-down', 12)}</div></div>
  <div class="row grow" style="align-items:flex-start;gap:24px;min-height:0">${takesGrid}${takeInfo}</div>
  ${composer({})}
</div>`);

// ------------------------------------------------------------------ render
const browser = await chromium.launch();
const ctx = await browser.newContext({ deviceScaleFactor: Number(process.env.SCALE || 2) });
for (const [name, html] of Object.entries(S)) {
  const file = path.join(HERE, `.${name}.html`);
  writeFileSync(file, html);
  const p = await ctx.newPage();
  const m = html.match(/<body style="width:(\d+)px;height:(\d+)px/);
  await p.setViewportSize({ width: +m[1], height: +m[2] });
  await p.goto(pathToFileURL(file).href);
  await p.waitForTimeout(300);
  await p.screenshot({ path: path.join(HERE, `${name}.png`) });
  await p.close();
  console.log('wrote', name);
}
await browser.close();

// Builds the Edit template-library mockups (plans/edit-templates.md §5) as HTML and screenshots them with Playwright.
// Run: node plans/design/edit-templates/src/build.mjs   (uses the repo's fonts and Phosphor icons; no network)
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire('/home/user/Claude-Template/server/api/package.json');
const { chromium } = require('playwright');

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../../..');
const out = path.resolve(here, '..');
const fontDir = `file://${root}/mac/Muse/Resources/Fonts`;
const img = n => `file://${here}/${n}.png`;
const icon = (n, size = 20) => fs.readFileSync(`${root}/design/icons/phosphor/${n}.svg`, 'utf8')
  .replace('<svg ', `<svg width="${size}" height="${size}" class="ic" `);

const THEMES = {
  A: { canvas: '#EFEBE3', raised: '#F8F5EF', field: '#E7E1D6', ink: '#141210', ink2: '#67605A', hairline: '#CFC7BA', accent: '#B5121B',
    action: '#141210', onAction: '#F8F5EF', caution: '#8A5200', positive: '#2F6B3A', display: 'Instrument Serif', text: 'Archivo', rC: 4, rK: 2, rP: 2 },
  B: { canvas: '#0D0E0F', raised: '#17191B', field: '#212427', ink: '#ECEAE5', ink2: '#A9A6A0', hairline: '#2C3033', accent: '#F2A93B',
    action: '#F2A93B', onAction: '#1A1205', caution: '#F2C14E', positive: '#7BD88F', display: 'Barlow Condensed', text: 'Barlow', rC: 14, rK: 10, rP: 8 },
};

const css = t => `
@font-face{font-family:'Archivo';src:url('${fontDir}/Archivo-VF.ttf');font-weight:100 900}
@font-face{font-family:'Instrument Serif';src:url('${fontDir}/InstrumentSerif-Regular.ttf')}
@font-face{font-family:'Barlow';src:url('${fontDir}/Barlow-Regular.ttf');font-weight:400}
@font-face{font-family:'Barlow';src:url('${fontDir}/Barlow-Medium.ttf');font-weight:500}
@font-face{font-family:'Barlow';src:url('${fontDir}/Barlow-SemiBold.ttf');font-weight:600}
@font-face{font-family:'Barlow Condensed';src:url('${fontDir}/BarlowCondensed-SemiBold.ttf');font-weight:600}
:root{--canvas:${t.canvas};--raised:${t.raised};--field:${t.field};--ink:${t.ink};--ink2:${t.ink2};--hair:${t.hairline};--accent:${t.accent};
--action:${t.action};--onAction:${t.onAction};--caution:${t.caution};--positive:${t.positive};--rC:${t.rC}px;--rK:${t.rK}px;--rP:${t.rP}px}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--canvas);color:var(--ink);font:400 15px/21px '${t.text}';-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
.ic{color:currentColor;flex:none}
.display{font:400 28px/32px '${t.display}';${t.display.includes('Barlow') ? 'font-weight:600;' : ''}}
.title{font:600 20px/26px '${t.text}'} .heading{font:600 16px/22px '${t.text}'} .label{font:500 14px/18px '${t.text}'}
.caption{font:400 13px/18px '${t.text}';color:var(--ink2)} .micro{font:500 11px/14px '${t.text}'}
.row{display:flex;align-items:center} .col{display:flex;flex-direction:column} .grow{flex:1} .muted{color:var(--ink2)}
.btn{display:inline-flex;align-items:center;gap:8px;height:36px;padding:0 14px;border-radius:var(--rK);font:500 14px/18px '${t.text}';color:var(--ink);background:var(--field);border:0;white-space:nowrap}
.btn.ghost{background:transparent} .btn.primary{background:var(--action);color:var(--onAction)} .btn.big{height:44px;padding:0 18px}
.seg{display:inline-flex;background:var(--field);border-radius:var(--rK);padding:3px;gap:2px}
.seg span{padding:6px 12px;border-radius:calc(var(--rK) - 1px);font:500 14px/18px '${t.text}';color:var(--ink2);white-space:nowrap}
.seg span.on{background:var(--raised);color:var(--ink)}
.chip{flex:none;display:inline-flex;align-items:center;gap:6px;height:32px;padding:0 12px;border-radius:var(--rP);background:var(--field);font:500 14px/18px '${t.text}';color:var(--ink2);white-space:nowrap}
.chip.on{background:var(--ink);color:var(--canvas)}
.media{position:relative;overflow:hidden;background:var(--field);border-radius:var(--rC)}
.media img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.sel{outline:2px solid var(--accent);outline-offset:2px}
.slider{height:4px;border-radius:2px;background:var(--field);position:relative}
.slider i{position:absolute;left:0;top:0;bottom:0;background:var(--ink);border-radius:2px}
.slider b{position:absolute;top:-6px;width:16px;height:16px;border-radius:50%;background:var(--raised);border:2px solid var(--ink)}
.toggle{width:36px;height:20px;border-radius:10px;background:var(--field);position:relative;flex:none}
.toggle.on{background:var(--ink)} .toggle::after{content:'';position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--raised)}
.toggle.on::after{left:18px}
.hr{height:1px;background:var(--hair)}
.field{height:36px;border-radius:var(--rK);background:var(--field);display:flex;align-items:center;gap:8px;padding:0 12px;color:var(--ink2);font:400 14px/18px '${t.text}'}
`;

// ---------- the template previews (what each tile shows) ----------
const P = {
  glitch: s => `<img src="${img(s || 'roof')}"><img src="${img(s || 'roof')}" style="mix-blend-mode:screen;opacity:.55;filter:sepia(1) saturate(6) hue-rotate(-50deg);transform:translateX(5px)"><img src="${img(s || 'roof')}" style="mix-blend-mode:screen;opacity:.45;filter:sepia(1) saturate(6) hue-rotate(150deg);transform:translateX(-5px)"><img src="${img(s || 'roof')}" style="clip-path:inset(38% 0 55% 0);transform:translateX(10px);filter:hue-rotate(60deg)">`,
  flash: () => `<img src="${img('living')}" style="filter:brightness(2.1) contrast(.7)">`,
  neg: () => `<img src="${img('roof')}" style="filter:invert(1) contrast(1.1)">`,
  punch: () => `<img src="${img('walk')}" style="transform:scale(1.45);filter:blur(.6px)">`,
  strip: () => `<img src="${img('roof')}"><div style="position:absolute;left:0;right:0;top:42%;height:18%;overflow:hidden;box-shadow:0 0 0 2px #fff"><img src="${img('living')}" style="position:absolute;top:-130%;height:330%;width:100%;object-fit:cover"></div>`,
  split: () => `<img src="${img('roof')}" style="width:50%;left:0"><img src="${img('hoodie')}" style="width:50%;left:50%"><i style="position:absolute;left:50%;top:0;bottom:0;width:2px;background:#fff"></i>`,
  page: () => `<img src="${img('living')}"><div style="position:absolute;inset:0;clip-path:polygon(0 0,62% 0,100% 38%,100% 100%,0 100%)"><img src="${img('roof')}"></div><i style="position:absolute;right:0;top:0;width:44%;height:44%;background:linear-gradient(225deg,transparent 50%,#f4efe6 50%,#d9d0c2);clip-path:polygon(14% 0,100% 86%,100% 0);filter:drop-shadow(-4px 4px 6px rgba(0,0,0,.4))"></i>`,
  freeze: () => `<div style="position:absolute;inset:0;background:#1d1b19"></div><img src="${img('walk')}" style="inset:12% 14%;width:72%;height:76%;border:5px solid #f4f1ea;transform:rotate(-4deg);filter:grayscale(.2)">`,
  words: () => `<img src="${img('roof')}" style="filter:brightness(.8)"><div style="position:absolute;left:10%;right:10%;top:56%;padding:8px 6px;border-radius:6px;backdrop-filter:blur(6px);background:rgba(255,255,255,.18);color:#fff;font:600 13px/16px Archivo;text-align:center">I made my own crown</div>`,
  behind: () => `<img src="${img('roof')}"><div style="position:absolute;left:0;right:0;top:20%;text-align:center;color:#fff;font:400 34px/34px 'Instrument Serif';mix-blend-mode:normal">ICON</div><img src="${img('roof')}" style="clip-path:polygon(38% 18%,62% 18%,70% 100%,30% 100%)">`,
  endcard: () => `<img src="${img('living')}" style="filter:brightness(.35) saturate(.4) blur(1px)"><div style="position:absolute;left:0;right:0;top:40%;text-align:center;color:#f4f1ea;font:400 30px/30px 'Instrument Serif';font-style:italic">Zelphira</div><i style="position:absolute;left:28%;right:28%;top:58%;height:1px;background:#f4f1ea"></i>`,
  corner: () => `<img src="${img('hoodie')}"><div style="position:absolute;right:8%;bottom:6%;color:#fff;font:400 13px/13px 'Instrument Serif';font-style:italic;opacity:.85">Zelphira</div>`,
  shatter: () => `<img src="${img('roof')}" style="clip-path:polygon(0 0,55% 0,40% 45%,0 60%)"><img src="${img('roof')}" style="clip-path:polygon(55% 0,100% 0,100% 50%,40% 45%);transform:translate(6px,-4px) rotate(2deg)"><img src="${img('roof')}" style="clip-path:polygon(0 60%,40% 45%,100% 50%,100% 100%,0 100%);transform:translate(-3px,5px)"><div style="position:absolute;inset:0;background:#111;z-index:-1"></div>`,
  stripes: () => `<img src="${img('living')}"><img src="${img('roof')}" style="-webkit-mask:repeating-linear-gradient(90deg,#000 0 14px,transparent 14px 26px)">`,
  covers: () => `<div style="position:absolute;inset:0;background:#1d1b19"></div>${[0, 1, 2].map(i => `<img src="${img(['roof', 'living', 'hoodie'][i])}" style="width:46%;height:28%;left:${8 + i * 16}%;top:${16 + i * 20}%;transform:rotate(${-8 + i * 7}deg);border:2px solid #fff">`).join('')}`,
  window: () => `<img src="${img('roof')}"><div style="position:absolute;left:30%;top:24%;width:40%;height:30%;overflow:hidden;box-shadow:0 0 0 2px #fff"><img src="${img('living')}" style="position:absolute;width:250%;height:333%;left:-75%;top:-80%"></div>`,
  sound: () => `<div style="position:absolute;inset:0;background:var(--field)"></div><svg viewBox="0 0 100 100" style="position:absolute;inset:18%"><path d="M0 30 C40 30 55 32 70 60 S90 92 100 95" fill="none" stroke="currentColor" stroke-width="3"/></svg>`,
};

const TPL = [
  { id: 'soft-rgb-glitch', name: 'Soft RGB glitch', len: '0.3 s', kind: 'Effect', p: 'glitch', live: true },
  { id: 'white-flash', name: 'White flash', len: '0.1 s', kind: 'Transition', p: 'flash', live: true },
  { id: 'beat-punch-in', name: 'Beat punch-in', len: '0.3 s', kind: 'Effect', p: 'punch', live: true },
  { id: 'negative-hit', name: 'Negative hit', len: '0.1 s', kind: 'Effect', p: 'neg', live: true },
  { id: 'strip-preview', name: 'Strip into next shot', len: '0.7 s', kind: 'Transition', p: 'strip', live: true },
  { id: 'window-preview', name: 'Window into next shot', len: '0.3 s', kind: 'Transition', p: 'window', live: true },
  { id: 'page-turn', name: 'Page turn', len: '0.4 s', kind: 'Transition', p: 'page', baked: true },
  { id: 'split-beat', name: 'Split on the beat', len: '2.1 s', kind: 'Transition', p: 'split', live: true },
  { id: 'freeze-cutout', name: 'Freeze cut-out', len: '1.8 s', kind: 'Effect', p: 'freeze', baked: true },
  { id: 'glass-lyrics', name: 'Glass lyrics', len: 'fits clip', kind: 'Text', p: 'words', baked: true },
  { id: 'title-behind', name: 'Title behind subject', len: '1.8 s', kind: 'Text', p: 'behind', baked: true },
  { id: 'storm-end-card', name: 'Storm end card', len: '4.0 s', kind: 'Text', p: 'endcard', baked: true },
  { id: 'shatter', name: 'Shatter', len: '0.5 s', kind: 'Transition', p: 'shatter', baked: true },
  { id: 'stripes-wipe', name: 'Stripes wipe', len: '0.4 s', kind: 'Transition', p: 'stripes', update: true },
];

const tile = (t, o = {}) => `<div class="col" style="gap:6px;min-width:0">
  <div class="media ${o.sel ? 'sel' : ''}" style="aspect-ratio:${o.ratio || '16/10'}">${P[t.p]()}
    ${o.badges !== false && t.update ? `<span class="micro" style="position:absolute;left:6px;bottom:6px;background:var(--raised);color:var(--ink);padding:2px 6px;border-radius:var(--rP)">Needs update</span>` : ''}</div>
  <div class="label" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${t.name}</div>
  ${o.sub !== false ? `<div class="caption" style="margin-top:-6px">${t.len}</div>` : ''}</div>`;

// ---------- Mac edit frame ----------
const rail = () => `<div class="col" style="width:64px;border-right:1px solid var(--hair);align-items:center;padding-top:18px;gap:22px;color:var(--ink2)">
  <div class="display" style="font-size:26px;color:var(--ink)">M</div>
  ${['house', 'user', 'video-camera'].map(n => icon(n, 24)).join('')}
  <div style="position:relative;color:var(--ink)">${icon('scissors', 24)}<i style="position:absolute;left:-22px;top:0;width:3px;height:24px;background:var(--accent)"></i></div>
  ${['stack', 'squares-four', 'paper-plane-tilt'].map(n => icon(n, 24)).join('')}</div>`;
const topbar = () => `<div class="row" style="height:60px;padding:0 24px;border-bottom:1px solid var(--hair);gap:16px">
  ${icon('caret-left', 20)}<div class="col"><div class="heading">Icon</div><div class="caption">Version 3, not exported yet</div></div>
  <div class="grow"></div><div class="seg"><span class="on">9:16</span><span>1:1</span><span>4:5</span><span>16:9</span></div><div class="grow"></div>
  <span class="btn ghost">${icon('chat-circle', 20)}Claude</span><span class="btn">${icon('export', 20)}Export</span></div>`;
const editRail = () => `<div class="col" style="width:84px;border-right:1px solid var(--hair);align-items:center;padding-top:12px;gap:6px">
  ${[['film-strip', 'Takes'], ['upload-simple', 'Uploads'], ['music-note', 'Music'], ['text-aa', 'Text'], ['sticker', 'Stickers'], ['stack', 'Templates', 1]].map(([i, l, on]) =>
    `<div class="col" style="align-items:center;gap:4px;width:68px;padding:10px 0;border-radius:var(--rK);${on ? 'background:var(--field);color:var(--ink)' : 'color:var(--ink2)'}">${icon(i, 24)}<span class="micro">${l}</span></div>`).join('')}</div>`;

const timeline = (o) => {
  const clips = [['roof', 70], ['living', 60], ['walk', 46], ['hoodie', 40], ['roof', 30], ['living', 36], ['walk', 28], ['hoodie', 34], ['roof', 56], ['living', 64], ['walk', 80], ['roof', 70], ['hoodie', 90], ['living', 110]];
  let x = 0;
  const cells = clips.map(([im, w], i) => { const s = `<div class="media" style="position:absolute;left:${x}px;top:0;width:${w - 2}px;height:56px;border-radius:2px;${o.clip === i ? 'outline:2px solid var(--accent);outline-offset:1px;z-index:2' : ''}"><img src="${img(im)}"></div>`; x += w; return s; }).join('');
  let cx = 0; for (let i = 0; i < o.cut; i++) cx += clips[i][1];
  const cutMark = o.cut != null ? `<div style="position:absolute;left:${cx - 7}px;top:-6px;width:12px;height:68px;border:2px solid var(--accent);border-radius:3px;z-index:3;background:color-mix(in srgb,var(--accent) 25%,transparent)"></div>` : '';
  return `<div style="border-top:1px solid var(--hair)">
  <div class="row" style="height:52px;padding:0 20px;gap:4px">
    ${[['scissors', 'Split'], ['trash', 'Delete'], ['gauge', 'Speed'], ['diamond', 'Keyframe']].map(([i, l]) => `<span class="btn ghost">${icon(i, 20)}${l}</span>`).join('')}
    <span class="btn ghost">${icon('stack', 20)}Save as template</span><div class="grow"></div>
    ${icon('magnifying-glass-minus', 20)}<div class="slider" style="width:110px;margin:0 10px"><i style="width:60%"></i><b style="left:58%"></b></div>${icon('magnifying-glass-plus', 20)}</div>
  <div class="row" style="height:${o.h || 210}px;align-items:stretch">
    <div class="col" style="width:150px;border-right:1px solid var(--hair);padding-top:36px">
      ${[['film-strip', 'Video', 74], ['stack', 'Overlay', 46], ['waveform', 'Sound', 46]].map(([i, l, h]) => `<div class="row label" style="height:${h}px;gap:10px;padding-left:20px;color:var(--ink2)">${icon(i, 20)}<span style="color:var(--ink)">${l}</span></div>`).join('')}</div>
    <div class="grow" style="position:relative;padding:0 16px;overflow:hidden">
      <div class="row micro muted" style="height:36px;gap:0">${['0:18', '0:20', '0:22', '0:24', '0:26', '0:28', '0:30'].map(t => `<span style="width:132px">${t}</span>`).join('')}</div>
      <div style="position:relative;height:74px;padding-top:9px"><div style="position:relative;height:56px">${cells}${cutMark}</div></div>
      <div style="position:relative;height:46px">${o.overlay ? `<div class="micro" style="position:absolute;left:${o.overlay[0]}px;width:${o.overlay[1]}px;top:9px;height:28px;border-radius:2px;background:var(--field);border:1px dashed var(--ink2);color:var(--ink2);display:flex;align-items:center;padding-left:6px;white-space:nowrap;overflow:hidden">${o.overlay[2]}</div>` : ''}</div>
      <div style="position:relative;height:46px"><svg width="1000" height="34" style="position:absolute;top:6px;color:var(--ink2)">${Array.from({ length: 160 }, (_, i) => { const h = 6 + Math.abs(Math.sin(i * 1.7) * 20 + Math.sin(i * .31) * 6); return `<rect x="${i * 6}" y="${17 - h / 2}" width="2" height="${h}" fill="currentColor" opacity=".7"/>`; }).join('')}</svg></div>
      <i style="position:absolute;left:${o.head}px;top:30px;bottom:0;width:2px;background:var(--accent)"></i>
    </div></div></div>`;
};

const library = (o) => `<div class="col" style="width:340px;border-right:1px solid var(--hair);padding:20px 20px 0;gap:14px;overflow:hidden">
  <div class="row"><div class="title grow">Templates</div>${icon('caret-double-left', 20)}</div>
  <div class="field">${icon('magnifying-glass', 16)}Search 27 templates</div>
  <div class="row" style="gap:6px;flex-wrap:wrap">${['All', 'Transitions', 'Effects', 'Text'].map(f => `<span class="chip ${f === o.filter ? 'on' : ''}">${f}</span>`).join('')}</div>
  <div class="row" style="justify-content:space-between"><div class="heading">Made by Claude</div><div class="caption">${o.count}</div></div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px 12px">${o.items.map(t => tile(t, { sel: t.id === o.sel })).join('')}</div></div>`;

const viewer = (o) => `<div class="col grow" style="padding:16px 24px 12px;gap:12px;min-width:0">
  <div class="row" style="gap:12px"><div class="seg"><span class="on">Clean</span><span>TikTok</span><span>Reels</span></div><div class="grow"></div>
    <span class="caption">${o.note}</span></div>
  <div class="grow" style="background:#111;border-radius:var(--rC);position:relative;display:flex;justify-content:center;overflow:hidden">
    <div class="media" style="height:100%;aspect-ratio:9/16;border-radius:0">${P[o.p]()}</div></div>
  <div class="row" style="gap:18px;justify-content:center;position:relative">
    <span class="label" style="position:absolute;left:0">${o.time}</span>
    ${icon('skip-back', 20)}<span style="width:44px;height:44px;border-radius:50%;background:var(--action);color:var(--onAction);display:grid;place-items:center">${icon('pause', 20)}</span>${icon('skip-forward', 20)}
    <span class="caption" style="position:absolute;right:0">Previewing on ${o.target}</span></div></div>`;

const param = (label, value, pct) => `<div class="col" style="gap:10px"><div class="row"><span class="label grow">${label}</span><span class="label muted">${value}</span></div>
  ${pct != null ? `<div class="slider"><i style="width:${pct}%"></i><b style="left:calc(${pct}% - 8px)"></b></div>` : ''}</div>`;

const inspector = (o) => `<div class="col" style="width:360px;border-left:1px solid var(--hair);padding:20px 24px;gap:20px;overflow:hidden">
  <div class="row"><div class="title grow">${o.name}</div>${icon('dots-three', 20)}</div>
  <div class="caption" style="margin-top:-14px">${o.desc}</div><div class="caption" style="margin-top:-16px">${o.source}</div>
  <div class="col" style="gap:8px"><div class="label muted">Applies to</div>
    <div class="row" style="gap:10px;padding:10px 12px;background:var(--field);border-radius:var(--rK)">${icon(o.targetIcon, 20)}<div class="col grow"><span class="label">${o.target}</span><span class="caption">${o.targetSub}</span></div><span class="label muted">Change</span></div></div>
  ${o.params}
  <div class="col" style="gap:6px"><div class="row" style="gap:8px">${icon(o.howIcon, 16)}<span class="label">${o.how}</span></div><div class="caption">${o.howSub}</div></div>
  <div class="grow"></div>
  <div class="col" style="gap:10px"><span class="btn primary big" style="justify-content:center">${o.primary}</span>
    <span class="btn ghost" style="justify-content:center">${o.secondary}</span></div></div>`;

const mac = (theme, o) => `<!doctype html><html><head><meta charset="utf-8"><style>${css(THEMES[theme])}</style></head><body>
<div class="row" style="width:1440px;height:900px;align-items:stretch">${rail()}<div class="col grow" style="min-width:0">${topbar()}
<div class="row grow" style="align-items:stretch;min-height:0">${editRail()}${library(o.lib)}${viewer(o.view)}${inspector(o.insp)}</div>${timeline(o.tl)}</div></div></body></html>`;

const pages = {};
const byId = Object.fromEntries(TPL.map(t => [t.id, t]));

pages['1-mac-library-effect-light'] = mac('A', {
  lib: { filter: 'All', count: '27', sel: 'soft-rgb-glitch', items: TPL.slice(0, 12) },
  view: { p: 'glitch', note: 'Preview, not applied yet', time: '0:21.8 / 1:08.6', target: 'clip 12' },
  insp: { name: 'Soft RGB glitch', desc: 'A short colour split with a flicker. Works on any clip, any length.',
    targetIcon: 'film-strip', target: 'Clip 12', targetSub: '0:21.7 to 0:22.0',
    params: param('Strength', '30%', 30) + param('Length', '0.3 s', 22) + `<div class="row"><span class="label grow">Add the glitch sound</span><span class="toggle on"></span></div>`,
    howIcon: 'check-circle', how: 'Live effect', howSub: 'Plays the same on Mac, Android and in the export. You can change it after applying.',
    primary: 'Apply to clip 12', secondary: 'Apply on every beat cut', source: 'Saved by Claude from the Icon edit, 14 Nov' },
  tl: { clip: 6, head: 420, overlay: null },
});

pages['2-mac-library-transition-dark'] = mac('B', {
  lib: { filter: 'Transitions', count: '11', sel: 'page-turn', items: [byId['white-flash'], byId['page-turn'], byId['split-beat'], byId['strip-preview'], byId['stripes-wipe'], byId['shatter'], byId['window-preview']] },
  view: { p: 'page', note: 'Preview, not applied yet', time: '0:18.0 / 1:08.6', target: 'the cut at 0:18.0' },
  insp: { name: 'Page turn', desc: 'The shot curls away from the corner and shows the next one.',
    targetIcon: 'square-split-horizontal', target: 'Cut at 0:18.0', targetSub: 'Between clip 4 and clip 5',
    params: param('Length', '0.4 s, fixed', null) + `<div class="caption" style="margin-top:-14px">This template is a finished clip, so its length and look stay as made.</div>`,
    howIcon: 'film-strip', how: 'Finished overlay clip', howSub: 'Placed over the cut on the Overlay track, 1080 × 1920. Delete or move it like any clip.',
    primary: 'Apply to cut at 0:18.0', secondary: 'Choose another cut', source: 'Saved by Claude from the Icon edit, 14 Nov' },
  tl: { cut: 4, head: 0 + 222, overlay: [196, 52, 'Page turn'] },
});

// ---------- Android ----------
const phone = (theme, inner) => `<div style="width:390px;height:844px;border-radius:44px;overflow:hidden;position:relative;background:var(--canvas);box-shadow:0 0 0 10px #000">${inner}</div>`;
const androidEdit = (sheet) => `
  <div class="row" style="height:56px;padding:0 16px;gap:12px;margin-top:28px">${icon('caret-left', 24)}<div class="heading grow">Icon</div><span class="btn">${icon('export', 20)}Export</span></div>
  <div style="height:330px;background:#111;display:flex;justify-content:center"><div class="media" style="height:100%;aspect-ratio:9/16;border-radius:0">${P.glitch()}</div></div>
  <div class="row" style="height:40px;padding:0 16px;gap:0"><span class="label">0:21.8</span><div class="grow"></div>${icon('play', 24)}<div class="grow"></div><span class="caption">1:08.6</span></div>
  <div style="position:relative;height:56px;margin:0 0 0 16px;overflow:hidden">${['roof', 'living', 'walk', 'hoodie', 'roof', 'living'].map((m, i) => `<div class="media" style="position:absolute;left:${i * 66}px;width:64px;height:56px;border-radius:2px;${i === 2 ? 'outline:2px solid var(--accent);outline-offset:1px' : ''}"><img src="${img(m)}"></div>`).join('')}</div>
  ${sheet}`;
const androidSheet = `<div class="col" style="position:absolute;left:0;right:0;bottom:0;height:420px;background:var(--raised);border-radius:16px 16px 0 0;box-shadow:0 -8px 24px rgba(0,0,0,.12);padding:8px 16px 16px;gap:14px">
  <i style="align-self:center;width:36px;height:4px;border-radius:2px;background:var(--hair)"></i>
  <div class="row"><div class="title grow">Templates</div>${icon('magnifying-glass', 24)}</div>
  <div class="row" style="gap:8px;overflow:hidden;flex:none;height:32px">${['All', 'Transitions', 'Effects', 'Text', 'Sound'].map(f => `<span class="chip ${f === 'Effects' ? 'on' : ''}">${f}</span>`).join('')}</div>
  <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px 10px">${[byId['soft-rgb-glitch'], byId['beat-punch-in'], byId['negative-hit'], byId['freeze-cutout'], byId['glass-lyrics'], byId['title-behind']].map(t => tile(t, { sel: t.id === 'soft-rgb-glitch', ratio: '1/1' })).join('')}</div></div>`;
const androidDetail = `<div class="col" style="position:absolute;left:0;right:0;bottom:0;height:420px;background:var(--raised);border-radius:16px 16px 0 0;box-shadow:0 -8px 24px rgba(0,0,0,.12);padding:8px 16px 16px;gap:18px">
  <i style="align-self:center;width:36px;height:4px;border-radius:2px;background:var(--hair)"></i>
  <div class="row" style="gap:12px">${icon('caret-left', 24)}<div class="col grow"><div class="title">Soft RGB glitch</div><div class="caption">On clip 3, 0:21.7 to 0:22.0</div></div></div>
  ${param('Strength', '30%', 30)}${param('Length', '0.3 s', 22)}
  <div class="row"><span class="label grow">Add the glitch sound</span><span class="toggle on"></span></div>
  <div class="caption">Live effect. Plays the same on Mac, Android and in the export.</div>
  <div class="grow"></div>
  <span class="btn primary big" style="justify-content:center;height:48px">Apply to clip 3</span></div>`;
pages['3-android-sheet-light'] = `<!doctype html><html><head><meta charset="utf-8"><style>${css(THEMES.A)}</style></head><body style="background:#D9D3C8">
<div class="row" style="width:1000px;height:940px;justify-content:center;gap:80px">
${phone('A', androidEdit(androidSheet))}${phone('A', androidEdit(androidDetail))}</div></body></html>`;

// ---------- Saving and states board (light) ----------
const panel = (title, body, w = 400) => `<div class="col" style="width:${w}px;gap:12px"><div class="label muted">${title}</div><div style="background:var(--raised);border-radius:var(--rC);padding:20px;border:1px solid var(--hair)">${body}</div></div>`;
const saveSheet = `<div class="col" style="gap:18px"><div class="title">Save as template</div>
  <div class="col" style="gap:6px"><span class="label muted">Name</span><div class="field" style="color:var(--ink)">Soft RGB glitch</div></div>
  <div class="col" style="gap:10px"><span class="label muted">Keep from clip 12</span>
  ${[['Effect: glitch, 30%', 1], ['Scale keyframes (punch-in)', 1], ['Glitch sound on the Sound track', 1], ['The clip itself', 0]].map(([l, on]) => `<div class="row" style="gap:10px">${icon(on ? 'check-square' : 'square', 20)}<span class="label" style="${on ? '' : 'color:var(--ink2)'}">${l}</span></div>`).join('')}</div>
  <div class="col" style="gap:6px"><span class="label muted">Applies to</span><div class="seg"><span class="on">A clip</span><span>A cut</span><span>The whole edit</span></div></div>
  <div class="row" style="gap:10px;justify-content:flex-end"><span class="btn ghost">Cancel</span><span class="btn primary">Save template</span></div></div>`;
const chatCard = `<div class="col" style="gap:12px"><div class="row" style="gap:8px">${icon('chat-circle', 16)}<span class="label">Claude</span></div>
  <div style="font:400 15px/21px Archivo">I saved the soft colour split from clip 12 as a template, so you can put it on any clip.</div>
  <div class="row" style="gap:12px;padding:10px;background:var(--field);border-radius:var(--rK)"><div class="media" style="width:48px;height:60px">${P.glitch()}</div>
    <div class="col grow"><span class="label">Soft RGB glitch</span><span class="caption">Effect, live, 0.3 s</span></div></div>
  <div class="row" style="gap:8px"><span class="btn">Open in Templates</span><span class="btn ghost">Undo</span></div></div>`;
const loading = `<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:14px 10px">${Array.from({ length: 6 }, () => `<div class="col" style="gap:6px"><div style="aspect-ratio:4/5;background:var(--field);border-radius:var(--rC)"></div><div style="height:12px;width:80%;background:var(--field);border-radius:2px"></div><div style="height:10px;width:40%;background:var(--field);border-radius:2px"></div></div>`).join('')}</div>`;
const empty = `<div class="col" style="gap:12px"><div class="heading">No templates yet</div><div class="caption">A template keeps an effect, a transition or a text look so you can put it on any clip. Select a clip and press Save as template, or ask Claude to save one.</div><span class="btn" style="align-self:flex-start">${icon('stack', 20)}Save clip 12 as template</span></div>`;
const update = `<div class="row" style="gap:14px;align-items:flex-start"><div style="width:96px">${tile(byId['stripes-wipe'], { sub: false })}</div><div class="col" style="gap:8px;flex:1"><div class="heading">Needs the next MUSE update</div><div class="caption">Stripes wipe uses a new mask shape. Update MUSE on this Mac to apply it here.</div></div></div>`;
const error = `<div class="col" style="gap:10px"><div class="row" style="gap:8px;color:var(--caution)">${icon('wifi-slash', 20)}<span class="heading" style="color:var(--ink)">Templates didn't load</span></div><div class="caption">MUSE can't reach the server. Templates you used on this Mac still work. Check the connection, then try again.</div><span class="btn" style="align-self:flex-start">Try again</span></div>`;
pages['4-saving-and-states-light'] = `<!doctype html><html><head><meta charset="utf-8"><style>${css(THEMES.A)}</style></head><body>
<div style="width:1440px;height:900px;padding:40px 48px;display:flex;flex-direction:column;gap:28px">
<div class="display">Edit templates: saving and states</div>
<div class="row" style="gap:40px;align-items:flex-start">${panel('Save as template (Mac sheet, from the timeline toolbar)', saveSheet, 420)}${panel('Claude saved one (chat card)', chatCard, 380)}
<div class="col" style="gap:28px">${panel('Loading', loading, 400)}</div></div>
<div class="row" style="gap:40px;align-items:flex-start">${panel('Empty library', empty, 420)}${panel('Older app', update, 380)}${panel('Offline', error, 400)}</div></div></body></html>`;

const browser = await chromium.launch();
const ctx = await browser.newContext({ deviceScaleFactor: 2 });
for (const [name, html] of Object.entries(pages)) {
  const f = path.join(here, `${name}.html`);
  fs.writeFileSync(f, html);
  const page = await ctx.newPage();
  const size = name.startsWith('3-') ? { width: 1000, height: 940 } : { width: 1440, height: 900 };
  await page.setViewportSize(size);
  await page.goto(`file://${f}`);
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: path.join(out, `${name}.png`) });
  await page.close();
  console.log('wrote', name);
}
await browser.close();

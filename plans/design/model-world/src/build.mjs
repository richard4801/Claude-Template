// Builds the "Her world" mockups (plans/model-world.md) as HTML and screenshots them with Playwright.
// Run: node plans/design/model-world/src/build.mjs
// Icons come from the repo's vendored set (design/icons/phosphor), falling back to src/icons (copied from @phosphor-icons/core 2.1.1, MIT) for
// the four this feature adds (at, paw-print, users, folder-simple). Imagery: crops of the approved Suite redesign
// stills and the Blender preview stills (no AI-generated people; the sister is a stand-in mannequin).
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../../..');
const out = path.resolve(here, '..');
const fontDir = `file://${root}/mac/Muse/Resources/Fonts`;
const img = n => `file://${here}/img/${n}.jpg`;
const icon = (n, size = 20) => {
  let f = `${root}/design/icons/phosphor/${n}.svg`;
  if (!fs.existsSync(f)) f = `${here}/icons/${n}.svg`;
  return fs.readFileSync(f, 'utf8').replace('<svg ', `<svg width="${size}" height="${size}" class="ic" `);
};

const t = { canvas: '#EFEBE3', raised: '#F8F5EF', field: '#E7E1D6', ink: '#141210', ink2: '#67605A', hairline: '#CFC7BA', accent: '#B5121B',
  action: '#141210', onAction: '#F8F5EF', positive: '#2F6B3A' };

const css = `
@font-face{font-family:'Archivo';src:url('${fontDir}/Archivo-VF.ttf');font-weight:100 900}
@font-face{font-family:'Instrument Serif';src:url('${fontDir}/InstrumentSerif-Regular.ttf')}
:root{--canvas:${t.canvas};--raised:${t.raised};--field:${t.field};--ink:${t.ink};--ink2:${t.ink2};--hair:${t.hairline};--accent:${t.accent};
--action:${t.action};--onAction:${t.onAction};--positive:${t.positive};--rC:4px;--rK:2px;--rP:2px}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--canvas);color:var(--ink);font:400 15px/21px 'Archivo';-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
.ic{color:currentColor;flex:none}
.display{font:400 28px/32px 'Instrument Serif'} .display.big{font-size:34px;line-height:38px}
.title{font:600 20px/26px 'Archivo'} .heading{font:600 16px/22px 'Archivo'} .label{font:500 14px/18px 'Archivo'}
.body{font:400 15px/21px 'Archivo'} .caption{font:400 13px/18px 'Archivo';color:var(--ink2)} .micro{font:500 11px/14px 'Archivo'}
.row{display:flex;align-items:center} .col{display:flex;flex-direction:column} .grow{flex:1;min-width:0} .muted{color:var(--ink2)}
.btn{display:inline-flex;align-items:center;gap:8px;height:36px;padding:0 14px;border-radius:var(--rK);font:500 14px/18px 'Archivo';color:var(--ink);background:var(--field);white-space:nowrap}
.btn.ghost{background:transparent;padding:0 8px} .btn.line{background:transparent;border:1px solid var(--hair)} .btn.primary{background:var(--action);color:var(--onAction)} .btn.big{height:44px;padding:0 18px}
.chip{flex:none;display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 10px;border-radius:var(--rP);background:var(--field);font:500 13px/18px 'Archivo';color:var(--ink);white-space:nowrap}
.tag{font:500 13px/18px 'Archivo';color:var(--ink2)}
.media{position:relative;overflow:hidden;background:var(--field);border-radius:var(--rC)}
.media img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.sel{outline:2px solid var(--accent);outline-offset:2px}
.toggle{width:36px;height:20px;border-radius:10px;background:var(--field);position:relative;flex:none;border:1px solid var(--hair)}
.toggle.on{background:var(--ink);border-color:var(--ink)} .toggle::after{content:'';position:absolute;top:1px;left:1px;width:16px;height:16px;border-radius:50%;background:var(--raised)}
.toggle.on::after{left:17px}
.hr{height:1px;background:var(--hair)}
.add{border:1px dashed var(--hair);border-radius:var(--rC);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;color:var(--ink2)}
.pop{position:absolute;background:var(--raised);border-radius:var(--rC);box-shadow:0 8px 28px rgba(20,18,16,.16),0 0 0 1px rgba(20,18,16,.06);z-index:10}
.mi{display:flex;align-items:center;gap:10px;height:36px;padding:0 12px;border-radius:var(--rK)}
.mi.on{background:var(--field)}
.mention{font-weight:600;text-decoration:underline;text-underline-offset:3px;text-decoration-thickness:1px}
`;

// ---------- Mac frame (the approved Suite redesign's sidebar and top bar) ----------
const NAV = [['house', 'Home'], ['user', 'Models'], ['video-camera', 'Video suite'], ['film-strip', 'Templates'], ['scissors', 'Edit'], ['list-bullets', 'Queue'], ['images', 'Library'], ['paper-plane-tilt', 'Posts']];
const sidebar = on => `<div class="col" style="width:232px;flex:none;border-right:1px solid var(--hair);padding:28px 16px 20px">
  <div style="font:400 30px/32px 'Instrument Serif';padding-left:12px;margin-bottom:28px">Muse</div>
  ${NAV.map(([i, l]) => `<div class="row label" style="gap:12px;height:38px;padding:0 12px;border-radius:var(--rK);position:relative;${l === on ? 'background:var(--field)' : 'color:var(--ink2)'}">
    ${l === on ? '<i style="position:absolute;left:-16px;top:8px;width:3px;height:22px;background:var(--accent)"></i>' : ''}${icon(i, 20)}<span style="color:var(--ink)">${l}</span></div>`).join('')}
  <div class="row label" style="gap:12px;height:38px;padding:0 12px;margin-top:16px;color:var(--ink2)">${icon('plus', 20)}<span style="color:var(--ink)">New model</span></div>
  <div class="grow"></div>
  <div class="row label" style="gap:12px;height:38px;padding:0 12px;color:var(--ink2)">${icon('sliders-horizontal', 20)}<span style="color:var(--ink)">Settings</span></div>
  <div class="row" style="padding:12px 12px 0;gap:8px"><div class="col grow"><span class="caption">Balance</span><span class="heading">$6.07</span></div><span class="label muted">${icon('plus', 16)} Add funds</span></div></div>`;
const topbar = () => `<div class="row" style="height:56px;flex:none;padding:0 32px;border-bottom:1px solid var(--hair);gap:16px">
  <div class="row caption" style="width:360px;height:34px;background:var(--field);border-radius:var(--rK);padding:0 12px;gap:8px">${icon('magnifying-glass', 16)}<span class="grow">Search or jump to…</span><span class="micro">⌘K</span></div>
  <div class="grow"></div><span class="btn line">${icon('chat-circle', 16)}Ask Claude</span>
  <div class="media" style="width:30px;height:30px;border-radius:50%"><img src="${img('her-walk')}"></div></div>`;
const mac = (on, content) => `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>
<div class="row" style="width:1440px;height:900px;align-items:stretch;overflow:hidden">${sidebar(on)}<div class="col grow">${topbar()}${content}</div></div></body></html>`;

// ---------- her page header + tabs ----------
const TABS = [['Profile'], ['Wardrobe', '6'], ['Places', '4'], ['People', '2'], ['Pets', '']];
const TABS0 = TABS.map(([l, n]) => [l, l === 'Wardrobe' ? n : '']);
const header = (tab, o = {}) => `<div class="col" style="padding:24px 32px 0;flex:none">
  <div class="row caption" style="gap:4px;margin-bottom:14px">${icon('caret-left', 16)}Models</div>
  <div class="row" style="gap:20px">
    <div class="media" style="width:72px;height:72px;border-radius:50%;flex:none"><img src="${img('her-face')}"></div>
    <div class="col grow" style="gap:2px"><div class="display big">Zelphira</div>
      <div class="caption">Long wavy dark hair, warm brown eyes. Identity locked, 24 photos</div></div>
    <span class="btn line">${icon('camera', 16)}Photo</span><span class="btn primary">${icon('video-camera', 16)}New shot</span><span class="btn ghost">${icon('dots-three', 20)}</span></div>
  <div class="row" style="gap:28px;margin-top:22px;border-bottom:1px solid var(--hair)">
    ${(o.empty ? TABS0 : TABS).map(([l, n]) => `<div class="row label" style="height:40px;gap:6px;position:relative;${l === tab ? '' : 'color:var(--ink2)'}">${l}${n ? `<span class="caption">${n}</span>` : ''}
      ${l === tab ? '<i style="position:absolute;left:0;right:0;bottom:-1px;height:2px;background:var(--accent)"></i>' : ''}</div>`).join('')}
    ${o.right ? `<div class="grow"></div>${o.right}` : ''}</div></div>`;

// ---------- 1. Profile ----------
const sheet = [['her-face', 'Face, front'], ['her-face2', 'Face, ¾'], ['her-living', 'Full body, front'], ['her-roof', 'Full body, ¾'], ['her-hoodie', 'Outfit, hoodie']];
const profile = mac('Models', header('Profile') + `<div class="row grow" style="align-items:flex-start;padding:28px 32px;gap:48px;min-height:0">
  <div class="col grow" style="gap:14px">
    <div class="row"><div class="heading grow">Her photos</div><span class="btn ghost">${icon('upload-simple', 16)}Upload</span><span class="btn ghost">${icon('clock-counter-clockwise', 16)}Versions</span></div>
    <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:16px">
      ${sheet.map(([i, l]) => `<div class="col" style="gap:6px"><div class="media" style="aspect-ratio:3/4"><img src="${img(i)}"></div><span class="caption">${l}</span></div>`).join('')}</div>
    <div class="heading" style="margin-top:20px">Her world</div>
    <div class="caption" style="margin-top:-8px">Places, people and pets keep her videos consistent. Type @ in any prompt to use them.</div>
    <div class="col" style="margin-top:4px">
      ${[['map-pin', 'Places', 'Apartment, Rooftop, Café by the gym, Studio', ['apt-sofa', 'roof-right', 'cafe-day', 'studio']],
         ['users', 'People', 'Mara (sister), Jonah (brother)', ['sis-face']],
         ['paw-print', 'Pets', 'None yet', []]].map(([i, l, s, th]) => `<div class="row" style="gap:14px;height:64px;border-top:1px solid var(--hair)">
        <span class="muted">${icon(i, 20)}</span><span class="label" style="width:72px">${l}</span><span class="caption grow">${s}</span>
        <div class="row" style="gap:4px">${th.map(x => `<div class="media" style="width:40px;height:40px"><img src="${img(x)}"></div>`).join('')}</div>
        ${th.length ? `<span class="muted">${icon('caret-right', 16)}</span>` : `<span class="btn ghost">${icon('plus', 16)}Add a pet</span>`}</div>`).join('')}</div>
  </div>
  <div class="col" style="width:320px;flex:none;gap:22px">
    <div class="col" style="gap:6px"><span class="label muted">Niche</span><span class="body">Lifestyle, cosy fitness</span></div>
    <div class="col" style="gap:6px"><span class="label muted">Personality</span><span class="body">Warm, a little goofy, early riser. Talks to camera like a friend.</span></div>
    <div class="col" style="gap:8px"><span class="label muted">Never add</span><div class="row" style="gap:6px"><span class="chip">Tattoos</span><span class="chip">Rings</span><span class="chip muted">${icon('plus', 16)}</span></div></div>
    <div class="hr"></div>
    <div class="row"><div class="col grow"><span class="label">Identity LoRA</span><span class="caption">Trained 12 Nov</span></div><span class="muted">${icon('caret-right', 16)}</span></div>
    <div class="row"><div class="col grow"><span class="label">Accounts</span><span class="caption">2 of 5 connected</span></div><span class="muted">${icon('caret-right', 16)}</span></div>
  </div></div>`);

// ---------- 2. Places: grid + one opened ----------
const PLACES = [['Apartment', 'apartment', 'apt-sofa', 4], ['Rooftop', 'rooftop', 'roof-left', 2], ['Café by the gym', 'cafe', 'cafe-day', 5], ['Studio', 'studio', 'studio', 2]];
const placeTile = ([n, tg, c, k], o = {}) => `<div class="col" style="gap:6px">
  <div class="media ${o.sel ? 'sel' : ''}" style="aspect-ratio:4/3"><img src="${img(c)}"></div>
  <div class="row"><span class="label grow">${n}</span><span class="caption">${k}</span></div><span class="tag" style="margin-top:-4px">@${tg}</span></div>`;
const places = mac('Models', header('Places', { right: `<span class="btn ghost" style="margin-bottom:4px">${icon('plus', 16)}Add a place</span>` }) + `<div class="row grow" style="align-items:stretch;min-height:0">
  <div class="col" style="width:520px;flex:none;padding:24px 32px;gap:16px;border-right:1px solid var(--hair)">
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px 16px">${PLACES.map(p => placeTile(p, { sel: p[1] === 'cafe' })).join('')}</div>
    <div class="add" style="height:84px;margin-top:4px"><span class="label" style="color:var(--ink)">${icon('plus', 16)} Add a place</span><span class="caption">Her bedroom, the gym, a park…</span></div>
  </div>
  <div class="col grow" style="padding:24px 32px;gap:16px;position:relative">
    <div class="row" style="gap:10px"><div class="title grow">Café by the gym</div><span class="btn ghost">${icon('pencil-simple', 16)}Rename</span><span class="btn ghost">${icon('dots-three', 20)}</span></div>
    <div class="row" style="gap:10px;margin-top:-8px"><span class="chip">@cafe</span><span class="caption">Type @cafe in any prompt to film here.</span></div>
    <div class="body muted" style="max-width:560px">Corner café with a striped awning, across the street from her gym. Wet cobbles, warm window light.</div>
    <div class="row" style="margin-top:6px"><span class="heading grow">Photos</span><span class="btn">${icon('plus', 16)}Add photo</span></div>
    <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:14px">
      ${['cafe-day', 'cafe-gold', 'cafe-night', 'cafe-rain', 'cafe-dusk'].map((c, i) => `<div class="col" style="gap:6px"><div class="media" style="aspect-ratio:16/10"><img src="${img(c)}">
        ${i === 0 ? `<span class="micro" style="position:absolute;left:6px;top:6px;background:var(--raised);padding:2px 6px;border-radius:var(--rP)">Cover</span>` : ''}</div>
        <span class="caption">${['Uploaded', 'Generated from a description', 'Generated, random view', 'Uploaded', 'Generated from a reference'][i]}</span></div>`).join('')}</div>
    <div class="caption" style="margin-top:4px">Sent as the scene picture when you type @cafe. Her photos always go first; if a model has no room left, the place is described in words instead.</div>
    <div class="pop" style="right:32px;top:232px;width:340px;padding:6px">
      <div class="mi on">${icon('upload-simple', 20)}<span class="label grow">Upload photos</span><span class="caption">Free</span></div>
      <div class="hr" style="margin:6px 0"></div>
      <div class="caption" style="padding:6px 12px 2px">Generate one</div>
      <div class="mi">${icon('shuffle', 20)}<div class="col grow"><span class="label">A random view of this place</span><span class="caption">From its photos</span></div><span class="caption">$0.03</span></div>
      <div class="mi" style="height:48px">${icon('text-aa', 20)}<div class="col grow"><span class="label">From a description</span><span class="caption">“The counter from inside, morning”</span></div><span class="caption">$0.03</span></div>
      <div class="mi" style="height:48px">${icon('image', 20)}<div class="col grow"><span class="label">From a reference picture</span><span class="caption">A photo you like, rebuilt as this place</span></div><span class="caption">$0.04</span></div>
      <div class="caption" style="padding:8px 12px 6px">You see the price and approve before anything is made.</div>
    </div>
  </div></div>`);

// ---------- 3. People ----------
const PEOPLE = [['Mara', 'Sister', 'sis-face', '3 photos, 2 outfits'], ['Jonah', 'Brother', null, 'No photos yet']];
const people = mac('Models', header('People', { right: `<span class="btn ghost" style="margin-bottom:4px">${icon('user-plus', 16)}Add a person</span>` }) + `<div class="row grow" style="align-items:stretch;min-height:0">
  <div class="col" style="width:320px;flex:none;padding:20px 16px;gap:4px;border-right:1px solid var(--hair)">
    ${PEOPLE.map(([n, r, a, s], i) => `<div class="row" style="gap:12px;height:68px;padding:0 16px;border-radius:var(--rK);${i === 0 ? 'background:var(--field)' : ''}">
      ${a ? `<div class="media" style="width:44px;height:44px;border-radius:50%"><img src="${img(a)}"></div>` : `<div style="width:44px;height:44px;border-radius:50%;background:var(--field);border:1px dashed var(--hair);display:grid;place-items:center" class="display">J</div>`}
      <div class="col grow"><span class="label">${n}</span><span class="caption">${r}. ${s}</span></div></div>`).join('')}
    <div class="row label muted" style="gap:10px;height:52px;padding:0 16px">${icon('plus', 16)}Add a person</div>
    <div class="caption" style="padding:8px 16px">Family and friends who appear with her. Lighter than a model: a few photos, their own outfits, no LoRA.</div>
  </div>
  <div class="col grow" style="padding:24px 32px;gap:18px">
    <div class="row" style="gap:16px">
      <div class="media" style="width:56px;height:56px;border-radius:50%"><img src="${img('sis-face')}"></div>
      <div class="col grow"><div class="title">Mara</div><div class="row" style="gap:10px"><span class="caption">Her sister, 2 years older</span><span class="chip">@mara</span></div></div>
      <span class="btn line">${icon('video-camera', 16)}Shot with Mara</span><span class="btn ghost">${icon('dots-three', 20)}</span></div>
    <div class="row"><span class="heading grow">Photos</span><span class="caption">3 is enough; up to 7</span></div>
    <div class="row" style="gap:14px;align-items:flex-start">
      ${[['sis-face', 'Face'], ['sis-34', 'Waist up'], ['sis-full', 'Full body']].map(([i, l]) => `<div class="col" style="gap:6px;width:150px"><div class="media" style="aspect-ratio:4/5"><img src="${img(i)}"></div><span class="caption">${l}</span></div>`).join('')}
      <div class="add" style="width:150px;aspect-ratio:4/5"><span class="label" style="color:var(--ink)">${icon('plus', 16)}</span><span class="caption">Add photo</span></div></div>
    <div class="row" style="margin-top:8px"><span class="heading grow">Wardrobe</span><span class="btn ghost">${icon('plus', 16)}Add outfit</span></div>
    <div class="row" style="gap:14px;align-items:flex-start">
      ${[['sis-full', 'Denim jacket', 'filter:sepia(.5) hue-rotate(180deg) saturate(1.6)'], ['sis-34', 'Running kit', 'filter:sepia(.6) hue-rotate(-30deg) saturate(1.8)']].map(([i, l, f]) => `<div class="col" style="gap:6px;width:120px"><div class="media" style="aspect-ratio:3/4"><img src="${img(i)}" style="${f}"></div><span class="label">${l}</span><span class="caption" style="margin-top:-6px">3 photos</span></div>`).join('')}
    </div>
    <div class="caption">Same outfit tools as Zelphira's wardrobe. In a prompt: @mara in her denim jacket.</div>
  </div></div>`);

// ---------- 4. Composer with @ mentions ----------
const suiteTabs = on => `<div class="row" style="gap:2px;background:var(--field);padding:3px;border-radius:var(--rK)">${[['video-camera', 'Shot'], ['camera', 'Photo'], ['swap', 'Swap'], ['squares-four', 'Storyboard'], ['arrows-clockwise', 'Recreate']].map(([i, l]) =>
  `<span class="row label" style="gap:6px;height:30px;padding:0 12px;border-radius:var(--rK);${l === on ? 'background:var(--raised)' : 'color:var(--ink2)'}">${icon(i, 16)}${l}</span>`).join('')}</div>`;
const suiteHead = on => `<div class="row" style="padding:20px 32px 16px;gap:24px;flex:none"><div class="display">Video suite</div>${suiteTabs(on)}<div class="grow"></div><span class="label">Test renders</span><span class="caption">Free</span><span class="toggle"></span></div>`;
const rigRow = (i, l, v) => `<div class="row" style="height:44px;gap:12px;border-bottom:1px solid var(--hair)"><span class="muted">${icon(i, 20)}</span><span class="label muted" style="width:96px">${l}</span><span class="label grow">${v}</span><span class="muted">${icon('caret-down', 16)}</span></div>`;
const SENT = [['her-face', 'Zelphira, face'], ['her-living', 'Zelphira, body'], ['her-hoodie', 'Zelphira, outfit'], ['sis-face', 'Mara, face'], ['sis-full', 'Mara, denim jacket'], ['cafe-gold', 'Café by the gym']];
const composer = mac('Video suite', suiteHead('Shot') + `<div class="row grow" style="align-items:stretch;padding:0 32px;gap:24px;min-height:0">
  <div class="col grow" style="background:var(--field);border-radius:var(--rC);padding:20px;gap:12px;align-items:center;justify-content:center">
    <div class="row" style="align-self:stretch"><div class="col grow"><span class="heading">New shot</span><span class="caption">8 s, 9:16, 1080p</span></div></div>
    <div class="grow" style="display:grid;place-items:center;width:100%"><div class="col" style="align-items:center;gap:8px;color:var(--ink2)">${icon('video-camera', 24)}<span class="caption">Your take appears here</span></div></div>
  </div>
  <div class="col" style="width:340px;flex:none;background:var(--raised);border-radius:var(--rC);padding:20px 20px;gap:0;border:1px solid var(--hair)">
    <div class="row"><span class="title grow">Rig</span><span class="caption">${icon('plus', 16)} Save rig</span></div>
    <span class="caption" style="margin-bottom:8px">How the shot is filmed.</span>
    ${rigRow('aperture', 'Camera', '35mm film')}${rigRow('lightbulb-filament', 'Light', 'Window light')}${rigRow('palette', 'Look', 'Golden warmth')}
    <div class="row" style="margin-top:16px"><span class="heading grow">Images sent</span><span class="caption">6 of 9</span></div>
    <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px 8px;margin-top:10px">
      ${SENT.map(([i, l], k) => `<div class="col" style="gap:4px"><div class="media" style="aspect-ratio:1"><img src="${img(i)}"><span class="micro" style="position:absolute;left:4px;top:4px;background:var(--raised);padding:1px 5px;border-radius:var(--rP)">${k + 1}</span></div><span class="micro muted" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${l}</span></div>`).join('')}</div>
    <span class="caption" style="margin-top:10px">People first, then the place. MiniMax H3 takes 9.</span>
  </div></div>
  <div class="col" style="padding:16px 32px 20px;gap:12px;flex:none;position:relative">
    <div class="row" style="background:var(--raised);border:1px solid var(--hair);border-radius:var(--rC);padding:16px 18px;min-height:64px">
      <div class="body grow"><span class="mention">@Zelphira</span> and <span class="mention">@Mara</span> share an iced coffee outside <span class="mention">@cafe</span>, laughing, morning light, handheld. Then Mara pulls her toward <span class="mention">@</span><span style="display:inline-block;width:1.5px;height:18px;background:var(--ink);vertical-align:-3px"></span></div>
      <span class="muted">${icon('at', 20)}</span></div>
    <div class="row" style="gap:8px"><span class="chip">${icon('clock', 16)}8 s</span><span class="chip">${icon('device-mobile', 16)}9:16</span><span class="chip">${icon('stack', 16)}1080p</span><div class="grow"></div>
      <span class="btn line">MiniMax H3 <span class="muted">· Higgsfield</span>${icon('caret-down', 16)}</span><span class="btn primary big">Generate · $1.20</span></div>
    <div class="pop" style="left:520px;bottom:128px;width:340px;padding:6px">
      <div class="caption" style="padding:6px 12px 2px">Her</div>
      <div class="mi"><div class="media" style="width:24px;height:24px;border-radius:50%"><img src="${img('her-face')}"></div><span class="label grow">Zelphira</span><span class="caption">in the prompt</span></div>
      <div class="caption" style="padding:8px 12px 2px">Places</div>
      ${PLACES.map(([n, tg, c], i) => `<div class="mi ${i === 0 ? 'on' : ''}"><div class="media" style="width:24px;height:24px"><img src="${img(c)}"></div><span class="label grow">${n}</span><span class="caption">@${tg}</span></div>`).join('')}
      <div class="caption" style="padding:8px 12px 2px">People</div>
      <div class="mi"><div class="media" style="width:24px;height:24px;border-radius:50%"><img src="${img('sis-face')}"></div><span class="label grow">Mara</span><span class="caption">in the prompt</span></div>
      <div class="mi"><div style="width:24px;height:24px;border-radius:50%;border:1px dashed var(--hair)"></div><span class="label grow muted">Jonah</span><span class="caption">needs photos</span></div>
      <div class="caption" style="padding:8px 12px 2px">Pets</div>
      <div class="mi"><span class="muted">${icon('plus', 16)}</span><span class="label grow muted">Add a pet</span></div>
    </div>
  </div>`);

// ---------- 5. Two-person Swap ----------
const marker = (n, x, y, on) => `<div style="position:absolute;left:${x}%;top:${y}%;transform:translate(-50%,-50%);width:28px;height:28px;border-radius:50%;background:${on ? 'var(--accent)' : 'var(--raised)'};color:${on ? '#fff' : 'var(--ink)'};display:grid;place-items:center;font:600 13px Archivo;box-shadow:0 0 0 2px #fff">${n}</div>`;
const castRow = (n, who, name, face, outfit, on) => `<div class="col" style="gap:10px;padding:14px 0;border-top:1px solid var(--hair)">
  <div class="row" style="gap:10px"><span style="width:22px;height:22px;border-radius:50%;background:${on ? 'var(--accent)' : 'var(--field)'};color:${on ? '#fff' : 'var(--ink)'};display:grid;place-items:center;font:600 12px Archivo">${n}</span>
    <span class="label grow">${who}</span><span class="muted">${icon('x', 16)}</span></div>
  <div class="row" style="gap:10px;height:52px;padding:0 12px;background:var(--field);border-radius:var(--rK)">
    <div class="media" style="width:32px;height:32px;border-radius:50%"><img src="${img(face)}"></div>
    <div class="col grow"><span class="label">Becomes ${name}</span><span class="caption">Outfit: ${outfit}</span></div><span class="muted">${icon('caret-down', 16)}</span></div></div>`;
const swap = mac('Video suite', suiteHead('Swap') + `<div class="row grow" style="align-items:stretch;padding:0 32px 24px;gap:24px;min-height:0">
  <div class="col grow" style="background:var(--field);border-radius:var(--rC);padding:20px;gap:14px">
    <div class="row"><div class="col grow"><span class="heading">Sisters walk</span><span class="caption">0:09, 9:16, 2 people found</span></div><span class="btn line">${icon('upload-simple', 16)}Replace clip</span></div>
    <div class="grow" style="display:grid;place-items:center;min-height:0">
      <div class="media" style="height:100%;max-height:560px;aspect-ratio:4/5;border-radius:2px"><img src="${img('two-shot')}">${marker(1, 37, 42, false)}${marker(2, 71, 42, true)}</div></div>
    <div class="caption" style="text-align:center">Click a face to choose who changes. Both are replaced in one pass.</div>
  </div>
  <div class="col" style="width:380px;flex:none;background:var(--raised);border:1px solid var(--hair);border-radius:var(--rC);padding:20px">
    <div class="title">Who becomes whom</div>
    <span class="caption" style="margin-bottom:10px">Motion, camera and sound stay from the clip.</span>
    ${castRow(1, 'Person on the left', 'Zelphira', 'her-face', 'Hoodie', false)}
    ${castRow(2, 'Person on the right', 'Mara', 'sis-face', 'Denim jacket', true)}
    <div class="row" style="height:44px;border-top:1px solid var(--hair)"><span class="label grow">${icon('speaker-high', 16)} Keep clip sound</span><span class="toggle on"></span></div>
    <div class="grow"></div>
    <div class="col" style="gap:4px;background:var(--field);border-radius:var(--rK);padding:12px"><div class="row"><span class="caption grow">9 s at $0.30 per second</span><span class="label">$2.70</span></div>
      <span class="caption">Both people are swapped in one pass. Charged only when the take finishes.</span></div>
    <div class="row" style="gap:8px;margin-top:12px"><span class="btn line grow" style="justify-content:space-between"><span>MiniMax H3 Max Recast <span class="muted">· fal</span></span>${icon('caret-down', 16)}</span><span class="btn primary big">Generate · $2.70</span></div>
  </div></div>`);

// ---------- 6. Empty states ----------
const empty = (i, h, s, btn, chips) => `<div class="col" style="flex:1;align-items:center;gap:10px;padding:160px 40px 40px;text-align:center">
  <span class="muted">${icon(i, 24)}</span><div class="heading">${h}</div><div class="caption" style="max-width:300px">${s}</div>
  <span class="btn primary" style="margin-top:8px">${icon('plus', 16)}${btn}</span>
  ${chips ? `<div class="row" style="gap:6px;margin-top:6px">${chips.map(c => `<span class="chip">${c}</span>`).join('')}</div>` : ''}</div>`;
const empties = mac('Models', header('Places', { empty: true }) + `<div class="row grow" style="align-items:stretch">
  ${empty('map-pin', 'No places yet', 'Add her apartment, gym, a café… A few photos of each keep the background the same in every video.', 'Add a place', ['Apartment', 'Bedroom', 'Gym', 'Café'])}
  <div style="width:1px;background:var(--hair);margin:40px 0"></div>
  ${empty('users', 'No people yet', 'Her sister, a brother, a best friend. Each gets a few photos and their own outfits, and you can @tag them.', 'Add a person')}
  <div style="width:1px;background:var(--hair);margin:40px 0"></div>
  ${empty('paw-print', 'No pets yet', 'Add her dog or cat: a few photos and a name to @tag in a prompt.', 'Add a pet')}</div>
  <div class="caption" style="text-align:center;padding:0 0 24px">Empty Places, People and Pets tabs, side by side for review.</div>`);

// ---------- Android (phone 390×844) ----------
const phone = content => `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body>
<div class="col" style="width:390px;height:844px;overflow:hidden;position:relative">
  <div class="row micro" style="height:28px;padding:0 20px"><span class="grow">9:41</span><span>5G</span></div>${content}</div></body></html>`;
const androidPlaces = phone(`<div class="row" style="height:56px;padding:0 8px;gap:4px"><span style="width:48px;height:48px;display:grid;place-items:center">${icon('caret-left', 24)}</span>
    <div class="media" style="width:32px;height:32px;border-radius:50%"><img src="${img('her-face')}"></div><span class="title grow" style="margin-left:8px">Zelphira</span><span style="width:48px;height:48px;display:grid;place-items:center">${icon('dots-three', 24)}</span></div>
  <div class="row" style="gap:22px;padding:0 16px;border-bottom:1px solid var(--hair);overflow:hidden">
    ${TABS.map(([l]) => `<div class="label" style="height:44px;display:flex;align-items:center;position:relative;flex:none;${l === 'Places' ? '' : 'color:var(--ink2)'}">${l}${l === 'Places' ? '<i style="position:absolute;left:0;right:0;bottom:-1px;height:2px;background:var(--accent)"></i>' : ''}</div>`).join('')}</div>
  <div class="caption" style="padding:14px 16px 4px">Type @ and a place name in any prompt.</div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:18px 12px;padding:8px 16px">${PLACES.map(p => placeTile(p)).join('')}</div>
  <div class="grow"></div>
  <div style="padding:12px 16px 28px"><span class="btn primary big" style="width:100%;justify-content:center;height:48px">${icon('plus', 20)}Add a place</span></div>`);
const androidSheet = phone(`<div class="row" style="height:56px;padding:0 8px;gap:4px"><span style="width:48px;height:48px;display:grid;place-items:center">${icon('caret-left', 24)}</span><span class="title grow">Café by the gym</span></div>
  <div class="row" style="gap:8px;padding:0 16px"><span class="chip">@cafe</span><span class="caption">5 photos</span></div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;padding:14px 16px">${['cafe-day', 'cafe-gold', 'cafe-night', 'cafe-rain'].map(c => `<div class="media" style="aspect-ratio:1"><img src="${img(c)}"></div>`).join('')}</div>
  <div style="position:absolute;inset:0;background:rgba(20,18,16,.32)"></div>
  <div class="col" style="position:absolute;left:0;right:0;bottom:0;background:var(--raised);border-radius:12px 12px 0 0;padding:8px 8px 28px">
    <div style="width:36px;height:4px;border-radius:2px;background:var(--hair);align-self:center;margin-bottom:10px"></div>
    <div class="title" style="padding:4px 16px 10px">Add photo</div>
    ${[['upload-simple', 'Upload photos', 'From your phone', 'Free'], ['shuffle', 'A random view', 'Made from this place’s photos', '$0.03'], ['text-aa', 'From a description', '“The counter from inside, morning”', '$0.03'], ['image', 'From a reference picture', 'A photo you like, rebuilt as this place', '$0.04']].map(([i, l, s, p]) =>
      `<div class="row" style="gap:14px;height:64px;padding:0 16px">${icon(i, 24)}<div class="col grow"><span class="label">${l}</span><span class="caption">${s}</span></div><span class="caption">${p}</span></div>`).join('')}
    <div class="caption" style="padding:8px 16px 0">You approve the price before anything is made.</div></div>`);

const pages = {
  '1-mac-her-page-profile': [profile, 1440, 900], '2-mac-places': [places, 1440, 900], '3-mac-people': [people, 1440, 900],
  '4-mac-composer-mentions': [composer, 1440, 900], '5-mac-two-person-swap': [swap, 1440, 900], '6-mac-empty-states': [empties, 1440, 900],
  '7-android-places': [androidPlaces, 390, 844], '8-android-add-photo': [androidSheet, 390, 844],
};
const browser = await chromium.launch();
for (const [name, [html, w, h]] of Object.entries(pages)) {
  const f = path.join(here, `${name}.html`);
  fs.writeFileSync(f, html);
  const p = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: w < 500 ? 3 : 1 });
  await p.goto(`file://${f}`); await p.waitForTimeout(250);
  await p.screenshot({ path: path.join(out, `${name}.png`) });
  await p.close(); fs.unlinkSync(f);
}
await browser.close();
console.log('done', Object.keys(pages).length);

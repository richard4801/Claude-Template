// A server render of an edit project (workstream 1; Release 1: "Your edit" in Recreate's Compare, and Recreate's
// export). ffmpeg, CPU, one render at a time. What it draws:
// - the main track: trims, speed and speed curves (the same constant-speed pieces the apps use), cover/contain fit,
//   transform and x/y/scale keyframes (camera moves), transitions (xfade), and the Look's LUT at its strength;
// - adjustment layers over the joined picture, under the text (runs of one colour matrix; keyed ones sampled);
// - text items: the apps' fonts (or the member's own font file), size, colour, stroke, position, timing;
// - sound: each clip's own sound (at its speed) plus music/voice/sfx clips, each with its gain over time (model.ts
//   audioEnvelope: volume and its keys, fades, transition crossfades, ducking) and its voice (audio.ts voiceChain);
//   project mute; or an external guide track instead.
// Anything else in the project is left out and listed in `unsupported` (test/render-coverage.test.ts checks every
// field of the model is drawn or listed), so the apps can say the render is a preview of the cut.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LOOK_IDS } from './lookpack.js';
import { FILTERS } from './presets.js';
import * as M from './model.js';
import { hash01 } from './look.js';
import { voiceChain } from './audio.js';
import { LOOK_DIR, PALETTE_DIR, paletteFiles } from './photo.js';

const here = path.dirname(fileURLToPath(import.meta.url));
export const FONT_DIR = path.resolve(here, '../../assets/fonts');
/** The apps' family per editor font (Mac EditV2TextRenderer; rounded has no bundled face, Outfit stands in). */
const FONTS: Record<M.TextStyle['font'], Record<'regular' | 'bold' | 'black', string>> = {
  sans: { regular: 'figtree_400', bold: 'figtree_700', black: 'figtree_800' },
  serif: { regular: 'instrument_serif_400', bold: 'instrument_serif_400', black: 'instrument_serif_400' },
  rounded: { regular: 'outfit_400', bold: 'outfit_700', black: 'outfit_700' },
  condensed: { regular: 'barlow_condensed_500', bold: 'barlow_condensed_700', black: 'barlow_condensed_700' },
  mono: { regular: 'dm_mono_400', bold: 'dm_mono_500', black: 'dm_mono_500' },
  marker: { regular: 'permanent_marker_400', bold: 'permanent_marker_400', black: 'permanent_marker_400' },
};
export const fontFile = (f: M.TextStyle['font'], weight: number) =>
  path.join(FONT_DIR, `${(FONTS[f] ?? FONTS.sans)[weight >= 900 ? 'black' : weight >= 700 ? 'bold' : 'regular']}.ttf`);

/** The editor transition → ffmpeg xfade (ffmpeg 5.1 names). */
const XFADE: Record<M.TransitionKind, string> = {
  fade: 'fade', black: 'fadeblack', white: 'fadewhite', slideLeft: 'slideleft', slideRight: 'slideright', slideUp: 'slideup', slideDown: 'slidedown',
  zoom: 'zoomin', whip: 'smoothleft', spin: 'radial', glitch: 'pixelize',
};

/**
 * The editor's glitch as the apps draw it (model.ts transitionState): a hard switch at the middle of the transition,
 * the picture jittering sideways (up to 4 % of the width) with red and blue pulled apart (up to 2 %), both strongest
 * at the switch. The switch is a one-frame fade at the middle, with both clips trimmed so the length and the cut times
 * are exactly a full xfade's, and both streams read together as in any xfade. `start` and `d` are frames on the
 * timeline.
 */
export function glitchSwitch(a: string, b: string, out: string, start: number, d: number, i: number, FPS: number): string[] {
  const half = Math.floor(d / 2);
  return [
    `[${a}]trim=end_frame=${start + half + 1}[gx${i}]`,
    `[${b}]trim=start_frame=${half},setpts=PTS-STARTPTS[gy${i}]`,
    `[gx${i}][gy${i}]xfade=transition=fade:duration=${n4(1 / FPS)}:offset=${n4((start + half) / FPS)}[${out}]`,
  ];
}
/**
 * The glitches' jitter and colour split, frame by frame, as rgbashift commands (one filter on the joined picture; a
 * per-pixel xfade expression took ~45 s for 0.4 s at 1080 × 1920). Red, green and blue move by the jitter, red and
 * blue a little further apart; back to rest after each window.
 */
export function glitchShifts(windows: { start: number; d: number }[], W: number, FPS: number, name: string): string {
  const cmds: string[] = [];
  const set = (f: number, r: number, g: number, bl: number) =>
    cmds.push(`${n4(f / FPS)} ${name} rh ${r}, ${name} gh ${g}, ${name} bh ${bl}`);
  for (const w of windows) {
    for (let k = 0; k < w.d; k++) {
      const p = (k + 0.5) / w.d, peak = Math.sin(Math.PI * p);
      const jit = (hash01(Math.floor(p * 24), p < 0.5 ? 1 : 2, 7) - 0.5) * 2;
      const dx = Math.round(0.04 * W * peak * jit), split = Math.round(0.02 * W * peak);
      const c = (v: number) => Math.max(-255, Math.min(255, v));
      set(w.start + k, c(dx + split), c(dx), c(dx - split));
    }
    set(w.start + w.d, 0, 0, 0);
  }
  return cmds.join(';');
}

/** A look's LUT file: a pack look, a palette, or an imported .cube (asset id → file from `files`). */
function lutFile(ref: string, files: Record<string, string>): string | null {
  if (ref.startsWith('pack:')) { const id = ref.slice(5); return LOOK_IDS.has(id) ? path.join(LOOK_DIR, `${id}.cube`) : null; }
  if (ref.startsWith('palette:')) { const f = paletteFiles().get(ref.slice(8)); return f ? path.join(PALETTE_DIR, f) : null; }
  return files[ref] ?? null;
}

const n4 = (x: number) => String(Math.round(x * 10000) / 10000);
const n6 = (x: number) => String(Math.round(x * 1e6) / 1e6);
/** model.ts `ease` on a 0–1 progress expression `p`, as an ffmpeg expression. */
export function easeExpr(kind: M.Ease | undefined, p: string): string {
  switch (kind ?? 'linear') {
    case 'easeIn': return `pow(${p},2)`;
    case 'easeOut': return `(1-pow(1-${p},2))`;
    case 'easeInOut': return `if(lt(${p},0.5),2*pow(${p},2),1-pow(2-2*${p},2)/2)`;
    case 'hold': return '0';
    default: return p;
  }
}
/**
 * The value of keyframes at `t` as an ffmpeg expression (model.ts keyframeValue: constant before the first and after the
 * last, each span eased by its first key's ease). `tv` is the time variable (t for most filters, T for geq, …).
 */
export function kfExpr(keys: M.Keyframe[] | undefined, fallback: number, tv = 't'): string {
  const k = keys ?? [];
  if (!k.length) return n4(fallback);
  if (k.length === 1) return n4(k[0]!.v);
  let e = n4(k.at(-1)!.v);
  for (let i = k.length - 2; i >= 0; i--) {
    const a = k[i]!, b = k[i + 1]!, dt = b.t - a.t;
    if (dt <= 0) { e = `if(lt(${tv},${n4(b.t)}),${n4(b.v)},${e})`; continue; }
    const p = `((${tv}-${n4(a.t)})/${n4(dt)})`;
    e = `if(lt(${tv},${n4(b.t)}),${n4(a.v)}+(${n4(b.v - a.v)})*${easeExpr(a.ease, p)},${e})`;
  }
  return `if(lt(${tv},${n4(k[0]!.t)}),${n4(k[0]!.v)},${e})`;
}
/**
 * A gain envelope (model.ts audioEnvelope: piecewise-linear points on the timeline) as a flat ffmpeg expression in t: a
 * sum of the non-silent spans (no deep nesting, so long ducked beds stay cheap to parse); silent before and after.
 */
export function envExpr(env: M.GainPoint[]): string {
  const parts: string[] = [];
  for (let i = 0; i + 1 < env.length; i++) {
    const a = env[i]!, b = env[i + 1]!, dt = b.t - a.t;
    if (dt <= 0 || (a.gain === 0 && b.gain === 0)) continue;
    const lin = a.gain === b.gain ? n6(a.gain) : `(${n6(a.gain)}+(${n6(b.gain - a.gain)})*(t-${n6(a.t)})/${n6(dt)})`;
    parts.push(`between(t,${n6(a.t)},${n6(b.t)})*lt(t,${n6(b.t)})*${lin}`);
  }
  const last = env.at(-1);
  if (last && last.gain) parts.push(`eq(t,${n6(last.t)})*${n6(last.gain)}`);
  return parts.join('+') || '0';
}
/** atempo stages for a speed (each stage 0.5–2). */
export function atempo(speed: number): string[] {
  const out: string[] = [];
  let s = speed;
  while (s > 2) { out.push('atempo=2'); s /= 2; }
  while (s < 0.5) { out.push('atempo=0.5'); s /= 0.5; }
  if (Math.abs(s - 1) > 1e-4) out.push(`atempo=${n4(s)}`);
  return out;
}
const color = (hex: string | undefined, alpha = 1) => `0x${(hex ?? '#000000').replace('#', '').slice(0, 6).padEnd(6, '0')}${alpha < 1 ? `@${n4(Math.max(0, alpha))}` : ''}`;
const even = (x: number) => Math.max(2, Math.round(x / 2) * 2);

/** Rough line wrap for a text box (the apps measure; ~0.55 em per character is close for these faces). */
export function wrap(text: string, fontPx: number, maxPx: number): string[] {
  const per = Math.max(4, Math.floor(maxPx / (fontPx * 0.55)));
  const out: string[] = [];
  for (const para of text.split('\n')) {
    let line = '';
    for (const w of para.split(/\s+/).filter(Boolean)) {
      if (!line) line = w; else if ((line + ' ' + w).length <= per) line += ' ' + w; else { out.push(line); line = w; }
    }
    out.push(line);
  }
  return out;
}

export type RenderOptions = {
  /** The longest side of the output (default: the canvas); preview renders use 720. */
  maxSide?: number;
  fps?: number;
  /** 'project': the clips' and tracks' sound; 'none': silent; or a guide track (a file) instead of the project's sound. */
  audio?: 'project' | 'none' | { file: string; volume?: number };
  /** Make the output exactly this long (padding with the last frame / cutting), e.g. a reference's length. */
  durationSec?: number;
  quality?: 'preview' | 'export';
};
export type RenderPlan = { args: string[]; durationSec: number; width: number; height: number; unsupported: string[]; temp: string[] };

/**
 * The ffmpeg arguments for a project. `files` maps asset ids to local files or URLs; `sizes` gives each video asset's
 * pixel size (the cover/contain fit needs it); `hasAudio` says which have sound.
 */
export function planRender(p: M.EditProject, files: Record<string, string>, sizes: Record<string, { width: number; height: number; hasAudio: boolean }>, out: string, o: RenderOptions = {}): RenderPlan {
  const unsupported = new Set<string>();
  const temp: string[] = [];
  const f = Math.min(1, (o.maxSide ?? Math.max(p.canvas.width, p.canvas.height)) / Math.max(p.canvas.width, p.canvas.height));
  const W = even(p.canvas.width * f), H = even(p.canvas.height * f), FPS = Math.min(o.fps ?? p.canvas.fps ?? 30, 60);
  const inputs: string[] = [], index = new Map<string, number>();
  const input = (file: string) => { let i = index.get(file); if (i === undefined) { i = inputs.length; inputs.push(file); index.set(file, i); } return i; };
  const g: string[] = [];
  const main = M.mainTrack(p), clips = main.items as M.VideoClip[], tl = M.timeline(p);
  if (main.hidden) unsupported.add('a hidden main track');
  if (!clips.length) throw new Error('nothing on the main track');
  const total = o.durationSec ?? (tl.at(-1)?.endSec ?? 0);
  const fr = (t: number) => Math.round(t * FPS);
  /** A clip's frames: from its first frame on the timeline to its last. */
  const frames = (i: number) => Math.max(1, fr(tl[i]!.endSec) - fr(tl[i]!.startSec));

  clips.forEach((c, i) => {
    const asset = p.assets.find(a => a.id === c.asset);
    const file = asset && files[asset.id], size = asset && sizes[asset.id];
    const len = M.clipLength(c);
    if (!asset || !file || !size) { g.push(`color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4(len + 1)},trim=end_frame=${frames(i)},setpts=N/${FPS}/TB,format=yuv420p,setsar=1,settb=AVTB[v${i}]`); unsupported.add('missing media'); return; }
    const k = input(file);
    const pieces = M.speedPieces(c);
    pieces.forEach((pc, j) => g.push(`[${k}:v]trim=start=${n4(pc.inSec)}:end=${n4(pc.outSec)},setpts=(PTS-STARTPTS)/${n4(pc.speed)},fps=${FPS}[p${i}_${j}]`));
    const src = pieces.length > 1 ? (g.push(`${pieces.map((_, j) => `[p${i}_${j}]`).join('')}concat=n=${pieces.length}:v=1:a=0[s${i}]`), `s${i}`) : `p${i}_0`;
    // Fit and transform: scaled about its centre onto the canvas (cover by default), the keys over time.
    const base = (c.fit === 'contain' ? Math.min : Math.max)(W / size.width, H / size.height);
    const kf = c.keyframes ?? {}, tr = c.transform ?? {};
    const S = kfExpr(kf.scale, tr.scale ?? 1), X = kfExpr(kf.x, tr.x ?? 0.5), Y = kfExpr(kf.y, tr.y ?? 0.5);
    const moving = !!(kf.scale?.length || kf.x?.length || kf.y?.length);
    if (tr.rotation || kf.rotation?.length) unsupported.add('rotation');
    if ((c.opacity ?? 1) !== 1 || kf.opacity?.length) unsupported.add('opacity');
    if (c.animIn && c.animIn.kind !== 'none' || c.animOut && c.animOut.kind !== 'none') unsupported.add('clip animation');
    if (M.COLOR_KF_PROPS.some(p => kf[p]?.length)) unsupported.add('colour keyframes');
    if (M.LOOK_KF_PROPS.some(p => kf[p]?.length)) unsupported.add('look details (curves, grain, …)');
    if (tr.flipX || tr.flipY) unsupported.add('mirror (flip)');
    if (c.holdSec !== undefined) unsupported.add('freeze frames');
    if (p.canvas.fill === 'blur' && c.fit === 'contain') unsupported.add('blur fill');
    for (const [k2, name] of [['crop', 'crop'], ['adjust', 'colour adjustments'], ['filter', 'filters'], ['mask', 'masks'], ['chroma', 'chroma key'], ['alphaMatte', 'background removal']] as const)
      if ((c as Record<string, unknown>)[k2] !== undefined) unsupported.add(name);
    const sw = `trunc(${n4(size.width * base)}*(${S})/2)*2`, sh = `trunc(${n4(size.height * base)}*(${S})/2)*2`;
    g.push(`[${src}]scale=w='${sw}':h='${sh}':eval=${moving ? 'frame' : 'init'},setsar=1[f${i}]`);
    g.push(`color=c=${color(p.canvas.background)}:s=${W}x${H}:r=${FPS}:d=${n4(len + 1)}[bg${i}]`);
    let last = `o${i}`;
    g.push(`[bg${i}][f${i}]overlay=x='${n4(W)}*(${X})-overlay_w/2':y='${n4(H)}*(${Y})-overlay_h/2':eval=${moving ? 'frame' : 'init'}[${last}]`);
    // The Look: its LUT at its strength (the look's other parts are not drawn here).
    const lut = c.look?.lut ? lutFile(c.look.lut, files) : null;
    if (c.look?.lut && !lut) unsupported.add('a look that is not on the server');
    if (lut) {
      const s = Math.max(0, Math.min(1, c.look!.strength ?? 1));
      const esc = lut.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, '');
      if (s >= 0.999) g.push(`[${last}]lut3d=file='${esc}'[l${i}]`);
      else g.push(`[${last}]split[la${i}][lb${i}];[lb${i}]lut3d=file='${esc}'[lc${i}];[la${i}][lc${i}]blend=all_mode=normal:all_opacity=${n4(s)}[l${i}]`);
      last = `l${i}`;
    }
    if (c.look && Object.keys(c.look).some(x => !['lut', 'strength'].includes(x))) unsupported.add('look details (curves, grain, …)');
    // Exactly the clip's frames on the timeline (rounded once from the timeline, so cuts never drift).
    g.push(`[${last}]trim=end_frame=${frames(i)},setpts=N/${FPS}/TB,format=yuv420p,setsar=1,fps=${FPS},settb=AVTB[v${i}]`);
  });
  // Join: a cut is a concat, a transition an xfade at the clip's place on the timeline.
  let acc = 'v0';
  const glitches: { start: number; d: number }[] = [];
  for (let i = 1; i < clips.length; i++) {
    const t = clips[i]!.transitionIn, next = `j${i}`;
    const d = t && tl[i]!.transitionSec > 0 ? fr(tl[i - 1]!.endSec) - fr(tl[i]!.startSec) : 0;
    if (t?.kind === 'glitch' && d >= 2) { g.push(...glitchSwitch(acc, `v${i}`, next, fr(tl[i]!.startSec), d, i, FPS)); glitches.push({ start: fr(tl[i]!.startSec), d }); }
    else if (t && d > 0) g.push(`[${acc}][v${i}]xfade=transition=${XFADE[t.kind] ?? 'fade'}:duration=${n4(d / FPS)}:offset=${n4(fr(tl[i]!.startSec) / FPS)}[${next}]`);
    else g.push(`[${acc}][v${i}]concat=n=2:v=1:a=0[${next}]`);
    acc = next;
  }

  // The glitches' jitter and colour split, on the joined picture.
  if (glitches.length) {
    g.push(`[${acc}]format=gbrp,sendcmd=c='${glitchShifts(glitches, W, FPS, 'rgbashift@glitch')}',rgbashift@glitch=rh=0:gh=0:bh=0:edge=smear,format=yuv420p[gfx]`);
    acc = 'gfx';
  }
  // Adjustment layers: over the joined picture, under the text. Each run of one colour is a channel mix plus its
  // offsets, on only while the run lasts.
  const runs = adjustRuns(p);
  if (runs.length) {
    const st: string[] = ['format=rgb24'];
    for (const { a, b, m } of runs) {
      const on = `enable='gte(t,${n4(a)})*lt(t,${n4(b)})'`;
      st.push(`colorchannelmixer=rr=${n6(m[0]!)}:rg=${n6(m[1]!)}:rb=${n6(m[2]!)}:gr=${n6(m[4]!)}:gg=${n6(m[5]!)}:gb=${n6(m[6]!)}:br=${n6(m[8]!)}:bg=${n6(m[9]!)}:bb=${n6(m[10]!)}:${on}`);
      if (m[3] || m[7] || m[11]) st.push(`lutrgb=r='clip(val+${n4(m[3]! * 255)},0,255)':g='clip(val+${n4(m[7]! * 255)},0,255)':b='clip(val+${n4(m[11]! * 255)},0,255)':${on}`);
    }
    g.push(`[${acc}]${st.join(',')},format=yuv420p[adj]`);
    acc = 'adj';
  }
  // Text items: one drawtext per line (centred by its own width; works on ffmpeg 5.1).
  let vlast = acc, ti = 0;
  for (const tr of p.tracks) {
    if (tr.hidden) continue;
    if (tr.kind === 'caption') { if (tr.items.length || tr.caption) unsupported.add('captions'); continue; }
    if (tr.kind === 'video' || tr.kind === 'image') { if (tr.items.length) unsupported.add('overlays'); continue; }
    if (tr.kind === 'adjust') continue; // drawn above
    if (tr.kind !== 'text') continue;
    for (const it of tr.items as M.TextItem[]) {
      const st = it.style, px = Math.max(6, st.sizePct * H);
      // An own font draws from its downloaded file; without one (not fetched) the fallback family stands in.
      const ownFont = (s: M.TextStyle) => {
        const f = s.fontAsset ? files[s.fontAsset] : undefined;
        if (s.fontAsset && (!f || /^https?:/.test(f))) unsupported.add('own fonts');
        return f && !/^https?:/.test(f) ? f : fontFile(s.font, s.weight);
      };
      if (it.animIn && it.animIn.kind !== 'none' || it.animOut && it.animOut.kind !== 'none' || it.keyframes || it.animLoop) unsupported.add('text animation');
      if (st.shadow || st.background || st.letterSpacing) unsupported.add('text styling (shadow, box, letter spacing)');
      if ((it.transform?.scale ?? 1) !== 1 || it.transform?.rotation || it.transform?.flipX || it.transform?.flipY) unsupported.add('text scale and rotation');
      const lines = wrap(st.uppercase ? it.text.toUpperCase() : it.text, px, (st.maxWidthPct ?? 0.9) * W);
      const lh = px * (st.lineHeight ?? 1.15), cx = (it.transform?.x ?? 0.5) * W, cy = (it.transform?.y ?? 0.5) * H;
      lines.forEach((line, li) => {
        const file = path.join(os.tmpdir(), `muse-text-${process.pid}-${Date.now()}-${ti}-${li}.txt`);
        fs.writeFileSync(file, line); temp.push(file);
        const y = cy - (lines.length * lh) / 2 + li * lh;
        const x = st.align === 'left' ? `${n4(cx - ((st.maxWidthPct ?? 0.9) * W) / 2)}` : st.align === 'right' ? `${n4(cx + ((st.maxWidthPct ?? 0.9) * W) / 2)}-text_w` : `${n4(cx)}-text_w/2`;
        const stroke = st.stroke ? `:borderw=${n4(Math.max(1, st.stroke.widthPct * px))}:bordercolor=${color(st.stroke.color)}` : '';
        const next = `t${ti}_${li}`;
        g.push(`[${vlast}]drawtext=fontfile='${ownFont(st).replace(/:/g, '\\:')}':textfile='${file.replace(/:/g, '\\:')}':fontsize=${n4(px)}:fontcolor=${color(st.color, it.opacity ?? 1)}${stroke}:x='${x}':y=${n4(y)}:enable='between(t,${n4(it.startSec)},${n4(it.startSec + it.durationSec)})'[${next}]`);
        vlast = next;
      });
      ti++;
    }
  }
  g.push(`[${vlast}]tpad=stop_mode=clone:stop_duration=${n4(Math.max(0, total))},trim=duration=${n4(total)},setpts=PTS-STARTPTS,format=yuv420p[vout]`);

  // Sound.
  const amix: string[] = [];
  const A = 'aformat=sample_rates=48000:channel_layouts=stereo';
  if (o.audio && typeof o.audio === 'object') {
    const k = input(o.audio.file);
    g.push(`[${k}:a]atrim=0:${n4(total)},asetpts=PTS-STARTPTS,${A},volume=${n4(o.audio.volume ?? 1)}[ag]`);
    amix.push('ag');
  } else if (o.audio !== 'none' && !p.mute) {
    // Each clip's sound: its source cut and timed like its picture, its voice (enhance, effect), placed on the timeline,
    // then its gain over time (model.ts audioEnvelope: volume and its keys, fades, transition crossfades, ducking).
    const voice = (c: M.VideoClip | M.AudioClip) => voiceChain(c, 48000).map(q => `,biquad=b0=${q.b0}:b1=${q.b1}:b2=${q.b2}:a0=1:a1=${q.a1}:a2=${q.a2}`).join('');
    const envelope = (c: M.VideoClip | M.AudioClip, trackId: string) => {
      const env = M.audioEnvelope(p, trackId, c.id);
      return env.some(x => x.gain > 0) ? env : null; // silent throughout: left out
    };
    const place = (src: string, c: M.VideoClip | M.AudioClip, env: M.GainPoint[], startSec: number, name: string) => {
      const ms = Math.round(startSec * 1000);
      const gain = env.every(x => x.gain === env[0]!.gain) ? n4(env[0]!.gain) : `'${envExpr(env)}':eval=frame`;
      g.push(`[${src}]${voice(c).replace(/^,/, '') || 'anull'},adelay=${ms}|${ms},volume=${gain}[${name}]`);
      amix.push(name);
    };
    clips.forEach((c, i) => {
      const asset = p.assets.find(a => a.id === (c.audioAsset ?? c.asset)), file = asset && files[asset.id];
      const env = asset && file && sizes[asset.id]?.hasAudio ? envelope(c, main.id) : null;
      if (!env || !file) return;
      const k = input(file), pieces = M.speedPieces(c);
      pieces.forEach((pc, j) => g.push(`[${k}:a]atrim=start=${n4(pc.inSec)}:end=${n4(pc.outSec)},asetpts=PTS-STARTPTS,${A}${atempo(pc.speed).map(x => `,${x}`).join('')}[ap${i}_${j}]`));
      const s = pieces.length > 1 ? (g.push(`${pieces.map((_, j) => `[ap${i}_${j}]`).join('')}concat=n=${pieces.length}:v=0:a=1[as${i}]`), `as${i}`) : `ap${i}_0`;
      place(s, c, env, tl[i]!.startSec, `ac${i}`);
    });
    let ai = 0;
    for (const tr of p.tracks.filter(t => (t.kind === 'music' || t.kind === 'voice' || t.kind === 'sfx') && !t.muted)) {
      for (const it of tr.items as M.AudioClip[]) {
        const asset = p.assets.find(a => a.id === it.asset), file = asset && files[asset.id];
        if (!asset || !file || it.muted) { if (asset?.library && !it.muted) unsupported.add('library music'); continue; }
        const env = sizes[asset.id]?.hasAudio ? envelope(it, tr.id) : null;
        if (!env) continue;
        const k = input(file);
        g.push(`[${k}:a]atrim=start=${n4(it.inSec)}:end=${n4(it.outSec)},asetpts=PTS-STARTPTS,${A}${atempo(it.speed ?? 1).map(x => `,${x}`).join('')}[ar${ai}]`);
        place(`ar${ai}`, it, env, it.startSec, `at${ai}`);
        ai++;
      }
    }
  }
  if (amix.length) g.push(`${amix.map(x => `[${x}]`).join('')}amix=inputs=${amix.length}:normalize=0:duration=longest,apad,atrim=0:${n4(total)}[aout]`);

  const q = o.quality === 'export' ? ['-preset', 'veryfast', '-crf', '18'] : ['-preset', 'ultrafast', '-crf', '28'];
  const args = ['-y', '-v', 'error', ...inputs.flatMap(x => ['-i', x]), '-filter_complex', g.join(';'), '-map', '[vout]', ...(amix.length ? ['-map', '[aout]', '-c:a', 'aac', '-b:a', '128k'] : []),
    '-c:v', 'libx264', ...q, '-pix_fmt', 'yuv420p', '-r', String(FPS), '-movflags', '+faststart', '-threads', '2', '-t', n4(total), out];
  return { args, durationSec: total, width: W, height: H, unsupported: [...unsupported], temp };
}

/**
 * Adjustment layers ([M.adjustLayerMatrix]) as runs of one matrix: split at every layer's start and end, and every
 * [stepSec] inside a layer with keyframes; equal neighbours merged; identity left out. A long keyed layer samples
 * more coarsely so the graph stays under [maxRuns].
 */
export function adjustRuns(p: M.EditProject, stepSec = 0.1, maxRuns = 600): { a: number; b: number; m: number[] }[] {
  const items = p.tracks.filter(t => t.kind === 'adjust' && !t.hidden).flatMap(t => t.items as M.AdjustItem[]);
  if (!items.length) return [];
  const keyed = items.filter(it => it.keyframes && Object.values(it.keyframes).some(k => k?.length));
  const keyedSec = keyed.reduce((s, it) => s + it.durationSec, 0);
  const step = Math.max(stepSec, keyedSec / maxRuns);
  const cuts = new Set<number>();
  const r4 = (x: number) => Math.round(x * 1e4) / 1e4;
  for (const it of items) { cuts.add(r4(it.startSec)); cuts.add(r4(it.startSec + it.durationSec)); }
  for (const it of keyed) for (let t = it.startSec + step; t < it.startSec + it.durationSec - 1e-6; t += step) cuts.add(r4(t));
  const ts = [...cuts].sort((x, y) => x - y);
  const out: { a: number; b: number; m: number[] }[] = [];
  for (let i = 0; i + 1 < ts.length; i++) {
    const a = ts[i]!, b = ts[i + 1]!;
    const m = M.adjustLayerMatrix(p, a, FILTERS);
    const last = out.at(-1);
    if (!m) continue;
    if (last && Math.abs(last.b - a) < 1e-9 && last.m.every((v, k) => v === m[k])) last.b = b;
    else out.push({ a, b, m });
  }
  return out;
}

/** A file's picture size and whether it has sound; audio-only files too (media.ts probe wants a picture). Null if unreadable. */
async function probeStreams(ffprobe: string, file: string): Promise<{ width: number; height: number; hasAudio: boolean } | null> {
  const out = await new Promise<string | null>(resolve => execFile(ffprobe, ['-v', 'error', '-print_format', 'json', '-show_streams', file], { timeout: 60_000, maxBuffer: 4 * 1024 * 1024 },
    (err, o) => resolve(err ? null : o)));
  if (!out) return null;
  try {
    const st = (JSON.parse(out) as { streams?: { codec_type?: string; width?: number; height?: number }[] }).streams ?? [];
    const v = st.find(x => x.codec_type === 'video');
    if (!v && !st.some(x => x.codec_type === 'audio')) return null;
    return { width: v?.width ?? 0, height: v?.height ?? 0, hasAudio: st.some(x => x.codec_type === 'audio') };
  } catch { return null; }
}

/** Probes each asset file (size, sound), plans and runs the render. */
export async function renderProject(cfg: { ffmpeg: string; ffprobe: string }, p: M.EditProject, files: Record<string, string>, out: string, o: RenderOptions = {}) {
  const sizes: Record<string, { width: number; height: number; hasAudio: boolean }> = {};
  for (const [id, file] of Object.entries(files)) {
    const a = p.assets.find(x => x.id === id);
    if (!a || a.kind === 'lut' || a.kind === 'font') continue;
    const info = await probeStreams(cfg.ffprobe, file);
    if (info) sizes[id] = { width: info.width || a.width || 1080, height: info.height || a.height || 1920, hasAudio: info.hasAudio };
  }
  const plan = planRender(p, files, sizes, out, o);
  try {
    await new Promise<void>((resolve, reject) => execFile(cfg.ffmpeg, plan.args, { timeout: 15 * 60_000, maxBuffer: 8 * 1024 * 1024 },
      (err, _o, e) => (err ? reject(new Error(`render failed: ${String(e ?? err.message).trim().split('\n').slice(-2).join(' ').slice(0, 300)}`)) : resolve())));
  } finally { for (const t of plan.temp) fs.rmSync(t, { force: true }); }
  return { durationSec: plan.durationSec, width: plan.width, height: plan.height, unsupported: plan.unsupported };
}

// sync_map (free, plus an optional Gemini call): study a REFERENCE edit the owner likes, where actions (a punch, a slide,
// a slap, food landing on a tray) "play" the song. The video's own sound gives every note hit (song_notes), its picture
// gives the impacts (find_impacts); impacts within ±60 ms of a note are pairs. From the pairs: the edit's style (how many
// strong notes get an action, on the beat or off it, early/on/late, density per section, drums or melody) and a template
// of target times (with their note, band and gap pattern) that sync_hits can follow on the owner's own footage.
import { execFile } from 'node:child_process';
import type { EditTool, ToolEnv } from '../editor/mcpTools.js';
import type { Impact } from '../editor/motion.js';
import { editorAi } from '../editor/service.js';
import { oneAtATime } from '../lib/mediaLane.js';
import type { Band } from './songDsp.js';
import { geminiJson, impactsOf, songOf, type SongAnalysis } from './songNotes.js';
import { IN_EDIT } from './watch.js';

export type Pair = { t: number; onset: number; offsetMs: number; band: Band; pitch: string; onsetStrength: number; kind: Impact['kind']; onBeat: boolean; label?: string };
export type SyncMap = ReturnType<typeof syncMap>;

const r3 = (v: number) => Math.round(v * 1000) / 1000, r2 = (v: number) => Math.round(v * 100) / 100;
const median = (v: number[]) => { if (!v.length) return 0; const s = [...v].sort((a, b) => a - b), m = s.length >> 1; return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2; };

/** Pairs impacts with note hits (each used once, nearest first) and reads the style and template from them (pure). */
export function syncMap(song: SongAnalysis, impacts: Impact[], o: { toleranceMs?: number; strong?: number } = {}) {
  const tol = (o.toleranceMs ?? 60) / 1000, strongMin = o.strong ?? 0.4;
  const beats = song.tempo.beats, onBeat = (t: number) => beats.some(b => Math.abs(b - t) <= 0.07);
  const cand: { i: number; j: number; d: number }[] = [];
  impacts.forEach((im, i) => song.noteOnsets.forEach((n, j) => { const d = Math.abs(im.t - n.t); if (d <= tol + 1e-9) cand.push({ i, j, d }); }));
  const usedI = new Set<number>(), usedJ = new Set<number>(), pairs: Pair[] = [];
  for (const c of cand.sort((a, b) => a.d - b.d || song.noteOnsets[b.j]!.strength - song.noteOnsets[a.j]!.strength)) {
    if (usedI.has(c.i) || usedJ.has(c.j)) continue;
    usedI.add(c.i); usedJ.add(c.j);
    const im = impacts[c.i]!, n = song.noteOnsets[c.j]!;
    pairs.push({ t: im.t, onset: n.t, offsetMs: Math.round((im.t - n.t) * 1000), band: n.band, pitch: n.pitch, onsetStrength: n.strength, kind: im.kind, onBeat: onBeat(n.t) });
  }
  pairs.sort((a, b) => a.t - b.t);
  const unmatchedImpacts = impacts.filter((_, i) => !usedI.has(i));
  const strong = song.noteOnsets.map((n, j) => ({ n, j })).filter(x => x.n.strength >= strongMin);
  const unmatchedStrongOnsets = strong.filter(x => !usedJ.has(x.j)).map(x => x.n);
  // Style.
  const offs = pairs.map(p => p.offsetMs), typical = Math.round(median(offs));
  const bands = { low: 0, mid: 0, high: 0 } as Record<Band, number>; for (const p of pairs) bands[p.band]++;
  const topBand = (Object.keys(bands) as Band[]).sort((a, b) => bands[b] - bands[a])[0]!;
  const pitches = new Set(pairs.map(p => p.pitch)).size;
  const follows = !pairs.length ? 'nothing yet (no pairs)'
    : topBand === 'mid' || (pitches >= 3 && bands.mid >= bands.low) ? 'the melody / voice notes (mid band, changing pitches)'
    : topBand === 'low' ? 'the drums and bass (kicks, 808s: low band)' : 'the percussion on top (hats, claps, snares: high band)';
  const style = {
    pairs: pairs.length, impacts: impacts.length, strongOnsets: strong.length,
    strongOnsetsWithAction: strong.length ? r2(strong.filter(x => usedJ.has(x.j)).length / strong.length) : 0,
    onBeat: pairs.length ? r2(pairs.filter(p => p.onBeat).length / pairs.length) : 0,
    offBeat: pairs.length ? r2(pairs.filter(p => !p.onBeat).length / pairs.length) : 0,
    typicalOffsetMs: typical, timing: !pairs.length ? 'n/a' : typical < -15 ? `early (actions lead the note by ~${-typical} ms)` : typical > 15 ? `late (actions trail the note by ~${typical} ms)` : 'on the note',
    bands, follows,
    perSection: song.sections.map(s => {
      const n = pairs.filter(p => p.onset >= s.fromSec && p.onset < s.toSec).length, len = Math.max(0.01, s.toSec - s.fromSec);
      return { section: s.name, fromSec: s.fromSec, toSec: s.toSec, pairs: n, actionsPerSec: r2(n / len) };
    }),
    kinds: { stop: pairs.filter(p => p.kind === 'stop').length, start: pairs.filter(p => p.kind === 'start').length, cut: pairs.filter(p => p.kind === 'cut').length },
  };
  // Template: the notes the actions land on (song seconds), with the gap pattern in seconds and in beats.
  const bpm = song.tempo.bpm;
  const targets = pairs.map(p => ({ t: p.onset, band: p.band, pitch: p.pitch, strength: p.onsetStrength, kind: p.kind, onBeat: p.onBeat }));
  const gapsSec = targets.slice(1).map((x, k) => r3(x.t - targets[k]!.t));
  const template = {
    targets, gapsSec, ...(bpm > 0 ? { gapsBeats: gapsSec.map(g => r2((g * bpm) / 60)), bpm } : {}),
    howToUse: 'targets[].t are seconds of the reference\'s song. With the same song on the owner\'s timeline: timeline target = the music item\'s start + (t − its trim-in); feed them to sync_hits as targets (one impact of the owner\'s clip per target, from find_impacts + watch_closer). With another song: keep the gap pattern (gapsBeats × 60 / its bpm) or the same bands (song_notes band filter) and pick its nearest note hits.',
  };
  return { pairs, unmatchedImpacts, unmatchedStrongOnsets, style, template };
}

export const LABELS_PROMPT = `This is a short video edit where on-screen actions land on the music. List every distinct physical action or visual hit with the moment it lands. Answer ONLY with JSON:
{"actions": [{"t": number, "label": string}]}
t is seconds from the start of the video, to the nearest 0.05 s, at the moment of contact or landing (or the cut). label is 1–3 words ("punch", "slide", "fruit lands on tray", "slap", "camera whip", "cut").`;

function encodeVideo(ffmpeg: string, input: string): Promise<{ data: Buffer; mime: string }> {
  return new Promise((resolve, reject) => execFile(ffmpeg, ['-v', 'error', '-threads', '1', '-i', input, '-t', '120', '-vf', 'scale=-2:360,fps=15', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '32',
    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '48k', '-ac', '1', '-movflags', 'frag_keyframe+empty_moov', '-f', 'mp4', 'pipe:1'],
  { encoding: 'buffer', timeout: 180_000, maxBuffer: 20 * 1024 * 1024 }, (err, out) => (err ? reject(err) : resolve({ data: out as Buffer, mime: 'video/mp4' }))));
}

const labelCache = new Map<string, Record<string, unknown>>();

async function run(env: ToolEnv, a: Record<string, unknown>) {
  const { ctx, user: u } = env;
  const ids = { id: a.id, takeId: a.takeId, sessionId: a.sessionId, itemId: a.itemId };
  const { song } = await songOf(ctx, u, ids);
  const im = await impactsOf(env, { ...ids, max: 300 });
  const map = syncMap(song, im.impacts as Impact[], { toleranceMs: Number(a.toleranceMs) || undefined, strong: a.strongOnset === undefined ? undefined : Number(a.strongOnset) });
  const out: Record<string, unknown> = { id: im.id, durationSec: song.durationSec, key: song.key?.name ?? null, bpm: song.tempo.bpm, fps: im.fps, ...map,
    howToRead: 'pairs: impacts (t, the video\'s seconds) within the tolerance of a note hit (onset); offsetMs > 0 = the action lands after the note. kind stop = a landing/contact, start = a sudden move, cut = a hard cut. unmatchedStrongOnsets are strong notes no action plays; unmatchedImpacts are actions on no note. Labels: '
      + (a.labels === true ? 'from the model where it found one; check them' : 'not looked for; name each pair yourself with watch_closer around its t') + '.' };
  if (a.labels === true) {
    const key = `${ctx.config.GEMINI_MODEL}|${im.mediaKey}`;
    const got = u.role !== 'owner' ? { note: 'Action labels are the studio owner\'s (they use the studio\'s own model account).' }
      : labelCache.get(key) ?? await oneAtATime(() => editorAi(ctx).withLocalInput(im.mediaKey, input => geminiJson(ctx, LABELS_PROMPT, () => encodeVideo(ctx.config.FFMPEG_PATH, input), 'Action labels')));
    if (!('note' in got)) { labelCache.set(key, got); while (labelCache.size > 16) labelCache.delete(labelCache.keys().next().value!); }
    const acts = Array.isArray(got.actions) ? (got.actions as { t?: unknown; label?: unknown }[]).filter(x => Number.isFinite(Number(x.t)) && typeof x.label === 'string').map(x => ({ t: Number(x.t), label: String(x.label).slice(0, 60) })) : [];
    for (const p of map.pairs) { const near = acts.filter(x => Math.abs(x.t - p.t) <= 0.25).sort((x, z) => Math.abs(x.t - p.t) - Math.abs(z.t - p.t))[0]; if (near) p.label = near.label; }
    out.labels = 'note' in got ? got : { actions: acts, by: got.by };
  }
  return out;
}

export const SYNC_MAP_TOOLS: EditTool[] = [{
  name: 'sync_map', title: 'Map a reference edit to its music (free)', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'Studies a REFERENCE edit where actions (a punch, a slide, a slap, food landing on a tray) play the song: finds every note hit in the video\'s own sound and every impact in its picture, and pairs those within ±60 ms. Returns pairs {t, onset, offsetMs, band, pitch, onsetStrength, kind start|stop|cut, onBeat}, the unmatched impacts and unmatched strong notes, the style (share of strong notes that get an action, on-beat vs off-beat, early/on/late, density per section, drums or melody) and a template (target times with their notes and the gap pattern in seconds and beats) to feed sync_hits on the owner\'s own footage. labels: true also asks a model to name the actions (owner only; only when the server has it set up), otherwise name them yourself with watch_closer. Takes any id watch takes, or in Edit sessionId + itemId.',
  inputSchema: { type: 'object', additionalProperties: false, properties: {
    id: { type: 'string', maxLength: 300, description: 'The reference video: a take, Library item, clip, uploaded video or /uploads/… link' }, takeId: { type: 'string', maxLength: 80, description: 'The take open on the page (filled in for you)' }, ...IN_EDIT,
    toleranceMs: { type: 'number', minimum: 10, maximum: 200, description: 'How close an impact must be to a note to count (default 60 ms)' },
    strongOnset: { type: 'number', minimum: 0, maximum: 1, description: 'Note hits at least this strong count as strong (default 0.4)' },
    labels: { type: 'boolean', description: 'Also ask a model to name the actions (default false)' } } },
  run,
}];

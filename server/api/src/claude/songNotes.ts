// song_notes and find_impacts (free): what Claude needs to cut picture to individual notes, not just beats.
// song_notes: key + mode (+ Camelot code for chaining songs), tempo and beats, sections, EVERY note hit (t to ~10 ms,
// strength, band, pitch), an energy curve, the lyrics when a caption track exists for the item, and optionally a
// Gemini "listening" (mood, genre, instruments, vocal spans, arc) when GEMINI_API_KEY is set. Analysis is cached per
// stored file (memory, then a small JSON in storage, so a redeploy doesn't redo it). find_impacts: the frames where
// motion stops sharply (a landing, a contact), starts suddenly, or cuts, for picking the frames that must land on notes.
// Heavy ffmpeg work runs one at a time (lib/mediaLane.ts).
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest } from '../errors.js';
import { BEAT_SR, decodeMono, detectBeats } from '../editor/audio.js';
import { requireAssetMedia } from '../editor/assetMedia.js';
import type { EditTool, ToolEnv } from '../editor/mcpTools.js';
import * as M from '../editor/model.js';
import { findCuts, findImpacts, measureMotion } from '../editor/motion.js';
import { editorAi } from '../editor/service.js';
import { leanDecode, oneAtATime } from '../lib/mediaLane.js';
import { mediaToolsAvailable } from '../replicate/media.js';
import { soundFileOf } from './listen.js';
import { chromaFrames, energyCurve, keyOf, noteOnsets, sections, songChroma, type Band, type Key, type Onset, type Section } from './songDsp.js';
import { IN_EDIT, videoOf, watchTarget } from './watch.js';
import { decThreads } from '../lib/resources.js';

const MAX_SEC = 600, VERSION = 1;

export type SongAnalysis = {
  durationSec: number; key: Key | null; tempo: { bpm: number; beats: number[]; strong: number[] };
  sections: Section[]; noteOnsets: Onset[]; energy: { stepSec: number; db: number[] };
};

/** The whole analysis of mono samples at BEAT_SR (pure; exported for tests). */
export function analyseSong(x: Float32Array, sr = BEAT_SR): SongAnalysis {
  const dur = x.length / sr;
  const onsets = noteOnsets(x, sr);
  const frames = chromaFrames(x, sr);
  const b = detectBeats(x, sr);
  // Section boundaries snap to the strongest note hit within ±0.6 s (the block grid is coarse).
  const secs = sections(frames, dur);
  for (let k = 1; k < secs.length; k++) {
    const at = secs[k]!.fromSec, near = onsets.filter(o => Math.abs(o.t - at) <= 0.6).sort((a, z) => z.strength - a.strength)[0];
    if (near && near.strength >= 0.2) { secs[k]!.fromSec = near.t; secs[k - 1]!.toSec = near.t; }
  }
  return { durationSec: Math.round(dur * 1000) / 1000, key: keyOf(songChroma(frames)), tempo: { bpm: b.bpm, beats: b.beats, strong: b.strong }, sections: secs,
    noteOnsets: onsets, energy: { stepSec: 0.25, db: energyCurve(x, sr, 0.25) } };
}

// ---- cache -------------------------------------------------------------------------------------------------------
const mem = new Map<string, unknown>();
const memSet = (k: string, v: unknown) => { mem.delete(k); mem.set(k, v); while (mem.size > 12) mem.delete(mem.keys().next().value!); return v; };
const storeKey = (mediaKey: string, kind: string) => `analysis/song-notes/v${VERSION}/${createHash('sha1').update(mediaKey).digest('hex')}.${kind}.json`;
async function cached<T>(ctx: Ctx, mediaKey: string, kind: string, make: () => Promise<T>, keep: (v: T) => boolean = () => true): Promise<T> {
  const k = `${kind}|${mediaKey}`;
  if (mem.has(k)) return mem.get(k) as T;
  try {
    const o = await ctx.storage.get(storeKey(mediaKey, kind));
    if (o) { const chunks: Buffer[] = []; for await (const c of o.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c)); return memSet(k, JSON.parse(Buffer.concat(chunks).toString('utf8'))) as T; }
  } catch { /* not stored yet */ }
  const v = await make();
  if (keep(v)) { memSet(k, v); await ctx.storage.put(storeKey(mediaKey, kind), Buffer.from(JSON.stringify(v)), 'application/json').catch(() => {}); }
  return v;
}
/** For tests. */
export const clearSongCache = () => mem.clear();

// ---- Gemini listening (optional, paid by the studio's own key; never fails the tool) -------------------------------
export const LISTENING_PROMPT = `Listen to this music as a video editor would. Answer ONLY with JSON:
{"mood": string, "genre": string, "instruments": [string], "vocals": [{"fromSec": number, "toSec": number, "kind": "lead"|"backing"|"rap"|"choir"|"spoken"}],
 "arc": [{"fromSec": number, "toSec": number, "feel": string}], "moments": [{"t": number, "what": string}], "summary": string}
Times are seconds from the start of the audio. "vocals" are the spans where a voice is heard (empty if instrumental). "arc" is the emotional shape in a few spans.
"moments" are notable hits, drops, stops, risers, key changes or lyric lines an editor would cut on (at most 20).`;

function encodeForListening(ffmpeg: string, input: string): Promise<{ data: Buffer; mime: string }> {
  const run = (args: string[], mime: string) => new Promise<{ data: Buffer; mime: string }>((resolve, reject) => execFile(ffmpeg,
    ['-v', 'error', '-threads', decThreads(1), '-i', input, '-vn', '-sn', '-dn', '-ac', '1', '-ar', '16000', '-t', String(MAX_SEC), ...args, 'pipe:1'],
    { encoding: 'buffer', timeout: 120_000, maxBuffer: 20 * 1024 * 1024 }, (err, out) => (err ? reject(err) : resolve({ data: out as Buffer, mime }))));
  return run(['-c:a', 'libmp3lame', '-b:a', '32k', '-f', 'mp3'], 'audio/mp3').catch(() => run(['-c:a', 'aac', '-b:a', '32k', '-f', 'adts'], 'audio/aac'));
}
/** One Gemini call: a prompt and one media part, answered as JSON. The key goes in a header, never in logs or results.
 * Never throws: { note } when there is no key, it failed or the answer was unreadable. */
export async function geminiJson(ctx: Ctx, prompt: string, media: () => Promise<{ data: Buffer; mime: string }>, what: string): Promise<Record<string, unknown>> {
  const c = ctx.config;
  if (!c.GEMINI_API_KEY) return { note: `${what} is off: the server has no GEMINI_API_KEY. The numbers are complete without it.` };
  try {
    const m = await media();
    const res = await fetch(`${c.GEMINI_API_URL.replace(/\/+$/, '')}/v1beta/models/${encodeURIComponent(c.GEMINI_MODEL)}:generateContent`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': c.GEMINI_API_KEY },
      body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: prompt }, { inline_data: { mime_type: m.mime, data: m.data.toString('base64') } }] }],
        generationConfig: { responseMimeType: 'application/json', temperature: 0.2 } }),
      signal: AbortSignal.timeout(120_000),
    });
    if (!res.ok) return { note: `${what} failed (Gemini answered ${res.status}); the numbers are complete without it.` };
    const j = await res.json() as { candidates?: { content?: { parts?: { text?: string }[] } }[] };
    const text = (j.candidates?.[0]?.content?.parts ?? []).map(p => p.text ?? '').join('').trim().replace(/^```(?:json)?\s*|\s*```$/g, '');
    return { ...(JSON.parse(text) as Record<string, unknown>), by: c.GEMINI_MODEL };
  } catch (e) {
    return { note: `${what} failed (${e instanceof SyntaxError ? 'an unreadable answer' : 'no answer'}); the numbers are complete without it.` };
  }
}
/** Gemini's listening to a file's sound (mood, genre, instruments, vocal spans, arc, moments). */
export const geminiListening = (ctx: Ctx, input: string) => geminiJson(ctx, LISTENING_PROMPT, () => encodeForListening(ctx.config.FFMPEG_PATH, input), 'Listening (mood, genre, instruments, vocal spans)');

// ---- where an item sits on the timeline -----------------------------------------------------------------------------
export type Placement = { itemId: string; trackKind: M.TrackKind; startSec: number; endSec: number; toTimeline: (fileSec: number) => number | null };
/** A timeline item's file → timeline mapping (main clips through their speed curve; music, voice and overlays too). */
export function placement(p: M.EditProject, itemId: string): Placement | null {
  for (const t of p.tracks) {
    const it = t.items.find(i => i.id === itemId) as (M.VideoClip | M.AudioClip) | undefined;
    if (!it || typeof (it as M.VideoClip).inSec !== 'number') continue;
    const span = M.itemSpan(p, t, it);
    const c = it as M.VideoClip;
    return { itemId, trackKind: t.kind, startSec: span.startSec, endSec: span.endSec,
      toTimeline: s => (s < c.inSec - 1e-6 || s > c.outSec + 1e-6 ? null : Math.round((span.startSec + M.clipTimeAt({ inSec: c.inSec, outSec: c.outSec, speed: c.speed ?? 1, speedCurve: c.speedCurve, holdSec: c.holdSec }, s)) * 1000) / 1000) };
  }
  return null;
}

/** The analysis of the file an id (or a session item) names, cached. */
export async function songOf(ctx: Ctx, u: AuthUser, a: Record<string, unknown>): Promise<{ id: string; key: string; song: SongAnalysis }> {
  if (!(await mediaToolsAvailable(ctx.config.FFMPEG_PATH, ctx.config.FFPROBE_PATH))) throw new ApiError(503, 'unavailable', 'song_notes needs ffmpeg on the server, which is missing here');
  const f = await soundFileOf(ctx, u, a);
  const song = await cached(ctx, f.key, 'dsp', () => oneAtATime(() => editorAi(ctx).withLocalInput(f.key, async input => {
    const x = await decodeMono(ctx.config.FFMPEG_PATH, input, MAX_SEC).catch(() => new Float32Array(0)); // no sound track at all
    if (x.length < BEAT_SR * 0.5) throw badRequest(`${f.id} has no sound to analyse`);
    return analyseSong(x);
  })));
  return { id: f.id, key: f.key, song };
}

/** The item a song_notes call is about in Edit: itemId, else the edit's first music track item. */
async function sessionItem(ctx: Ctx, u: AuthUser, a: Record<string, unknown>) {
  const sid = typeof a.sessionId === 'string' && a.sessionId ? a.sessionId : undefined;
  if (!sid) return null;
  const { editSessionsOf } = await import('../editor/sessions.js');
  const s = await editSessionsOf(ctx).row(u, sid);
  const p = s.project as unknown as M.EditProject;
  let itemId = typeof a.itemId === 'string' && a.itemId ? a.itemId : undefined;
  if (!itemId && a.id === undefined && a.takeId === undefined) itemId = p.tracks.find(t => t.kind === 'music' && t.items.length)?.items[0]?.id;
  return itemId ? { p, itemId } : null;
}

const r3 = (v: number) => Math.round(v * 1000) / 1000;
const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const num = (d: string, min?: number, max?: number) => ({ type: 'number', description: d, ...(min !== undefined ? { minimum: min } : {}), ...(max !== undefined ? { maximum: max } : {}) });

export async function songNotes(env: ToolEnv, a: Record<string, unknown>) {
  const { ctx, user: u } = env;
  const inEdit = await sessionItem(ctx, u, a);
  const args = inEdit && a.itemId === undefined ? { ...a, itemId: inEdit.itemId } : a;
  const { id, key, song } = await songOf(ctx, u, args);
  const from = a.fromSec === undefined ? 0 : Number(a.fromSec), to = a.toSec === undefined ? Infinity : Number(a.toSec);
  if (!(from >= 0) || !(to > from)) throw badRequest('fromSec/toSec: seconds in the file, toSec > fromSec');
  const band = typeof a.band === 'string' ? a.band as Band : undefined;
  const minStrength = Number(a.minStrength) || 0, max = Math.min(1000, Math.max(1, Number(a.maxOnsets) || 300));
  const place = inEdit ? placement(inEdit.p, inEdit.itemId) : null;
  let onsets = song.noteOnsets.filter(o => o.t >= from && o.t <= to && (!band || o.band === band) && o.strength >= minStrength);
  const total = onsets.length;
  if (onsets.length > max) onsets = [...onsets].sort((x, z) => z.strength - x.strength).slice(0, max).sort((x, z) => x.t - z.t);
  const withTl = onsets.map(o => { const tl = place?.toTimeline(o.t); return tl === null || tl === undefined ? o : { ...o, tl }; });
  const inWin = (t: number) => t >= from && t <= to;
  // Lyrics: the caption track transcribed from this item's asset (word times are the file's seconds).
  let lyrics: { text: string; t: number; end: number }[] | undefined;
  if (inEdit) {
    const it = inEdit.p.tracks.flatMap(t => t.items).find(i => i.id === inEdit.itemId) as { asset?: string } | undefined;
    const cap = inEdit.p.tracks.find(t => t.caption && t.caption.asset === (it?.asset ?? inEdit.itemId))?.caption;
    if (cap) lyrics = cap.words.filter(w => inWin(w.startSec)).slice(0, 400).map(w => ({ text: w.text, t: r3(w.startSec), end: r3(w.endSec) }));
  }
  const out: Record<string, unknown> = {
    id, durationSec: song.durationSec, key: song.key, tempo: { bpm: song.tempo.bpm, beats: song.tempo.beats.filter(inWin), strong: song.tempo.strong.filter(inWin) },
    sections: song.sections, noteOnsets: withTl, onsetCount: { inWindow: total, returned: withTl.length, wholeSong: song.noteOnsets.length },
    energy: song.energy,
    ...(lyrics ? { lyrics } : inEdit ? { lyricsNote: 'No caption track for this item: auto_captions with its itemId transcribes the lyrics.' } : {}),
    ...(place ? { onTimeline: { itemId: place.itemId, track: place.trackKind, startSec: r3(place.startSec), endSec: r3(place.endSec) } } : {}),
    howToRead: 'Times (t) are the file\'s own seconds; tl, when present, is the same moment on the edit\'s timeline (only for hits inside the item\'s trimmed part). noteOnsets: every note hit (to ~10 ms), strength 0–1 (1 = the strongest hit in the song), band low (<200 Hz: kick, bass), mid (200–2000 Hz: voice, melody, snare body), high (>2 kHz: hats, claps, attacks), pitch = the dominant pitch class right after the hit. key: with confidence 0–1 and the Camelot code (songs whose codes are the same or next to it, mixesWith, chain smoothly). sections: boundaries from where the sound changes; the same letter means it sounds alike (a repeat); guess is only a hint. energy.db: the level every 0.25 s in dBFS.'
      + (total > withTl.length ? ` Only the ${withTl.length} strongest of ${total} hits are listed: pass fromSec/toSec (a window of the song) or minStrength/band for all of them.` : ''),
  };
  if (a.listening === true && u.role !== 'owner') out.listening = { note: 'Listening is the studio owner\'s (it uses the studio\'s own model account); the numbers above are complete without it.' };
  else if (a.listening === true) {
    out.listening = await cached(ctx, key, `listening-${ctx.config.GEMINI_MODEL}`, () => (ctx.config.GEMINI_API_KEY
      ? oneAtATime(() => editorAi(ctx).withLocalInput(key, input => geminiListening(ctx, input)))
      : geminiListening(ctx, '')), v => !('note' in v));
  }
  return out;
}

export async function impactsOf(env: ToolEnv, a: Record<string, unknown>) {
  const { ctx, user: u } = env, c = ctx.config;
  if (!(await mediaToolsAvailable(c.FFMPEG_PATH, c.FFPROBE_PATH))) throw new ApiError(503, 'unavailable', 'find_impacts needs ffmpeg on the server, which is missing here');
  let mediaKey: string, id: string, place: Placement | null = null;
  const sid = typeof a.sessionId === 'string' && a.sessionId ? a.sessionId : undefined;
  if (sid && a.id === undefined) {
    const { editSessionsOf } = await import('../editor/sessions.js');
    const svc = editSessionsOf(ctx), s = await svc.row(u, sid);
    const p = s.project as M.EditProject;
    const asset = svc.sourceAsset(p, s.takeId, typeof a.itemId === 'string' ? a.itemId : undefined);
    if (asset.kind !== 'video' || !(asset.take || asset.upload)) throw badRequest('That item has no stored video to analyse');
    mediaKey = (await requireAssetMedia(ctx, s.studioId, asset)).key; id = asset.id;
    const itemId = typeof a.itemId === 'string' ? a.itemId : (M.mainTrack(p).items.find(i => (i as M.VideoClip).asset === asset.id)?.id);
    if (itemId) place = placement(p, itemId);
  } else {
    const v = await videoOf(ctx, u, await watchTarget({ ctx, user: u }, a));
    mediaKey = v.key; id = v.id;
  }
  const m = await oneAtATime(() => editorAi(ctx).withLocalInput(mediaKey, input => measureMotion(c.FFMPEG_PATH, c.FFPROBE_PATH, input, { maxSec: MAX_SEC, inputArgs: leanDecode() })));
  const from = a.fromSec === undefined ? 0 : Number(a.fromSec), to = a.toSec === undefined ? Infinity : Number(a.toSec);
  const kinds = Array.isArray(a.kinds) ? new Set(a.kinds as string[]) : null;
  const all = findImpacts(m, { cuts: findCuts(m), sensitivity: Number(a.sensitivity) || undefined });
  const list = all.filter(x => x.t >= from && x.t <= to && (!kinds || kinds.has(x.kind))).slice(0, Math.min(300, Number(a.max) || 100))
    .map(x => { const tl = place?.toTimeline(x.t); return tl === null || tl === undefined ? x : { ...x, tl }; });
  return { id, mediaKey, fps: m.fps, durationSec: r3(m.energy.length / m.fps), impacts: list,
    howToRead: `t is the clip's own (source) seconds, on its ${m.fps} fps frame grid; tl, when present, is the timeline time now. kind stop = motion ends sharply (a landing, a hand reaching the tray, a contact): t is the frame where it comes to rest. start = motion begins suddenly: t is the first moving frame. cut = a hard cut. strength 0–1. Confirm each with watch_closer (around t ± 0.2 s) before sync_hits.` };
}

export const SONG_TOOLS: EditTool[] = [{
  name: 'song_notes', title: 'Song notes (free)', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'A song\'s musical map, for editing picture to individual NOTES (not just beats): key and mode with confidence and Camelot code (for mood and for chaining songs), tempo and beats, sections (where the sound changes; same letter = repeats), EVERY note hit (noteOnsets: t to ~10 ms, strength, band low/mid/high, pitch; in Edit also tl = timeline seconds), an energy curve every 0.25 s, and the lyrics when a caption track exists for the item. listening: true adds a model\'s listening (mood, genre, instruments, vocal spans, emotional arc, notable moments; only when the server has it set up, otherwise a note). Takes the same ids as listen (a take, Library item, clip, upload, audio upload), or in Edit sessionId + itemId (no itemId: the edit\'s music). fromSec/toSec narrow the hits listed (file seconds); the whole song is analysed once and cached. Free unless listening.',
  inputSchema: { type: 'object', additionalProperties: false, properties: {
    id: str('A take, job, Library item, clip, uploaded video or audio, or /uploads/… link', 300), takeId: str('The take open on the page (filled in for you)', 80), ...IN_EDIT,
    fromSec: num('Only hits from this second of the file', 0), toSec: num('Only hits up to this second of the file', 0),
    band: { type: 'string', enum: ['low', 'mid', 'high'], description: 'Only hits in this band' }, minStrength: num('Only hits at least this strong (0–1)', 0, 1),
    maxOnsets: num('At most this many hits, strongest kept (default 300)', 1, 1000), listening: { type: 'boolean', description: 'Also a model\'s listening (mood, instruments, vocal spans); default false' } } },
  run: songNotes,
}, {
  name: 'find_impacts', title: 'Find impact frames (free)', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'The frames to land on notes: where motion STOPS sharply (a landing, a hand putting fruit on a tray, a contact), where it STARTS suddenly, and hard cuts, each with t (the clip\'s own seconds, frame-exact), strength 0–1 and kind start|stop|cut (in Edit also tl, timeline seconds). Free (frame differencing on a small proxy). It finds candidates; confirm each with watch_closer before sync_hits. Takes sessionId + itemId in Edit (default the main video), or any id watch takes.',
  inputSchema: { type: 'object', additionalProperties: false, properties: {
    id: str('A take, Library item, clip or uploaded video (outside Edit)', 300), takeId: str('The take open on the page (filled in for you)', 80), ...IN_EDIT,
    fromSec: num('Only from this second of the clip', 0), toSec: num('Only up to this second of the clip', 0),
    kinds: { type: 'array', items: { type: 'string', enum: ['start', 'stop', 'cut'] }, description: 'Only these kinds' },
    sensitivity: num('Higher finds fewer, sharper moments (default 3)', 1, 12), max: num('At most this many (default 100)', 1, 300) } },
  run: impactsOf,
}];

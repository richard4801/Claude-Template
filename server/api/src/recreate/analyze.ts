// Recreate this edit · the analysis (workstream 1, plans/recreate-edit.md "Analysis"; schema in plans/api.md
// "Recreate this edit"): a reference video becomes a versioned `recipe`. Free: ffmpeg, the beat detector and sharp on
// the server's CPU. Pose skeletons and the words of on-screen text wait for their engines (status "pending" / null).
import { decodeMono, detectBeats } from '../editor/audio.js';
import { energyCurve, findCuts, findPeaks, measureMotion, type Cut } from '../editor/motion.js';
import { probe } from '../replicate/media.js';
import type { Rig } from '../suite/drafts.js';
import { contactSheet, decodeArgs, grabFrame, gradeOf, sheetTiles, type GradeInfo } from './frames.js';
import { cameraOf, classifyCut, findGlitches, findGradual, motionTracker, peaksIn, shotsOf, speedOf, transitionFrames, type CameraMotion, type Speed, type Transition } from './signals.js';
import { findText, type TextItem } from './text.js';
import { readWords } from './ocr.js';
import { textMotions } from './textMotion.js';
import { freeMemoryMb, readPoses, type PoseRun } from './pose.js';
import { readPoseTracks, type PoseTrack, type TrackRun } from './poseTrack.js';

export const RECIPE_SCHEMA = 'muse.recipe/1';
export const ANALYZER_VERSION = '1.1.0'; // 1.1: words (OCR) and poses

export type Slot = {
  id: string; index: number; startSec: number; endSec: number; durationSec: number; keyframeSec: number; confidence: number;
  /** Written by Claude from the contact sheet (shot size, angle, subject, action, location). */
  brief: { shotSize?: string; angle?: string; subject?: string; action?: string; location?: string; notes?: string } | null;
  /** The Suite rig that recreates it (moves from the camera motion; Claude's brief adds framing and angle). */
  rig: Rig | null;
  camera: CameraMotion; speed: Speed; peaks: { t: number; strength: number }[];
  /** Body keypoints only (never pixels), 0–1 in the frame: MoveNet's 17 points at the keyframe. "none": no person found;
   * "pending": not read (memory was tight, past the first 20 slots, or the pose engine is off). */
  pose: { status: 'pending' | 'done' | 'none'; frameSec?: number; keypoints?: { name: string; x: number; y: number; score: number }[];
    /** Per-frame poses of the whole shot (stored next to the reference, not in the recipe): how many frames, at what rate. */
    track?: { frames: number; fps: number } };
};
export type RecipeTransition = Transition & { from: string; to: string };
export type Gap = { key: string; kind: 'transition' | 'effect' | 'text' | 'font' | 'motion' | 'other'; what: string; atSec?: number; note: string };
export type Recipe = {
  schema: typeof RECIPE_SCHEMA; analyzer: { version: string; tookMs: number; pose?: { frames: number; ms: number; peakRssMb: number } | { skipped: string; peakRssMb?: number };
    /** The per-frame pose read (every frame of each shot, for matching takes by movement). */
    poseTracks?: { frames: number; ms: number; peakRssMb: number } | { skipped: string };
    /** Optional steps left out to keep the server alive (workstream 1): "lite" after a crash, "memory" when free memory was short. */
    skipped?: { step: 'words' | 'textMotion' | 'pose' | 'poseTracks'; why: 'lite' | 'memory' }[]; lite?: boolean };
  /** Where it came from: a reference video (this analysis) or one of the studio's own edits (workstream 3's converter). */
  origin: 'reference' | 'edit'; referenceId?: string; takeId?: string; versionId?: string;
  /** Claude's one-line read of the contact sheet, and free tags ("street", "dance", "outfit-transition"). */
  summary?: string; tags?: string[];
  source: { durationSec: number; width: number; height: number; fps: number; aspect: string; hasAudio: boolean };
  sound: { bpm: number; beats: number[]; strong: number[]; confidence: number } | null;
  pacing: { shots: number; avgShotSec: number; cutsPerMin: number; energy: { everySec: number; values: number[] } };
  slots: Slot[]; transitions: RecipeTransition[]; text: TextItem[];
  grade: Omit<GradeInfo, 'confidence'> & { confidence: number };
  contactSheet: { url: string; times: number[]; tiles?: { slotId: string; x: number; y: number; w: number; h: number }[] } | null;
  gaps: Gap[];
};
/** The recipe's size caps (≈ 256 KB in all, workstream 3's library keeps many): per slot. */
export const MAX_CURVE_POINTS = 48, MAX_CAMERA_KEYS = 64;
/** Every `step`-th item, always keeping the last, so at most `max` remain. */
export const thin = <T>(xs: T[], max: number) => { if (xs.length <= max) return xs; const step = Math.ceil(xs.length / max); return xs.filter((_, i) => i % step === 0 || i === xs.length - 1).slice(-max); };

/** The composer shape closest to w×h. */
export function aspectName(w: number, h: number) {
  const r = w / h, shapes: [string, number][] = [['9:16', 9 / 16], ['16:9', 16 / 9], ['1:1', 1], ['4:5', 4 / 5], ['3:4', 3 / 4], ['4:3', 4 / 3], ['21:9', 21 / 9]];
  return shapes.reduce((a, b) => (Math.abs(Math.log(b[1] / r)) < Math.abs(Math.log(a[1] / r)) ? b : a))[0];
}

/** The Suite move that recreates a slot's camera motion (content moving left = the camera pans right). */
export function moveFor(c: CameraMotion): Rig['moves'] {
  const last = c.keys.at(-1) ?? { x: 0, y: 0, scale: 1 };
  const id = c.motion === 'pan' ? (last.x < 0 ? 'pan_right' : 'pan_left')
    : c.motion === 'tilt' ? (last.y < 0 ? 'tilt_down' : 'tilt_up')
    : c.motion === 'zoom_in' ? 'zoom_in' : c.motion === 'zoom_out' ? 'zoom_out'
    : c.motion === 'shake' ? 'handheld' : c.motion === 'static' ? 'static' : null;
  return id ? [{ id }] : [];
}

export type AnalyzeHooks = { progress?: (f: number, phase: string) => void | Promise<void>; maxSec?: number;
  /** Required steps only (cuts, beats, peaks, text boxes, the look, the contact sheet): after an analysis that took the server down. */
  lite?: boolean;
  /** Optional steps (words, text motion, poses) run only with at least this much free memory (MB). Default OPTIONAL_MIN_FREE_MB. */
  minFreeMb?: number };
/** Free memory an optional step needs before it starts (the server, one ffmpeg and tesseract or the pose child fit in 512 MB). */
export const OPTIONAL_MIN_FREE_MB = 150;

/**
 * The recipe of the video at `input` (a local path or URL). Returns the recipe plus the contact sheet PNG for the
 * caller to store (its URL goes into `recipe.contactSheet`).
 */
export async function analyzeReference(cfg: { ffmpeg: string; ffprobe: string; tesseract?: string; pose?: boolean | { model?: string; minFreeMb?: number; trackFrames?: number } }, input: string, o: AnalyzeHooks = {}): Promise<{ recipe: Recipe; contactSheetPng: Buffer | null; poseTracks?: (PoseTrack | null)[] }> {
  const t0 = Date.now(), maxSec = o.maxSec ?? 61;
  // Workstream 1 (512 MB box): every step runs alone, one decoder at a time; optional ones only with room to spare.
  const skipped: NonNullable<Recipe['analyzer']['skipped']> = [];
  const minFree = o.minFreeMb ?? OPTIONAL_MIN_FREE_MB;
  const may = (step: NonNullable<Recipe['analyzer']['skipped']>[number]['step']) => {
    if (o.lite) { skipped.push({ step, why: 'lite' }); return false; }
    if (freeMemoryMb() < minFree) { skipped.push({ step, why: 'memory' }); return false; }
    return true;
  };
  const info = await probe(cfg.ffprobe, input);
  if (!info.width || !info.height) throw new Error('no video stream');
  await o.progress?.(0.05, 'Finding the cuts');
  const tracker = motionTracker();
  const m = await measureMotion(cfg.ffmpeg, cfg.ffprobe, input, { maxSec, onFrame: tracker.hook, inputArgs: decodeArgs() });
  const g = tracker.g;
  // Glitch bursts first (G6): the cut finder may take a burst's edge frames for cuts, which then belong to the glitch.
  const glitches = findGlitches(m);
  const inGlitch = (t: number) => glitches.some(x => t * m.fps >= x.startFrame - 1 && t * m.fps <= x.endFrame + 1);
  const cuts = findCuts(m).filter(c => !inGlitch(c.t));
  const gradual = [...findGradual(m, cuts, g), ...glitches.filter(x => !x.inShot)];
  const shots = shotsOf(m, cuts, gradual);
  const skip = transitionFrames(m, cuts, [...gradual, ...glitches.filter(x => x.inShot)]);
  // A glitch's flicker isn't action: its frames are kept out of the peaks like a cut's.
  const glitchFrames = glitches.flatMap(x => Array.from({ length: x.endFrame - x.startFrame + 1 }, (_, i) => ({ t: (x.startFrame + i) / m.fps, strength: 1 })));
  const peaks = findPeaks(m, { cuts: [...cuts, ...glitchFrames] });
  const durationSec = r3(Math.min(info.duration || m.energy.length / m.fps, maxSec));

  await o.progress?.(0.45, 'Listening for the beat');
  let sound: Recipe['sound'] = null;
  if (info.audioCodec) {
    const b = detectBeats(await decodeMono(cfg.ffmpeg, input, maxSec));
    if (b.beats.length >= 4) sound = { bpm: b.bpm, beats: b.beats.map(r3), strong: b.strong.map(r3), confidence: 0.75 };
  }

  await o.progress?.(0.6, 'Reading the text');
  const found = await findText(cfg.ffmpeg, input, Math.round(192 * info.height / info.width), maxSec);
  const read = cfg.tesseract && found.length && may('words') ? await readWords({ ffmpeg: cfg.ffmpeg, tesseract: cfg.tesseract }, input, found, info) : found;
  // How each comes in and goes out (fade, typewriter, cut), from the contrast in its box around those times (G4).
  let motionCut = false;
  const text = read.length && may('textMotion') ? await textMotions(cfg.ffmpeg, input, read, { width: info.width, height: info.height, durationSec: Math.min(info.duration || maxSec, maxSec) },
    { stop: () => (freeMemoryMb() < minFree ? (motionCut = true) : false) }) : read;
  if (motionCut) skipped.push({ step: 'textMotion', why: 'memory' });

  await o.progress?.(0.75, 'Reading the look');
  const kw = 200, kh = Math.max(2, Math.round(kw * info.height / info.width / 2) * 2);
  const keyTimes = shots.map(s => r3(s.startSec + (s.endSec - s.startSec) / 2));
  const frames = [];
  for (const t of keyTimes) frames.push(await grabFrame(cfg.ffmpeg, input, t, kw, kh).catch(() => null));
  const got = frames.filter((f): f is NonNullable<typeof f> => !!f);
  const grade = gradeOf(got);

  let poseRun: PoseRun | null = null;
  if (cfg.pose && may('pose')) {
    await o.progress?.(0.85, 'Reading the poses');
    poseRun = await readPoses({ ffmpeg: cfg.ffmpeg, ...(typeof cfg.pose === 'object' ? cfg.pose : {}) }, input, keyTimes, info).catch(e => ({ skipped: 'failed' as const, detail: String(e?.message ?? e) }));
  }
  // Every frame of each shot, for matching takes by movement (only when the keyframe poses could be read).
  let trackRun: TrackRun | null = null;
  if (cfg.pose && poseRun && 'poses' in poseRun && may('poseTracks')) {
    await o.progress?.(0.9, 'Following the movement');
    const pc = typeof cfg.pose === 'object' ? cfg.pose : {};
    trackRun = await readPoseTracks({ ffmpeg: cfg.ffmpeg, ...pc }, input, shots.map(s => ({ startSec: s.startSec, endSec: s.endSec })),
      { width: info.width, height: info.height, fps: info.fps || m.fps }, { maxFrames: pc.trackFrames }).catch(e => ({ skipped: 'failed' as const, detail: String(e?.message ?? e) }));
  }
  const tracks = trackRun && 'tracks' in trackRun ? trackRun.tracks : null;

  // Shots → slots; boundaries → transitions.
  const slots: Slot[] = shots.map((s, i) => {
    const cam0 = cameraOf(s, g, m.fps, skip);
    const camera = { ...cam0, keys: thin(cam0.keys, MAX_CAMERA_KEYS) };
    const sp = speedOf(s, m);
    return {
      id: `s${i + 1}`, index: i, startSec: s.startSec, endSec: s.endSec, durationSec: r3(s.endSec - s.startSec), keyframeSec: keyTimes[i]!,
      confidence: s.endSec - s.startSec < 0.15 ? 0.5 : 0.9, brief: null, rig: { moves: moveFor(camera) }, camera, speed: { ...sp, curve: thin(sp.curve, MAX_CURVE_POINTS) }, peaks: peaksIn(peaks, s),
      pose: { ...((poseRun && 'poses' in poseRun ? poseRun.poses[i] : undefined) ?? { status: 'pending' as const }),
        ...(tracks?.[i] ? { track: { frames: tracks[i]!.frames.length, fps: tracks[i]!.fps } } : {}) },
    };
  });
  const transitions: RecipeTransition[] = [];
  for (let i = 1; i < slots.length; i++) {
    const at = slots[i]!.startSec;
    const gr = gradual.find(x => Math.abs(x.atSec - at) < 2 / m.fps);
    const cut = cuts.filter(c => !c.flash).find(c => Math.abs(c.t - at) < 1.5 / m.fps) as Cut | undefined;
    const t: Transition = gr ? { atSec: gr.atSec, kind: gr.kind, durationSec: r3((gr.endFrame - gr.startFrame) / m.fps), confidence: gr.kind === 'glitch' ? 0.6 : 0.7 }
      : cut ? classifyCut(cut, m, g, cuts) : { atSec: at, kind: 'unknown', durationSec: 0, confidence: 0.3 };
    transitions.push({ ...t, from: slots[i - 1]!.id, to: slots[i]!.id });
  }
  // A flash inside a shot (no new shot after it) is a transition-style effect too.
  for (const c of cuts.filter(x => x.flash)) {
    if (!transitions.some(t => Math.abs(t.atSec - c.t) < 3 / m.fps)) {
      const s = slots.find(x => c.t >= x.startSec && c.t < x.endSec);
      if (s) transitions.push({ atSec: c.t, kind: 'flash', durationSec: r3(2 / m.fps), confidence: 0.8, from: s.id, to: s.id });
    }
  }
  // So is a glitch that comes back to the same picture.
  for (const x of glitches.filter(y => y.inShot)) {
    const s = slots.find(y => x.atSec >= y.startSec && x.atSec < y.endSec);
    if (s) transitions.push({ atSec: x.atSec, kind: 'glitch', durationSec: r3((x.endFrame - x.startFrame) / m.fps), confidence: 0.55, from: s.id, to: s.id });
  }
  transitions.sort((a, b) => a.atSec - b.atSec);

  // Stable keys, so workstream 3's gap list can count them across studios.
  const gaps: Gap[] = [
    ...transitions.filter(t => t.kind === 'unknown').map((t): Gap => ({ key: `transition:unknown@${t.atSec.toFixed(2)}`, kind: 'transition', what: 'A transition MUSE couldn’t name', atSec: t.atSec, note: 'Not supported yet' })),
    ...(skipped.some(x => x.step === 'textMotion') ? [{ key: 'text:motion', kind: 'text' as const, what: 'How the text comes in and goes out', note: skipped.find(x => x.step === 'textMotion')!.why === 'lite' ? 'Not read: a lighter analysis after the last one stopped' : 'Not read: the server was short of memory' }] : []),
    ...(text.some(x => !x.words) ? [{ key: 'text:words', kind: 'text' as const, what: 'On-screen words', note: text.every(x => !x.words) ? 'Not read: Claude reads them from the contact sheet' : 'Some weren’t read: Claude reads them from the contact sheet' }] : []),
    ...(slots.some(s => s.pose.status === 'pending') ? [{ key: 'pose', kind: 'motion' as const, what: 'Body poses',
      note: !poseRun ? (skipped.find(x => x.step === 'pose')?.why === 'lite' ? 'Not read: a lighter analysis after the last one stopped' : skipped.some(x => x.step === 'pose') ? 'Not read: the server was short of memory' : 'Not read') : 'skipped' in poseRun ? (poseRun.skipped === 'memory' ? 'Not read: the server was short of memory' : 'Not read') : 'Read for the first 20 shots only' }] : []),
  ];

  const png = got.length ? await contactSheet(got, got.map(f => { const i = keyTimes.indexOf(f.t); const s = slots[i]!; return `${i + 1} · ${s.startSec.toFixed(1)}–${s.endSec.toFixed(1)} s`; })) : null;
  await o.progress?.(0.95, 'Writing the recipe');
  const recipe: Recipe = {
    schema: RECIPE_SCHEMA, analyzer: { version: ANALYZER_VERSION, tookMs: Date.now() - t0,
      ...(poseRun ? { pose: 'poses' in poseRun ? { frames: poseRun.poses.length, ms: poseRun.ms, peakRssMb: poseRun.peakRssMb } : { skipped: poseRun.skipped, ...(poseRun.peakRssMb ? { peakRssMb: poseRun.peakRssMb } : {}) } } : {}),
      ...(trackRun ? { poseTracks: 'tracks' in trackRun ? { frames: trackRun.frames, ms: trackRun.ms, peakRssMb: trackRun.peakRssMb } : { skipped: trackRun.skipped } } : {}),
      ...(skipped.length ? { skipped } : {}), ...(o.lite ? { lite: true } : {}) }, origin: 'reference',
    source: { durationSec, width: info.width, height: info.height, fps: r3(info.fps || m.fps), aspect: aspectName(info.width, info.height), hasAudio: !!info.audioCodec },
    sound,
    pacing: { shots: slots.length, avgShotSec: r3(durationSec / Math.max(1, slots.length)), cutsPerMin: r3((slots.length - 1) / Math.max(durationSec, 1) * 60), energy: energyCurve(m) },
    slots, transitions, text, grade, gaps,
    contactSheet: png ? { url: '', times: keyTimes, tiles: sheetTiles(slots.length, kw, kh).map((t, i) => ({ slotId: slots[i]!.id, ...t })) } : null,
  };
  return { recipe, contactSheetPng: png, ...(tracks ? { poseTracks: tracks } : {}) };
}

const r3 = (x: number) => Math.round(x * 1000) / 1000;

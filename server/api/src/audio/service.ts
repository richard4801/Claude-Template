// Talking detection for uploaded clips (plans/prompt-scripts.md §5). After an upload the clip's audio is classified
// in the background (free: ffmpeg + heuristics); the result is stored in clips.meta.audio, the clip's "Performer
// talking" check follows it, and a clip event tells the apps (the studio's "Performer is speaking" switch is pre-set
// from it). A render resolves `speaking` once, at creation: the switch, else the upload's own "talking: true", else
// the detection (waited for if still running), else not speaking.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { clips, type ClipCheck } from '../db/schema.js';
import { detectTalking, type AudioKind } from './detect.js';

export type ClipAudio = { kind: AudioKind; speaking: boolean; confidence: number; detectedAt: number };
type ClipRow = typeof clips.$inferSelect;

const running = new Map<string, Promise<ClipAudio | null>>();
export const TALKING_LABEL = 'Performer talking';

/** The stored detection of a clip, if any. */
export const clipAudio = (c: Pick<ClipRow, 'meta'>): ClipAudio | null => ((c.meta ?? {}) as { audio?: ClipAudio }).audio ?? null;
/** True when the upload itself said the performer talks (older apps send false by default, so false means "unknown"). */
const saidTalking = (c: Pick<ClipRow, 'meta'>) => (c.meta as { talking?: boolean | null } | null)?.talking === true;

/** What the apps see on a clip: the detection, for the switch's starting value. */
export function audioView(c: Pick<ClipRow, 'meta'>) {
  const a = clipAudio(c);
  if (saidTalking(c)) return { kind: a?.kind ?? 'speech', speaking: true, detected: !!a };
  return a ? { kind: a.kind, speaking: a.speaking, detected: true } : null;
}

/** Analyses a clip's audio (once at a time per clip); stores the result and emits the clip. Never throws. */
export function analyzeClip(ctx: Ctx, clipId: string, onDone?: (row: ClipRow) => void): Promise<ClipAudio | null> {
  const prev = running.get(clipId);
  if (prev) return prev;
  const p = (async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-aud-'));
    try {
      const [c] = await ctx.db.select().from(clips).where(eq(clips.id, clipId));
      if (!c?.storageKey) return null;
      const obj = await ctx.storage.get(c.storageKey);
      if (!obj) return null;
      const file = path.join(tmp, `clip${path.extname(c.storageKey) || '.mp4'}`);
      await pipeline(obj.body, fs.createWriteStream(file));
      const r = await detectTalking(ctx.config.FFMPEG_PATH, file);
      const audio: ClipAudio = { kind: r.kind, speaking: r.speaking, confidence: r.confidence, detectedAt: Date.now() };
      const [u] = await ctx.db.update(clips).set({ meta: { ...(c.meta ?? {}), audio }, checks: talkingChecks(c.checks, saidTalking(c) || audio.speaking) })
        .where(eq(clips.id, clipId)).returning();
      ctx.log.info({ clip: clipId, kind: r.kind, speaking: r.speaking, features: r.features }, 'Clip audio classified');
      if (u) onDone?.(u);
      return audio;
    } catch (e) {
      ctx.log.warn({ clip: clipId, err: (e as Error).message }, 'Clip audio detection failed');
      return null;
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
      running.delete(clipId);
    }
  })();
  running.set(clipId, p);
  return p;
}

/** The clip's checks with "Performer talking" set to the detection. */
export function talkingChecks(checks: ClipCheck[] | null, talking: boolean): ClipCheck[] {
  const out = (checks ?? []).filter(c => c.label !== TALKING_LABEL);
  out.push({ label: TALKING_LABEL, value: talking ? 'Yes' : 'No', status: 'info' });
  return out;
}

/** Waits for every detection running in this process (tests, shutdown). */
export const audioIdle = async () => { await Promise.all([...running.values()]); };

/**
 * Whether a render treats the performer as speaking: the request's switch, else the upload's "talking: true", else
 * the detection (run now if it hasn't finished, at most `waitMs`), else false.
 */
export async function resolveSpeaking(ctx: Ctx, clip: ClipRow | undefined, requested: boolean | null | undefined, waitMs = 20_000): Promise<{ speaking: boolean; source: 'switch' | 'upload' | 'detected' | 'default' }> {
  if (typeof requested === 'boolean') return { speaking: requested, source: 'switch' };
  if (!clip) return { speaking: false, source: 'default' };
  if (saidTalking(clip)) return { speaking: true, source: 'upload' };
  const stored = clipAudio(clip);
  if (stored) return { speaking: stored.speaking, source: 'detected' };
  if (!clip.storageKey) return { speaking: false, source: 'default' };
  const a = await Promise.race([analyzeClip(ctx, clip.id), new Promise<null>(r => setTimeout(() => r(null), waitMs).unref())]);
  return a ? { speaking: a.speaking, source: 'detected' } : { speaking: false, source: 'default' };
}

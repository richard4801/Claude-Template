// job_sent_media (owner only): the files MUSE actually sent to the provider for one job — the source video it uploaded
// and the pictures — each with a short-lived link, its storage key and, for videos, ffprobe's facts. For checking what a
// model really got (size, frame rate, quality) when a take looks wrong. Read-only; studio-scoped.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { jobs } from '../db/schema.js';
import type { EditTool } from '../editor/mcpTools.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { probe } from '../replicate/media.js';
import type { SentItem } from '../suite/runner.js';

const LINK_TTL_SEC = 15 * 60;
/** Videos larger than this are listed with a link only (no ffprobe: it would read the whole file). */
const PROBE_MAX_BYTES = 300 * 1024 * 1024;

type Item = SentItem & { recorded: boolean };

/**
 * The keys a job's runs write under its own id, for jobs from before the record (`stats.suite.sent`) existed:
 * New Swap / Shot (suite runner, s/<jobId>/…) and the classic Swap (r/<jobId>/source_padded.mp4, Genjutsu's pictures).
 */
export function candidateKeys(jobId: string): Omit<Item, 'recorded'>[] {
  const s = (name: string, kind: SentItem['kind'], role: string) => ({ kind, role, key: `s/${jobId}/${name}` });
  return [
    s('source_upscaled.mp4', 'video', 'source video (scaled up)'), s('source_part.mp4', 'video', 'source video (trimmed part)'),
    { kind: 'video', role: 'source video (padded)', key: `r/${jobId}/source_padded.mp4` },
    s('bridge.jpg', 'image', 'bridge frame'), s('frame_first.jpg', 'image', 'start frame'), s('frame_last.jpg', 'image', 'end frame'),
    ...[1, 2, 3].map(k => s(`frame_${k}.jpg`, 'image', `clip frame ${k}`)), s('person.jpg', 'image', 'person still'),
    ...Array.from({ length: 8 }, (_, k) => ({ kind: 'image' as const, role: `picture ${k + 1}`, key: `r/${jobId}/genjutsu_ref_${k + 1}.jpg` })),
  ];
}

async function videoFacts(ctx: Ctx, key: string, bytes: number) {
  if (bytes > PROBE_MAX_BYTES) return null;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sent-'));
  try {
    const obj = await ctx.storage.get(key);
    if (!obj) return null;
    const f = path.join(dir, 'v');
    await pipeline(obj.body, fs.createWriteStream(f));
    const i = await probe(ctx.config.FFPROBE_PATH, f);
    return { width: i.width, height: i.height, fps: i.fps, durationSec: Math.round(i.duration * 1000) / 1000,
      bitrateKbps: i.duration > 0 ? Math.round((bytes * 8) / i.duration / 1000) : null, audio: i.audioCodec };
  } catch { return null; } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

export async function jobSentMedia(ctx: Ctx, studioId: string, jobId: string) {
  const [j] = await ctx.db.select().from(jobs).where(and(eq(jobs.id, jobId), eq(jobs.studioId, studioId)));
  if (!j) throw notFound('Job');
  const stats = (j.stats ?? {}) as { suite?: { sent?: SentItem[]; plan?: { remix?: { sourceKey?: string }; videos?: { video?: { key?: string } }[] } }; replicate?: { paddedKey?: string } };
  let items: Item[];
  let note: string;
  if (stats.suite?.sent) {
    items = stats.suite.sent.map(x => ({ ...x, recorded: true }));
    note = 'As recorded when the job started (in input order).';
  } else {
    // Older jobs: the files written under the job's id, then the plan's own source (sent as is when nothing was cut).
    const found: Item[] = [];
    for (const c of candidateKeys(j.id)) if (await ctx.storage.head(c.key!)) found.push({ ...c, recorded: false });
    const planKey = stats.suite?.plan?.remix?.sourceKey ?? stats.suite?.plan?.videos?.[0]?.video?.key;
    if (planKey && !found.some(x => x.kind === 'video')) found.unshift({ kind: 'video', role: 'source video (the clip as stored)', key: planKey, recorded: false });
    items = found;
    note = 'This job predates the record of sent files: these are the files its run writes under its id (and the clip it was planned on). Pictures sent from their own stored keys are not listed.';
  }
  const media = await Promise.all(items.map(async x => {
    if (!x.key) return { ...x, exists: null };
    const head = await ctx.storage.head(x.key);
    if (!head) return { ...x, exists: false };
    const url = await ctx.storage.presignGet(x.key, LINK_TTL_SEC);
    const facts = x.kind === 'video' ? await videoFacts(ctx, x.key, head.size) : null;
    return { ...x, exists: true, bytes: head.size, url, ...(facts ? { video: facts } : {}) };
  }));
  return { jobId: j.id, state: j.state, model: j.modelName || j.modelId, linkExpiresInSec: LINK_TTL_SEC, note, media };
}

export const JOB_SENT_MEDIA: EditTool = {
  name: 'job_sent_media', title: 'What a job sent to the provider', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'Owner only. The files MUSE actually sent to the provider for one job (queue_list for ids): the source video it uploaded and the pictures, each with its storage key, a 15-minute link and, for videos, width, height, fps, duration and bitrate. Use it to check what a model really got when a take looks wrong.',
  inputSchema: { type: 'object', additionalProperties: false, required: ['jobId'], properties: { jobId: { type: 'string', description: 'The job id', maxLength: 80 } } },
  run: async (env, a) => {
    if (env.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'What a job sent is the studio owner\'s');
    if (typeof a.jobId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(a.jobId)) throw badRequest('jobId: a job id');
    return jobSentMedia(env.ctx, env.user.studioId, a.jobId);
  },
};

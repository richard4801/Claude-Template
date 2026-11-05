// Identity LoRA (plans/lora-training.md): build a 30-shot training set with the image engine, the user reviews it,
// then training runs on the GPU controller as job kind "lora-train". Same states and prices as the mock.
import { eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { loras, models, type ImageRef, type LoraCandidate } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact } from '../lib/util.js';
import { whoOf } from '../money/money.js';
import { PhotoBill } from '../images/bill.js';
import * as P from '../pricing.js';
import { characterSheetShot, loraToken, SHEET_ANGLES } from '../prompt/engine.js';
import type { JobRow } from '../gpu/controller.js';

/** Candidate pool: the bundled character stills, cycled with labels (same as the mock and prototype features.js). */
export const LORA_POOL: [string, string][] = [['g_front', 'Green set · front'], ['g_tq', 'Green set · ¾'], ['face', 'Close-up · window light'], ['c_front', 'Crystal dress · full'], ['g_side', 'Green set · side'],
  ['profile', 'Profile · soft light'], ['c_tq', 'Crystal · ¾'], ['g_back', 'Back · physique'], ['hero', 'Portrait · golden hour'], ['c_face', 'Close-up · choker']];
const SIM_FLAGGED = [9, 19, 23];
/** Variations for real candidates: new angles, light and expressions, including full-body shots for her physique. */
const VARIATIONS = ['window light, soft smile', 'golden hour outdoors, laughing', 'overcast street, neutral expression', 'studio softbox, looking over shoulder',
  'evening city lights, candid', 'bright kitchen, relaxed', 'beach at noon, full body', 'gym mirror, full body athletic wear', 'cafe table, three-quarter', 'night flash photo, close-up'];

type LoraRow = typeof loras.$inferSelect;

export class LoraService {
  constructor(private ctx: Ctx) {}

  view(l: LoraRow) {
    return compact({ modelId: l.modelId, version: l.version, state: l.state, use: l.use, candidates: l.candidates, progress: l.progress,
      photo: l.photo, video: l.video, cost: l.cost, trainedOn: l.trainedOn });
  }
  private emit(l: LoraRow) { this.ctx.hub.emit(l.studioId, { type: 'lora', lora: this.view(l) }); }

  private async model(user: { studioId: string }, modelId: string) {
    const [m] = await this.ctx.db.select().from(models).where(eq(models.id, modelId));
    if (!m || m.studioId !== user.studioId) throw notFound('Model');
    return m;
  }
  async row(user: { studioId: string }, modelId: string): Promise<LoraRow> {
    await this.model(user, modelId);
    const [l] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, modelId));
    if (l) return l;
    const [n] = await this.ctx.db.insert(loras).values({ modelId, studioId: user.studioId, version: 0, state: 'none', use: true, candidates: [], progress: 0,
      photo: { state: 'none', progress: 0 }, video: { state: 'none', progress: 0 }, cost: 0, weights: [] }).onConflictDoNothing().returning();
    return n ?? (await this.ctx.db.select().from(loras).where(eq(loras.modelId, modelId)))[0]!;
  }
  private async set(modelId: string, patch: Partial<LoraRow>) {
    const [u] = await this.ctx.db.update(loras).set(patch).where(eq(loras.modelId, modelId)).returning();
    return u!;
  }

  async get(user: AuthUser, modelId: string) { return this.view(await this.row(user, modelId)); }

  private archived(m: typeof models.$inferSelect) {
    if (m.archivedAt) throw new ApiError(409, 'model_archived', 'This model is archived · restore her in Settings → Archived models');
  }

  async buildCandidates(user: AuthUser, modelId: string) {
    const m = await this.model(user, modelId);
    this.archived(m);
    const l = await this.row(user, modelId);
    if (['building', 'training'].includes(l.state)) throw new ApiError(409, 'busy', 'Already working on it');
    // Pass-through pricing: hold the estimate, settle to what the engine really charged (plans/api.md "App clean-up" §3).
    const estimate = P.LORA_CANDIDATES * await this.ctx.images.newShotCost(user.studioId, 1, this.ctx.images.refCount(m.slots.map(s => s.image)));
    const bill = await new PhotoBill(this.ctx, whoOf(user), `lora_${modelId}_${Date.now()}`, estimate, `LoRA training set · ${P.LORA_CANDIDATES} photos`).start();
    const before = l.state;
    const building = await this.set(modelId, { state: 'building', candidates: [], progress: 0 });
    this.emit(building);
    void this.generateCandidates(user, m, before, bill).catch(() => {});
    return this.view(building);
  }

  private async generateCandidates(user: AuthUser, m: typeof models.$inferSelect, before: string, bill: PhotoBill) {
    try {
      const sel = await this.ctx.images.selection(user.studioId);
      const identity = { name: m.name, look: m.look || `${m.age}-year-old woman`, neverAdd: m.neverAdd, referenceCount: Math.max(1, m.slots.filter(s => s.image).length) };
      const refs = m.slots.map(s => s.image);
      let images: ImageRef[];
      if (sel.provider === 'simulated') {
        const r = await this.ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'lora-candidate', refId: m.id, refs, bill,
          req: { prompt: characterSheetShot(identity, SHEET_ANGLES[2]).text, width: 768, height: 1024, count: P.LORA_CANDIDATES, simAssets: LORA_POOL.map(p => p[0]) } });
        images = r.images;
      } else {
        images = [];
        for (let i = 0; i < P.LORA_CANDIDATES; i += 4) {
          const batch = await Promise.all(Array.from({ length: Math.min(4, P.LORA_CANDIDATES - i) }, (_, k) => {
            const n = i + k, angle = SHEET_ANGLES[n % SHEET_ANGLES.length]!;
            const prompt = `${characterSheetShot(identity, angle).text}\nVariation: ${VARIATIONS[n % VARIATIONS.length]}.`;
            return this.ctx.images.generate({ studioId: user.studioId, userId: user.id, purpose: 'lora-candidate', refId: m.id, refs, bill,
              req: { prompt, width: 768, height: 1024, count: 1, seed: 1000 + n } }).then(r => r.images[0]!);
          }));
          images.push(...batch);
        }
      }
      const simulated = sel.provider === 'simulated';
      const candidates: LoraCandidate[] = images.slice(0, P.LORA_CANDIDATES).map((image, i) => {
        const [asset, label] = LORA_POOL[i % LORA_POOL.length]!;
        // Simulated sets pre-flag 3 risky shots like the prototype. Real sets aren't auto-checked yet: nothing is flagged.
        const flag = simulated && SIM_FLAGGED.includes(i) ? (asset === 'c_face' ? 'choker' : 'face drift') : undefined;
        return compact({ id: `c${i + 1}`, image, label: simulated ? label : `${SHEET_ANGLES[i % 6]!.label} · ${VARIATIONS[i % VARIATIONS.length]}`, flag, keep: !flag }) as LoraCandidate;
      });
      const [cur] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, m.id));
      await bill.finish();
      if (!cur || cur.state !== 'building') return;
      this.emit(await this.set(m.id, { state: 'review', candidates, cost: cur.cost + bill.spent }));
    } catch (e) {
      this.ctx.log.warn({ err: (e as Error).message }, 'LoRA training set failed');
      await bill.fail();
      const [cur] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, m.id));
      if (cur) this.emit(await this.set(m.id, { state: before === 'building' ? 'none' : before }));
    }
  }

  async keep(user: AuthUser, modelId: string, cid: string, keep: boolean) {
    const l = await this.row(user, modelId);
    const c = l.candidates.find(x => x.id === cid);
    if (!c) throw notFound('Candidate');
    if (l.state === 'training') throw new ApiError(409, 'busy', 'Training is running');
    const u = await this.set(modelId, { candidates: l.candidates.map(x => (x.id === cid ? { ...x, keep } : x)) });
    this.emit(u);
    return this.view(u);
  }

  async train(user: AuthUser, modelId: string) {
    const m = await this.model(user, modelId);
    this.archived(m);
    const l = await this.row(user, modelId);
    if (!['review', 'ready', 'failed'].includes(l.state) || !l.candidates.length) throw badRequest('Build the training set first');
    const kept = l.candidates.filter(c => c.keep).length;
    if (kept < P.LORA_MIN_KEEP) throw badRequest(`Keep at least ${P.LORA_MIN_KEEP} shots so the LoRA learns her well`);
    if (this.ctx.gpu.mode === 'runpod') this.ctx.jobs.requireCapabilities('lora-train');
    const cost = P.loraTrainCost();
    const token = loraToken(m.name, l.version + 1);
    const job = await this.ctx.jobs.createInternal(user, {
      kind: 'lora-train', title: `LoRA ${token}`, modelId: m.id, modelName: m.name, outfitId: '',
      request: { token, version: l.version + 1, kept, rank: 16, photoMinutes: P.LORA_PHOTO_MIN, videoMinutes: P.LORA_VIDEO_MIN },
      cost, totalSeconds: P.loraTrainMinutes() * 60, totalSteps: 100, prompt: token, seed: 0, thumb: null,
    });
    const u = await this.set(modelId, { state: 'training', progress: 0, cost: l.cost + cost, jobId: job.id, ...P.loraParts(0) });
    this.emit(u);
    return this.view(u);
  }

  async patch(user: AuthUser, modelId: string, b: { use?: unknown; state?: unknown }) {
    let l = await this.row(user, modelId);
    const patch: Partial<LoraRow> = {};
    if (typeof b.use === 'boolean') patch.use = b.use;
    // Retrain: back to the review grid with the same shots; the current version stays in use until the next one is ready.
    if (b.state === 'review') { if (l.state !== 'ready') throw badRequest('Nothing to retrain yet'); patch.state = 'review'; }
    if (Object.keys(patch).length) l = await this.set(modelId, patch);
    this.emit(l);
    return this.view(l);
  }

  // ------------------------------------------------------------------ from the GPU
  async onProgress(job: JobRow, p: number) {
    const pr = Math.min(99.9, Math.max(0, p));
    const [l] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, job.modelId));
    if (!l || l.jobId !== job.id) return;
    this.emit(await this.set(job.modelId, { progress: pr, ...P.loraParts(pr) }));
  }
  async onDone(job: JobRow) {
    const [l] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, job.modelId));
    if (!l || l.jobId !== job.id) return;
    const version = l.version + 1;
    const keyOf = (n: string) => (job.outputs ?? []).find(o => o.name === n)?.key as string | undefined;
    this.emit(await this.set(job.modelId, {
      state: 'ready', version, progress: 100, ...P.loraParts(100), trainedOn: job.request.kept ?? l.candidates.filter(c => c.keep).length, jobId: null,
      weights: [...l.weights, { version, photo: keyOf('lora_photo.safetensors'), video: keyOf('lora_video.safetensors') }],
    }));
  }
  async onFailed(job: JobRow) {
    const [l] = await this.ctx.db.select().from(loras).where(eq(loras.modelId, job.modelId));
    if (!l || l.jobId !== job.id) return;
    this.emit(await this.set(job.modelId, { state: 'failed', jobId: null, cost: Math.max(0, l.cost - job.cost) }));
  }
}

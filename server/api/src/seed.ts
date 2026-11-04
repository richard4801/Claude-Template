// Dev seed: the same studio data as server/mock/data.js (Sienna, Noor, two outfits, three jobs, six takes, $6.07),
// so the apps and their contract tests behave the same against this server. Only used with DEV_SEED / DEV_MODE.
import { eq, sql } from 'drizzle-orm';
import type { Ctx } from './ctx.js';
import { accounts, clips, generatedImages, templateFavourites, templates, jobs, ledger, loras, models, outfits, pods, posts, studios, studioSettings, takes, uploads, users, wallets, warmSessions } from './db/schema.js';
import { ensureStudio, hashPassword } from './auth/auth.js';
import { dayStart, monthStart } from './lib/util.js';

export const SLOT_SAMPLE: Record<string, string> = { face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back' };
const SLOT_KEYS = Object.keys(SLOT_SAMPLE);
const asset = (a: string) => ({ asset: a });
const req = (title: string, engine: string, steps: number, outfitId = 'o_green') =>
  ({ title, modelId: 'm_sienna', outfitId, clipId: 'clip_sample', engine, steps, use: 'first', takes: 1, keepAudio: true, lipSync: false, background: 'keep', backgroundMotion: 'subtle' });

export async function seedDev(ctx: Ctx, o: { onlyIfEmpty?: boolean; reset?: boolean } = {}) {
  const db = ctx.db, now = Date.now();
  const studio = await ensureStudio(ctx, 'Jenne Studio');
  const sid = studio.id;
  const email = ctx.config.DEV_OWNER_EMAIL.toLowerCase();
  let [owner] = await db.select().from(users).where(sql`lower(${users.email}) = ${email}`);
  if (!owner) {
    [owner] = await db.insert(users).values({ id: 'u_owner', studioId: sid, email, passwordHash: await hashPassword(ctx.config.DEV_OWNER_PASSWORD), role: 'owner',
      attestAdultRightsOriginalAt: now, attestLabelAiAt: now, createdAt: now }).returning();
  }
  if (o.onlyIfEmpty && !o.reset) {
    const [m] = await db.select({ id: models.id }).from(models).limit(1);
    if (m) return;
  }
  if (o.reset) {
    await ctx.gpu.shutdown();
    for (const t of [templateFavourites, templates, takes, jobs, outfits, clips, loras, accounts, posts, ledger, warmSessions, pods, generatedImages, uploads, models]) await db.delete(t);
    await db.update(wallets).set({ tokens: 0, held: 0, updatedAt: now });
    ctx.templates.forget();
  }
  await db.update(studios).set({ name: 'Jenne Studio' }).where(eq(studios.id, sid));
  await db.insert(studioSettings).values({ studioId: sid, simBalance: ctx.config.SIM_START_BALANCE })
    .onConflictDoUpdate({ target: studioSettings.studioId, set: { simBalance: ctx.config.SIM_START_BALANCE, failNext: false, lowBalanceSince: null, imageEngine: null } });

  const slotsFull = SLOT_KEYS.map(k => ({ key: k, image: asset(SLOT_SAMPLE[k]!), source: 'upload' as const, busy: false }));
  await db.insert(models).values([
    { id: 'm_sienna', studioId: sid, name: 'Sienna Vale', age: 24, niche: 'Fashion', look: 'young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin',
      neverAdd: ['tattoos', 'rings'], slots: slotsFull, outfitIds: ['o_green', 'o_crystal'], createdBy: owner!.id, createdAt: now - 3 },
    { id: 'm_noor', studioId: sid, name: 'Noor Ellis', age: 27, niche: 'Beauty', look: '', neverAdd: [], slots: SLOT_KEYS.map(k => ({ key: k, image: null, source: 'upload' as const, busy: false })),
      outfitIds: [], createdBy: owner!.id, createdAt: now - 2 },
  ]);
  await db.insert(outfits).values([
    { id: 'o_green', studioId: sid, modelId: 'm_sienna', name: 'Green set', mode: 'own', description: 'Dark green cropped tee and drawstring shorts', angles: ['g_front', 'g_tq', 'g_side', 'g_back'].map(asset), state: 'ready', prompt: '', createdAt: now - 2 },
    { id: 'o_crystal', studioId: sid, modelId: 'm_sienna', name: 'Crystal dress', mode: 'describe', description: 'Silver crystal cowl-neck mini dress', angles: ['c_front', 'c_tq', 'c_face', 'c_front'].map(asset), state: 'ready', prompt: '', createdAt: now - 1 },
  ]);
  const base = { studioId: sid, userId: owner!.id, kind: 'render' as const, modelId: 'm_sienna', modelName: 'Sienna Vale', take: 1, refunded: 0, prompt: '', gpuState: 'done' as const };
  await db.insert(jobs).values([
    { ...base, id: 'j1', title: 'Kick test', outfitId: 'o_green', request: req('Kick test', 'viggle', 4), state: 'done', progress: 100, step: 4, totalSteps: 4, phase: 'Done', secondsLeft: 0, totalSeconds: 95, cost: 0.13, createdAt: now - 7_200_000, finishedAt: now - 7_000_000, seed: 7, thumb: asset('g_front') },
    { ...base, id: 'j2', title: 'Bathroom trend', outfitId: 'o_crystal', request: req('Bathroom trend', 'h3', 30, 'o_crystal'), state: 'done', progress: 100, step: 30, totalSteps: 30, phase: 'Done', secondsLeft: 0, totalSeconds: 2760, cost: 3.05, createdAt: now - 86_400_000, finishedAt: now - 83_640_000, seed: 42, thumb: asset('c_front') },
    { ...base, id: 'j0', title: 'Mirror selfie', outfitId: 'o_green', request: req('Mirror selfie', 'h3', 10), state: 'failed', gpuState: 'failed', progress: 18, step: 3, totalSteps: 10, phase: 'Failed at step 3', secondsLeft: 0, totalSeconds: 608, cost: 0.19, refunded: 0.19, error: 'The GPU disconnected at step 3.', createdAt: now - 3_600_000, seed: 42, thumb: asset('g_tq') },
  ]);
  const t = (id: string, kind: 'take' | 'shot', jobId: string | null, title: string, label: string, engineLabel: string, cost: number, seed: number, thumb: string, createdAt: number) =>
    ({ id, studioId: sid, userId: owner!.id, kind, jobId, modelId: 'm_sienna', index: 1, of: 1, title, label, engineLabel, cost, seed, status: 'test' as const, thumb: asset(thumb), prompt: '', createdAt });
  await db.insert(takes).values([
    t('t_j1', 'take', 'j1', 'Kick test', 'Fast · beta', 'Fast · beta', 0.13, 7, 'g_front', now - 7_000_000),
    t('t_j2', 'take', 'j2', 'Bathroom trend', '30 steps', 'Standard · 30 steps', 3.05, 42, 'c_front', now - 83_640_000),
    t('t_g1', 'take', null, 'Living-room dance', '10 steps', 'Standard · 10 steps', 0.67, 42, 'g_tq', now - 90_000_000),
    t('t_g5', 'take', null, 'Living-room dance', '15 steps', 'Standard · 15 steps', 0.99, 42, 'g_side', now - 95_000_000),
    t('t_g4', 'shot', null, 'Shoot', 'Shoot', '', 0.03, 0, 'c_front', now - 96_000_000),
    t('t_g6', 'shot', null, 'Shoot', 'Shoot', '', 0.03, 0, 'c_tq', now - 97_000_000),
  ]);
  // The mock's "today $0.13, this month $18.93" as ledger rows.
  const today = dayStart(now), month = monthStart(now);
  await db.insert(ledger).values({ studioId: sid, userId: owner!.id, actorId: owner!.id, jobId: 'j1', kind: 'settle', amountUsd: 0.13, note: 'seed', createdAt: Math.max(today, now - 1000) });
  if (month < today) await db.insert(ledger).values({ studioId: sid, userId: owner!.id, actorId: owner!.id, jobId: null, kind: 'charge', amountUsd: 18.8, note: 'seed: earlier this month', createdAt: month });
}

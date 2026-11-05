// The studio's prompt library: defaults (library.ts) plus the owner's overrides (prompt_overrides), cached per studio.
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { promptOverrides, users } from '../db/schema.js';
import { ApiError, notFound } from '../errors.js';
import { allowEmpty, DEFAULT_TEXTS, fill, listOf, PROMPT_DEFS, PROMPT_GROUPS, promptDef, resolveTexts, validatePrompt, type PromptDef, type PromptTexts } from './library.js';
import * as E from './engine.js';
import { buildTemplatePrompt } from '../templates/prompt.js';
import { suiteExample } from '../suite/example.js';
import { dressPrompt, withRules } from './scripts/builders.js';
import { loadRules } from './scripts/service.js';

export type PromptEntry = {
  key: string; group: string; title: string; description: string; kind: PromptDef['kind']; default: string; current: string; overridden: boolean;
  allowEmpty: boolean; placeholders: { name: string; description: string; required: boolean }[]; updatedAt: number | null; updatedBy: string | null;
};
type Row = typeof promptOverrides.$inferSelect;

/** Sample values for the editor's preview (the sample model is "Demo model"). */
const SAMPLE_ID: E.Identity = { name: 'Demo model', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin', neverAdd: ['tattoos', 'rings'], referenceCount: 7 };
const SAMPLE: Record<string, string> = {
  name: 'Demo model', look: SAMPLE_ID.look, refCount: '7', lora: '', outfit: 'green set', scene: 'rooftop · golden hour', shot: 'medium', lens: '35', aperture: 'f/2.8',
  lensNote: '', light: 'golden hour', grade: 'phone-natural', direction: 'laughing mid-step, hair blowing', style: '', never: '', refIndex: '8',
  person: 'panels 1–3 show', panels: '; panel 4 shows the outfit to wear; panel 5 guides the pose & framing only',
  angle: 'body · front', framing: 'full body, facing the camera', seed: '421337', anchor: '', camera: 'handheld, slightly tilted', pose: 'mid-step, glancing back',
  product: 'held up next to the cheek', subject: 'the person in <Image 1> to <Image 5>: ' + SAMPLE_ID.look, reference: 'face and identity from <Image 1> and <Image 2>',
  faceRef: '<Image 1>', performer: 'the person', setting: 'the room', refs: '<Image 1> (face, front) and <Image 2> (face, profile)', audio: '', audioTag: '',
  background: 'The camera, framing, background, lighting and timing of <Video 1> are unchanged.', video: 'fully_preserved', tattoos: '', clean: '', n: '6',
  variation: 'window light, soft smile',
};

export class PromptLibrary {
  private cache = new Map<string, { at: number; texts: PromptTexts }>();
  constructor(private ctx: Ctx) {}

  /** Drops the cached texts and rules (after a script rule edit). */
  forget(studioId: string) { this.cache.delete(studioId); }

  private async rows(studioId: string): Promise<Row[]> {
    return this.ctx.db.select().from(promptOverrides).where(eq(promptOverrides.studioId, studioId));
  }
  /** The studio's resolved texts (defaults ⊕ overrides). Cached; every write drops the cache. */
  async texts(studioId: string): Promise<PromptTexts> {
    const hit = this.cache.get(studioId);
    if (hit && Date.now() - hit.at < 60_000) return hit.texts;
    // With the studio's script rules attached (prompt scripts), so every builder sees the owner's rule edits too.
    const texts = withRules(resolveTexts(Object.fromEntries((await this.rows(studioId)).map(r => [r.key, r.text]))), await loadRules(this.ctx, studioId));
    this.cache.set(studioId, { at: Date.now(), texts });
    return texts;
  }

  private entry(def: PromptDef, row: Row | undefined, emails: Map<string, string>): PromptEntry {
    const ok = row && validatePrompt(def.key, row.text) == null;
    return { key: def.key, group: def.group, title: def.title, description: def.description, kind: def.kind, default: def.default,
      current: ok ? row!.text : def.default, overridden: !!ok, allowEmpty: allowEmpty(def),
      placeholders: def.placeholders.map(([name, description, req]) => ({ name, description, required: !!req })),
      updatedAt: ok ? row!.updatedAt : null, updatedBy: ok && row!.updatedBy ? emails.get(row!.updatedBy) ?? null : null };
  }
  private async emails(studioId: string) {
    return new Map((await this.ctx.db.select({ id: users.id, email: users.email }).from(users).where(eq(users.studioId, studioId))).map(u => [u.id, u.email]));
  }
  async list(studioId: string) {
    const rows = new Map((await this.rows(studioId)).map(r => [r.key, r]));
    const emails = await this.emails(studioId);
    return { groups: PROMPT_GROUPS.map(g => ({ ...g })), prompts: PROMPT_DEFS.map(d => this.entry(d, rows.get(d.key), emails)) };
  }
  async one(studioId: string, key: string) {
    const def = this.def(key);
    const [row] = await this.ctx.db.select().from(promptOverrides).where(and(eq(promptOverrides.studioId, studioId), eq(promptOverrides.key, key)));
    return this.entry(def, row, await this.emails(studioId));
  }
  private def(key: string) {
    const def = promptDef(key);
    if (!def) throw notFound('Prompt');
    return def;
  }
  private check(key: string, text: unknown): string {
    if (typeof text !== 'string') throw new ApiError(400, 'prompt_invalid', 'Send the prompt as text');
    const why = validatePrompt(key, text);
    if (why) throw new ApiError(400, 'prompt_invalid', why);
    return text;
  }

  async set(u: AuthUser, key: string, body: unknown) {
    const def = this.def(key);
    const text = this.check(key, (body as { text?: unknown } | null)?.text);
    if (text === def.default) return this.reset(u, key);
    await this.ctx.db.insert(promptOverrides).values({ studioId: u.studioId, key, text, updatedBy: u.id, updatedAt: Date.now() })
      .onConflictDoUpdate({ target: [promptOverrides.studioId, promptOverrides.key], set: { text, updatedBy: u.id, updatedAt: Date.now() } });
    return this.changed(u.studioId, key);
  }
  async reset(u: AuthUser, key: string) {
    this.def(key);
    await this.ctx.db.delete(promptOverrides).where(and(eq(promptOverrides.studioId, u.studioId), eq(promptOverrides.key, key)));
    return this.changed(u.studioId, key);
  }
  private async changed(studioId: string, key: string) {
    this.cache.delete(studioId);
    const e = await this.one(studioId, key);
    this.ctx.hub.emitOwners(studioId, { type: 'prompts', prompt: e });
    return e;
  }

  /** The entry rendered with sample values, and the whole prompt it is part of, with `text` (default: the saved one). */
  async preview(u: AuthUser, body: unknown) {
    const b = (body ?? {}) as { key?: unknown; text?: unknown };
    if (typeof b.key !== 'string') throw new ApiError(400, 'bad_request', 'key: which prompt');
    const def = this.def(b.key);
    const saved = await this.texts(u.studioId);
    const text = b.text === undefined ? saved[def.key]! : this.check(def.key, b.text);
    const t: PromptTexts = { ...saved, [def.key]: text };
    const sample: Record<string, string> = { ...SAMPLE, style: t['style.house']!, never: E.neverList(SAMPLE_ID, t).join(', ') };
    if (def.key === 'shoot.camera') sample.lensNote = '';
    if (def.key.startsWith('dress.')) sample.anchor = ` ${t['dress.anchor']}`;
    const rendered = def.kind === 'text' ? fill(text, sample) : listOf(text, def.kind).join(def.kind === 'lines' ? '\n' : ', ');
    const used = Object.fromEntries(def.placeholders.map(([n]) => [n, sample[n] ?? '']));
    return { key: def.key, text: rendered, example: exampleFor(def, t), sample: used };
  }
}

/** The whole prompt an entry is part of, built for the sample model with these texts. */
export function exampleFor(def: PromptDef, t: PromptTexts = DEFAULT_TEXTS): string {
  const outfit: E.OutfitSpec = { name: 'Green set' };
  switch (def.group) {
    case 'photoshoot': case 'references':
      return (def.key === 'refs.collage' ? `${E.collageLine([{ label: 'face', role: 'person' }, { label: 'face ¾', role: 'person' }, { label: 'body', role: 'person' },
        { label: 'outfit', role: 'outfit' }, { label: E.refPanelLabel(['pose']), role: 'ref', guides: ['pose'] }], t)}\n` : '') + E.photoshoot({ identity: SAMPLE_ID, outfit, direction: 'laughing mid-step, hair blowing', refs: [{ index: 8, guides: ['pose', 'look', 'scene'] }],
        camera: def.key === 'shoot.camera.wide' ? { shot: 'Wide', lensMm: 24, aperture: 'f/5.6' } : def.key === 'shoot.camera.tele' ? { shot: 'Close', lensMm: 85, aperture: 'f/1.4' } : undefined,
        lockSeed: def.key === 'shoot.seed.locked', ...(def.key === 'shoot.outfit.described' ? { outfit: { name: 'Knit', description: 'a cream cable-knit sweater', source: 'described' } } : {}),
        ...(def.key === 'shoot.outfit.product' ? { outfit: { name: 'Green set', source: 'product-photo' } } : {}) }, t).text;
    case 'sheet': return E.characterSheetShot(SAMPLE_ID, E.SHEET_ANGLES[2], t).text;
    case 'outfits': return def.key === 'outfit.edit' ? E.outfitEditPrompt(E.OUTFIT_ANGLES[1], t) : E.outfitSet(SAMPLE_ID, outfit, 421337, t)[0]!.text;
    case 'enhance': return t['enhance.prompt']!;
    case 'dressup': return dressPrompt(def.key === 'dress.closeup' ? 'face' : 'tq', true, t);
    case 'templates': {
      const p = buildTemplatePrompt({ templateId: 't', templateName: 'Mirror selfie', layers: { scene: 'bedroom mirror', camera: 'phone in hand', light: 'window light', product: 'held up', style: 'casual' },
        pool: { pose: ['phone held low at the chest'], framing: ['full length in the mirror'] }, identity: SAMPLE_ID, outfit, shuffleSeed: 1, lockSeed: def.key === 'template.seed.locked',
        seed: 421337, hasProduct: def.key !== 'template.product.none' }, t);
      return def.key === 'template.locked' ? p.visibleText : p.fullText;
    }
    case 'video':
      if (def.key.startsWith('video.edit')) return E.videoSwap({ identity: SAMPLE_ID, outfit, direction: 'smiling' }, t).text;
      return E.replicateSwap({ identity: SAMPLE_ID, outfit, referenceLabels: ['face, front', 'face, profile', 'body, front', 'body, ¾', 'body, back', 'outfit, front'], direction: 'smiling' }, t).text;
    // AI suite (workstream 1)
    case 'suite': return suiteExample(def.key, t);
    case 'lora': return `${E.characterSheetShot(SAMPLE_ID, E.SHEET_ANGLES[0], t).text}\n${loraVariationLine(0, t)}`;
  }
  return '';
}

/** The Dress up prompt for one sheet image (plans/api.md "Model tools" §5). */
export { dressPrompt };
/** The LoRA candidate variations and the line for candidate `n`. */
export const loraVariations = (t: PromptTexts = DEFAULT_TEXTS) => { const l = listOf(t['lora.variations']!, 'lines'); return l.length ? l : listOf(DEFAULT_TEXTS['lora.variations']!, 'lines'); };
/** The variation line of LoRA candidate n (the candidate's whole prompt: scripts' loraCandidate). */
export const loraVariationLine = (n: number, t: PromptTexts = DEFAULT_TEXTS) => { const v = loraVariations(t); return fill(t['lora.variation']!, { variation: v[n % v.length] }); };

/** Every entry on its default, as GET /v1/prompts lists them for a studio with no overrides (the app's demo mode ships this). */
export function libraryDefaults() {
  return { groups: PROMPT_GROUPS.map(g => ({ ...g })), prompts: PROMPT_DEFS.map(d => ({ key: d.key, group: d.group, title: d.title, description: d.description, kind: d.kind,
    default: d.default, current: d.default, overridden: false, allowEmpty: allowEmpty(d), placeholders: d.placeholders.map(([name, description, req]) => ({ name, description, required: !!req })),
    updatedAt: null, updatedBy: null })) };
}

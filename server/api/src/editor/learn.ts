// The learning editor (plans/recreate-edit.md §5, workstream 3; plans/api.md "Learning editor"). The studio's editing
// memory: Claude's model doesn't change, MUSE's memory does, and Claude reads it before every edit.
// - Recipe library: every analysed reference (workstream 1's recipes) and every finished edit (recipeFromProject), kept
//   with searchable tags and a feature vector for "nearest recipe". Synced lazily from references and edited takes.
// - Corrections: the owner changing or undoing one of Claude's changes in an edit session, with its context.
// - Playbook: plain-language rules with evidence; the owner reads, edits, pins and deletes them; Claude adds them.
// - Performance: the stats of the posts made from a recipe's take (Posts).
// - Gaps: effects recipes needed that the editor can't do yet, most requested first.
// Owner only (like edit sessions). No money, no model calls.
import { and, desc, eq, inArray, isNull, sql } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { posts, takes } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { recreateReferences } from '../recreate/schema.js';
import type { Gap, Recipe, RecipeTransition, Slot } from '../recreate/analyze.js';
import type { TextItem as RecipeText } from '../recreate/text.js';
import { PALETTES } from '../suite/camera.js';
import { swatchesOf } from '../suite/looks.js';
import * as M from './model.js';
import { editCorrections, editGaps, editRecipes, playbookRules } from './learnSchema.js';
/** One Claude: the playbook is the owner's memory; members' memories (user_id set) never join it. */
const ownersRules = () => isNull(playbookRules.userId);
import { editOps, editSessions } from './schema.js';

export const LEARN_LIMITS = { rules: 200, ruleChars: 300, tags: 30, tagChars: 32, nearest: 10, corrections: 200, gapExamples: 5 } as const;
export const AREAS = ['captions', 'text', 'transition', 'look', 'motion', 'speed', 'timing', 'audio', 'pacing', 'ratio', 'other'] as const;
/** One Claude (plans/one-claude.md): the memory's own groups (claude/memory.ts), valid areas for the owner's rules too. */
export const MEMORY_AREAS = ['figure', 'style', 'models', 'rejected'] as const;
export type Area = (typeof AREAS)[number];

const r3 = (x: number) => Math.round(x * 1000) / 1000;
const owner = (u: AuthUser) => { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'The editing playbook and library are for the studio owner'); };

// ---------------------------------------------------------------- recipes from the studio's own edits

/** An edit project as a recipe (origin "edit"): its cuts, transitions, text, look and sound, in the reference schema. */
export function recipeFromProject(p: M.EditProject, o: { takeId: string; versionId?: string; name?: string }): Recipe {
  const spans = M.timeline(p);
  const duration = M.durationSec(p);
  const main = (p.tracks.find(t => t.kind === 'main')?.items ?? []) as M.VideoClip[];
  const slots: Slot[] = spans.map((s, i) => {
    const c = main[i]!;
    const len = s.endSec - s.startSec;
    const tf = c.keyframes;
    const scaleKeys = tf?.scale ?? [];
    const keys = (tf?.x ?? tf?.y ?? tf?.scale ?? []).slice(0, 64).map(k => ({ t: r3(k.t), x: r3(tf?.x?.find(q => q.t === k.t)?.v ?? 0), y: r3(tf?.y?.find(q => q.t === k.t)?.v ?? 0),
      scale: r3(tf?.scale?.find(q => q.t === k.t)?.v ?? 1) }));
    const motion = !tf ? 'static' : scaleKeys.length >= 2 ? (scaleKeys.at(-1)!.v > scaleKeys[0]!.v ? 'zoom_in' : 'zoom_out') : 'mixed';
    const curve = c.speedCurve ? c.speedCurve.points.slice(0, 48).map(([x, v]) => ({ t: r3(x * len), speed: v })) : [];
    const ramp = !c.speedCurve ? 'none' : curve.length >= 2 && curve.at(-1)!.speed > curve[0]!.speed ? 'speed_up' : curve.length >= 2 && curve.at(-1)!.speed < curve[0]!.speed ? 'slow_down' : 'mixed';
    return { id: `s${i + 1}`, index: i, startSec: r3(s.startSec), endSec: r3(s.endSec), durationSec: r3(len), keyframeSec: r3(s.startSec + len / 2), confidence: 1,
      brief: null, rig: null,
      camera: { motion, shake: 0, keys, confidence: 1 } as Slot['camera'],
      speed: { ramp, curve, confidence: 1 } as Slot['speed'],
      peaks: [], pose: { status: 'pending' } };
  });
  const transitions: RecipeTransition[] = spans.slice(1).map((s, i) => {
    const t = main[i + 1]!.transitionIn;
    const k = t?.kind as string | undefined;
    const kind = !t ? 'cut' : k === 'dissolve' || k === 'crossfade' ? 'crossfade' : k === 'fade' || k === 'black' || k === 'white' ? 'fade'
      : k?.startsWith('whip') ? 'whip' : k?.startsWith('zoom') ? 'zoom' : k === 'flash' ? 'flash' : k === 'glitch' ? 'glitch' : 'unknown';
    return { atSec: r3(s.startSec + (t?.durationSec ?? 0) / 2), from: `s${i + 1}`, to: `s${i + 2}`, kind: kind as RecipeTransition['kind'], durationSec: t?.durationSec ?? 0, confidence: 1 };
  });
  const text: RecipeText[] = p.tracks.filter(t => t.kind === 'text').flatMap(t => t.items as M.TextItem[]).slice(0, 100).map(x => {
    const size = x.style.sizePct ?? 0.05, w = Math.min(0.9, Math.max(0.1, x.text.length * size * 0.55)), h = size * 1.3;
    const cx = x.transform?.x ?? 0.5, cy = x.transform?.y ?? 0.75;
    const anim = (a?: M.Anim) => (!a || a.kind === 'none' ? 'cut' : 'fade') as 'cut' | 'fade';
    return { id: x.id, startSec: r3(x.startSec), endSec: r3(x.startSec + x.durationSec), box: { x: r3(cx - w / 2), y: r3(cy - h / 2), w: r3(w), h: r3(h) },
      words: x.text, sizeFrac: r3(size), color: x.style.color, fontId: M.FONT_FALLBACK[x.style.font] as 'sans' /* a recipe names the built-in families */, animIn: anim(x.animIn), animOut: anim(x.animOut), confidence: 1 };
  });
  const lut = main.find(c => c.look?.lut)?.look?.lut ?? '';
  const palId = lut.startsWith('palette:') ? lut.slice(8) : '';
  const pal = palId ? PALETTES.find(x => x.id === palId) : undefined;
  const adj = main[0]?.adjust;
  const grade = {
    swatches: (pal ? swatchesOf('palettes', pal.id) : null) ?? ['#202020', '#505050', '#808080', '#b0b0b0', '#e0e0e0'],
    contrast: r3((adj?.contrast ?? 0) / 100), saturation: r3((adj?.saturation ?? 0) / 100), warmth: r3((adj?.temperature ?? 0) / 100),
    look: pal ? { id: pal.id, kind: 'palette' as const, label: pal.label, distance: 0 } : null, grade: null, confidence: 1,
  };
  const music = p.tracks.find(t => t.kind === 'music')?.items[0] as M.AudioClip | undefined;
  const beats = music?.beats ?? [];
  const gaps = beats.length > 1 ? beats.slice(1).map((b, i) => b - beats[i]!).sort((a, b) => a - b) : [];
  const bpm = gaps.length ? r3(60 / gaps[Math.floor(gaps.length / 2)]!) : 0;
  const shots = slots.length;
  return {
    schema: 'muse.recipe/1', analyzer: { version: 'edit-1', tookMs: 0 }, origin: 'edit', takeId: o.takeId, ...(o.versionId ? { versionId: o.versionId } : {}),
    summary: o.name ?? '', tags: [],
    source: { durationSec: r3(duration), width: p.canvas.width, height: p.canvas.height, fps: p.canvas.fps,
      aspect: aspectOf(p.canvas.width, p.canvas.height), hasAudio: p.mute !== true },
    sound: bpm ? { bpm, beats, strong: music?.strongBeats ?? [], confidence: 1 } : null,
    pacing: { shots, avgShotSec: shots ? r3(duration / shots) : 0, cutsPerMin: duration > 0 ? r3(Math.max(0, shots - 1) / duration * 60) : 0, energy: { everySec: 1, values: [] } },
    slots, transitions, text, grade, contactSheet: null, gaps: [],
    ...({ id: `edit_${o.takeId}`, createdAt: Date.now() } as object),
  } as Recipe;
}
const aspectOf = (w: number, h: number) => {
  const r = w / h, shapes: [string, number][] = [['9:16', 9 / 16], ['16:9', 16 / 9], ['1:1', 1], ['4:5', 4 / 5], ['3:4', 3 / 4], ['4:3', 4 / 3]];
  return shapes.reduce((a, b) => (Math.abs(Math.log(b[1] / r)) < Math.abs(Math.log(a[1] / r)) ? b : a))[0];
};

// ---------------------------------------------------------------- features, tags, nearest

/** The numbers "nearest recipe" compares (all present, 0 when unknown). */
export function features(r: Recipe): Record<string, number> {
  const e = r.pacing?.energy?.values ?? [];
  const trans = r.transitions ?? [];
  return {
    durationSec: r.source?.durationSec ?? 0, shots: r.pacing?.shots ?? 0, cutsPerMin: r.pacing?.cutsPerMin ?? 0, avgShotSec: r.pacing?.avgShotSec ?? 0,
    bpm: r.sound?.bpm ?? 0, energy: e.length ? r3(e.reduce((a, b) => a + b, 0) / e.length) : 0, text: (r.text ?? []).length,
    fancyTransitions: trans.length ? r3(trans.filter(t => t.kind !== 'cut').length / trans.length) : 0,
    warmth: r.grade?.warmth ?? 0, saturation: r.grade?.saturation ?? 0, contrast: r.grade?.contrast ?? 0,
  };
}
const SCALES: Record<string, number> = { durationSec: 30, shots: 10, cutsPerMin: 40, avgShotSec: 3, bpm: 60, energy: 0.5, text: 5, fancyTransitions: 0.5, warmth: 0.5, saturation: 0.5, contrast: 0.5 };

/** Tags anyone can search by, from the numbers, plus the recipe's own (Claude's) tags. Lower case, unique. */
export function deriveTags(r: Recipe): string[] {
  const f = features(r), out = new Set<string>([r.origin === 'edit' ? 'own-edit' : 'reference']);
  out.add(f.cutsPerMin >= 40 ? 'fast-cuts' : f.cutsPerMin >= 15 ? 'medium-cuts' : 'slow-cuts');
  out.add(f.durationSec < 15 ? 'short' : f.durationSec < 35 ? 'medium-length' : 'long');
  if (f.bpm) out.add(f.bpm < 90 ? 'tempo-slow' : f.bpm < 130 ? 'tempo-mid' : 'tempo-fast');
  if (f.energy >= 0.6) out.add('high-energy'); else if (f.energy > 0 && f.energy < 0.3) out.add('calm');
  for (const t of r.transitions ?? []) if (t.kind !== 'cut' && t.kind !== 'unknown') out.add(`transition-${t.kind}`);
  if ((r.text ?? []).length) out.add('text');
  if ((r.slots ?? []).some(s => s.speed?.ramp && s.speed.ramp !== 'none')) out.add('speed-ramps');
  if (r.grade?.look) out.add(`look-${r.grade.look.id.replace(/_/g, '-')}`);
  for (const t of r.tags ?? []) out.add(t.toLowerCase().slice(0, LEARN_LIMITS.tagChars));
  return [...out].slice(0, LEARN_LIMITS.tags);
}

/** 0 = the same; grows with the difference in pacing, tempo, energy, text, transitions, grade and tags. */
export function distance(a: { features: Record<string, number>; tags: string[] }, b: { features: Record<string, number>; tags: string[] }) {
  let s = 0;
  for (const [k, sc] of Object.entries(SCALES)) { const d = ((a.features[k] ?? 0) - (b.features[k] ?? 0)) / sc; s += d * d; }
  const ta = new Set(a.tags), tb = new Set(b.tags);
  const inter = [...ta].filter(t => tb.has(t)).length, union = new Set([...ta, ...tb]).size;
  return r3(Math.sqrt(s / Object.keys(SCALES).length) + (union ? 1 - inter / union : 0) * 0.5);
}

// ---------------------------------------------------------------- corrections

/** What changed between two projects, item by item: "<itemId>/<key>" (an item key), "<itemId>/*" (added or removed),
 *  "track:<trackId>/<key>" (track settings: caption style, duck…) and "canvas/<key>". Stored with every change. */
export function touched(before: M.EditProject, after: M.EditProject): string[] {
  const out = new Set<string>();
  const items = (p: M.EditProject) => { const m = new Map<string, { kind: M.TrackKind; item: Record<string, unknown> }>(); for (const t of p.tracks) for (const it of t.items) m.set((it as { id: string }).id, { kind: t.kind, item: it as unknown as Record<string, unknown> }); return m; };
  const a = items(before), b = items(after);
  const same = (x: unknown, y: unknown) => JSON.stringify(x) === JSON.stringify(y);
  for (const id of new Set([...a.keys(), ...b.keys()])) {
    const x = a.get(id), y = b.get(id);
    if (!x || !y) { out.add(`${id}/*`); continue; }
    for (const k of new Set([...Object.keys(x.item), ...Object.keys(y.item)])) if (!same(x.item[k], y.item[k])) out.add(`${id}/${k}`);
  }
  const tracks = (p: M.EditProject) => new Map(p.tracks.map(t => [t.id, t as unknown as Record<string, unknown>]));
  const ta = tracks(before), tb = tracks(after);
  for (const id of new Set([...ta.keys(), ...tb.keys()])) {
    const x = ta.get(id) ?? {}, y = tb.get(id) ?? {};
    for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) if (k !== 'items' && !same(x[k], y[k])) out.add(`track:${id}/${k}`);
  }
  for (const k of new Set([...Object.keys(before.canvas), ...Object.keys(after.canvas)])) if (!same((before.canvas as Record<string, unknown>)[k], (after.canvas as Record<string, unknown>)[k])) out.add(`canvas/${k}`);
  if (before.mute !== after.mute) out.add('canvas/mute');
  return [...out].slice(0, 200);
}
/** Two touched entries are about the same thing: the same item (one of them all of it, or the same key), or the same setting. */
export const sameThing = (x: string, y: string) => {
  const [ix, kx] = [x.slice(0, x.lastIndexOf('/')), x.slice(x.lastIndexOf('/') + 1)], [iy, ky] = [y.slice(0, y.lastIndexOf('/')), y.slice(y.lastIndexOf('/') + 1)];
  return ix === iy && (kx === '*' || ky === '*' || kx === ky);
};
/** What a touched entry is about, from its track's kind and the key. */
export function areaFor(trackKind: M.TrackKind | 'canvas' | 'track' | undefined, key: string): Area {
  if (trackKind === 'canvas') return 'ratio';
  if (trackKind === 'caption' || key === 'caption') return 'captions';
  if (trackKind === 'text') return 'text';
  if (trackKind === 'music' || trackKind === 'voice' || trackKind === 'sfx' || key === 'duck') return 'audio';
  if (key === '*') return 'timing';
  if (key === 'transitionIn') return 'transition';
  if (['look', 'adjust', 'filter', 'chroma'].includes(key)) return 'look';
  if (['transform', 'keyframes', 'crop', 'mask', 'fit', 'opacity'].includes(key)) return 'motion';
  if (key === 'speed' || key === 'speedCurve') return 'speed';
  if (['inSec', 'outSec', 'startSec', 'durationSec'].includes(key)) return 'timing';
  if (['volume', 'muted', 'fadeInSec', 'fadeOutSec', 'voiceEffect', 'enhance', 'audioAsset'].includes(key)) return 'audio';
  return 'other';
}
const kindOf = (p: M.EditProject, entry: string): M.TrackKind | 'canvas' | 'track' | undefined => {
  if (entry.startsWith('canvas/')) return 'canvas';
  if (entry.startsWith('track:')) { const id = entry.slice(6, entry.lastIndexOf('/')); return p.tracks.find(t => t.id === id)?.kind; }
  const id = entry.slice(0, entry.lastIndexOf('/'));
  return p.tracks.find(t => t.items.some(i => (i as { id: string }).id === id))?.kind;
};
const AREA_WORDS: Record<Area, string> = { captions: 'the captions', text: 'the text', transition: 'the transition', look: 'the look', motion: 'the framing / motion',
  speed: 'the speed', timing: 'the timing', audio: 'the sound', pacing: 'the pacing', ratio: 'the shape', other: 'the edit' };
const short = (v: unknown) => { const s = JSON.stringify(v ?? null); return s.length > 200 ? `${s.slice(0, 197)}…` : s; };
const valueOf = (p: M.EditProject, entry: string) => {
  const key = entry.slice(entry.lastIndexOf('/') + 1), id = entry.slice(0, entry.lastIndexOf('/'));
  if (entry.startsWith('canvas/')) return (p.canvas as Record<string, unknown>)[key];
  if (entry.startsWith('track:')) return (p.tracks.find(t => t.id === id.slice(6)) as Record<string, unknown> | undefined)?.[key];
  for (const t of p.tracks) for (const it of t.items) if ((it as { id: string }).id === id) return key === '*' ? it : (it as Record<string, unknown>)[key];
  return undefined;
};

type OpRow = typeof editOps.$inferSelect;
type SessionRow = typeof editSessions.$inferSelect;

// ---------------------------------------------------------------- the service

export class Learning {
  constructor(private ctx: Ctx) {}
  private get db() { return this.ctx.db; }

  /**
   * Called after every change in an edit session (sessions.ts commit). When the owner's change undoes one of Claude's,
   * or touches what one of Claude's recent changes touched, it is logged as a correction. Never throws.
   */
  async observe(s: SessionRow, before: M.EditProject, after: M.EditProject, entry: OpRow) {
    try {
      if (entry.author === 'claude' || entry.kind === 'tool') return;
      const touchedOf = (o: OpRow) => (((o.meta ?? {}) as { touched?: string[] }).touched ?? []);
      if (entry.kind === 'undo' && entry.undoes) {
        const [c] = await this.db.select().from(editOps).where(eq(editOps.id, entry.undoes));
        if (!c || c.author !== 'claude') return;
        const t = touchedOf(c)[0];
        const area = t ? areaFor(kindOf(before, t), t.slice(t.lastIndexOf('/') + 1)) : 'other';
        await this.record(s, entry, c, 'undo', area, `Undid Claude's “${c.label}”`, { touched: touchedOf(c).slice(0, 10) }, t);
        return;
      }
      const mine = touchedOf(entry);
      if (!mine.length) return;
      const recent = await this.db.select().from(editOps)
        .where(and(eq(editOps.sessionId, s.id), eq(editOps.author, 'claude'), eq(editOps.kind, 'edit'), eq(editOps.undone, 0)))
        .orderBy(desc(editOps.id)).limit(20);
      for (const c of recent) {
        const theirs = touchedOf(c);
        const hit = mine.find(m => theirs.some(t => sameThing(m, t)));
        if (!hit) continue;
        const area = areaFor(kindOf(before, hit) ?? kindOf(after, hit), hit.slice(hit.lastIndexOf('/') + 1));
        // A drag is many small changes: one lesson per Claude change and area within a minute.
        const [dup] = await this.db.select({ id: editCorrections.id }).from(editCorrections)
          .where(and(eq(editCorrections.claudeOpId, c.id), eq(editCorrections.area, area), sql`${editCorrections.createdAt} > ${Date.now() - 60_000}`)).limit(1);
        if (dup) return;
        await this.record(s, entry, c, 'change', area, `Changed ${AREA_WORDS[area]} after Claude's “${c.label}”`,
          { touched: mine.slice(0, 10), before: short(valueOf(before, hit)), after: short(valueOf(after, hit)) }, hit);
        return;
      }
    } catch (e) { this.ctx.log.warn({ err: e }, 'learn observe'); }
  }
  private async record(s: SessionRow, entry: OpRow, c: OpRow, kind: 'undo' | 'change', area: Area, what: string, extra: Record<string, unknown>, hit?: string) {
    const meta = (c.meta ?? {}) as { sources?: Record<string, unknown> };
    const item = hit && !hit.startsWith('canvas/') && !hit.startsWith('track:') ? hit.slice(0, hit.lastIndexOf('/')) : undefined;
    const source = item && meta.sources ? meta.sources[item] : undefined;
    await this.db.insert(editCorrections).values({ studioId: s.studioId, sessionId: s.id, takeId: s.takeId, opId: entry.id, claudeOpId: c.id, kind, area,
      what: what.slice(0, 240), context: { claudeLabel: c.label, ...(item ? { itemId: item } : {}), ...(source ? { source } : {}), ...extra }, createdAt: Date.now() });
  }

  async corrections(u: AuthUser, o: { limit?: number; sessionId?: string; area?: string } = {}) {
    owner(u);
    const rows = await this.db.select().from(editCorrections).where(and(eq(editCorrections.studioId, u.studioId),
      o.sessionId ? eq(editCorrections.sessionId, o.sessionId) : undefined, o.area ? eq(editCorrections.area, o.area) : undefined))
      .orderBy(desc(editCorrections.id)).limit(Math.min(LEARN_LIMITS.corrections, Math.max(1, o.limit ?? 50)));
    const live = await this.liveTakes(u.studioId, rows.map(r => r.takeId));
    return rows.map(r => ({ id: r.id, sessionId: r.sessionId, takeId: r.takeId, takeExists: live.has(r.takeId), opId: r.opId, claudeOpId: r.claudeOpId, kind: r.kind, area: r.area, what: r.what,
      context: r.context, createdAt: r.createdAt }));
  }
  /** Which of these takes still exist (a correction or rule evidence opens its edit only then). */
  private async liveTakes(studioId: string, ids: string[]) {
    const want = [...new Set(ids.filter(Boolean))];
    if (!want.length) return new Set<string>();
    const rows = await this.db.select({ id: takes.id }).from(takes).where(and(eq(takes.studioId, studioId), inArray(takes.id, want)));
    return new Set(rows.map(r => r.id));
  }
  /** Corrections grouped by area and Claude's change (most frequent first): what Claude keeps getting wrong. */
  async lessons(u: AuthUser) {
    owner(u);
    const rows = await this.db.select().from(editCorrections).where(eq(editCorrections.studioId, u.studioId)).orderBy(desc(editCorrections.id)).limit(500);
    const groups = new Map<string, { area: string; claudeChange: string; count: number; undos: number; last: number; examples: string[]; ids: number[] }>();
    for (const r of rows) {
      const label = String((r.context as { claudeLabel?: string }).claudeLabel ?? '').replace(/\s*[“"].*$/, '').slice(0, 60);
      const k = `${r.area}|${label}`;
      const g = groups.get(k) ?? { area: r.area, claudeChange: label, count: 0, undos: 0, last: 0, examples: [], ids: [] };
      g.count++; if (r.kind === 'undo') g.undos++;
      g.last = Math.max(g.last, r.createdAt);
      if (g.examples.length < 3) g.examples.push(r.what);
      if (g.ids.length < 20) g.ids.push(r.id);
      groups.set(k, g);
    }
    const cited = new Map<number, string>();
    for (const r of await this.db.select({ id: playbookRules.id, evidence: playbookRules.evidence }).from(playbookRules).where(and(eq(playbookRules.studioId, u.studioId), ownersRules())))
      for (const e of r.evidence) if (e.kind === 'correction' && typeof e.id === 'number') cited.set(e.id, r.id);
    return [...groups.values()].sort((a, b) => b.count - a.count || b.last - a.last).map(g => {
      const ruleId = g.ids.map(i => cited.get(i)).find(Boolean);
      return ruleId ? { ...g, ruleId } : g;
    });
  }

  // ------------------------------------------------------------------ library
  /** Copies ready references and finished edits that aren't in the library yet; refreshes Claude's tags; counts gaps. */
  async sync(studioId: string) {
    const have = await this.db.select({ id: editRecipes.id, referenceId: editRecipes.referenceId, takeId: editRecipes.takeId, summary: editRecipes.summary, tags: editRecipes.tags, recipe: editRecipes.recipe })
      .from(editRecipes).where(eq(editRecipes.studioId, studioId));
    const byRef = new Map(have.filter(h => h.referenceId).map(h => [h.referenceId!, h]));
    const byTake = new Set(have.filter(h => h.takeId).map(h => h.takeId!));
    const refs = await this.db.select().from(recreateReferences).where(and(eq(recreateReferences.studioId, studioId), isNull(recreateReferences.deletedAt),
      inArray(recreateReferences.state, ['ready', 'expired'])));
    const now = Date.now();
    for (const r of refs) {
      if (!r.recipe) continue;
      const rec = { ...(r.recipe as Recipe), origin: 'reference' as const, referenceId: r.id };
      const cur = byRef.get(r.id);
      if (cur) {
        const was = cur.recipe as Recipe;
        if ((was.summary ?? '') !== (rec.summary ?? '') || JSON.stringify(was.tags ?? []) !== JSON.stringify(rec.tags ?? [])) {
          await this.db.update(editRecipes).set({ recipe: rec as unknown as Record<string, unknown>, summary: rec.summary ?? '', tags: deriveTags(rec), updatedAt: now }).where(eq(editRecipes.id, cur.id));
        }
        continue;
      }
      const id = uid('rcp');
      await this.db.insert(editRecipes).values({ id, studioId, origin: 'reference', referenceId: r.id, takeId: null, name: r.name || 'Reference', summary: rec.summary ?? '',
        tags: deriveTags(rec), features: features(rec), recipe: rec as unknown as Record<string, unknown>, createdAt: r.createdAt, updatedAt: now }).onConflictDoNothing();
      await this.countGaps(studioId, id, r.id, rec.gaps ?? []);
    }
    const edits = await this.db.select().from(takes).where(and(eq(takes.studioId, studioId), sql`${takes.kind} = 'edit'`));
    for (const t of edits) {
      if (byTake.has(t.id)) continue;
      const media = (t.media ?? {}) as { edits?: { version?: number }; parentTakeId?: string };
      if (media.edits?.version !== 2) continue;
      const rec = recipeFromProject(media.edits as unknown as M.EditProject, { takeId: t.id, versionId: media.parentTakeId, name: t.title });
      await this.db.insert(editRecipes).values({ id: uid('rcp'), studioId, origin: 'edit', referenceId: null, takeId: t.id, name: t.title || 'Edit', summary: '',
        tags: deriveTags(rec), features: features(rec), recipe: rec as unknown as Record<string, unknown>, createdAt: t.createdAt, updatedAt: now }).onConflictDoNothing();
    }
  }

  /** Performance of the posts made from these takes (posted ones; stats as the platforms report them). */
  async performance(studioId: string, takeIds: string[]) {
    const out = new Map<string, { posts: number; views: number; likes: number; comments: number; saves?: number; avgWatchSec?: number; completion?: number }>();
    if (!takeIds.length) return out;
    const rows = await this.db.select({ takeId: posts.takeId, stats: posts.stats, state: posts.state }).from(posts)
      .where(and(eq(posts.studioId, studioId), inArray(posts.takeId, takeIds)));
    for (const r of rows) {
      const p = out.get(r.takeId) ?? { posts: 0, views: 0, likes: 0, comments: 0 };
      p.posts++;
      const s = (r.stats ?? {}) as { views?: number; likes?: number; comments?: number; saves?: number; watchTimeSec?: number; completion?: number };
      p.views += s.views ?? 0; p.likes += s.likes ?? 0; p.comments += s.comments ?? 0;
      if (s.saves != null) p.saves = (p.saves ?? 0) + s.saves;
      if (s.watchTimeSec != null) p.avgWatchSec = r3(((p.avgWatchSec ?? 0) * (p.posts - 1) + s.watchTimeSec) / p.posts);
      if (s.completion != null) p.completion = r3(((p.completion ?? 0) * (p.posts - 1) + s.completion) / p.posts);
      out.set(r.takeId, p);
    }
    return out;
  }

  private view(r: typeof editRecipes.$inferSelect, perf?: Awaited<ReturnType<Learning['performance']>> extends Map<string, infer V> ? V : never, full = false,
    src?: { available: boolean; thumb?: unknown }) {
    const f = r.features ?? {};
    return { id: r.id, origin: r.origin, referenceId: r.referenceId, takeId: r.takeId, name: r.name, summary: r.summary, tags: r.tags, features: r.features,
      // For the Recipes screens (plans/learning-editor-ui.md): the tile's picture, its badge numbers, and whether the source still exists.
      durationSec: f.durationSec ?? 0, cuts: Math.max(0, (f.shots ?? 0) - 1),
      picture: r.origin === 'reference' && r.referenceId ? { poster: `/v1/recreate/references/${r.referenceId}/poster` } : src?.thumb ? { thumb: src.thumb } : null,
      available: src?.available ?? false,
      performance: perf ?? null, createdAt: r.createdAt, updatedAt: r.updatedAt, ...(full ? { recipe: r.recipe } : {}) };
  }
  private async withPerf(studioId: string, rows: (typeof editRecipes.$inferSelect)[], full = false) {
    const takeIds = rows.map(r => r.takeId).filter((x): x is string => !!x), refIds = rows.map(r => r.referenceId).filter((x): x is string => !!x);
    const perf = await this.performance(studioId, takeIds);
    const tk = takeIds.length ? await this.db.select({ id: takes.id, thumb: takes.thumb }).from(takes).where(and(eq(takes.studioId, studioId), inArray(takes.id, takeIds))) : [];
    const rf = refIds.length ? await this.db.select({ id: recreateReferences.id, state: recreateReferences.state, deletedAt: recreateReferences.deletedAt }).from(recreateReferences)
      .where(and(eq(recreateReferences.studioId, studioId), inArray(recreateReferences.id, refIds))) : [];
    const takeOf = new Map(tk.map(t => [t.id, t])), refOf = new Map(rf.map(x => [x.id, x]));
    return rows.map(r => {
      const t = r.takeId ? takeOf.get(r.takeId) : undefined, ref = r.referenceId ? refOf.get(r.referenceId) : undefined;
      // A reference can be used in Recreate while its video is kept (state "ready"); an edit opens while its take exists.
      const src = r.origin === 'reference' ? { available: !!ref && !ref.deletedAt && ref.state === 'ready' } : { available: !!t, thumb: t?.thumb ?? undefined };
      return this.view(r, r.takeId ? perf.get(r.takeId) : undefined, full, src);
    });
  }
  /** The most used tags across the library, for the Recipes filter chips. */
  async topTags(u: AuthUser, limit = 8) {
    owner(u);
    await this.sync(u.studioId);
    const n = new Map<string, number>();
    for (const r of await this.db.select({ tags: editRecipes.tags }).from(editRecipes).where(eq(editRecipes.studioId, u.studioId))) for (const t of r.tags) n.set(t, (n.get(t) ?? 0) + 1);
    return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, Math.min(30, Math.max(1, limit))).map(([tag, count]) => ({ tag, count }));
  }

  /** The library: search words match name, summary and tags; `tags` must all be present. Newest first. */
  async recipes(u: AuthUser, o: { q?: string; tags?: string[]; origin?: string; limit?: number } = {}) {
    owner(u);
    await this.sync(u.studioId);
    let rows = await this.db.select().from(editRecipes).where(and(eq(editRecipes.studioId, u.studioId), o.origin ? eq(editRecipes.origin, o.origin as 'edit') : undefined))
      .orderBy(desc(editRecipes.createdAt));
    const words = (o.q ?? '').toLowerCase().split(/\s+/).filter(Boolean);
    if (words.length) rows = rows.filter(r => { const hay = `${r.name} ${r.summary} ${r.tags.join(' ')}`.toLowerCase(); return words.every(w => hay.includes(w)); });
    if (o.tags?.length) rows = rows.filter(r => o.tags!.every(t => r.tags.includes(t.toLowerCase())));
    return this.withPerf(u.studioId, rows.slice(0, Math.min(200, o.limit ?? 50)));
  }
  async recipe(u: AuthUser, id: string) {
    owner(u);
    const [r] = await this.db.select().from(editRecipes).where(and(eq(editRecipes.id, id), eq(editRecipes.studioId, u.studioId)));
    if (!r) throw notFound('Recipe');
    return (await this.withPerf(u.studioId, [r], true))[0]!;
  }
  async updateRecipe(u: AuthUser, id: string, b: { name?: unknown; tags?: unknown }) {
    owner(u);
    const [r] = await this.db.select().from(editRecipes).where(and(eq(editRecipes.id, id), eq(editRecipes.studioId, u.studioId)));
    if (!r) throw notFound('Recipe');
    const set: Partial<typeof editRecipes.$inferInsert> = { updatedAt: Date.now() };
    if (b.name !== undefined) { if (typeof b.name !== 'string' || b.name.length > 120) throw badRequest('name: up to 120 characters'); set.name = b.name.trim(); }
    if (b.tags !== undefined) {
      if (!Array.isArray(b.tags) || b.tags.length > LEARN_LIMITS.tags || b.tags.some(t => typeof t !== 'string' || !t.trim() || t.length > LEARN_LIMITS.tagChars)) throw badRequest(`tags: up to ${LEARN_LIMITS.tags} words of ${LEARN_LIMITS.tagChars} characters`);
      set.tags = [...new Set((b.tags as string[]).map(t => t.trim().toLowerCase()))];
    }
    await this.db.update(editRecipes).set(set).where(eq(editRecipes.id, id));
    return this.recipe(u, id);
  }
  async removeRecipe(u: AuthUser, id: string) {
    owner(u);
    const gone = await this.db.delete(editRecipes).where(and(eq(editRecipes.id, id), eq(editRecipes.studioId, u.studioId))).returning({ id: editRecipes.id });
    if (!gone.length) throw notFound('Recipe');
  }
  /** The closest recipes to a recipe, a reference or an edited take (not itself), with how close and how they did. */
  async nearest(u: AuthUser, o: { recipeId?: string; referenceId?: string; takeId?: string; k?: number; origin?: string }) {
    owner(u);
    await this.sync(u.studioId);
    const all = await this.db.select().from(editRecipes).where(eq(editRecipes.studioId, u.studioId));
    const self = all.find(r => (o.recipeId && r.id === o.recipeId) || (o.referenceId && r.referenceId === o.referenceId) || (o.takeId && r.takeId === o.takeId));
    if (!self) throw notFound('Recipe');
    const k = Math.min(LEARN_LIMITS.nearest, Math.max(1, o.k ?? 3));
    const ranked = all.filter(r => r.id !== self.id && (!o.origin || r.origin === o.origin)).map(r => ({ r, d: distance(self, r) })).sort((a, b) => a.d - b.d).slice(0, k);
    const views = await this.withPerf(u.studioId, ranked.map(x => x.r));
    return { recipeId: self.id, nearest: views.map((v, i) => ({ ...v, distance: ranked[i]!.d })) };
  }

  // ------------------------------------------------------------------ gaps
  private async countGaps(studioId: string, recipeId: string, referenceId: string | undefined, gaps: Gap[]) {
    const now = Date.now();
    for (const g of gaps) {
      const key = String(g.key ?? '').split('@')[0]!.slice(0, 80);
      if (!key) continue;
      const [cur] = await this.db.select().from(editGaps).where(and(eq(editGaps.studioId, studioId), eq(editGaps.key, key)));
      const ex = { recipeId, ...(referenceId ? { referenceId } : {}), ...(g.atSec != null ? { atSec: g.atSec } : {}), note: String(g.note ?? '').slice(0, 200), at: now };
      if (!cur) {
        await this.db.insert(editGaps).values({ studioId, key, kind: g.kind ?? 'other', what: String(g.what ?? key).slice(0, 200), count: 1, examples: [ex], seen: [recipeId], firstAt: now, lastAt: now })
          .onConflictDoNothing();
      } else if (!cur.seen.includes(recipeId)) {
        await this.db.update(editGaps).set({ count: cur.count + 1, seen: [...cur.seen, recipeId].slice(-500), examples: [ex, ...cur.examples].slice(0, LEARN_LIMITS.gapExamples), lastAt: now })
          .where(eq(editGaps.id, cur.id));
      }
    }
  }
  /** Most requested first. */
  async gaps(u: AuthUser, limit = 50) {
    owner(u);
    await this.sync(u.studioId);
    const rows = await this.db.select().from(editGaps).where(eq(editGaps.studioId, u.studioId)).orderBy(desc(editGaps.count), desc(editGaps.lastAt)).limit(Math.min(200, limit));
    // `references`: recipes that needed it; `asks`: times it was asked for directly (Claude or the owner). count = references + asks.
    return rows.map(g => { const asks = g.seen.filter(x => x.startsWith('ask_')).length;
      return { key: g.key, kind: g.kind, what: g.what, count: g.count, references: Math.max(0, g.count - asks), asks, examples: g.examples, firstAt: g.firstAt, lastAt: g.lastAt }; });
  }
  /** A gap someone asked for directly (Claude couldn't do an effect, or the owner wants one). */
  async addGap(u: AuthUser, b: { key?: unknown; kind?: unknown; what?: unknown; note?: unknown }) {
    owner(u);
    const key = typeof b.key === 'string' ? b.key.trim().split('@')[0]!.slice(0, 80) : '';
    if (!/^[a-z][a-z0-9_-]*(:[a-z0-9 _./-]+)?$/i.test(key)) throw badRequest('key: like "transition:rgb-split" or "effect:lens-flare"');
    const kinds = ['transition', 'effect', 'text', 'font', 'motion', 'other'];
    const kind = typeof b.kind === 'string' && kinds.includes(b.kind) ? b.kind : 'other';
    await this.countGaps(u.studioId, `ask_${Date.now()}`, undefined, [{ key, kind: kind as Gap['kind'], what: typeof b.what === 'string' && b.what ? b.what : key, note: typeof b.note === 'string' ? b.note : '' }]);
    return (await this.gaps(u)).find(g => g.key === key.toLowerCase() || g.key === key)!;
  }

  // ------------------------------------------------------------------ playbook
  private ruleView = (r: typeof playbookRules.$inferSelect) => ({ id: r.id, text: r.text, area: r.area, source: r.source, pinned: r.pinned, evidence: r.evidence,
    createdAt: r.createdAt, updatedAt: r.updatedAt });
  /** Pinned first, then the best-evidenced, then the newest. */
  async playbook(u: AuthUser, o: { area?: string } = {}) {
    owner(u);
    const rows = await this.db.select().from(playbookRules).where(and(eq(playbookRules.studioId, u.studioId), ownersRules(), o.area ? eq(playbookRules.area, o.area) : undefined));
    return rows.sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.evidence.length - a.evidence.length || b.updatedAt - a.updatedAt).map(this.ruleView);
  }
  /** The playbook as the app shows it: correction evidence carries its take and whether that take still exists. */
  async playbookForApp(u: AuthUser, o: { area?: string } = {}) {
    const rules = await this.playbook(u, o);
    const ids = rules.flatMap(r => r.evidence.filter(e => e.kind === 'correction' && typeof e.id === 'number').map(e => e.id as number));
    const cs = ids.length ? await this.db.select({ id: editCorrections.id, takeId: editCorrections.takeId }).from(editCorrections)
      .where(and(eq(editCorrections.studioId, u.studioId), inArray(editCorrections.id, [...new Set(ids)]))) : [];
    const takeOf = new Map(cs.map(c => [c.id, c.takeId])), live = await this.liveTakes(u.studioId, cs.map(c => c.takeId));
    return rules.map(r => ({ ...r, evidence: r.evidence.map(e => { const t = e.kind === 'correction' && typeof e.id === 'number' ? takeOf.get(e.id) : undefined;
      return t ? { ...e, takeId: t, takeExists: live.has(t) } : e; }) }));
  }
  private checkRule(b: { text?: unknown; area?: unknown; evidence?: unknown }, partial: boolean) {
    const out: { text?: string; area?: string; evidence?: { kind: string; id?: string | number; note: string; at: number }[] } = {};
    if (b.text !== undefined || !partial) {
      if (typeof b.text !== 'string' || !b.text.trim()) throw badRequest('text: the rule in plain words');
      if (b.text.length > LEARN_LIMITS.ruleChars) throw badRequest(`text: at most ${LEARN_LIMITS.ruleChars} characters`);
      out.text = b.text.trim();
    }
    if (b.area !== undefined) {
      const areas: readonly string[] = [...MEMORY_AREAS, ...AREAS];
      if (typeof b.area !== 'string' || !areas.includes(b.area)) throw badRequest(`area: one of ${areas.join(', ')}`);
      out.area = b.area;
    }
    if (b.evidence !== undefined) {
      if (!Array.isArray(b.evidence) || b.evidence.length > 50) throw badRequest('evidence: up to 50 items');
      out.evidence = (b.evidence as { kind?: unknown; id?: unknown; note?: unknown }[]).map((e, i) => {
        if (!e || typeof e !== 'object' || !['correction', 'post', 'recipe', 'note'].includes(String(e.kind))) throw badRequest(`evidence.${i}.kind: correction, post, recipe or note`);
        return { kind: String(e.kind), ...(typeof e.id === 'string' || typeof e.id === 'number' ? { id: e.id } : {}), note: String(e.note ?? '').slice(0, 300), at: Date.now() };
      });
    }
    return out;
  }
  async addRule(u: AuthUser, b: { text?: unknown; area?: unknown; evidence?: unknown; pinned?: unknown }, source: 'owner' | 'claude' | 'learned' = 'owner') {
    owner(u);
    const v = this.checkRule(b, false);
    const [{ n }] = await this.db.select({ n: sql<number>`count(*)::int` }).from(playbookRules).where(and(eq(playbookRules.studioId, u.studioId), ownersRules())) as [{ n: number }];
    if (n >= LEARN_LIMITS.rules) throw badRequest(`The playbook holds up to ${LEARN_LIMITS.rules} rules · delete some first`);
    const now = Date.now();
    const [r] = await this.db.insert(playbookRules).values({ id: uid('rule'), studioId: u.studioId, text: v.text!, area: v.area ?? 'other', source,
      pinned: source === 'owner' && b.pinned === true, evidence: v.evidence ?? [], createdAt: now, updatedAt: now }).returning();
    return this.ruleView(r!);
  }
  async updateRule(u: AuthUser, id: string, b: { text?: unknown; area?: unknown; evidence?: unknown; pinned?: unknown }) {
    owner(u);
    const v = this.checkRule(b, true);
    if (b.pinned !== undefined && typeof b.pinned !== 'boolean') throw badRequest('pinned: true or false');
    const [r] = await this.db.update(playbookRules).set({ ...v, ...(typeof b.pinned === 'boolean' ? { pinned: b.pinned } : {}), updatedAt: Date.now() })
      .where(and(eq(playbookRules.id, id), eq(playbookRules.studioId, u.studioId), ownersRules())).returning();
    if (!r) throw notFound('Rule');
    return this.ruleView(r);
  }
  async removeRule(u: AuthUser, id: string) {
    owner(u);
    const gone = await this.db.delete(playbookRules).where(and(eq(playbookRules.id, id), eq(playbookRules.studioId, u.studioId), ownersRules())).returning({ id: playbookRules.id });
    if (!gone.length) throw notFound('Rule');
  }

  // ------------------------------------------------------------------ what Claude reads before an edit
  /**
   * The playbook (pinned first, at most 25), the closest proven recipes (with performance) to the recipe / reference /
   * take at hand, the latest corrections and lessons, and the top gaps. The `playbook_read` tool returns this.
   */
  async context(u: AuthUser, o: { recipeId?: string; referenceId?: string; takeId?: string; area?: string } = {}) {
    owner(u);
    await this.sync(u.studioId);
    const rules = (await this.playbook(u, o.area ? { area: o.area } : {})).slice(0, 25);
    let nearest: unknown[] = [];
    if (o.recipeId || o.referenceId || o.takeId) {
      try { nearest = (await this.nearest(u, { ...o, k: 3 })).nearest; } catch (e) { if (!(e instanceof ApiError)) throw e; }
    } else {
      const latest = await this.db.select().from(editRecipes).where(and(eq(editRecipes.studioId, u.studioId), eq(editRecipes.origin, 'edit'))).orderBy(desc(editRecipes.createdAt)).limit(3);
      nearest = await this.withPerf(u.studioId, latest);
    }
    return { playbook: rules, recipes: nearest, corrections: (await this.corrections(u, { limit: 10 })).map(c => ({ area: c.area, what: c.what, kind: c.kind, at: c.createdAt })),
      lessons: (await this.lessons(u)).slice(0, 8), gaps: (await this.gaps(u, 5)) };
  }
}

const one = new WeakMap<Ctx, Learning>();
export const learningOf = (ctx: Ctx) => { let l = one.get(ctx); if (!l) { l = new Learning(ctx); one.set(ctx, l); } return l; };


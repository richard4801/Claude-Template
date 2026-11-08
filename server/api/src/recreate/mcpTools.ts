// Recreate this edit · Claude's tools (workstream 1, plans/recreate-edit.md step 6): analyse a reference, read its
// recipe (with the contact sheet to write shot briefs), match slots to takes, build the edit, and fill missing slots
// with Suite shots (price first; the owner approves in the app). Owner only, like every edit tool.
import { ApiError, badRequest } from '../errors.js';
import { withImage, type EditTool, type ToolEnv } from '../editor/mcpTools.js';
import { editSessionsOf } from '../editor/sessions.js';
import { learningOf } from '../editor/learn.js';
import type { Recipe } from './analyze.js';
import { recreateOf } from './references.js';
import { playbookBrief, provenStart } from './playbook.js';

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const bool = (d: string) => ({ type: 'boolean', description: d });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const RID = str('Reference id (rx_…), from analyze_reference');
const need = (a: Record<string, unknown>, k: string) => { const v = a[k]; if (typeof v !== 'string' || !v) throw badRequest(`${k}: required`); return v; };

/** The recipe in a few lines a model can read at a glance. */
export function recipeSummary(r: Recipe) {
  return {
    durationSec: r.source.durationSec, aspect: r.source.aspect, shots: r.pacing.shots, cutsPerMin: r.pacing.cutsPerMin, bpm: r.sound?.bpm ?? null,
    slots: r.slots.map(s => ({ id: s.id, startSec: s.startSec, endSec: s.endSec, camera: s.camera.motion, move: s.rig?.moves?.[0]?.id ?? null, speed: s.speed.ramp,
      peaks: s.peaks.length, brief: s.brief, ...((s as { fill?: unknown }).fill ? { fill: (s as { fill?: unknown }).fill } : {}) })),
    transitions: r.transitions.map(t => ({ atSec: t.atSec, kind: t.kind, from: t.from, to: t.to })),
    text: r.text.map(t => ({ id: t.id, startSec: t.startSec, endSec: t.endSec, words: t.words, y: t.box.y })),
    look: r.grade.look ? `${r.grade.look.label} (distance ${r.grade.look.distance})` : null, gaps: r.gaps.map(g => g.what),
  };
}

const rx = (env: ToolEnv) => {
  if (env.user.role !== 'owner') throw new ApiError(403, 'owner_only', 'Recreating edits with Claude is for the studio owner');
  return recreateOf(env.ctx);
};

export const RECREATE_TOOLS: EditTool[] = [
  {
    name: 'analyze_reference', title: 'Analyse a reference edit (free)', scope: 'edit:write',
    description: 'Turns a reference video (an upload in the studio, up to 60 s) into its edit recipe: shots and cut times, transitions, camera moves, speed ramps, action peaks, beats, on-screen text, the grade. Free (server CPU). Waits up to a minute; returns the referenceId, a summary, the studio\'s playbook (follow the owner\'s pinned rules) and startFrom: the studio\'s own posted edit closest to it, when one fits (apply_recipe starts from it unless you pass startFrom: false). Then call get_recipe to see the contact sheet and write each slot\'s brief with set_slot_briefs. Anything in the reference MUSE can\'t rebuild (an effect, a transition, a font): log it with report_gap.',
    inputSchema: obj({ uploadId: str('A video upload id (up_…)'), name: str('A short name for it', 80) }, ['uploadId']),
    run: async (env, a) => {
      const svc = rx(env);
      const r = await svc.create(env.user, { uploadId: need(a, 'uploadId'), ...(typeof a.name === 'string' ? { name: a.name } : {}) });
      const t0 = Date.now();
      for (;;) {
        const row = await svc.row(env.user, r.id);
        if (row.state !== 'analyzing') {
          const v = svc.view(row);
          // Before building: the playbook, and the studio's own proven edit to start from when one is close.
          const extra = v.state === 'ready' ? { playbook: await playbookBrief(env.ctx, env.user, { referenceId: r.id }), startFrom: await provenStart(env.ctx, env.user, r.id) } : {};
          return { referenceId: r.id, state: v.state, ...(v.error ? { error: v.error } : {}), ...(v.recipe ? { summary: recipeSummary(v.recipe as Recipe) } : {}), ...extra };
        }
        if (Date.now() - t0 > 60_000) return { referenceId: r.id, state: 'analyzing', message: 'Still analysing; call get_recipe in a moment.' };
        await new Promise(res => setTimeout(res, 250));
      }
    },
  },
  {
    name: 'get_recipe', title: 'Read a recipe', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'The reference\'s full recipe JSON (schema muse.recipe/1), plus by default the contact sheet image: each slot\'s keyframe labelled "N · start–end s". Use it to write shot briefs (set_slot_briefs) and to read on-screen words the analysis left as null.',
    inputSchema: obj({ referenceId: RID, contactSheet: bool('Include the contact sheet image (default true)') }, ['referenceId']),
    run: async (env, a) => {
      const svc = rx(env), row = await svc.row(env.user, need(a, 'referenceId')), v = svc.view(row);
      const meta = { referenceId: row.id, state: v.state, recipe: v.recipe ?? null };
      if (a.contactSheet === false || !row.contactSheetKey) return meta;
      const obj2 = await svc.contactSheet(env.user, row.id);
      const chunks: Buffer[] = []; for await (const c of obj2.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
      return withImage(Buffer.concat(chunks), meta);
    },
  },
  {
    name: 'set_slot_briefs', title: 'Write shot briefs', scope: 'edit:write',
    description: 'Writes what each slot shows, read from the contact sheet: {slots: {s1: {shotSize, angle, subject, action, location, notes}}}. shotSize: els|ls|full|cowboy|ms|mcu|cu|ecu|insert|ots|pov|two_shot; angle: eye|shoulder|low|high|overhead|worm|ground|hip. The framing and angle also go into the slot\'s rig (used to match takes and to generate missing shots).',
    inputSchema: obj({ referenceId: RID, slots: { type: 'object', description: 'slotId → brief' } }, ['referenceId', 'slots']),
    run: async (env, a) => {
      const v = await rx(env).setBriefs(env.user, need(a, 'referenceId'), { slots: a.slots });
      return { referenceId: v.id, summary: recipeSummary(v.recipe as Recipe) };
    },
  },
  {
    name: 'match_slots', title: 'Match slots to takes', scope: 'edit:read', readOnly: true,
    description: 'Scores the studio\'s video takes against each slot (length, shape, move, framing and angle from their drafts, the lead model, kept takes) and suggests one per slot (each take once). Slots nothing fits are marked toGenerate. You make the final choice for apply_recipe.',
    inputSchema: obj({ referenceId: RID, modelId: str('The lead model (her takes score higher)'), top: { type: 'number', minimum: 1, maximum: 10 } }, ['referenceId']),
    run: async (env, a) => rx(env).match(env.user, need(a, 'referenceId'), { ...(typeof a.modelId === 'string' ? { modelId: a.modelId } : {}), ...(typeof a.top === 'number' ? { top: a.top } : {}) }),
  },
  {
    name: 'apply_recipe', title: 'Build the edit from the recipe', scope: 'edit:write',
    description: 'Builds the edit in an edit session (open_edit) from the recipe: each slot gets its take (or a finished fill_slot job id), cut to the reference\'s timing, with its transition, speed ramp, camera move as keyframes, the text items and the Look. One undoable change. Slots without a take are left out (listed in missing). options: {camera, speed, text, look, transitions} (all true by default). The owner\'s pinned playbook rules win over your options (returned as playbook.followed; playbook.followYourself lists pinned rules for you to apply). startFrom: a proven recipe id, or false; by default the nearest that fits lends its look when the reference\'s can\'t be mapped.',
    inputSchema: obj({ referenceId: RID, sessionId: str('Edit session id (es_…), from open_edit'), slots: { type: 'object', description: 'slotId → takeId or a finished job id' },
      baseRevision: { type: 'number' }, options: { type: 'object', description: '{camera?, speed?, text?, look?, transitions?}' },
      startFrom: { description: 'A proven recipe id from the library, or false for none', anyOf: [{ type: 'string' }, { type: 'boolean' }] } }, ['referenceId', 'sessionId', 'slots']),
    run: async (env, a) => {
      const out = await rx(env).apply(env.user, need(a, 'referenceId'), { sessionId: need(a, 'sessionId'), slots: a.slots, ...(typeof a.baseRevision === 'number' ? { baseRevision: a.baseRevision } : {}),
        ...(a.options ? { options: a.options } : {}), ...(a.startFrom !== undefined ? { startFrom: a.startFrom } : {}) }, { by: 'claude' });
      const s = await editSessionsOf(env.ctx).row(env.user, out.sessionId);
      if (out.missing.length) await editSessionsOf(env.ctx).log(s, `${out.missing.length} slot${out.missing.length === 1 ? '' : 's'} still to fill: ${out.missing.join(', ')}`);
      return { ...out, applied: true };
    },
  },
  {
    name: 'fill_slot', title: 'Generate a missing shot', scope: 'edit:write',
    description: 'Generates a Suite shot for a slot nothing fits: the brief as the prompt, the reference\'s shape, the slot\'s framing, angle and move, long enough for the slot, with the lead model. Paid: without confirm it returns the price; with confirm: true it asks the owner in the MUSE app (in this edit session) and runs after they approve. When the job is done, pass its job id to apply_recipe for that slot.',
    inputSchema: obj({ referenceId: RID, slotId: str('The slot (s1, s2, …)'), modelId: str('The model who plays it'), quality: str('draft | standard | hd | cinema (default standard)'),
      sessionId: str('The edit session to ask the owner in'), confirm: bool('Ask the owner to approve the price') }, ['referenceId', 'slotId', 'modelId', 'sessionId']),
    run: async (env, a) => {
      const svc = rx(env), sess = editSessionsOf(env.ctx);
      const s = await sess.row(env.user, need(a, 'sessionId'));
      const body = { modelId: need(a, 'modelId'), ...(typeof a.quality === 'string' ? { quality: a.quality } : {}) };
      const e = await svc.estimateSlot(env.user, need(a, 'referenceId'), need(a, 'slotId'), body);
      const usd = Number((e.estimate as { estimate?: number }).estimate) || 0;
      const label = `Generate ${e.slotId} for “${(await svc.row(env.user, need(a, 'referenceId'))).name}”`;
      if (a.confirm !== true) {
        await sess.log(s, `Priced ${label}: about $${usd.toFixed(2)}`);
        return { needsConfirmation: true, estimateUsd: usd, seconds: e.request.duration, prompt: e.request.prompt, message: `${label} costs about $${usd.toFixed(2)}. Call again with confirm: true to ask the owner; it runs only after they approve it in the MUSE app.` };
      }
      const p = await sess.askOwner(s, { kind: 'recreate_fill', label, estimateUsd: usd, args: { referenceId: need(a, 'referenceId'), slotId: e.slotId, body } });
      return { waitingForOwner: true, pendingId: p.id, estimateUsd: usd, message: 'The owner has been asked in the MUSE app. When the job is done, use its job id for this slot in apply_recipe.' };
    },
  },
  // The playbook (workstream 3's learning editor, src/editor/learn.ts): read it before building, add what you learned.
  {
    name: 'playbook_read', title: 'Read the studio\'s editing playbook', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'The studio\'s editing playbook before you build an edit: its rules (pinned first, at most 25), the 3 nearest proven recipes with how their posts performed, the latest corrections the owner made to your edits, lessons, and the top gaps. Pass the recipe, reference or take at hand to get the nearest recipes; area narrows the rules (e.g. text, pacing, look).',
    inputSchema: obj({ recipeId: str('A recipe id'), referenceId: str('A reference id (rx_…)'), takeId: str('A take id'), area: str('Narrow the rules to one area', 40) }),
    run: async (env, a) => {
      rx(env);
      const o: { recipeId?: string; referenceId?: string; takeId?: string; area?: string } = {};
      for (const k of ['recipeId', 'referenceId', 'takeId', 'area'] as const) if (typeof a[k] === 'string' && a[k]) o[k] = a[k] as string;
      return learningOf(env.ctx).context(env.user, o);
    },
  },
  {
    name: 'playbook_add', title: 'Add a rule to the playbook', scope: 'edit:write',
    description: 'Adds a rule you learned (≤ 300 characters, one plain sentence, e.g. "Captions sit above the lower third on talking shots"), with its evidence: [{kind: correction|post|recipe|note, id?, note}]. Your rules arrive unpinned; the owner pins, edits or deletes them.',
    inputSchema: obj({ text: str('The rule', 300), area: str('Its area (e.g. text, pacing, look)', 40), evidence: { type: 'array', description: '[{kind, id?, note}]' } }, ['text']),
    run: async (env, a) => { rx(env); return learningOf(env.ctx).addRule(env.user, { text: a.text, area: a.area, evidence: a.evidence }, 'claude'); },
  },
  {
    name: 'report_gap', title: 'Report something MUSE can\'t do yet', scope: 'edit:write',
    description: 'Records a gap: an effect, transition or font in a reference that MUSE can\'t recreate. key is stable and specific (e.g. "effect:lens-flare", "transition:page-curl"); gaps are counted across references to decide what to build.',
    inputSchema: obj({ key: str('A stable key, kind:name', 80), kind: str('transition | effect | text | font | motion | other'), what: str('What it is, in a few words', 120), note: str('Where you saw it', 300) }, ['key', 'kind', 'what']),
    run: async (env, a) => { rx(env); return learningOf(env.ctx).addGap(env.user, { key: a.key, kind: a.kind, what: a.what, note: a.note }); },
  },
];

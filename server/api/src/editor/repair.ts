// One-off repair (WS3, 2026-11-08): until 06ec12c the mock's background removal handed back the source video as the
// matte, and with the apps applying alphaMatte the clip's own brightness became its alpha. This removes those alphaMatte
// entries (a matte asset that is the clip's own source: the same take or the same upload) from open edit sessions and
// saved edited versions. Idempotent: a repaired project has none left. Logs counts only.
import { and, eq, sql } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { takes } from '../db/schema.js';
import * as M from './model.js';
import { editSessions } from './schema.js';

type Asset = { id: string; take?: string; upload?: string };

/** The project without alphaMatte entries whose matte is the clip's own source, and how many were removed. */
export function stripSourceMattes(p: M.EditProject): { project: M.EditProject; removed: number } {
  const assets = new Map((p.assets as Asset[]).map(a => [a.id, a]));
  const same = (a?: Asset, b?: Asset) => !!a && !!b && ((!!a.take && a.take === b.take) || (!!a.upload && a.upload === b.upload));
  let removed = 0;
  const tracks = p.tracks.map(t => ({
    ...t,
    items: t.items.map(it => {
      const c = it as M.VideoClip;
      if (!c.alphaMatte || !same(assets.get(c.alphaMatte.asset), assets.get(c.asset))) return it;
      removed++;
      const { alphaMatte: _gone, ...rest } = c;
      return rest as typeof it;
    }),
  })) as M.EditProject['tracks'];
  return { project: removed ? { ...p, tracks } : p, removed };
}

/** Saved edited versions (takes of kind "edit" with a v2 project): repaired in place. */
export async function repairSourceMatteVersions(ctx: Ctx): Promise<number> {
  const rows = await ctx.db.select({ id: takes.id, media: takes.media }).from(takes)
    .where(and(sql`${takes.kind} = 'edit'`, sql`${takes.media}::text like '%alphaMatte%'`));
  let n = 0;
  for (const r of rows) {
    const media = (r.media ?? {}) as { edits?: M.EditProject & { version?: number } };
    if (media.edits?.version !== 2) continue;
    const { project, removed } = stripSourceMattes(media.edits);
    if (!removed) continue;
    await ctx.db.update(takes).set({ media: { ...media, edits: project } as Record<string, unknown> }).where(eq(takes.id, r.id));
    n++;
  }
  return n;
}

/** Ids of edit sessions whose project mentions alphaMatte (the candidates; the sessions service repairs them). */
export async function sourceMatteCandidates(ctx: Ctx): Promise<string[]> {
  return (await ctx.db.select({ id: editSessions.id }).from(editSessions).where(sql`${editSessions.project}::text like '%alphaMatte%'`)).map(r => r.id);
}

// A provider result that is (or may be) paid but did not become a take. Shared by the AI Suite line (suite/runner.ts)
// and the Character swap line (services/replicateVideo.ts, Replicate + Higgsfield): never say "you weren't charged" for
// it, keep the provider's request id, tell the owner (high-severity issue), and let the owner bring it back for free
// (POST /v1/jobs/:id/recover, MCP tool job_recover: a status/result GET only, never a new generation).
import { eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { users } from '../db/schema.js';
import { recordIssue } from '../claude/issues.js';
import type { JobRow } from '../gpu/controller.js';

/** The provider made (and charged for) the video, but this server could not save it. Never "you weren't charged". */
export const PAID_UNSAVED = "Your video was made (the provider charged the studio) but MUSE couldn't save it · it can be recovered for free";
/** We stopped waiting, the provider didn't confirm a cancel: it may still finish and charge. */
export const PAID_UNCONFIRMED = "The provider didn't finish in time and may still charge the studio · it can be recovered for free if it finishes";
/** The job error codes the apps show "Recover" for (free, owner-only) instead of "Retry". */
export const PAID_CODES = { unsaved: 'provider_paid_unsaved', unconfirmed: 'provider_unconfirmed' } as const;

export class PaidLost extends Error {
  constructor(readonly kind: 'unsaved' | 'unconfirmed', readonly take: number, readonly why: string) { super(why); }
}

export const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

/** The failed job's message and code for a lost paid result. */
export function paidLostFailure(e: PaidLost) {
  return { message: e.kind === 'unsaved' ? PAID_UNSAVED : PAID_UNCONFIRMED, code: PAID_CODES[e.kind] };
}

/** The owner's issue list gets the lost result (owner tool job_recover brings it back for free). */
export async function reportPaidLost(ctx: Ctx, job: JobRow, modelName: string, e: PaidLost, tool: string) {
  const [u] = job.userId ? await ctx.db.select({ role: users.role }).from(users).where(eq(users.id, job.userId)) : [];
  await recordIssue(ctx, { id: job.userId ?? 'system', studioId: job.studioId, role: u?.role ?? 'member' }, {
    source: 'auto', kind: 'bug', severity: 'high', page: 'queue', tool,
    summary: e.kind === 'unsaved'
      ? `A paid ${modelName} take was made by the provider but MUSE could not save it (job ${job.id}). Recover it free with job_recover.`
      : `A ${modelName} take ran past its time and the provider did not confirm a cancel (job ${job.id}); it may still be charged. job_recover fetches it if it finishes.`,
    error: e.why.slice(0, 300),
  });
}

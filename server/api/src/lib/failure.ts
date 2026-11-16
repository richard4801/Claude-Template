// Owner-only failure diagnostics (coordinator 2026-11-16, job j_c1d11a56e120): when a provider refuses or fails a job, the
// member sees only the member-safe `error`; the provider's own words used to reach the server log only. A failed job now
// keeps {provider, model, httpStatus, category, providerMessage, at, stage} in its stats (`stats.failure`; an Edit helper
// job in `result.failure`), shown to the studio owner only (queue_list, GET /v1/jobs, GET /v1/jobs/:id). The provider's
// message is scrubbed of anything credential-shaped and of signed-URL query strings, and capped at 300 characters.

export const FAILURE_CATEGORIES = ['credit', 'key', 'validation', 'content_filter', 'unreachable', 'timeout', 'server', 'unknown'] as const;
export type FailureCategory = typeof FAILURE_CATEGORIES[number];
export type FailureStage = 'submit' | 'poll' | 'download';
export type ProviderFailure = {
  provider: string; model: string | null; httpStatus: number | null; category: FailureCategory;
  providerMessage: string | null; at: number; stage: FailureStage;
};

/** What a provider error may carry (set where it's thrown: byo/adapters.ts, suite/providers.ts, replicate/client.ts). */
export type FailureNotes = { detail?: string; stage?: FailureStage; provider?: string; model?: string; failure?: ProviderFailure };

/** Adds the provider's own words (and where it failed) to an error, for the owner's diagnostic. Returns the error. */
export function note<E extends object>(e: E, n: Omit<FailureNotes, 'failure'>): E {
  const t = e as E & FailureNotes;
  if (n.detail != null && t.detail == null) t.detail = n.detail;
  if (n.stage && !t.stage) t.stage = n.stage;
  if (n.provider && !t.provider) t.provider = n.provider;
  if (n.model && !t.model) t.model = n.model;
  return e;
}

export const MESSAGE_MAX = 300;

/** A provider's words, safe to store: no keys, tokens, auth headers or signed-URL queries; at most 300 characters. */
export function scrubProviderMessage(s: unknown, secrets: (string | null | undefined)[] = []): string | null {
  if (s == null) return null;
  let t = typeof s === 'string' ? s : (() => { try { return JSON.stringify(s); } catch { return String(s); } })();
  for (const k of secrets) if (k && k.length >= 4) t = t.split(k).join('[redacted]');
  // A key the provider echoes in "x-api-key: …" / "Authorization: Key …" form.
  t = t.replace(/\b(x-api-key|authorization)(["']?\s*[:=]\s*["']?)(?:(bearer|basic|key|token)\s+)?[^\s"',;]+/gi, (_m, h, sep) => `${h}${sep}[redacted]`);
  // The same rules as claude/issues.ts scrub() and editor/templatePacks.ts redactCredentials() (kept here: those modules
  // pull in the database and chat layers, and this one is imported by the provider adapters).
  t = t
    .replace(/\b(bearer|basic|token|key)\s+[A-Za-z0-9._~+/=:-]{16,}/gi, '$1 [redacted]')
    .replace(/\b((?:api[_-]?)?key|secret|password|passwd|pwd|token|auth(?:orization)?|signature|credential)s?(["']?\s*[:=]\s*["']?)[^\s"'&,;]{4,}/gi, '$1$2[redacted]')
    .replace(/\b(?:sk|pk|rk|r8|fal|ghp|gho|github_pat|xox[abp]|AKIA|mt|pat|hf)[-_][A-Za-z0-9_-]{8,}/g, '[redacted]')
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, '[redacted]')
    .replace(/(https?:\/\/[^\s?#"']+)\?[^\s#"']*/g, '$1?[query removed]')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
    .replace(/\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{32,}={0,2}/g, '[redacted]')
    .replace(/\s+/g, ' ').trim();
  if (t.length > MESSAGE_MAX) t = `${t.slice(0, MESSAGE_MAX - 1)}…`;
  return t || null;
}

const kindOf = (e: unknown): string | undefined => {
  const x = e as { kind?: unknown; code?: unknown } | null;
  return typeof x?.kind === 'string' ? x.kind : typeof x?.code === 'string' ? x.code : undefined;
};

/** Which kind of failure this is, from the error's kind, HTTP status and words. */
export function categoryOf(e: unknown): FailureCategory {
  if (!e || typeof e !== 'object') return 'unknown';
  const kind = kindOf(e), status = (e as { status?: unknown }).status;
  const st = typeof status === 'number' ? status : null;
  const text = `${(e as Error).message ?? ''} ${(e as FailureNotes).detail ?? ''}`;
  if (kind === 'out_of_credit' || kind === 'provider_out_of_credit' || st === 402) return 'credit';
  if (kind === 'refused' || kind === 'provider_refused') return 'content_filter';
  if (st === 401 || /refused the (studio's|server's) (key|token)|didn't accept that key|invalid (api[ _-]?)?key|not authori[sz]ed/i.test(text)) return 'key';
  if (st === 403 && kind === 'unavailable') return 'key';
  if (/\bunreachable\b|ECONNREFUSED|ENOTFOUND|ECONNRESET|EAI_AGAIN|fetch failed/i.test(text) && st == null) return 'unreachable';
  if (kind === 'timeout' || /\btimed out\b|took too long|TimeoutError/i.test(text)) return 'timeout';
  if (st != null && (st >= 500 || st === 429)) return 'server';
  if (kind === 'rate_limited' || kind === 'provider_rate_limited') return 'server';
  if (st != null && st >= 400) return 'validation';
  return 'unknown';
}

/**
 * The owner's diagnostic for a failed provider call. `fallback` names the provider and model when the error doesn't
 * (the error's own `provider`/`model` notes win: a custom model reports e.g. muapi and its catalog name, not "byo").
 * `secrets` are literal values (a provider key in hand) removed from the message as well.
 */
export function providerFailure(e: unknown, fallback: { provider: string; model?: string | null; stage?: FailureStage; secrets?: (string | null | undefined)[] }): ProviderFailure {
  const n = (e && typeof e === 'object' ? e : {}) as FailureNotes & { status?: unknown; message?: string };
  if (n.failure) return n.failure;
  const status = typeof n.status === 'number' ? n.status : null;
  const message = n.detail != null && String(n.detail).trim() ? n.detail : n.message ?? (typeof e === 'string' ? e : null);
  const stage: FailureStage = n.stage ?? fallback.stage ?? (/download/i.test(n.message ?? '') ? 'download' : status != null ? 'submit' : 'poll');
  return {
    provider: String(n.provider ?? fallback.provider ?? 'unknown').slice(0, 40), model: (n.model ?? fallback.model ?? null)?.slice(0, 200) ?? null,
    httpStatus: status, category: categoryOf(e), providerMessage: scrubProviderMessage(message, fallback.secrets), at: Date.now(), stage,
  };
}

/** Attaches a ready diagnostic to an error (kept through re-wrapping by callers that copy `failure`). */
export function withFailure<E extends object>(e: E, f: ProviderFailure | undefined): E {
  if (f) (e as E & FailureNotes).failure = f;
  return e;
}

/** The diagnostic an error already carries, if any. */
export const failureOfError = (e: unknown): ProviderFailure | undefined => (e && typeof e === 'object' ? (e as FailureNotes).failure : undefined);

// AssemblyAI transcription (captions and cuts): the owner's account, key ASSEMBLYAI_API_KEY (server env; sent only in
// the authorization header, never logged). Async pre-recorded API: POST /v2/transcript {audio_url} → poll
// GET /v2/transcript/{id} (queued | processing | completed | error) → words in ms. The transcript is deleted at
// AssemblyAI as soon as we have the words (DELETE also removes the audio it fetched), finished or not.
// Price (assemblyai.com/pricing, 2026-10-27): per hour of audio, Universal-3.5 Pro $0.21, Universal-2 $0.15; with the
// default routing U3 Pro takes its 18 languages and U2 the rest. Settled on audio_duration × the model it used.
import { ReplicateError } from '../replicate/client.js';
import type { Word } from './cuts.js';
import type { Hooks, Transcript } from './providers.js';

/** The model id the owner picks in Default models (purpose captions). */
export const ASSEMBLY_MODEL = 'assemblyai/universal';
/** $ per second of audio per speech model; the estimate uses the dearer one. */
export const ASSEMBLY_RATES: Record<string, number> = { 'universal-3-5-pro': 0.21 / 3600, 'universal-2': 0.15 / 3600 };
export const ASSEMBLY_MAX_RATE = Math.max(...Object.values(ASSEMBLY_RATES));
const SPEECH_MODELS = ['universal-3-5-pro', 'universal-2'];

type Reply = {
  id?: string; status?: string; error?: string; language_code?: string; audio_duration?: number; speech_model_used?: string;
  words?: { text: string; start: number; end: number; confidence?: number }[];
};

export class AssemblyAI {
  pollMs = 3000;
  constructor(private key: string | undefined, private base: string, private fetchFn: typeof fetch = fetch, private log?: { warn: (o: object, m: string) => void }) {}
  configured() { return !!this.key; }
  private url(p: string) { return `${this.base.replace(/\/$/, '')}${p}`; }
  private headers() { return { authorization: this.key!, 'content-type': 'application/json' }; }

  private async call(method: string, p: string, body?: unknown): Promise<{ status: number; json: Reply }> {
    const res = await this.fetchFn(this.url(p), { method, headers: this.headers(), ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(60_000) })
      .catch(e => { throw new ReplicateError(`Transcription service unreachable (${(e as Error).name})`, 'unavailable'); });
    const json = (await res.json().catch(() => ({}))) as Reply;
    return { status: res.status, json };
  }
  private async remove(id: string) {
    try { await this.call('DELETE', `/v2/transcript/${encodeURIComponent(id)}`); } catch (e) { this.log?.warn({ err: (e as Error).message }, 'assemblyai delete failed'); }
  }

  /**
   * [mediaUrl] transcribed: its words (seconds), the language spoken (detected unless given) and the audio seconds it
   * billed with the model used (`usd`, before markup). Silence comes back as no words, not a failure.
   */
  async transcribe(mediaUrl: string, durationSec: number, language: string | null, h: Hooks): Promise<Transcript & { usd: number; model: string | null }> {
    if (!this.key) throw new ReplicateError('Transcription is not set up on the server', 'unavailable');
    if (h.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
    const sub = await this.call('POST', '/v2/transcript', { audio_url: mediaUrl, speech_models: SPEECH_MODELS, punctuate: true, format_text: true, ...(language ? { language_code: language } : { language_detection: true }) });
    if (sub.status === 401 || sub.status === 403) throw new ReplicateError("The transcription service refused the server's key", 'unavailable', sub.status);
    if (sub.status === 402) throw new ReplicateError('The transcription account is out of credit', 'out_of_credit', 402);
    if (sub.status === 429) throw new ReplicateError('The transcription service is busy', 'rate_limited', 429);
    if (sub.status >= 400 || !sub.json.id) throw new ReplicateError(`Transcription was rejected (${sub.status}: ${String(sub.json.error ?? '').slice(0, 200)})`, 'failed', sub.status);
    const id = sub.json.id;
    await h.onPrediction?.(`assemblyai:${id}`);
    const t0 = Date.now(), maxMs = Math.max(10 * 60_000, durationSec * 3000);
    try {
      for (;;) {
        if (h.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
        if (Date.now() - t0 > maxMs) throw new ReplicateError('Transcription took too long', 'failed');
        await new Promise(r => setTimeout(r, this.pollMs));
        const g = await this.call('GET', `/v2/transcript/${encodeURIComponent(id)}`).catch(e => { if (e instanceof ReplicateError) return null; throw e; });
        if (!g || g.status >= 500 || g.status === 429) continue;
        const r = g.json;
        if (r.status === 'error') {
          // A video with no speech in it: no captions, nothing to fail.
          if (/no spoken audio|no speech|does not appear to contain audio|contain(s)? no audio/i.test(r.error ?? '')) return { words: [], language: language ?? 'en', gpuSec: null, usd: 0, model: null };
          throw new ReplicateError(`Transcription failed: ${String(r.error ?? 'unknown').slice(0, 200)}`, 'failed');
        }
        if (r.status === 'completed') {
          const words: Word[] = (r.words ?? []).filter(w => typeof w.text === 'string' && Number.isFinite(w.start) && Number.isFinite(w.end))
            .map(w => ({ text: w.text, startSec: w.start / 1000, endSec: Math.max(w.start, w.end) / 1000, ...(typeof w.confidence === 'number' ? { score: w.confidence } : {}) }));
          const audioSec = Number(r.audio_duration) > 0 ? Number(r.audio_duration) : durationSec;
          const model = r.speech_model_used ?? null, rate = (model && ASSEMBLY_RATES[model]) || ASSEMBLY_MAX_RATE;
          const lang = (r.language_code ?? language ?? 'en').split('_')[0]!.toLowerCase();
          return { words, language: lang, gpuSec: null, usd: audioSec * rate, model };
        }
        await h.onProgress?.(Math.min(0.9, (Date.now() - t0) / Math.max(30_000, durationSec * 400)), '');
      }
    } finally { await this.remove(id); }
  }
}

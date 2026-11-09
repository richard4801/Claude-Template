// Translated captions (src/editor/translate.ts, kind "translate"): lines and timing (unit), then the job with a fake
// Claude client — needs a transcript, estimate → hold → settle on the tokens actually used, the owner's switch, the
// model kept from members, a line the answer misses kept as it was.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { ledger, takes } from '../src/db/schema.js';
import { editorAi } from '../src/editor/service.js';
import { TRANSLATE_MODELS, captionLines, timeLine, translateUsd, type TranslateClient } from '../src/editor/translate.js';
import { exportNotice } from '../src/editor/scripts.js';
import { makeApp, people, until, type Client } from './helpers.js';

describe('translated captions (unit)', () => {
  it('lines break at pauses, sentence ends and 12 words; a translated line shares its time out by word length', () => {
    const w = (text: string, s: number, e: number) => ({ text, startSec: s, endSec: e });
    const words = [w('Hi', 0, 0.3), w('there.', 0.3, 0.6), w('So', 0.7, 0.9), w('today', 0.9, 1.2), w('we', 2.5, 2.6), ...Array.from({ length: 14 }, (_, i) => w('go', 2.7 + i * 0.1, 2.75 + i * 0.1))];
    const lines = captionLines(words);
    expect(lines.map(l => l.text)).toEqual(['Hi there.', 'So today', `we ${'go '.repeat(11).trim()}`, 'go go go']);
    expect(lines[1]).toMatchObject({ from: 2, to: 3, startSec: 0.7, endSec: 1.2 });
    const t = timeLine({ startSec: 1, endSec: 2 }, 'Hola a todos', 'es');
    expect(t.map(x => x.text)).toEqual(['Hola', 'a', 'todos']);
    expect(t[0]!.startSec).toBe(1); expect(t.at(-1)!.endSec).toBe(2);
    expect(t[1]!.endSec - t[1]!.startSec).toBeLessThan(t[0]!.endSec - t[0]!.startSec); // shorter word, less time
    const ja = timeLine({ startSec: 0, endSec: 1 }, 'こんにちは、みなさん今日は', 'ja');
    expect(ja.length).toBeGreaterThan(2); expect(ja.map(x => x.text).join('')).toBe('こんにちは、みなさん今日は');
    expect(translateUsd('standard', { input: 1000, output: 1000 }, 2)).toBe(0.01); // at least a cent
    expect(translateUsd('best', { input: 100_000, output: 100_000 }, 2)).toBeCloseTo((0.2 + 1) * 2, 6);
  });
  it('captions in a script the export can’t draw yet say so; drawable ones don’t', () => {
    expect(exportNotice('ja')).toMatch(/Japanese show in the app, but exports can't draw them yet/);
    for (const l of ['zh', 'ko', 'ar', 'he', 'hi', 'th']) expect(exportNotice(l)).not.toBeNull();
    for (const l of ['en', 'ru', 'el', 'vi', 'fil']) expect(exportNotice(l, [{ text: 'Привет' }, { text: 'Xin chào' }])).toBeNull();
    expect(exportNotice('en', [{ text: 'hello' }, { text: '東京' }])).toMatch(/Some caption letters/);
    expect(exportNotice(null, [{ text: 'مرحبا' }])).toMatch(/Some caption letters/);
  });
});

describe('translate job (fake Claude)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client;
  const calls: Record<string, unknown>[] = [];
  let drop = false;
  const fake: TranslateClient = { messages: { create: async p => {
    calls.push(p);
    const lines = (JSON.parse((p.messages as { content: string }[])[0]!.content) as { lines: { i: number; text: string }[] }).lines;
    const out = lines.filter(l => !(drop && l.i === 0)).map(l => ({ i: l.i, text: `ES ${l.text}` }));
    return { content: [{ type: 'text', text: JSON.stringify({ lines: out }) }], usage: { input_tokens: 50_000, output_tokens: 40_000 }, stop_reason: 'end_turn' };
  } } };
  beforeAll(async () => { a = await makeApp(); const p = await people(a, 1); owner = p.owner; member = p.members[0]!; await owner.req('POST', '/v1/wallets/transfer', { toUserId: (member as any).id, tokens: 1000, note: 'test' }); editorAi(a.ctx).setTranslateClient(fake); });
  afterAll(async () => { await a.close(); });

  const take = async () => {
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id as string;
    const id = `take_${Math.random().toString(16).slice(2, 10)}`;
    await a.ctx.storage.put(`c/${id}.mp4`, Buffer.from('source video'), 'video/mp4');
    await a.ctx.db.insert(takes).values({ id, studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD', engineLabel: 'HD', cost: 1, seed: 1,
      status: 'final', thumb: null, prompt: 'p', mediaKey: `c/${id}.mp4`, media: { durationSec: 25, width: 1080, height: 1920, fps: 30, contentType: 'video/mp4' }, createdAt: Date.now() });
    return id;
  };
  const done = (c: Client, id: string) => until(async () => { const x = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; });

  it('needs captions first; then translates every line, timed inside it, and settles on the tokens used', async () => {
    const src = await take();
    const feat = (await owner.req('GET', '/v1/editor/features')).body.translate;
    expect(feat).toMatchObject({ available: true, qualities: ['standard', 'best'] });
    // Only languages the export draws today (scripts.ts): no CJK, Arabic, Hebrew, Hindi or Thai until fonts and shaping land.
    expect(feat.languages).toEqual(expect.arrayContaining(['es', 'ru', 'el', 'vi']));
    for (const l of ['ja', 'zh', 'ko', 'ar', 'he', 'hi', 'th']) expect(feat.languages).not.toContain(l);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'ja' } })).body.error).toMatch(/targetLanguage: one of/);
    const none = await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'es' } });
    expect(none.status).toBe(400); expect(none.body.error).toMatch(/captions for this video first/);
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'xx' } })).status).toBe(400);
    const cap = await done(owner, (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: src }, options: { language: 'en' } })).body.id);
    expect(cap.state).toBe('done');
    expect(cap.result.exportNotice).toBeUndefined();
    // Captions in Japanese: made, with a plain notice that exports can't draw them yet.
    const jaCap = await done(owner, (await owner.req('POST', '/v1/editor/jobs', { kind: 'captions', source: { takeId: await take() }, options: { language: 'ja' } })).body.id);
    expect(jaCap.result).toMatchObject({ language: 'ja', exportNotice: expect.stringMatching(/Japanese .* exports can't draw them yet/) });
    expect((await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'en' } })).body.error).toMatch(/already in that language/);

    const est = (await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'es' } })).body;
    expect(est).toMatchObject({ kind: 'translate', free: false });
    expect(est.usd).toBeGreaterThanOrEqual(0.01);
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'es' } })).body;
    expect(j.models).toEqual([TRANSLATE_MODELS.standard.model]); // owner only
    const r = await done(owner, j.id);
    expect(r.state, JSON.stringify(r)).toBe('done');
    expect(r.result).toMatchObject({ language: 'es', sourceLanguage: 'en', quality: 'standard', untranslatedLines: 0 });
    expect(r.result.words[0].text).toBe('ES');
    const lines = captionLines(cap.result.words);
    expect(r.result.lines).toHaveLength(lines.length);
    expect(r.result.lines[0]).toMatchObject({ text: `ES ${lines[0]!.text}`, startSec: lines[0]!.startSec, endSec: lines[0]!.endSec, translated: true });
    // Every translated word sits inside its line's time, in order.
    for (let i = 1; i < r.result.words.length; i++) expect(r.result.words[i].startSec).toBeGreaterThanOrEqual(r.result.words[i - 1].startSec - 1e-9);
    expect(r.result.words[0].startSec).toBeCloseTo(lines[0]!.startSec, 3); expect(r.result.words.at(-1).endSec).toBeCloseTo(lines.at(-1)!.endSec, 3);
    // Settled on what the calls used: 50K in + 40K out per call on Haiku, × 2.
    const expected = translateUsd('standard', { input: 50_000 * calls.length, output: 40_000 * calls.length }, 2);
    expect(r.costUsd).toBeCloseTo(expected, 6);
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, j.id));
    expect(rows.map(x => x.kind).sort()).toEqual(['hold', 'settle']);
    expect(calls[0]).toMatchObject({ model: 'claude-haiku-5-5', output_config: { format: { type: 'json_schema' } } });
    expect(String(calls[0]!.system)).toMatch(/Spanish/);

    // The member sees the job but not the model; "best" uses the larger model; a line the answer misses stays as it was.
    drop = true;
    const m = (await member.req('POST', '/v1/editor/jobs', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'fr', quality: 'best', fromJobId: cap.id } })).body;
    expect(m.id, JSON.stringify(m)).toBeTruthy();
    expect(m.models).toBeUndefined();
    const mr = await done(member, m.id);
    drop = false;
    expect(mr.state, JSON.stringify(mr)).toBe('done');
    expect(mr.result.untranslatedLines).toBe(1);
    expect(mr.result.words[0].text).toBe(cap.result.words[0].text);
    expect(calls.at(-1)).toMatchObject({ model: TRANSLATE_MODELS.best.model });
    expect(JSON.stringify(mr)).not.toMatch(/claude|haiku|sonnet|anthropic/i);

    // The app's own lines (edited captions): ids come back, no transcript needed, a missed line keeps its text, timed.
    const appLines = [{ id: 'p1', text: 'Hello everyone', startSec: 0, endSec: 1.2 }, { id: 'p2', text: 'Edited by hand', startSec: 1.5, endSec: 3 }];
    const bad = async (options: unknown) => (await owner.req('POST', '/v1/editor/estimate', { kind: 'translate', source: { takeId: src }, options })).body.error;
    expect(await bad({ targetLanguage: 'es', lines: [] })).toMatch(/1 to 2000 lines/);
    expect(await bad({ targetLanguage: 'es', lines: [appLines[0], appLines[0]] })).toMatch(/unique id/);
    expect(await bad({ targetLanguage: 'es', lines: [{ ...appLines[0], endSec: -1 }] })).toMatch(/seconds from 0/);
    expect(await bad({ targetLanguage: 'es', sourceLanguage: 'es', lines: appLines })).toMatch(/already in that language/);
    const fresh = await take(); // no captions job: lines alone are enough
    drop = true;
    const al = await done(owner, (await owner.req('POST', '/v1/editor/jobs', { kind: 'translate', source: { takeId: fresh }, options: { targetLanguage: 'de', sourceLanguage: 'en', lines: appLines } })).body.id);
    drop = false;
    expect(al.state, JSON.stringify(al)).toBe('done');
    expect(al.result).toMatchObject({ language: 'de', sourceLanguage: 'en', untranslatedLines: 1, lines: [{ id: 'p1', text: 'Hello everyone', translated: false }, { id: 'p2', text: 'ES Edited by hand', translated: true, startSec: 1.5, endSec: 3 }] });
    expect(al.result.words.map((w: any) => w.text)).toEqual(['Hello', 'everyone', 'ES', 'Edited', 'by', 'hand']);
    expect(al.result.words[0].startSec).toBe(0); expect(al.result.words[1].endSec).toBe(1.2); expect(al.result.words[2].startSec).toBe(1.5);

    // The owner's switch stops it.
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'off' });
    const off = await owner.req('POST', '/v1/editor/jobs', { kind: 'translate', source: { takeId: src }, options: { targetLanguage: 'de' } });
    expect(off.status).toBe(503);
    await owner.req('PATCH', '/v1/editor/settings', { paidHelpers: 'on' });
  }, 60_000);
});

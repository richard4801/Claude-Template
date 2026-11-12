// Edit's platform preview, for Claude (owner decision 2026-11-12, plans/edit-platform-preview.md). The app's preview shows
// a view (Clean, TikTok, Reels, Shorts, Facebook; YouTube or Facebook on 16:9) and a red safe-area box; the app sends that
// choice with its presence ping. This file gives the box for the view and finds captions and text outside it, so get_edit
// can show Claude what the person sees and apply_edit_ops can warn when a change puts words under an app's buttons.
// The same estimate as MuseCore EditSafeCheck (mac/MuseCore/Sources/MuseCore/Edit/EditPlatformPreview.swift).
import * as M from './model.js';
import { PREVIEW_LANDSCAPE, PREVIEW_ZONES, type SafeZone } from '../suite/previewLayouts.js';

export const PREVIEW_VIEWS = ['clean', 'tiktok', 'reels', 'shorts', 'facebook', 'youtube'] as const;
export type PreviewView = (typeof PREVIEW_VIEWS)[number];
export type EditPreview = { view: PreviewView; safeArea: boolean };

const LABEL: Record<PreviewView, string> = { clean: 'Clean', tiktok: 'TikTok', reels: 'Reels', shorts: 'Shorts', facebook: 'Facebook', youtube: 'YouTube' };
export const TITLE_SAFE: SafeZone = { top: 0.05, bottom: 0.05, left: 0.05, right: 0.05 };

/** The app's preview from its presence body, or null when it sent none (an older app). */
export function previewOf(raw: unknown): EditPreview | null {
  const r = raw as { view?: unknown; safeArea?: unknown } | null | undefined;
  if (!r || typeof r !== 'object' || !PREVIEW_VIEWS.includes(r.view as PreviewView)) return null;
  return { view: r.view as PreviewView, safeArea: r.safeArea !== false };
}

const landscape = (p: M.EditProject) => p.canvas.width / Math.max(1, p.canvas.height) > 1.05;

/** The views a canvas of this shape offers, and the one it shows (a view the shape lacks shows as Clean). */
export const viewsFor = (p: M.EditProject): PreviewView[] => (landscape(p) ? ['clean', 'youtube', 'facebook'] : ['clean', 'tiktok', 'reels', 'shorts', 'facebook']);
const resolved = (p: M.EditProject, v: PreviewView): PreviewView => (viewsFor(p).includes(v) ? v : 'clean');

/** The box safe on every phone app: the largest inset of each side. */
export function everyApp(): SafeZone {
  const zs = Object.values(PREVIEW_ZONES);
  return { top: Math.max(...zs.map(z => z.top)), bottom: Math.max(...zs.map(z => z.bottom)), left: Math.max(...zs.map(z => z.left)), right: Math.max(...zs.map(z => z.right)) };
}

/** The red box for this view on this canvas (null: the switch is off). */
export function zoneFor(p: M.EditProject, pv: EditPreview): SafeZone | null {
  if (!pv.safeArea) return null;
  const v = resolved(p, pv.view);
  if (landscape(p)) return v === 'clean' ? TITLE_SAFE : PREVIEW_LANDSCAPE[v as 'youtube' | 'facebook'] ?? null;
  return v === 'clean' ? everyApp() : PREVIEW_ZONES[v as keyof typeof PREVIEW_ZONES] ?? null;
}

/** What the app's own chrome covers ("TikTok's caption and buttons"). */
export function covers(p: M.EditProject, pv: EditPreview): string {
  const v = resolved(p, pv.view), wide = landscape(p);
  if (v === 'clean') return wide ? 'the edge of some screens' : "some apps' captions and buttons";
  if (v === 'youtube') return "YouTube's title and controls";
  return wide ? `${LABEL[v]}'s controls` : `${LABEL[v]}'s caption and buttons`;
}

type Box = { x: number; y: number; w: number; h: number };
/** An approximate box for a block of text (fractions of the canvas); glyphs ≈ 0.55 em (0.62 uppercase). */
export function textBox(text: string, o: { x: number; y: number; sizePct: number; maxWidthPct?: number; lineHeight?: number; uppercase?: boolean; maxLines?: number; aspect: number }): Box {
  const em = o.sizePct / Math.max(0.1, o.aspect), glyph = em * (o.uppercase ? 0.62 : 0.55), wrap = o.maxWidthPct ?? 0.85;
  let lines = 0, widest = 0;
  for (const raw of text.split('\n')) {
    const w = [...raw].length * glyph;
    lines += Math.max(1, Math.ceil(w / Math.max(0.01, wrap)));
    widest = Math.max(widest, Math.min(w, wrap));
  }
  if (o.maxLines !== undefined) lines = Math.min(lines, Math.max(1, o.maxLines));
  return { x: o.x, y: o.y, w: widest, h: Math.max(1, lines) * o.sizePct * (o.lineHeight ?? 1.15) };
}

function edges(b: Box, z: SafeZone): string[] {
  const tol = 0.005, e: string[] = [];
  if (b.y - b.h / 2 < z.top - tol) e.push('top');
  if (b.y + b.h / 2 > 1 - z.bottom + tol) e.push('bottom');
  if (b.x - b.w / 2 < z.left - tol) e.push('left');
  if (b.x + b.w / 2 > 1 - z.right + tol) e.push('right');
  return e;
}

export type SafeIssue = { kind: 'captions' | 'text'; itemId?: string; text?: string; fromSec: number; toSec: number; edges: string[] };

/** Captions (each page) and text items (at rest) outside the box. Captions are one issue over every page that crosses it. */
export function safeIssues(p: M.EditProject, z: SafeZone): SafeIssue[] {
  const aspect = p.canvas.width / Math.max(1, p.canvas.height), out: SafeIssue[] = [];
  const capTrack = p.tracks.find(t => t.kind === 'caption' && t.caption);
  if (capTrack?.caption && !capTrack.hidden) {
    const ct = capTrack.caption, s = ct.style;
    let from: number | undefined, to = 0;
    const es = new Set<string>();
    for (const page of M.captionPages(p)) {
      const b = textBox(M.captionText(page.words, ct.language), { x: 0.5, y: s.y ?? 0.72, sizePct: s.sizePct, maxWidthPct: s.maxWidthPct, lineHeight: s.lineHeight, uppercase: s.uppercase, maxLines: s.maxLines ?? 2, aspect });
      const e = edges(b, z);
      if (!e.length) continue;
      from ??= page.startSec;
      to = Math.max(to, page.endSec);
      e.forEach(x => es.add(x));
    }
    if (from !== undefined) out.push({ kind: 'captions', fromSec: r2(from), toSec: r2(to), edges: ['top', 'bottom', 'left', 'right'].filter(x => es.has(x)) });
  }
  for (const t of p.tracks) {
    if (t.kind !== 'text' || t.hidden) continue;
    for (const it of t.items as M.TextItem[]) {
      const sc = it.transform?.scale ?? 1;
      const b = textBox(it.text, { x: it.transform?.x ?? 0.5, y: it.transform?.y ?? 0.5, sizePct: it.style.sizePct * sc, maxWidthPct: it.style.maxWidthPct !== undefined ? it.style.maxWidthPct * sc : undefined,
        lineHeight: it.style.lineHeight, uppercase: it.style.uppercase, aspect });
      const e = edges(b, z);
      if (e.length) out.push({ kind: 'text', itemId: it.id, text: it.text.slice(0, 60), fromSec: r2(it.startSec), toSec: r2(it.startSec + it.durationSec), edges: e });
    }
  }
  return out;
}

const r2 = (n: number) => Math.round(n * 100) / 100;
const key = (i: SafeIssue) => `${i.kind}:${i.itemId ?? ''}`;

/** get_edit's `preview`: what the person sees, the box, and what sits outside it. */
export function previewView(p: M.EditProject, pv: EditPreview | null) {
  if (!pv) return { view: null, note: 'No app has reported its preview yet (the app may be older or closed).' };
  const v = resolved(p, pv.view), z = zoneFor(p, pv);
  return { view: v, label: LABEL[v], views: viewsFor(p), safeArea: pv.safeArea, ...(z ? { safeBox: z, unsafe: safeIssues(p, z) } : {}),
    covers: covers(p, pv), note: 'Approximate. Each app moves its buttons now and then.' };
}

/** apply_edit_ops: the issues this change created (captions or a text item that was inside the box before), with the line to say. */
export function newSafeIssues(before: M.EditProject, after: M.EditProject, pv: EditPreview | null) {
  if (!pv) return null;
  const z = zoneFor(after, pv);
  if (!z) return null;
  const old = new Set(safeIssues(before, z).map(key)), now = safeIssues(after, z).filter(i => !old.has(key(i)));
  if (!now.length) return null;
  const what = now.some(i => i.kind === 'captions') ? (now.length > 1 ? 'Captions and text' : 'Captions') : now.length > 1 ? `${now.length} texts` : 'A text';
  return { view: resolved(after, pv.view), issues: now, safeBox: z,
    tell: `${what} now sit under ${covers(after, pv)} in the person's ${LABEL[resolved(after, pv.view)]} view. Say so in one plain line and offer to move them inside the safe area (caption_style y, or the text's transform).` };
}

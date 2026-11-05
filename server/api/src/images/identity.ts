// The model's identity images a photo step sends (plans/api.md "Identity images"): by default 3 — face front, face ¾
// (her profile when the ¾ is empty) and ONE full-body image, the slot she chose (`identityBodySlot`, default front) —
// then the outfit's front angle when the step wears an outfit, then any product photo. The studio's `identityRefs`
// (1–7) widens or narrows the person part; the face front is always first and never dropped.
import type { ImageRef, SheetSlot } from '../db/schema.js';

export const BODY_SLOTS = ['front', 'tq', 'side', 'back'] as const;
export type BodySlot = (typeof BODY_SLOTS)[number];
export const IDENTITY_REFS_DEFAULT = 3, IDENTITY_REFS_MIN = 1, IDENTITY_REFS_MAX = 7;

/** One image sent to a model, with its role and the short label a reference sheet prints on its panel. */
export type IdentityRef = { image: ImageRef; label: string; role: 'person' | 'outfit' | 'product' };

type ModelLike = { slots: SheetSlot[]; identityBodySlot?: string | null };
type OutfitLike = { angles?: (ImageRef | null)[] | null; faces?: (ImageRef | null)[] | null } | null | undefined;

export const bodySlotOf = (m: ModelLike): BodySlot => (BODY_SLOTS as readonly string[]).includes(m.identityBodySlot ?? '') ? m.identityBodySlot as BodySlot : 'front';
export const clampIdentityRefs = (n: number | null | undefined) =>
  Math.min(IDENTITY_REFS_MAX, Math.max(IDENTITY_REFS_MIN, Math.round(n ?? IDENTITY_REFS_DEFAULT)));

/**
 * The images for one photo step, most important first. `count` is the person budget (face, face ¾, body, then her other
 * sheet images); `outfit` adds the outfit's front angle; `extra` (product photos …) goes last.
 */
export function identityRefs(m: ModelLike, o: OutfitLike, opts: { count?: number; outfit?: boolean; extra?: IdentityRef[] } = {}): IdentityRef[] {
  const slot = (k: string) => m.slots.find(s => s.key === k && s.image)?.image ?? null;
  // A Dress up outfit carries its own face close-ups (with its accessories): they go in place of hers.
  const faces = o?.faces ?? [];
  const body = bodySlotOf(m);
  const tq = faces[1] ?? slot('faceTq'), profile = faces[2] ?? slot('profile');
  const bodies = [body, ...BODY_SLOTS.filter(b => b !== body)];
  const firstBody = bodies.find(b => slot(b));
  const ranked: [ImageRef | null, string][] = [
    [faces[0] ?? slot('face'), 'face'],
    tq ? [tq, 'face ¾'] : [profile, 'face profile'],
    [firstBody ? slot(firstBody) : null, 'body'],
    // Beyond 3: her profile (when the ¾ was there), then her other body angles.
    ...(tq ? [[profile, 'face profile'] as [ImageRef | null, string]] : []),
    ...bodies.filter(b => b !== firstBody).map(b => [slot(b), 'body'] as [ImageRef | null, string]),
  ];
  const seen = new Set<ImageRef>();
  const person: IdentityRef[] = [];
  for (const [image, label] of ranked) {
    if (!image || seen.has(image)) continue;
    seen.add(image);
    person.push({ image, label, role: 'person' });
  }
  const out = person.slice(0, clampIdentityRefs(opts.count));
  if (opts.outfit) {
    const front = o?.angles?.find(Boolean);
    if (front) out.push({ image: front, label: 'outfit', role: 'outfit' });
  }
  return [...out, ...(opts.extra ?? [])];
}

// The model's identity images a photo step sends (plans/api.md "Identity images"): by default 3 — face front, face ¾
// (her profile when the ¾ is empty) and ONE full-body image, the slot she chose (`identityBodySlot`, default front) —
// then any product photo. When the step wears an outfit, the outfit's own images go instead (outfitRefs). The studio's `identityRefs`
// (1–7) widens or narrows the person part; the face front is always first and never dropped.
import type { ImageRef, SheetSlot } from '../db/schema.js';

export const BODY_SLOTS = ['front', 'tq', 'side', 'back'] as const;
export type BodySlot = (typeof BODY_SLOTS)[number];
export const IDENTITY_REFS_DEFAULT = 3, IDENTITY_REFS_MIN = 1, IDENTITY_REFS_MAX = 7;

/** One image sent to a model, with its role and the short label a reference sheet prints on its panel; `why` (optional)
 * replaces the usual reason in the images-sent list. */
export type IdentityRef = { image: ImageRef; label: string; role: 'person' | 'outfit' | 'product'; why?: string };

type ModelLike = { slots: SheetSlot[]; identityBodySlot?: string | null };
type OutfitLike = { angles?: (ImageRef | null)[] | null; faces?: (ImageRef | null)[] | null } | null | undefined;

export const bodySlotOf = (m: ModelLike): BodySlot => (BODY_SLOTS as readonly string[]).includes(m.identityBodySlot ?? '') ? m.identityBodySlot as BodySlot : 'front';
export const clampIdentityRefs = (n: number | null | undefined) =>
  Math.min(IDENTITY_REFS_MAX, Math.max(IDENTITY_REFS_MIN, Math.round(n ?? IDENTITY_REFS_DEFAULT)));

/**
 * The images for one photo step, most important first. `count` is the person budget (face, face ¾, body, then her other
 * sheet images); `extra` (product photos …) goes last. With `outfit` and an outfit that has pictures, the outfit's own
 * images replace hers entirely (outfitRefs); the person budget then doesn't apply (the model's limit still does).
 */
export function identityRefs(m: ModelLike, o: OutfitLike, opts: { count?: number; outfit?: boolean; extra?: IdentityRef[] } = {}): IdentityRef[] {
  const slot = (k: string) => m.slots.find(s => s.key === k && s.image)?.image ?? null;
  // With an outfit picked, ONLY the outfit's images go (owner 2026-11-11): its face close-ups and its body angles.
  if (opts.outfit && o?.angles?.some(Boolean)) return [...outfitRefs(o, slot('face')), ...(opts.extra ?? [])];
  const body = bodySlotOf(m);
  const tq = slot('faceTq'), profile = slot('profile');
  const bodies = [body, ...BODY_SLOTS.filter(b => b !== body)];
  const firstBody = bodies.find(b => slot(b));
  const ranked: [ImageRef | null, string][] = [
    [slot('face'), 'face'],
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
  return [...person.slice(0, clampIdentityRefs(opts.count)), ...(opts.extra ?? [])];
}

const FACE_LABELS = ['face', 'face ¾', 'face profile'] as const;
const ANGLE_LABELS = ['outfit, front', 'outfit, ¾', 'outfit, side', 'outfit, back'] as const;
/** Whether an outfit has its own face close-ups (every new outfit does; older ones until "Add face close-ups" runs). */
export const hasOutfitFaces = (o: OutfitLike) => !!o?.faces?.[0];
/**
 * The images a shot sends when she wears an outfit (owner 2026-11-11): the outfit's face close-ups (its own hair, make-up
 * and face accessories) and its four body angles; never her base face or body. An older outfit without face close-ups
 * sends her base face front only (`baseFace`), plus the outfit's body angles, and says so. Most important first: face,
 * outfit front, face ¾, face profile, then the other angles (a model with fewer inputs keeps the first ones).
 */
export function outfitRefs(o: NonNullable<OutfitLike>, baseFace: ImageRef | null): IdentityRef[] {
  const angles = o.angles ?? [], faces = o.faces ?? [];
  const own = hasOutfitFaces(o);
  const face = (i: number): IdentityRef | null => {
    const img = faces[i];
    return img ? { image: img, label: FACE_LABELS[i]!, role: 'person', why: `the outfit's ${['face, front', 'face from ¾', 'face in profile'][i]} (its hair, make-up and accessories)${i === 0 ? ' · always sent first' : ''}` } : null;
  };
  const angle = (i: number): IdentityRef | null => (angles[i] ? { image: angles[i]!, label: ANGLE_LABELS[i]!, role: 'outfit' } : null);
  const first = own ? face(0) : baseFace ? { image: baseFace, label: 'face', role: 'person' as const, why: 'her base face, front · this outfit has no face close-ups yet (Add face close-ups)' } : null;
  return [first, angle(0), own ? face(1) : null, own ? face(2) : null, angle(1), angle(2), angle(3)].filter((x): x is IdentityRef => !!x);
}

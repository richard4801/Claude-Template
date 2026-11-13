// The take viewer's platform previews (plans/swap-viewer-design.md §B2, owner-approved 2026-11-12): the parts of a
// phone screen each app's own buttons and captions cover, as fractions of the screen. Approximate: the apps publish
// these only for ads and move their buttons now and then, so the table lives here and the apps fetch it
// (GET /v1/preview/layouts) instead of hard-coding it. The numbers follow the common guidance of the safe-zone checkers
// (Pallyy, bundle.social, upload-post) on a 1080 × 1920 frame. Since the owner's decision of 2026-11-12 these show in Edit
// only (its view picker and red safe-area box), never in the take viewer. `landscape` is what the 16:9 players' title and
// controls cover (YouTube, Facebook); Clean has no zones (Edit shows the box safe on every app, or title-safe on 16:9).

export type SafeZone = { top: number; bottom: number; left: number; right: number };

export const PREVIEW_ZONES: Record<'tiktok' | 'reels' | 'shorts' | 'facebook', SafeZone> = {
  tiktok: { top: 0.11, bottom: 0.29, left: 0.03, right: 0.17 },
  reels: { top: 0.10, bottom: 0.30, left: 0.03, right: 0.16 },
  shorts: { top: 0.09, bottom: 0.30, left: 0.03, right: 0.17 },
  facebook: { top: 0.10, bottom: 0.28, left: 0.03, right: 0.16 },
};

export const PREVIEW_LANDSCAPE: Record<'youtube' | 'facebook', SafeZone> = {
  youtube: { top: 0.12, bottom: 0.16, left: 0.03, right: 0.03 },
  facebook: { top: 0.08, bottom: 0.16, left: 0.03, right: 0.03 },
};

export const PREVIEW_NOTE = 'Approximate. Each app moves its buttons now and then.';

/** The reply of GET /v1/preview/layouts. */
export const previewLayouts = () => ({ zones: PREVIEW_ZONES, landscape: PREVIEW_LANDSCAPE, note: PREVIEW_NOTE });

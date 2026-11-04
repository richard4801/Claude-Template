# Social accounts and posting (spec)

_Added 2026-11-04._ Each AI model can link its **own** accounts on TikTok, Instagram, Facebook, YouTube (Shorts) and X. Posts from her renders go to her accounts, not the user's personal ones.

## What the user can do
- **Connect** each platform from the model's profile (OAuth sign-in), and disconnect at any time.
- **Post** a finished take from Result → Post. In one sheet, the user sets:
  - the accounts to post to
  - the caption and hashtags
  - "Mark as AI-generated"
  - "Paid partnership"
  - Now or Schedule
- **Schedule** a post for a chosen time, and see Scheduled and Posted in **Posts**.
- **Stats:** views, likes and comments for each posted video, shown on the Posts page and on the take.

## Labels are the user's choice
"Mark as AI-generated" and "Paid partnership" are **off by default**, and MUSE never turns them on by itself. When the user turns one on, MUSE sets that platform's own field:

| Label | TikTok | Instagram / Facebook | YouTube | X |
|---|---|---|---|---|
| AI-generated | AI-generated content setting | AI info label | `containsSyntheticMedia` | none |
| Paid partnership | Branded content toggle | Paid partnership label | Paid promotion | none |

Where a platform has no field, the toggle shows as unavailable for that platform. The Terms keep the responsibility with the user (`plans/app-features.md` §9). The export screen no longer says it adds a label.

## Two stages
Direct posting needs each platform to approve MUSE first.

| Platform | Before approval | What approval needs |
|---|---|---|
| TikTok | API posts from unaudited apps can only be private | Content Posting API audit (reported as 2–6 weeks) |
| Instagram | Publishing only works for Business/Creator accounts linked to a Facebook Page | Meta App Review for `instagram_content_publish` / `instagram_business_content_publish`, plus Business Verification. The limit is 100 API posts per 24 h per account |
| Facebook | Page posting only | Meta App Review for `pages_manage_posts` |
| YouTube | API uploads from unverified projects are locked to private | Google OAuth verification and a YouTube API compliance audit. Uploads use about 100 videos/day of quota by default |
| X | Pay-per-use: no free tier since Feb 2026, about $0.015 per post | A paid developer account and billing |

**Stage 1 (ships first):**
- Connecting an account gives the handle, and stats where read access is allowed.
- **Post** saves the video and opens each app, or its upload page on the Mac, with the caption on the clipboard. The user taps Post there.
- **Schedule** sends a notification at the chosen time that opens that same handoff.

**Stage 2 (per platform, as each approval lands):**
- Real direct posting and auto-publishing at the scheduled time.
- The labels set through the API.
- Stats pulled on a schedule.

The UI doesn't change between stages; only the button text does ("Opening TikTok…" vs "Posted").

## Backend
- Platform tokens are stored server-side, encrypted, per model account. They're never stored on the phone or the Mac.
- A scheduler runs the queued posts and retries on failure. Failures send a push notification.
- Stats are fetched every few hours for posts from the last 30 days.

Sources: [TikTok Direct Post](https://developers.tiktok.com/docs/en/content-posting-api-reference-direct-post) · [Instagram content publishing](https://developers.facebook.com/docs/instagram-platform/content-publishing) · [YouTube videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert) · [X pay-per-use](https://opentermsarchive.org/en/memos/x-replaces-its-dollar200-entry-level-api-plan-with-a-pay-per-use-model/)

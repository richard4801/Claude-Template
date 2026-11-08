# Platform download rules for "Recreate this edit" (coordinator check, 2026-11-08)

Question: may MUSE fetch a reference video from a pasted link (server-side), or must the owner bring the file?

## Findings
| Platform | Automated fetching from a link | What the platform itself allows |
|---|---|---|
| TikTok | Prohibited. The US Terms (updated 15 Jul 2026) bar extracting content with automated software unless TikTok approves in writing. The Display and Embed APIs give metadata and an embedded player, with no file export. | In-app **Save video**, which only appears when the creator allows downloads (it adds a watermark). |
| Instagram | Prohibited. The Terms of Use and Meta's Automated Data Collection Terms bar automated collection without express written permission. The Graph API covers only accounts you own or manage. | No in-app save to file for others' Reels; saving is a bookmark only. Screen recording is the user's own act. |
| YouTube Shorts | Prohibited. The ToS bar downloading unless YouTube shows a download link, or with prior written permission. The Data API has no media download. | In-app offline download only (Premium, stays inside YouTube). Screen recording is the user's own act. |

Sources are partly secondary (vendor blogs quoting the terms). The direction is unanimous, so no further primary reading changes the decision.

## Decision proposed to the owner
- **No server-side fetching from links** for any of the three platforms.
- A pasted link opens the video **in its own app**. The owner saves it there (TikTok's Save video, which honours the creator's download setting) or screen-records it, then shares or drops the file into MUSE.
- MUSE stores the reference privately, for analysis only, and deletes it after 30 days, as already built.
- Phone share target (WS4): accept a **video file** shared into MUSE. It does not accept a link to fetch.

## Sources
- https://www.proxy-cheap.com/blog/tiktok-data-scraping
- https://scrapeops.io/websites/tiktok/
- https://developers.tiktok.com/doc/display-api-overview/
- https://scrapeops.io/websites/instagram/
- https://uwaterloo.ca/copyright-at-waterloo/catalogs/frequently-asked-questions/27-my-course-i-link-youtube-videos-some-students-are-not
- https://web-wp.archive.org/web/20210416000515/https:/www.youtube.com/t/terms

## Owner's decision (2026-11-08): "Keep link fetching"
The owner chose to keep link fetching after seeing the terms. The risk is theirs: a terms breach (a contract matter) could get the server or their accounts blocked. Guardrails:
- **Personal reference only:** the video is stored privately, used only for analysis, never posted or used as footage, and deleted after 30 days. This is unchanged.
- **Respect the creator:** where the platform exposes a downloads-off flag (for example TikTok's download setting in the video's metadata), MUSE refuses that video.
- **No sign-ins:** MUSE never uses the owner's platform logins or cookies and never bypasses private or age-gated videos. Public videos only.
- **Polite access:** one fetch per request, no crawling, cached by URL.
- **Fallback:** when a fetch is blocked or refused, MUSE says so plainly and offers "drop the saved file" instead.
- WS1 builds it server-side (one resolver for Mac and Android). The phone share target accepts both links and files.

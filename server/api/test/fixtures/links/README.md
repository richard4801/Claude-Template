# Link-fetch fixtures (workstream 1)

These are hand-written fixtures in the shape of yt-dlp's `--dump-single-json` output and TikTok's public video page, trimmed to the fields MUSE reads. They are not captured live. `test/recreate-links.test.ts` replays them through a fake `yt-dlp` that it writes into a temp folder, so CI never calls a platform.

The error lines the tests use are copied in yt-dlp's message style. For example:
- `ERROR: [Instagram] C9x: This content may be inappropriate… / login required`
- `ERROR: [TikTok] …: HTTP Error 403: Forbidden`

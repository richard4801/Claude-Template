# Higgsfield in "Bring your own provider" (2026-11-11)

Owner: "We should easily get access to all of Higgsfield's models, just like we do Muapi and the rest in our app."
Branch `claude/byo-higgsfield` (server; app patches held in `plans/patches/byo-higgsfield-{mac,android}.patch`).

## What Higgsfield's API offers (docs.higgsfield.ai, read 2026-11-11)
- **No model-list or schema API.** The docs say to discover models in the console; `/docs/openapi.json` covers 6 models.
  Every model page in `llms-full.txt` has an "Endpoint ID" and a "Complete JSON schema". MUSE's catalog is built from
  those (`server/api/assets/higgsfield/catalog.json`, `scripts/higgsfield-catalog.py`): **83 models (16 image, 67 video)**.
  It is a maintained static list: refresh it when Higgsfield adds models (one command, in the script's header).
- Auth `Authorization: Key KEY_ID:KEY_SECRET` (the server's `HF_CREDENTIALS`). Submit `POST /{endpoint}` with the flat
  input → `{request_id, status_url, cancel_url}`; poll `GET /requests/{id}/status` (queued, in_progress, completed,
  failed, nsfw, canceled; `images[].url` / `video.url`); cancel `POST /requests/{id}/cancel` (only while queued).
- **Prices:** none published per model. `POST /estimate/{endpoint}` (free) prices a request for this account
  (`{"usd":"0.094"}`), so discounts on the owner's plan show. MUSE quotes the shortest/longest duration at each
  resolution and keeps the dearest rate (as for Muapi). No balance endpoint.
- **Errors:** 401 bad key; 403 = empty balance ("Not enough credits"), or `api_key_expired` / `api_key_disabled`;
  423 model blocked; 429 queue full; 503 model disabled. Failed / nsfw / canceled-while-queued runs are refunded.

## What MUSE does now
- Higgsfield is the fourth provider kind. When the server has `HF_CREDENTIALS`, the owner connects it with **one tap,
  no key pasted** ("Use the studio's Higgsfield account"); nothing is stored, the key stays in Railway's settings. The
  owner can paste a different Higgsfield key instead (stored encrypted, like the others).
- Browse / search / add / name / price markup / switch on, exactly like Muapi. **69 of 83 run in MUSE today**: every
  text/image/reference-to-video model (Seedance 2.0/2.5, Kling 2.5/2.6/3.0/O3/Omni, H3, Hailuo, Wan 2.6/2.7/3.0, Happy
  Horse, LTX, PixVerse, Grok, Cinema Studio 4.0) and every image model (Soul, Marketing Studio, Qwen, Recraft, Ideogram,
  Grok Image, Z-Image, Ads Studio).
- **14 need a source video** (Genjutsu motion transfer / object swap / restyle, Kling motion control ×4, Kling O3/Omni
  video edit and video reference, Seedance 2.5 video edit and extend, Wan 2.6 reference). They can be browsed and added,
  but show "needs setup: video_url" until custom video models get the clip as an input (queue item 5B, "custom video
  models that take a video input in Character swap, Recast, Extend, Recreate"). Genjutsu Restyle also needs a style
  preset (`GET /models/higgsfield/genjutsu/restyle/v1.0/presets`).
- Built-in `h3-hf` (MiniMax H3 on Higgsfield in the HD ladder and Character swap) is unchanged. There is no built-in
  Genjutsu entry on prod.

## Limits
- Not verified against the live API from here: this session's proxy credential for api.higgsfield.ai answers
  "Invalid credentials". Tests use a fake Higgsfield built from the docs' shapes.
- Fields MUSE has no role for (Kling `sound` on/off, Cinema Studio's genre/lens/palette, Soul styles) take Higgsfield's
  defaults; the owner can fix a value per model (fixedInputs).
- The server's Higgsfield account can be connected by any studio's owner (like the built-in H3 already uses it).

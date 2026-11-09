Recorded provider responses for the "Bring your own provider" tests (test/byo.test.ts). Hand-recorded in the shapes the
providers document (replicate.com/docs/reference/http; fal.ai/docs/platform-apis/v1/models and /models/pricing), with
made-up model names. No live provider is called by any test.

`muapi-*.json` (test/byo-muapi.test.ts) are real responses from Muapi's PUBLIC, keyless endpoints, recorded 2026-11-09:
`GET https://api.muapi.ai/api/v1/models` (cut down to eight entries: six image/video generators, a lipsync model and an
LLM, which the adapter leaves out) and `GET /api/v1/models/<name>` for each `muapi-model-<name>.json`. The fake's price
quotes match what `POST /api/v1/models/<name>/estimate-cost` returned for those models that day. Balance, submit and
poll take a key, so they are written in the shapes Muapi documents (muapi.ai/llms.txt and /playground/<model>/llms.txt);
no key was used. To refresh: `curl https://api.muapi.ai/api/v1/models/<name> > muapi-model-<name>.json` (no key needed).

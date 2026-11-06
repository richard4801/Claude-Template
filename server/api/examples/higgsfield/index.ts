// Higgsfield API example: Seedance 2.5 text-to-video through the official SDK (server-side only).
// Run from server/api:  npx tsx --env-file=.env.local examples/higgsfield/index.ts
// Credentials come from HF_CREDENTIALS ("key-id:key-secret") at runtime and are never printed.
import { config, higgsfield } from '@higgsfield/client/v2';

const credentials = process.env.HF_CREDENTIALS;
if (!credentials || !credentials.includes(':')) {
  console.error('HF_CREDENTIALS is missing or not in key-id:key-secret format (set it in server/api/.env.local).');
  process.exit(1);
}
config({ credentials });

const MODEL = 'bytedance/seedance-2.5/text-to-video';

async function main() {
  console.log(`Submitting ${MODEL} (5 s, 720p, 16:9)…`);
  let result: any;
  try {
    result = await higgsfield.subscribe(MODEL, {
      input: { prompt: 'A cinematic scene at sunset', duration: 5, resolution: '720p', aspect_ratio: '16:9' },
      withPolling: true,
    });
  } catch (err: any) {
    // The SDK throws for failed, moderated (nsfw) and canceled requests and for HTTP errors; never claim success here.
    const status = err?.status ?? err?.response?.status ?? err?.name ?? 'error';
    console.error(`Request did not complete (${status}): ${err?.message ?? String(err)}`);
    process.exit(1);
  }

  const status = result?.status;
  if (status === 'completed' && result?.video?.url) {
    console.log(`Completed · request ${result.request_id}`);
    console.log(`Video URL: ${result.video.url}`);
    return;
  }
  if (status === 'nsfw') console.error(`Moderated: the request was refused as NSFW (request ${result?.request_id}).`);
  else if (status === 'canceled') console.error(`Canceled (request ${result?.request_id}).`);
  else if (status === 'failed') console.error(`Failed (request ${result?.request_id}): ${result?.error ?? 'no error message'}`);
  else console.error(`Unexpected result status "${status}" with no video URL.`);
  process.exit(1);
}

void main();

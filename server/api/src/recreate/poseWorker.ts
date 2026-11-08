// Recreate this edit · the pose child process (workstream 1, plans/recreate-edit.md "Pose"). Runs one job and exits,
// so the model's memory goes back as soon as it is done: MoveNet Lightning (ONNX, CPU, one thread) on each frame,
// letterboxed to 192 × 192. Receives {model, frames: [{width, height, rgb}]} over IPC; answers {poses, peakRssMb, ms}.
import * as ort from 'onnxruntime-node';

export const KEYPOINTS = ['nose', 'left_eye', 'right_eye', 'left_ear', 'right_ear', 'left_shoulder', 'right_shoulder', 'left_elbow', 'right_elbow',
  'left_wrist', 'right_wrist', 'left_hip', 'right_hip', 'left_knee', 'right_knee', 'left_ankle', 'right_ankle'] as const;
export type Keypoint = { name: (typeof KEYPOINTS)[number]; x: number; y: number; score: number };
export type PoseJob = { model: string; frames: { width: number; height: number; rgb: Uint8Array }[] };
export type PoseReply = { ok: true; poses: Keypoint[][]; peakRssMb: number; ms: number } | { ok: false; error: string; peakRssMb: number };

const SIZE = 192;

/** The frame letterboxed into SIZE × SIZE (int32 RGB, centred), and how to map back. Nearest-neighbour is enough at this size. */
export function letterbox(rgb: Uint8Array, w: number, h: number) {
  const s = SIZE / Math.max(w, h), nw = Math.round(w * s), nh = Math.round(h * s), ox = Math.floor((SIZE - nw) / 2), oy = Math.floor((SIZE - nh) / 2);
  const out = new Int32Array(SIZE * SIZE * 3);
  for (let y = 0; y < nh; y++) {
    const sy = Math.min(h - 1, Math.floor((y + 0.5) / s));
    for (let x = 0; x < nw; x++) {
      const sx = Math.min(w - 1, Math.floor((x + 0.5) / s)), i = (sy * w + sx) * 3, o = ((y + oy) * SIZE + x + ox) * 3;
      out[o] = rgb[i]!; out[o + 1] = rgb[i + 1]!; out[o + 2] = rgb[i + 2]!;
    }
  }
  return { data: out, toFrame: (nx: number, ny: number) => ({ x: (nx * SIZE - ox) / nw, y: (ny * SIZE - oy) / nh }) };
}

async function run(job: PoseJob): Promise<PoseReply> {
  const t0 = Date.now();
  // Loaded only now (the parent starts this process only for a reference with frames to read).
  const session = await ort.InferenceSession.create(job.model, { intraOpNumThreads: 1, interOpNumThreads: 1, executionMode: 'sequential', graphOptimizationLevel: 'all' });
  const poses: Keypoint[][] = [];
  for (const f of job.frames) {
    const lb = letterbox(f.rgb, f.width, f.height);
    const out = await session.run({ [session.inputNames[0]!]: new ort.Tensor('int32', lb.data, [1, SIZE, SIZE, 3]) });
    const v = out[session.outputNames[0]!]!.data as Float32Array; // [1, 1, 17, 3]: y, x, score (0–1 in the 192 square)
    poses.push(KEYPOINTS.map((name, k) => {
      const p = lb.toFrame(v[k * 3 + 1]!, v[k * 3]!);
      const r = (x: number) => Math.round(Math.max(0, Math.min(1, x)) * 1000) / 1000;
      return { name, x: r(p.x), y: r(p.y), score: Math.round(v[k * 3 + 2]! * 1000) / 1000 };
    }));
  }
  await session.release();
  return { ok: true, poses, peakRssMb: peak(), ms: Date.now() - t0 };
}

const peak = () => Math.round(process.resourceUsage().maxRSS / 1024);

// Only as the child that pose.ts forks (importing this file elsewhere, e.g. in tests, does nothing).
if (process.send && process.env.MUSE_POSE_WORKER === '1') {
  process.once('message', (job: PoseJob) => {
    run(job).then(r => process.send!(r), (e: Error) => process.send!({ ok: false, error: String(e?.message ?? e).slice(0, 300), peakRssMb: peak() } satisfies PoseReply))
      .finally(() => process.disconnect?.());
  });
}

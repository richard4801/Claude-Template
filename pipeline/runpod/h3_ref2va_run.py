# H3 Ref2VA speed benchmark / quality run on the dancing clip (first ~5.2s).
# Usage: python run_bench.py <variant: bf16|pruned_fp8|int8> <steps> <save:0|1>
# Model files follow DiffSynth examples MiniMax-H3-Ref2VA.py, -FP8-Pruned-Ref2VA.py, -Int8-ConvRot-Ref2VA.py.
import sys, time, json, glob, os, subprocess, torch
torch.backends.cuda.enable_cudnn_sdp(False)  # cu130 cuDNN SDPA has no engine for H3 masked attention
from PIL import Image
from diffsynth.pipelines.minimax_h3_audio_video import MiniMaxH3Pipeline, ModelConfig
from diffsynth.utils.data.audio_video import write_video_audio, read_video_audio
from diffsynth.utils.data.audio import read_audio

VARIANT, STEPS, SAVE = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
W, H, FPS, FRAMES = 768, 1344, 24, 124          # 5.17s, n % 17 == 5
IN, OUT, M = "inputs", "outputs", "/workspace/models"
vram = dict(offload_dtype=torch.bfloat16, offload_device="cpu", onload_dtype=torch.bfloat16, onload_device="cpu",
            preparing_dtype=torch.bfloat16, preparing_device="cuda", computation_dtype=torch.bfloat16, computation_device="cuda")
dit = {"bf16": sorted(glob.glob(f"{M}/h3/Ref2VA/transformer/model*.safetensors")),
       "pruned_fp8": f"{M}/comfy/diffusion_models/minimax_h3_ref2va_pruned_fp8_scaled.safetensors",
       "int8": f"{M}/comfy/diffusion_models/minimax_h3_ref2va_int8_convrot.safetensors"}[VARIANT]
t0 = time.time()
pipe = MiniMaxH3Pipeline.from_pretrained(
    torch_dtype=torch.bfloat16, device="cuda",
    model_configs=[
        ModelConfig(path=dit, **vram),
        ModelConfig(path=f"{M}/nf4/minimax-h3-text-encoder-nf4.safetensors", **vram),
        ModelConfig(path=f"{M}/h3/Ref2VA/video_vae/source/model.safetensors", **vram),
        ModelConfig(path=f"{M}/h3/Ref2VA/audio_vae/model.safetensors", **vram),
    ],
    processor_config=ModelConfig(path=f"{M}/h3/Ref2VA/processor/"),
    vram_limit=torch.cuda.mem_get_info("cuda")[1] / (1024 ** 3) - float(os.environ.get("VRAM_HEADROOM_GB", "20")),
)
load_s = time.time() - t0

ref_video, ref_audio, ref_sr = read_video_audio(f"{IN}/source.mp4", height=H, width=W, num_frames=FRAMES, fps=FPS,
                                                audio_sample_rate=pipe.audio_vae.sample_rate)
if ref_audio is None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f"{IN}/source.mp4", "-vn", "-ac", "2", f"{IN}/source.wav"], check=True)
    ref_audio, ref_sr = read_audio(f"{IN}/source.wav", duration=len(ref_video) / FPS, resample=True, resample_rate=pipe.audio_vae.sample_rate)
img = lambda f: {"type": "image", "image": Image.open(f"{IN}/{f}").convert("RGB")}
refs = [{"type": "video_audio", "video": ref_video, "audio": ref_audio, "sample_rate": ref_sr},
        img("face_front.jpg"), img("face_side.jpg"), img("body_front.jpg"), img("body_threequarter.jpg"), img("body_back.jpg")]

prompt = """subject_definitions:
<Subject 1> is the young woman in <Video 1> with long red hair and arm tattoos, wearing a pink crop top, grey shorts and white socks, dancing in a living room.
<Subject 2> is the young woman with long wavy honey-blonde hair, green eyes, light freckles and smooth tanned skin with NO tattoos, shown in <Image 1> (face, front), <Image 2> (face, profile), <Image 3> (full body, front), <Image 4> (full body, three-quarter) and <Image 5> (full body, back).
<Video 1> is the source video for the editing task.
<Audio 1> is the synchronized audio track of <Video 1>.

summary:
[video editing + character replacement + audio reuse] The target video is an edited version of <Video 1> in which <Subject 1> is replaced by <Subject 2>. Every movement, dance step, leg kick, pose, gesture, hand position, head turn, facial expression and mouth movement of <Subject 1> is kept exactly, frame by frame, at exactly the same moments. The camera, framing, living room with the large wall-mounted TV and white cabinets, lighting and timing of <Video 1> are unchanged. <Audio 1> is fully reused.

retention_analysis:
<Video 1> (source video editing): fully_preserved - the living room background, the TV, furniture, camera position, lighting and the full body motion and timing are maintained exactly.
<Subject 1>: replaced - identity, face, hair, skin, tattoos, body and clothing are all replaced by <Subject 2>; only motion and expressions are kept. None of <Subject 1>'s tattoos remain.
<Subject 2>: reference - identity, face, hair, clean tattoo-free skin, body shape and outfit follow <Image 1>-<Image 5>: a dark green short-sleeve cropped t-shirt, dark green drawstring dolphin shorts, white crew socks and cream clogs. She wears no necklace, no choker and no rings.
<Audio 1>: fully_copy - the original audio is kept unchanged.

detailed_description:
The target video is in realistic photographic style, like a casual smartphone TikTok video filmed from a low angle. [Shot 1] <Subject 2> dances in the living room from <Video 1>, performing exactly the same dance as <Subject 1> with the same timing, including the leg kicks, hip movements, arm waves and touching her hair. She wears the dark green cropped t-shirt, dark green shorts, white socks and cream clogs from <Image 3>. Her arms and legs are smooth, clean tanned skin with no tattoos. Her face is sharp and detailed and matches <Image 1>, with natural skin texture, natural expressions, stable eyes, natural lips and teeth, and realistic hands with five fingers.
"""
step_times = []
class TimedTqdm:
    def __init__(self, it, *a, **k): self.it = it
    def __iter__(self):
        t = time.time()
        for x in self.it:
            yield x
            torch.cuda.synchronize(); step_times.append(round(time.time() - t, 1)); t = time.time()
            print("STEP", len(step_times), step_times[-1], flush=True)
    def __len__(self): return len(self.it)
torch.cuda.reset_peak_memory_stats(); t1 = time.time()
video, audio = pipe(prompt=prompt, height=H, width=W, num_frames=FRAMES, num_inference_steps=STEPS, seed=42,
                    references=refs, progress_bar_cmd=TimedTqdm)
gen_s = time.time() - t1
name = f"h3_{VARIANT}_{STEPS}steps"
os.makedirs(OUT, exist_ok=True)
if SAVE:
    write_video_audio(video=video, audio=audio, output_path=f"{OUT}/{name}.mp4", fps=FPS, audio_sample_rate=32000)
from diffsynth.core.attention.attention import ATTENTION_IMPLEMENTATION
stats = dict(variant=VARIANT, attention=ATTENTION_IMPLEMENTATION, gpu=torch.cuda.get_device_name(0), size=f"{W}x{H}", frames=FRAMES, steps=STEPS,
             load_s=round(load_s), gen_s=round(gen_s), step_times_s=step_times, peak_vram_gb=round(torch.cuda.max_memory_allocated() / 1e9, 1))
json.dump(stats, open(f"{OUT}/{name}_stats.json", "w"), indent=2); print("STATS", json.dumps(stats), flush=True)

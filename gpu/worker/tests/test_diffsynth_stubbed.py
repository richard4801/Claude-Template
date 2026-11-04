"""Drive the real DiffSynth backend code with stub torch/diffsynth/PIL modules.

This checks our side of the integration (FA3 gate, VRAM limit, reference layout, frame trim,
audio handling, step callback) against the DiffSynth API as read at commit 1e8ae1d. It cannot
tell whether the real pipeline renders well; only a GPU run can.
"""

import sys
import types
from pathlib import Path

import pytest

from muse_worker import media
from muse_worker.backends.diffsynth_h3 import DiffSynthH3Backend
from muse_worker.jobs.base import JobCancelled
from muse_worker.jobs.h3 import BackendUnavailable, RenderRequest

pytestmark = pytest.mark.skipif(not media.have_ffmpeg(), reason="needs ffmpeg")


class Tensor:
    def __init__(self, n):
        self.shape = (2, n)

    def __getitem__(self, key):
        return Tensor(len(range(*key[1].indices(self.shape[1]))))


@pytest.fixture
def stubs(monkeypatch):
    calls = {}
    GB = 1024 ** 3

    torch = types.ModuleType("torch")
    torch.bfloat16 = "bf16"
    torch.zeros = lambda c, n: Tensor(n)
    torch.cuda = types.SimpleNamespace(
        is_available=lambda: True, mem_get_info=lambda dev: (70 * GB, 80 * GB), get_device_name=lambda i: "STUB H100",
        reset_peak_memory_stats=lambda: None, max_memory_allocated=lambda: 61e9,
        synchronize=lambda: calls.setdefault("syncs", []).append(1))
    torch.backends = types.SimpleNamespace(cuda=types.SimpleNamespace(
        enable_cudnn_sdp=lambda v: calls.__setitem__("cudnn_sdp", v)))

    kernels = types.ModuleType("kernels")
    kernels.get_kernel = lambda repo, version: calls.__setitem__("kernel", (repo, version))

    attn = types.ModuleType("diffsynth.core.attention.attention")
    attn.ATTENTION_IMPLEMENTATION = "customized_fa_kernel"

    class ModelConfig:
        def __init__(self, path=None, **kw):
            self.path, self.kw = path, kw

    class Pipe:
        audio_vae = types.SimpleNamespace(sample_rate=48000)

        @classmethod
        def from_pretrained(cls, **kw):
            calls["from_pretrained"] = kw
            return cls()

        def __call__(self, **kw):
            calls["pipe_call"] = kw
            for _ in kw["progress_bar_cmd"](list(range(kw["num_inference_steps"]))):
                pass
            return ["frame"] * kw["num_frames"], Tensor(32000)

    pipes = types.ModuleType("diffsynth.pipelines.minimax_h3_audio_video")
    pipes.MiniMaxH3Pipeline, pipes.ModelConfig = Pipe, ModelConfig

    av = types.ModuleType("diffsynth.utils.data.audio_video")

    def read_video_audio(path, height, width, num_frames, fps, audio_sample_rate):
        calls["read"] = dict(height=height, width=width, num_frames=num_frames, fps=fps, sr=audio_sample_rate)
        got = min(num_frames, calls.get("source_frames", num_frames))
        return ["f"] * got, (None if calls.get("no_audio") else Tensor(int(got / fps * audio_sample_rate) + 999)), \
            audio_sample_rate

    def write_video_audio(video, audio, output_path, fps, audio_sample_rate):
        calls["write"] = dict(frames=len(video), fps=fps, sr=audio_sample_rate)
        media.make_test_video(Path(output_path), 96, 168, fps, len(video), with_audio=True)

    av.read_video_audio, av.write_video_audio = read_video_audio, write_video_audio
    audio = types.ModuleType("diffsynth.utils.data.audio")
    audio.read_audio = lambda path, duration, resample, resample_rate: (Tensor(int(duration * resample_rate)),
                                                                       resample_rate)
    pil = types.ModuleType("PIL")
    pil.Image = types.SimpleNamespace(open=lambda p: types.SimpleNamespace(convert=lambda m: f"img:{Path(p).name}"))

    for name, mod in {"torch": torch, "kernels": kernels, "PIL": pil, "diffsynth": types.ModuleType("diffsynth"),
                      "diffsynth.core": types.ModuleType("x"), "diffsynth.core.attention": types.ModuleType("x"),
                      "diffsynth.core.attention.attention": attn, "diffsynth.pipelines": types.ModuleType("x"),
                      "diffsynth.pipelines.minimax_h3_audio_video": pipes, "diffsynth.utils": types.ModuleType("x"),
                      "diffsynth.utils.data": types.ModuleType("x"), "diffsynth.utils.data.audio_video": av,
                      "diffsynth.utils.data.audio": audio}.items():
        monkeypatch.setitem(sys.modules, name, mod)
    for k in ("DIFFSYNTH_FLASH_ATTN_KERNEL_REPO_ID", "DIFFSYNTH_FLASH_ATTN_KERNEL_VERSION"):
        monkeypatch.delenv(k, raising=False)
    calls["attn"] = attn
    return calls


def models(tmp_path):
    m = tmp_path / "models"
    for rel in ["h3/Ref2VA/transformer/model-1.safetensors", "h3/Ref2VA/transformer/model-2.safetensors",
                "nf4/minimax-h3-text-encoder-nf4.safetensors", "h3/Ref2VA/video_vae/source/model.safetensors",
                "h3/Ref2VA/audio_vae/model.safetensors", "h3/Ref2VA/processor/x.json"]:
        (m / rel).parent.mkdir(parents=True, exist_ok=True)
        (m / rel).write_bytes(b"x")
    return m


def request(tmp_path, keep_audio=True, frames=124):
    src = tmp_path / "source.mp4"
    media.make_test_video(src, 96, 168, 30, 300, with_audio=True)
    refs = []
    for n in ("face_front.jpg", "body_front.jpg"):
        (tmp_path / n).write_bytes(b"x")
        refs.append(tmp_path / n)
    return RenderRequest(source=src, references=refs, prompt="P", steps=10, seed=42, num_frames=frames,
                         keep_audio=keep_audio, audio_source="source", out_path=tmp_path / "take1.mp4",
                         work_dir=tmp_path)


def test_load_once_and_render(stubs, tmp_path):
    b = DiffSynthH3Backend(models_dir=models(tmp_path))
    b.ensure_loaded()
    b.ensure_loaded()
    fp = stubs["from_pretrained"]
    assert stubs["kernel"] == ("kernels-community/flash-attn3", 1)
    assert stubs["cudnn_sdp"] is False
    assert fp["vram_limit"] == pytest.approx(80 - 30)  # VRAM_HEADROOM_GB default 30
    assert len(fp["model_configs"]) == 4 and len(fp["model_configs"][0].path) == 2  # both transformer shards
    assert b.attention == "customized_fa_kernel"

    steps = []
    res = b.render(request(tmp_path), lambda i, t: steps.append((i, t)), lambda: None)
    call = stubs["pipe_call"]
    assert (call["width"], call["height"], call["num_frames"], call["num_inference_steps"], call["seed"]) == \
        (768, 1344, 124, 10, 42)
    refs = call["references"]
    assert refs[0]["type"] == "video_audio" and len(refs[0]["video"]) == 124 and refs[0]["sample_rate"] == 48000
    assert refs[0]["audio"].shape[1] == round(124 / 24 * 48000)  # audio clipped to the trimmed frames
    assert [r["image"] for r in refs[1:]] == ["img:face_front.jpg", "img:body_front.jpg"]
    assert steps == [(i, 10) for i in range(1, 11)] and len(stubs["syncs"]) == 10
    assert stubs["write"] == {"frames": 124, "fps": 24, "sr": 32000}
    info = media.probe(res.path)
    assert info.has_audio and abs(info.duration_sec - 124 / 24) < 0.1
    assert res.stats["attention"] == "customized_fa_kernel" and res.stats["peak_vram_gb"] == 61.0


def test_short_read_is_retrimmed_and_silent_source_uses_ffmpeg_fallback(stubs, tmp_path):
    stubs["source_frames"], stubs["no_audio"] = 120, True  # decoder returned fewer frames, no audio
    b = DiffSynthH3Backend(models_dir=models(tmp_path))
    res = b.render(request(tmp_path, keep_audio=False), lambda i, t: None, lambda: None)
    assert stubs["pipe_call"]["num_frames"] == 107  # 120 -> 107 (n % 17 == 5)
    assert stubs["pipe_call"]["references"][0]["audio"].shape[1] == int(107 / 24 * 48000)
    assert not media.probe(res.path).has_audio  # keepAudio off: silent output


def test_fa3_missing_refuses_loudly(stubs, tmp_path, caplog):
    stubs["attn"].ATTENTION_IMPLEMENTATION = "torch"
    b = DiffSynthH3Backend(models_dir=models(tmp_path))
    with pytest.raises(BackendUnavailable, match="FlashAttention 3 not active"):
        b.ensure_loaded()
    assert "FLASHATTENTION 3 IS NOT ACTIVE" in caplog.text
    with pytest.raises(BackendUnavailable, match="failed to load earlier"):
        b.ensure_loaded()  # cached: every job fails fast with the reason


def test_fa3_missing_allowed_when_not_required(stubs, tmp_path, caplog):
    stubs["attn"].ATTENTION_IMPLEMENTATION = "torch"
    b = DiffSynthH3Backend(models_dir=models(tmp_path), require_fa3=False)
    b.ensure_loaded()
    assert "SLOWLY" in caplog.text and b.pipe is not None


def test_cancel_between_steps(stubs, tmp_path):
    b = DiffSynthH3Backend(models_dir=models(tmp_path))
    n = {"steps": 0}

    def on_step(i, t):
        n["steps"] = i

    def check():
        if n["steps"] >= 3:
            raise JobCancelled("shutdown")

    with pytest.raises(JobCancelled):
        b.render(request(tmp_path), on_step, check)
    assert n["steps"] == 3

"""Pure H3 logic: the n % 17 == 5 frame rule, params, prompt sections, step wrapper, ETA."""

import pytest

from muse_worker.jobs.base import Job, JobCancelled, JobFailure
from muse_worker.jobs.h3 import (FIRST_FRAMES, Eta, H3Params, build_prompt, frames_for, make_progress_cmd,
                                 trim_frames)


def job(params=None, **kw):
    d = {"id": "j1", "kind": "h3", "params": params or {}, "inputs": [], "outputs": [], "prompt": "p", "seed": 7}
    d.update(kw)
    return Job.from_dict(d)


@pytest.mark.parametrize("n,expected", [(22, 22), (38, 22), (39, 39), (124, 124), (140, 124), (141, 141),
                                        (225, 209), (360, 345)])
def test_trim_frames(n, expected):
    assert trim_frames(n) == expected
    assert expected % 17 == 5 and expected <= n


def test_trim_frames_too_short():
    with pytest.raises(JobFailure) as e:
        trim_frames(21)
    assert not e.value.retryable


def test_frames_for_first_and_full():
    assert FIRST_FRAMES == 124 and frames_for("first", 1000) == 124
    assert frames_for("first", 100) == 90  # shorter source than 5.2 s
    assert frames_for("full", int(9.4 * 24)) == 209  # Test 5's 9.4 s clip
    assert frames_for("full", 10_000) == 345  # capped at 15 s
    assert frames_for("full", 10_000, clip_seconds=6.0) == 141
    for n in range(22, 400):
        assert frames_for("full", n) % 17 == 5


def test_params_defaults():
    p = H3Params.from_job(job())
    assert (p.steps, p.use, p.takes, p.seeds, p.keep_audio, p.audio_source) == (10, "first", 1, [7], True, "source")


def test_params_takes_and_seeds():
    p = H3Params.from_job(job({"takes": 3, "steps": 4, "use": "full", "keepAudio": False}))
    assert p.seeds == [7, 8, 9] and p.steps == 4 and p.use == "full" and p.keep_audio is False
    p = H3Params.from_job(job({"takes": 2, "seeds": [5, 99]}))
    assert p.seeds == [5, 99]


@pytest.mark.parametrize("params", [{"steps": 3}, {"steps": 31}, {"steps": "10"}, {"takes": 5}, {"use": "middle"},
                                    {"seeds": [1]  , "takes": 2}, {"clipSeconds": -1}, {"audioSource": "x"}])
def test_params_invalid(params):
    with pytest.raises(JobFailure) as e:
        H3Params.from_job(job(params))
    assert e.value.retryable is False


def test_params_steps_from_job_top_level():
    assert H3Params.from_job(job(steps=20)).steps == 20


def test_prompt_sections():
    sections = {"detailed_description": "D", "summary": "S", "subject_definitions": "A\nB",
                "retention_analysis": "", "extra": "E"}
    text = build_prompt(sections)
    assert text == "subject_definitions:\nA\nB\n\nsummary:\nS\n\ndetailed_description:\nD\n\nextra:\nE\n"
    p = H3Params.from_job(job({"promptSections": sections}, prompt=None))
    assert p.prompt == text
    with pytest.raises(JobFailure):
        H3Params.from_job(job({}, prompt=None))


def test_progress_cmd_reports_each_step_and_cancels():
    seen, cancel = [], {"now": False}

    def check():
        if cancel["now"]:
            raise JobCancelled("test")

    cmd = make_progress_cmd(lambda i, t: seen.append((i, t)), check)
    assert len(cmd(range(5))) == 5
    assert list(cmd(range(3))) == [0, 1, 2]
    assert seen == [(1, 3), (2, 3), (3, 3)]
    seen.clear()
    with pytest.raises(JobCancelled):
        for i in cmd(range(10)):
            if i == 2:
                cancel["now"] = True
    assert seen == [(1, 10), (2, 10), (3, 10)]


def test_eta_uses_measured_steps():
    t = [0.0]
    eta = Eta(steps=10, takes=2, frames=124, sec_per_step_124=60, overhead_per_take=40, clock=lambda: t[0])
    assert eta.remaining(0, 0) == pytest.approx(20 * 60 + 1.5 * 40)
    for _ in range(10):
        t[0] += 30
        eta.step_done()
    t[0] += 20
    eta.take_done(10)
    assert eta.overhead == pytest.approx(20)
    assert eta.remaining(1, 0) == pytest.approx(10 * 30 + 0.5 * 20)


def test_job_from_dict_sanitizes_names():
    j = Job.from_dict({"id": "x", "kind": "h3", "inputs": [{"name": "../../etc/passwd", "url": "u"}],
                       "outputs": [{"name": "a/b.mp4", "uploadUrl": "u", "contentType": "video/mp4"}]})
    assert j.inputs[0].name == "passwd" and j.outputs[0].name == "b.mp4"
    assert j.outputs[0].headers == {"Content-Type": "video/mp4"}
    with pytest.raises(JobFailure):
        Job.from_dict({"id": "x", "inputs": [{"name": ".."}]})

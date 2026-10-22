"""
Reference outputs ("golden files") from the Python backend, in Tests/golden/.

They record exactly what the backend produces today, so a rewrite (like moving it to Swift) can be checked
against them, and so any change to the output shows up in a test. GoldenOutputTests in test_backend.py fails
when the backend's output no longer matches. After an intended change, regenerate them and review the diff:

    .venv/bin/python3 Tests/python/golden.py --update

- text_functions.json: inputs and outputs of the text-processing functions (sentences, echo removal, repeat
  detection, subtitle wrapping and timing, transcript headers, keyword and language parsing).
- runs/*: whole runs on a generated recording against a fake OpenAI (see FakeOpenAI below), with the
  transcript or subtitle file each one writes. These also record where the chunks are cut.
"""

from __future__ import annotations

import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = ROOT / "Tests" / "golden"
TEXT_FUNCTIONS_FILE = GOLDEN_DIR / "text_functions.json"
RUNS_DIR = GOLDEN_DIR / "runs"

if __name__ == "__main__":
    _vendor = ROOT / "vendor" / "ffmpeg" / platform.machine()
    os.environ.setdefault("FFMPEG_BIN", str(_vendor / "ffmpeg"))
    os.environ.setdefault("FFPROBE_BIN", str(_vendor / "ffprobe"))
    os.environ.setdefault("TRANSCRIBE_WORKDIR", tempfile.mkdtemp(prefix="lecture-transcribe-golden-"))
    sys.path.insert(0, str(ROOT))

import lecture_transcribe as lt  # noqa: E402
import transcription_job as tj  # noqa: E402

# ---------------------------------------------------------------------------------------------------------------
# Text functions

LECTURE = (
    "Good morning, everyone. Today we're going to talk about nucleophilic substitution. Dr. Patel asked me to "
    "start with the SN2 reaction, which happens in one step. The nucleophile attacks from the back side... "
    "And the leaving group departs at the same time.Why does that matter?It matters because the "
    "stereochemistry inverts. Let's compare that with the SN1 reaction, which goes through a carbocation. "
    "The U.S.A. is not a sentence break here, and neither is e.g. this. Okay! Questions?"
)
LOOPED = (
    "So the rate depends only on the substrate, because the slow step is the loss of the leaving group and the "
    "nucleophile isn't involved yet. That's why we call it first order. "
    + "Remember that the carbocation is flat, so the nucleophile can attack from either face and we get a "
    "mixture of both configurations, which chemists call racemization in the ideal case. " * 3
    + "Next week we'll look at elimination."
)

SUBTITLE_SEGMENTS = {
    "one_speaker": [
        {"speaker": "A", "start": 0.0, "end": 4.2, "text": "Good morning, everyone. Today we're talking about substitution."},
        {"speaker": "A", "start": 4.6, "end": 13.9, "text": "The SN2 reaction happens in a single concerted step, where the nucleophile attacks from the back side while the leaving group departs, and the stereochemistry inverts like an umbrella in the wind."},
        {"speaker": "A", "start": 14.0, "end": 14.4, "text": "Okay."},
        {"speaker": "A", "start": 14.5, "end": 16.0, "text": "Any questions so far?"},
    ],
    "quick_exchange": [
        {"speaker": "A", "start": 0.0, "end": 0.6, "text": "Where were you?"},
        {"speaker": "B", "start": 0.7, "end": 1.0, "text": "Out."},
        {"speaker": "A", "start": 1.2, "end": 3.0, "text": "Out where? The lab closes at six."},
        {"speaker": "B", "start": 3.1, "end": 3.3, "text": "Library."},
        {"speaker": "A", "start": 6.0, "end": 9.5, "text": "Fine, but next time leave a note on the board."},
    ],
    "gaps_and_untimed": [
        {"speaker": "A", "start": 0.0, "end": 2.0, "text": "First line."},
        {"speaker": "A", "start": None, "end": None, "text": "This one has no timing and is skipped."},
        {"speaker": "A", "start": 2.05, "end": 2.3, "text": "Hm."},
        {"speaker": "B", "start": 30.0, "end": 31.0, "text": "Much later."},
        {"speaker": "B", "start": 31.0, "end": 31.0, "text": "   "},
    ],
}


def _error(function, *args):
    try:
        return function(*args)
    except ValueError as exc:
        return {"error": str(exc)}


def text_function_cases() -> list[dict]:
    """Each case: the function, its inputs, and what it returns (tuples as lists, so it round-trips as JSON)."""
    cases: list[dict] = []

    def add(function: str, inputs: dict, output) -> None:
        cases.append({"function": function, "input": inputs, "output": json.loads(json.dumps(output))})

    for text in [LECTURE, "", "   ", "no punctuation at all", "Mr. Smith met Mrs. Jones at St. Mary's. They talked.",
                 "Wait... What? Really!", "He said 3.5 percent. Then 4 percent."]:
        add("sentence_lines", {"text": text}, lt.sentence_lines(text))

    for text, max_chars in [(LECTURE, 300), (LECTURE, 80), ("One sentence. " + "x" * 400, 300), ("", 300)]:
        add("transcript_tail", {"text": text, "max_chars": max_chars}, lt.transcript_tail(text, max_chars))

    tail = "and the stereochemistry inverts like an umbrella."
    for text in [
        "And the stereochemistry inverts like an umbrella. Next, the SN1 reaction.",
        "inverts like an umbrella. Next, the SN1 reaction.",
        "umbrella. Next, the SN1 reaction.",
        "Next, the SN1 reaction.",
    ]:
        add("strip_echoed_tail", {"text": text, "tail": tail}, lt.strip_echoed_tail(text, tail))

    for text in [LOOPED, LECTURE, "Almost there. Almost there. Almost there."]:
        add("find_repeated_passage", {"text": text}, lt.find_repeated_passage(text))

    for context, previous in [(None, None), ("Organic chemistry, week 3", None), (None, "the leaving group departs."),
                              ("  Organic chemistry  ", "the leaving group departs.")]:
        add("build_chunk_prompt", {"context": context, "previous_tail": previous}, lt.build_chunk_prompt(context, previous))

    for text in ["Short line.", "The nucleophile attacks from the back side while the leaving group departs.",
                 "Supercalifragilisticexpialidocious-and-another-very-long-hyphenated-compound word",
                 "Well, if you think about it, the answer is yes."]:
        add("wrap_subtitle_text", {"text": text}, lt.wrap_subtitle_text(text))
    for text in [SUBTITLE_SEGMENTS["one_speaker"][1]["text"], LECTURE]:
        add("subtitle_pieces", {"text": text}, lt.subtitle_pieces(text))

    for seconds in [0, 0.0004, 59.9996, 61.5, 3599.999, 3725.25]:
        add("srt_timestamp", {"seconds": seconds}, lt.srt_timestamp(seconds))
        add("hhmmss", {"seconds": seconds}, lt.hhmmss(seconds))

    for name, segments in SUBTITLE_SEGMENTS.items():
        for offset, chunk in [(0.0, 0), (599.586, 1)]:
            srt = lt.format_srt(lt.subtitle_cues(segments, offset, chunk))
            add("format_srt(subtitle_cues)", {"segments": name, "offset_seconds": offset, "chunk": chunk}, srt)
        add("format_diarized_lines", {"segments": name, "offset_seconds": 0.0}, lt.format_diarized_lines(segments))

    for raw in ["SN2, Grignard reagent\nsn2\n\n  carbocation  ", "", "bad <tag>"]:
        add("parse_keywords", {"raw": raw}, _error(lt.parse_keywords, raw))
    for raw in ["en, ES,en", "", "english", "zz"]:
        add("parse_language_codes", {"raw": raw}, _error(lt.parse_language_codes, raw))

    for options in [
        {"model": "gpt-transcribe", "local_chunk_seconds": 300, "languages": ["en"], "context": "Organic\nchemistry",
         "keywords": ["SN2"], "consistency_mode": True, "chunk_warnings": ["part_002.m4a: looks repeated"]},
        {"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json", "chunking_strategy": "auto",
         "duration_seconds": 1234.5678},
        {"model": "gpt-4o-transcribe", "context": ""},
    ]:
        header = lt.build_transcript_header(input_path=Path("/lectures/week3.mp4"), working_input_path=Path("/lectures/week3.mp4"), **options)
        add("build_transcript_header", options, header)
    return cases


# ---------------------------------------------------------------------------------------------------------------
# Whole runs


class FakeOpenAI:
    """Answers each chunk with fixed text, so a run's output depends only on the backend's own logic."""

    def __init__(self) -> None:
        self.audio = SimpleNamespace(transcriptions=SimpleNamespace(create=self.create))

    def create(self, **kwargs):
        name = Path(kwargs["file"].name).name
        n = int(name.split("_")[1].split(".")[0])
        usage = {"output_tokens": 50}
        if kwargs["response_format"] == "diarized_json":
            segments = [
                {"speaker": "A", "start": 0.4, "end": 3.9, "text": f"Part {n + 1}. Where were you?"},
                {"speaker": "B", "start": 4.0, "end": 4.3, "text": "Out."},
                {"speaker": "A", "start": 5.0, "end": 14.0, "text": "Then let's go over the mechanism again, because the nucleophile attacks from the back side and the stereochemistry inverts."},
            ]
            return SimpleNamespace(text=" ".join(s["text"] for s in segments), segments=segments, usage=usage)
        prompt = kwargs.get("prompt") or ""
        echo = "The recording begins right after this transcript excerpt" in prompt
        text = f"Part {n + 1} of the lecture. The nucleophile attacks from the back side.Why?Because of sterics. Dr. Patel agrees."
        if echo:
            # Models sometimes repeat the excerpt they were given; the backend removes it.
            text = "of sterics. Dr. Patel agrees. " + text
        if n == 1:
            text += " " + LOOPED
        return SimpleNamespace(text=text, usage=usage)


RUNS = {
    "transcript_gpt4o": {"model": lt.MODEL_NORMAL, "chunk_seconds": 60},
    "transcript_consistency_mode": {
        "model": lt.MODEL_GPT_TRANSCRIBE, "chunk_seconds": 60, "carry_context": True,
        "context": "Organic chemistry, week 3", "keywords": ["SN2", "Grignard"], "languages": ["en"],
    },
    "speaker_labels": {"model": lt.MODEL_NORMAL, "diarize": True},
    "subtitles": {"model": lt.MODEL_NORMAL, "subtitles": True},
}


def make_recording(path: Path) -> None:
    """150s of tone with a clear pause at 52s and 110s, so the cuts land in known places."""
    tone = "sine=frequency=300:duration={}"
    parts = [tone.format(52), "anullsrc=r=44100:cl=mono:d=0.6", tone.format(57.4), "anullsrc=r=44100:cl=mono:d=0.6", tone.format(39.4)]
    args = []
    for p in parts:
        args += ["-f", "lavfi", "-i", p]
    chains = "".join(f"[{i}:a]aformat=sample_rates=44100:channel_layouts=mono[a{i}];" for i in range(len(parts)))
    concat = "".join(f"[a{i}]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1"
    subprocess.run([*lt.ffmpeg_cmd_prefix(), "-hide_banner", "-loglevel", "error", "-y", *args,
                    "-filter_complex", chains + concat, "-c:a", "aac", str(path)], check=True)


def run_outputs(workdir: Path) -> dict[str, str]:
    """Each run's output file, with the temporary folder replaced by <RECORDING> so it doesn't change."""
    recording = workdir / "lecture.m4a"
    make_recording(recording)
    outputs: dict[str, str] = {}
    for name, options in RUNS.items():
        out_dir = workdir / name
        out_dir.mkdir()
        options = dict(options)
        model = options.pop("model")
        diarize = options.pop("diarize", False)
        with mock.patch.object(tj, "OpenAI", return_value=FakeOpenAI()), \
             mock.patch.dict(os.environ, {"TRANSCRIBE_MAX_PARALLEL": "1"}), \
             mock.patch.object(tj, "DIARIZE_SINGLE_BUFFER", 60), \
             mock.patch.object(tj, "DIARIZE_CHUNK_SECONDS", 60):
            out = tj.run_transcription_job(recording, diarize, out_dir, model, lambda *_: None, **options)
        suffix = out.suffix
        outputs[name + suffix] = out.read_text(encoding="utf-8").replace(str(recording), "<RECORDING>")
    return outputs


def update() -> None:
    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
    TEXT_FUNCTIONS_FILE.write_text(json.dumps(text_function_cases(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    for old in RUNS_DIR.iterdir():
        old.unlink()
    with tempfile.TemporaryDirectory() as workdir:
        for name, text in run_outputs(Path(workdir)).items():
            (RUNS_DIR / name).write_text(text, encoding="utf-8")
    print(f"Wrote {TEXT_FUNCTIONS_FILE.relative_to(ROOT)} and {len(list(RUNS_DIR.iterdir()))} files in {RUNS_DIR.relative_to(ROOT)}.")


if __name__ == "__main__":
    if sys.argv[1:] != ["--update"]:
        sys.exit(__doc__)
    update()

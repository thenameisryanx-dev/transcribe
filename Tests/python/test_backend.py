"""
Tests for the Python backend. Run with the repo's .venv (scripts/ensure_dev_python.sh makes it):

    .venv/bin/python3 -m unittest discover -s Tests/python

They make small test videos with the ffmpeg in vendor/ffmpeg and never call OpenAI.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
_VENDOR = ROOT / "vendor" / "ffmpeg" / platform.machine()
os.environ.setdefault("FFMPEG_BIN", str(_VENDOR / "ffmpeg"))
os.environ.setdefault("FFPROBE_BIN", str(_VENDOR / "ffprobe"))
# Chunks and converted inputs go here instead of the repo; the backend reads this when it's imported.
_WORKDIR = tempfile.mkdtemp(prefix="lecture-transcribe-tests-")
os.environ["TRANSCRIBE_WORKDIR"] = _WORKDIR
sys.path.insert(0, str(ROOT))

import lecture_transcribe as lt  # noqa: E402
import transcribe_backend  # noqa: E402
import transcription_job as tj  # noqa: E402
from transcription_job import run_transcription_job  # noqa: E402


def tearDownModule() -> None:
    shutil.rmtree(_WORKDIR, ignore_errors=True)


def ffmpeg(*args: str) -> None:
    subprocess.run([*lt.ffmpeg_cmd_prefix(), "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


class TempDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="lecture-transcribe-test-"))
        self.addCleanup(shutil.rmtree, self.dir, True)


class BackendArgumentsTests(unittest.TestCase):
    def parse(self, *argv: str):
        with mock.patch.object(sys, "argv", ["transcribe_backend.py", *argv]):
            return transcribe_backend.parse_args()

    def test_run_accepts_each_model(self) -> None:
        for model in transcribe_backend.SUPPORTED_TRANSCRIPTION_MODELS:
            args = self.parse("run", "--input", "in.m4a", "--output", "out", "--model", model)
            self.assertEqual(args.model, model)

    def test_run_rejects_unknown_model(self) -> None:
        with mock.patch.object(sys, "stderr"), self.assertRaises(SystemExit):
            self.parse("run", "--input", "in.m4a", "--output", "out", "--model", "whisper-1")


class TranscriptionJobTests(TempDirTestCase):
    def test_speaker_labels_with_mini_model_fail_before_any_upload(self) -> None:
        audio = self.dir / "lecture.m4a"
        ffmpeg("-f", "lavfi", "-i", "sine=duration=1", "-c:a", "aac", str(audio))
        # No key, so even if the check breaks, the job can't reach OpenAI.
        environment = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
        with mock.patch.dict(os.environ, environment, clear=True), self.assertRaises(SystemExit) as raised:
            run_transcription_job(audio, True, self.dir, lt.MODEL_MINI, lambda kind, payload: None)
        self.assertIn("not supported with gpt-4o-mini-transcribe", str(raised.exception))


class ChunkCutTests(TempDirTestCase):
    """Chunks are cut in a pause before the nominal cut, so no sentence is sliced in half."""

    def test_cut_moves_back_into_the_pause(self) -> None:
        # Steady "speech" with one 0.6s pause at 52s. With 60s chunks the cut is searched for in 45-60s.
        audio = self.dir / "lecture.m4a"
        ffmpeg(
            "-f", "lavfi", "-i", "sine=frequency=300:duration=52",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=0.6",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=37.4",
            "-filter_complex", "[0:a]aformat=sample_rates=44100:channel_layouts=mono[a];"
            "[1:a]aformat=sample_rates=44100:channel_layouts=mono[b];"
            "[2:a]aformat=sample_rates=44100:channel_layouts=mono[c];[a][b][c]concat=n=3:v=0:a=1",
            "-c:a", "aac", str(audio),
        )
        cuts = lt.plan_chunk_cuts(audio, 60)
        self.assertEqual(len(cuts), 1)
        self.assertGreaterEqual(cuts[0], 52.0)
        self.assertLessEqual(cuts[0], 52.6)

        # The chunk files really end there (to within one AAC frame), not at 60s.
        parts = lt.split_audio_to_chunks(audio, self.dir / "chunks", 60)
        self.assertEqual(len(parts), 2)
        first = lt.get_duration_seconds(parts[0])
        self.assertGreaterEqual(first, 52.0)
        self.assertLessEqual(first, 52.6)

    def test_audio_without_a_pause_still_gets_full_length_chunks(self) -> None:
        audio = self.dir / "tone.m4a"
        ffmpeg("-f", "lavfi", "-i", "sine=frequency=300:duration=90", "-c:a", "aac", str(audio))
        cuts = lt.plan_chunk_cuts(audio, 60)
        self.assertEqual(len(cuts), 1)
        # With no pause to find, the cut stays in the search window (the last quarter of the chunk) and never
        # makes a chunk longer than asked for.
        self.assertGreaterEqual(cuts[0], 45.0)
        self.assertLessEqual(cuts[0], 60.0)


class FakeOpenAI:
    """Answers transcription requests with text naming the chunk and attempt; fails the chunks in `fail`."""

    def __init__(self, attempt: str, fail: tuple[str, ...] = (), slow: tuple[str, ...] = ()) -> None:
        self.attempt = attempt
        self.fail = fail
        self.slow = slow
        self.sent: list[str] = []
        self.audio = SimpleNamespace(transcriptions=SimpleNamespace(create=self.create))

    def create(self, **kwargs):
        name = Path(kwargs["file"].name).name
        self.sent.append(name)
        if name in self.slow:
            time.sleep(1)
        if name in self.fail:
            raise RuntimeError(f"OpenAI broke on {name}")
        return SimpleNamespace(text=f"Words from {name} on the {self.attempt} attempt.", usage={"output_tokens": 12})


class ResumeRunTests(TempDirTestCase):
    """A failed run saves its finished chunks, and running it again only sends the rest."""

    def setUp(self) -> None:
        super().setUp()
        shutil.rmtree(lt.RESULTS_ROOT_DIR, ignore_errors=True)
        self.addCleanup(shutil.rmtree, lt.RESULTS_ROOT_DIR, True)
        # One chunk at a time, so which chunks finish before the failure is always the same.
        patcher = mock.patch.dict(os.environ, {"TRANSCRIBE_MAX_PARALLEL": "1"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.audio = self.dir / "lecture.m4a"
        # Noise under a tone, so every stretch is equally loud and each 60s chunk is cut at 60s.
        ffmpeg(
            "-f", "lavfi", "-i", "sine=frequency=300:duration=150",
            "-f", "lavfi", "-i", "anoisesrc=d=150:a=0.05",
            "-filter_complex", "amix=inputs=2", "-c:a", "aac", str(self.audio),
        )

    def run_job(self, client: FakeOpenAI, events: list, **options) -> Path:
        push = lambda kind, payload: events.append((kind, payload))  # noqa: E731
        with mock.patch.object(tj, "OpenAI", return_value=client):
            return run_transcription_job(self.audio, False, self.dir, lt.MODEL_NORMAL, push, chunk_seconds=60, **options)

    def logs(self, events: list) -> list[str]:
        return [payload for kind, payload in events if kind == "log"]

    def saved_results(self) -> list[Path]:
        return list(lt.RESULTS_ROOT_DIR.glob("*.json")) if lt.RESULTS_ROOT_DIR.exists() else []

    def test_rerun_after_a_failure_sends_only_unfinished_chunks(self) -> None:
        first, first_events = FakeOpenAI("first", fail=("part_001.m4a",)), []
        with self.assertRaises(RuntimeError):
            self.run_job(first, first_events)
        self.assertEqual(first.sent, ["part_000.m4a", "part_001.m4a"])
        self.assertIn("1 of 3 chunk(s) finished and were saved.", " ".join(self.logs(first_events)))
        self.assertEqual(len(self.saved_results()), 1)
        self.assertEqual(list(self.dir.glob("*.txt")), [])

        second, second_events = FakeOpenAI("second"), []
        out = self.run_job(second, second_events)
        self.assertEqual(second.sent, ["part_001.m4a", "part_002.m4a"])
        self.assertIn("Reused 1 of 3 chunk(s) saved from an earlier attempt.", self.logs(second_events))
        transcript = out.read_text(encoding="utf-8")
        self.assertIn("Words from part_000.m4a on the first attempt.", transcript)
        self.assertIn("Words from part_001.m4a on the second attempt.", transcript)
        self.assertIn("Words from part_002.m4a on the second attempt.", transcript)
        # A finished run doesn't need its chunks again.
        self.assertEqual(self.saved_results(), [])

    def test_chunks_already_sent_when_another_fails_are_saved(self) -> None:
        # All three chunks go out at once; chunk 2 fails while the others are still being transcribed.
        with mock.patch.dict(os.environ, {"TRANSCRIBE_MAX_PARALLEL": "4"}), self.assertRaises(RuntimeError):
            self.run_job(FakeOpenAI("first", fail=("part_001.m4a",), slow=("part_000.m4a", "part_002.m4a")), [])
        second = FakeOpenAI("second")
        self.run_job(second, [])
        self.assertEqual(second.sent, ["part_001.m4a"])

    def test_consistency_mode_resumes_in_order(self) -> None:
        first = FakeOpenAI("first", fail=("part_002.m4a",))
        with mock.patch.object(tj, "OpenAI", return_value=first), self.assertRaises(RuntimeError):
            run_transcription_job(
                self.audio, False, self.dir, lt.MODEL_GPT_TRANSCRIBE, lambda *_: None,
                chunk_seconds=60, carry_context=True,
            )
        second = FakeOpenAI("second")
        with mock.patch.object(tj, "OpenAI", return_value=second):
            run_transcription_job(
                self.audio, False, self.dir, lt.MODEL_GPT_TRANSCRIBE, lambda *_: None,
                chunk_seconds=60, carry_context=True,
            )
        self.assertEqual(second.sent, ["part_002.m4a"])

    def test_different_settings_send_every_chunk_again(self) -> None:
        with self.assertRaises(RuntimeError):
            self.run_job(FakeOpenAI("first", fail=("part_002.m4a",)), [])
        second = FakeOpenAI("second")
        self.run_job(second, [], context="Organic chemistry")
        self.assertEqual(second.sent, ["part_000.m4a", "part_001.m4a", "part_002.m4a"])

    def test_chunks_that_failed_their_checks_are_not_saved(self) -> None:
        self.assertIsNone(tj._encode_transcript(("the the the", "part_000.m4a repeated a passage")))
        self.assertEqual(tj._encode_transcript(("Hello.", None)), {"text": "Hello."})

    def test_saved_diarize_results_read_back_the_same(self) -> None:
        response = SimpleNamespace(
            text="Hi. Hello.",
            segments=[
                SimpleNamespace(speaker="A", start=0.0, end=1.5, text="Hi."),
                SimpleNamespace(speaker="B", start=1.5, end=3.0, text="Hello."),
            ],
        )
        saved = tj._decode_diarized(json.loads(json.dumps(tj._encode_diarized(response))))
        self.assertEqual(
            lt.format_diarized_lines(lt.extract_diarization_segments(saved), 60),
            lt.format_diarized_lines(lt.extract_diarization_segments(response), 60),
        )
        self.assertEqual(
            lt.subtitle_cues(lt.extract_diarization_segments(saved), 60),
            lt.subtitle_cues(lt.extract_diarization_segments(response), 60),
        )

    def test_old_results_are_removed(self) -> None:
        lt.RESULTS_ROOT_DIR.mkdir(parents=True, exist_ok=True)
        old, recent = lt.RESULTS_ROOT_DIR / "old.json", lt.RESULTS_ROOT_DIR / "recent.json"
        old.write_text("{}")
        recent.write_text("{}")
        week_and_a_day_ago = time.time() - lt.RESULTS_MAX_AGE_SECONDS - 24 * 60 * 60
        os.utime(old, (week_and_a_day_ago, week_and_a_day_ago))
        tj.prune_chunk_results()
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())


class MediaToolArchitectureTests(TempDirTestCase):
    def macho(self, cpu_type: int) -> Path:
        path = self.dir / f"tool-{cpu_type:x}"
        path.write_bytes(b"\xcf\xfa\xed\xfe" + cpu_type.to_bytes(4, "little") + bytes(24))
        return path

    def test_apple_silicon_needs_an_arm64_tool(self) -> None:
        with mock.patch.object(lt.platform, "machine", return_value="arm64"):
            self.assertTrue(lt._supports_host_arch(self.macho(0x0100000C)))
            self.assertFalse(lt._supports_host_arch(self.macho(0x01000007)))

    def test_intel_needs_an_x86_64_tool(self) -> None:
        with mock.patch.object(lt.platform, "machine", return_value="x86_64"):
            self.assertTrue(lt._supports_host_arch(self.macho(0x01000007)))
            self.assertFalse(lt._supports_host_arch(self.macho(0x0100000C)))

    def test_bundled_tools_run_on_this_mac(self) -> None:
        self.assertTrue(lt._supports_host_arch(Path(os.environ["FFMPEG_BIN"])))
        self.assertTrue(lt._supports_host_arch(Path(os.environ["FFPROBE_BIN"])))


class TrackEditingTests(TempDirTestCase):
    """The Tracks pane's save, in each format it supports: video, English + Spanish audio, one subtitle."""

    FORMATS = (".mp4", ".mov", ".mkv")

    def setUp(self) -> None:
        super().setUp()
        self.srt = self.dir / "french.srt"
        self.srt.write_text("1\n00:00:00,000 --> 00:00:01,000\nBonjour\n", encoding="utf-8")
        source = self.dir / "source.mp4"
        ffmpeg(
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1",
            "-f", "lavfi", "-i", "sine=duration=1",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
            "-i", str(self.srt),
            "-map", "0", "-map", "1", "-map", "2", "-map", "3",
            "-c:v", "libx264", "-c:a", "aac", "-c:s", "mov_text",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=spa",
            "-metadata:s:s:0", "language=eng",
            str(source),
        )
        ffmpeg("-i", str(source), "-map", "0", "-c", "copy", str(self.dir / "source.mov"))
        ffmpeg("-i", str(source), "-map", "0", "-c", "copy", "-c:s", "srt", str(self.dir / "source.mkv"))
        self.videos = {".mp4": source, ".mov": self.dir / "source.mov", ".mkv": self.dir / "source.mkv"}

    def save(self, video: Path, name: str, plan: list[dict]) -> list[dict]:
        out = self.dir / f"{name}{video.suffix}"
        lt.save_edited_tracks(video, out, plan)
        return [t for t in lt.list_media_tracks(out) if t["kind"] in ("audio", "subtitle")]

    @staticmethod
    def track(kind: str, source: int | str, language: str, title: str = "", default: bool = False) -> dict:
        entry = {"kind": kind, "language": language, "title": title, "default": default, "forced": False}
        entry["file" if isinstance(source, str) else "index"] = source
        return entry

    def test_titles_order_and_added_subtitles_are_saved(self) -> None:
        for suffix in self.FORMATS:
            with self.subTest(suffix):
                saved = self.save(self.videos[suffix], "edited", [
                    self.track("audio", 2, "spa", "Spanish", default=True),
                    self.track("subtitle", 3, "eng", "English subs", default=True),
                    self.track("subtitle", str(self.srt), "fra", "French"),
                ])
                self.assertEqual([t["kind"] for t in saved], ["audio", "subtitle", "subtitle"])
                self.assertEqual([t["title"] for t in saved], ["Spanish", "English subs", "French"])
                self.assertEqual(saved[0]["language"], "spa")
                self.assertEqual([t["default"] for t in saved], [True, True, False])

    def test_no_default_subtitle_stays_off(self) -> None:
        # ffmpeg turns the first .mp4/.mov subtitle on when none is the default; the save turns it off again.
        for suffix in self.FORMATS:
            with self.subTest(suffix):
                saved = self.save(self.videos[suffix], "subs-off", [
                    self.track("audio", 1, "eng", default=True),
                    self.track("subtitle", str(self.srt), "fra"),
                    self.track("subtitle", 3, "eng"),
                ])
                self.assertEqual([t["default"] for t in saved], [True, False, False])

    def test_cleared_title_stays_cleared(self) -> None:
        for suffix in self.FORMATS:
            with self.subTest(suffix):
                named = self.dir / f"named{suffix}"
                lt.save_edited_tracks(self.videos[suffix], named, [self.track("audio", 1, "eng", "Lecture", True)])
                saved = self.save(named, "renamed", [self.track("audio", 1, "eng", "", True)])
                self.assertEqual(saved[0]["title"], "")

    def test_generic_handler_names_are_not_titles(self) -> None:
        video = self.dir / "phone.mov"
        ffmpeg(
            "-i", str(self.videos[".mp4"]), "-map", "0", "-c", "copy",
            "-metadata:s:a:0", "handler_name=Core Media Audio",
            "-metadata:s:a:1", "handler_name=Commentary",
            str(video),
        )
        audio = [t for t in lt.list_media_tracks(video) if t["kind"] == "audio"]
        self.assertEqual([t["title"] for t in audio], ["", "Commentary"])


if __name__ == "__main__":
    unittest.main()

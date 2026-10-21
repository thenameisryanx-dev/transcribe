"""
Tests for the Python backend. Run with the repo's .venv (scripts/ensure_dev_python.sh makes it):

    .venv/bin/python3 -m unittest discover -s Tests/python

They make small test videos with the ffmpeg in vendor/ffmpeg and never call OpenAI.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
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

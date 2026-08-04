import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "verify_ffmpeg_tools", Path(__file__).with_name("verify_ffmpeg_tools.py")
)
ffmpeg = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(ffmpeg)


class VerifyFFmpegToolsTests(unittest.TestCase):
    def test_verifies_hash_architecture_version_and_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "Tools"
            tools.mkdir()
            binaries = {}
            for name in ("ffmpeg", "ffprobe"):
                path = tools / name
                path.write_bytes(name.encode("ascii"))
                path.chmod(0o755)
                binaries[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({
                "architecture": "arm64",
                "display_version": "8.1.2-quicksrt",
                "required_ffmpeg_filters": ["aresample"],
                "binaries": binaries,
            }), encoding="utf-8")

            def fake_run(*arguments):
                if arguments[0] == "/usr/bin/lipo":
                    return "arm64"
                if arguments[0] == "/usr/bin/codesign":
                    return ""
                name = Path(arguments[0]).name
                if len(arguments) > 1 and arguments[1] == "-filters":
                    return "Filters:\n .. aresample A->A Resample audio.\n"
                return f"{name} version 8.1.2-quicksrt\n"

            with mock.patch.object(ffmpeg, "run", side_effect=fake_run) as runner:
                ffmpeg.verify(tools, manifest)

            self.assertTrue(any(call.args[0] == "/usr/bin/codesign" for call in runner.call_args_list))

    def test_rejects_ffmpeg_without_required_audio_resampler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "Tools"
            tools.mkdir()
            binaries = {}
            for name in ("ffmpeg", "ffprobe"):
                path = tools / name
                path.write_bytes(name.encode("ascii"))
                path.chmod(0o755)
                binaries[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({
                "architecture": "arm64",
                "display_version": "8.1.2-quicksrt",
                "required_ffmpeg_filters": ["aresample"],
                "binaries": binaries,
            }), encoding="utf-8")

            def fake_run(*arguments):
                if arguments[0] == "/usr/bin/lipo":
                    return "arm64"
                if arguments[0] == "/usr/bin/codesign":
                    return ""
                if len(arguments) > 1 and arguments[1] == "-filters":
                    return "Filters:\n .. anull A->A Pass audio unchanged.\n"
                name = Path(arguments[0]).name
                return f"{name} version 8.1.2-quicksrt\n"

            with mock.patch.object(ffmpeg, "run", side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError, "missing required filters: aresample"):
                    ffmpeg.verify(tools, manifest)

    def test_rejects_wrong_hash_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "Tools"
            tools.mkdir()
            for name in ("ffmpeg", "ffprobe"):
                path = tools / name
                path.write_bytes(name.encode("ascii"))
                path.chmod(0o755)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({
                "architecture": "arm64",
                "display_version": "8.1.2-quicksrt",
                "binaries": {
                    "ffmpeg": {"sha256": "0" * 64},
                    "ffprobe": {"sha256": "0" * 64},
                },
            }), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                ffmpeg.verify(tools, manifest)


if __name__ == "__main__":
    unittest.main()

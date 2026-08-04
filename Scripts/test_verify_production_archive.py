import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "verify_production_archive", Path(__file__).with_name("verify_production_archive.py")
)
archive_verifier = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(archive_verifier)


class ProductionArchiveVerifierTests(unittest.TestCase):
    SYNTHETIC_VERSION = "7.3"

    def fixture(self, directory: str) -> tuple[Path, Path]:
        archive = Path(directory) / "QuickSRT.xcarchive"
        app = archive / "Products/Applications/QuickSRT.app"
        executable = app / "Contents/MacOS/QuickSRT"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"app")
        info = {
            "CFBundleIdentifier": "local.quicksrt.app",
            "CFBundleExecutable": "QuickSRT",
            "CFBundleShortVersionString": self.SYNTHETIC_VERSION,
            "CFBundleVersion": "42",
            "LSMinimumSystemVersion": "15.0",
        }
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        archive_info = {
            "ApplicationProperties": {
                "ApplicationPath": "Applications/QuickSRT.app",
                "Architectures": ["arm64"],
                "CFBundleIdentifier": "local.quicksrt.app",
                "CFBundleShortVersionString": self.SYNTHETIC_VERSION,
                "CFBundleVersion": "42",
            }
        }
        with (archive / "Info.plist").open("wb") as handle:
            plistlib.dump(archive_info, handle)
        dsym = archive / "dSYMs/QuickSRT.app.dSYM/Contents/Resources/DWARF/QuickSRT"
        dsym.parent.mkdir(parents=True)
        dsym.write_bytes(b"\xcf\xfa\xed\xfe" + b"dsym")
        return archive, app

    def test_clean_archive_structure_and_metadata_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, app = self.fixture(directory)
            self.assertEqual(archive_verifier.structural_failures(archive, app), [])
            self.assertEqual(archive_verifier.metadata_failures(archive, app), [])

    def test_xctest_and_profiling_artifacts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, app = self.fixture(directory)
            xctest = app / "Contents/PlugIns/QuickSRTTests.xctest"
            xctest.mkdir(parents=True)
            (app / "Contents/default.profraw").write_bytes(b"profile")

            failures = archive_verifier.structural_failures(archive, app)

            self.assertTrue(any("test/profiling/debug artifact" in failure for failure in failures))
            self.assertTrue(any("QuickSRTTests" in failure for failure in failures))

    def test_dsym_inside_application_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, app = self.fixture(directory)
            (app / "Contents/Resources/QuickSRT.app.dSYM").mkdir(parents=True)

            failures = archive_verifier.structural_failures(archive, app)

            self.assertTrue(any("dSYM must remain outside" in failure for failure in failures))

    def test_private_paths_are_detected_in_every_file_name(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, app = self.fixture(directory)
            private = app / "Contents/Resources/metadata.bin"
            private.parent.mkdir(parents=True, exist_ok=True)
            private.write_bytes(b"prefix /" + b"Users/builder/project suffix")
            scanner = app / "Contents/Resources/support_integrity.py"
            scanner.write_bytes(b"marker /" + b"Users/")

            failures = archive_verifier.privacy_failures(app)

            self.assertEqual(len(failures), 2)
            self.assertTrue(any("metadata.bin" in failure for failure in failures))
            self.assertTrue(any("support_integrity.py" in failure for failure in failures))

    def test_macho_magic_detection_is_header_based(self):
        with tempfile.TemporaryDirectory() as directory:
            macho = Path(directory) / "binary"
            macho.write_bytes(b"\xcf\xfa\xed\xfe" + b"payload")
            text = Path(directory) / "text"
            text.write_text("Mach-O words are not a binary", encoding="utf-8")

            self.assertTrue(archive_verifier.is_macho(macho))
            self.assertFalse(archive_verifier.is_macho(text))

    def test_static_native_archive_is_detected_without_matching_plain_files(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "library.a"
            archive.write_bytes(b"!<arch>\n" + b"payload")
            text = Path(directory) / "notes.a"
            text.write_text("not an archive", encoding="utf-8")

            self.assertTrue(archive_verifier.is_static_archive(archive))
            self.assertTrue(archive_verifier.is_native_code(archive))
            self.assertFalse(archive_verifier.is_static_archive(text))

    def test_deployment_target_parser_supports_modern_and_legacy_commands(self):
        modern = "cmd LC_BUILD_VERSION\n platform 1\n minos 15.0\n sdk 26.0"
        legacy = "cmd LC_VERSION_MIN_MACOSX\n version 12.0\n sdk 12.3"

        self.assertEqual(archive_verifier.deployment_target(modern), "15.0")
        self.assertEqual(archive_verifier.deployment_target(legacy), "12.0")
        self.assertIsNone(archive_verifier.deployment_target("cmd LC_UUID"))
        self.assertLess(
            archive_verifier.version_tuple("14.0"),
            archive_verifier.version_tuple(archive_verifier.EXPECTED_DEPLOYMENT_TARGET),
        )


if __name__ == "__main__":
    unittest.main()

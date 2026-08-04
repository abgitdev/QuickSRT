import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "source_archive_policy", Path(__file__).with_name("source_archive_policy.py")
)
policy = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(policy)


class SourceArchivePolicyTests(unittest.TestCase):
    def archive(self, directory: str, entries: dict[str, bytes]) -> Path:
        path = Path(directory) / "source.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, contents in entries.items():
                archive.writestr(name, contents)
        return path

    def test_normal_source_archive_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, {"QuickSRT/README.md": b"public source"})
            policy.verify(str(archive))

    def test_credential_filenames_fail_even_with_innocent_content(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, {"QuickSRT/.npmrc": b"registry config"})
            with self.assertRaisesRegex(ValueError, "credential filename"):
                policy.verify(str(archive))

    def test_private_keys_and_access_tokens_fail_in_ordinary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(
                directory,
                {
                    "QuickSRT/notes.txt": b"-----BEGIN " + b"PRIVATE KEY-----",
                    "QuickSRT/config.txt": b"key=" + b"AK" + b"IA" + b"1234567890ABCDEF",
                },
            )
            with self.assertRaisesRegex(ValueError, "private key material"):
                policy.verify(str(archive))


if __name__ == "__main__":
    unittest.main()

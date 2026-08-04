import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


integrity = load_module("support_integrity", "support_integrity.py")


class SupportIntegrityTests(unittest.TestCase):
    def test_manifest_detects_tampering_and_extra_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Scripts").mkdir()
            target = root / "Scripts/runner.py"
            target.write_text("print('ok')\n", encoding="utf-8")
            manifest = root / "support-manifest.json"

            integrity.create_manifest(root, manifest)
            integrity.verify_manifest(root, manifest)
            target.write_text("print('changed')\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "runner.py"):
                integrity.verify_manifest(root, manifest)

            target.write_text("print('ok')\n", encoding="utf-8")
            (root / "unexpected.txt").write_text("extra", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected.txt"):
                integrity.verify_manifest(root, manifest)

    def test_manifest_rejects_absolute_and_escaping_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.symlink("/tmp/outside", root / "absolute")
            with self.assertRaisesRegex(ValueError, "absolute symlink"):
                integrity.inventory(root)

    def test_privacy_scan_finds_user_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = b"/" + b"Users/example/model"
            (root / "metadata.json").write_bytes(b'{"cache":"' + marker + b'"}')
            with self.assertRaisesRegex(ValueError, "/" + "Users/"):
                integrity.privacy_scan([root])

    def test_scanner_named_files_are_not_exempt_from_privacy_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = b"/" + b"Users/example/private"
            (root / "support_integrity.py").write_bytes(marker)
            with self.assertRaisesRegex(ValueError, "support_integrity.py"):
                integrity.privacy_scan([root])

    def test_scripts_tree_passes_its_own_privacy_scan(self):
        integrity.privacy_scan([Path(__file__).parent])


if __name__ == "__main__":
    unittest.main()

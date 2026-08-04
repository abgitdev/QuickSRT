import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from write_runtime_lock import render_lock


class RuntimeLockWriterTests(unittest.TestCase):
    def test_render_lock_uses_exact_wheel_metadata_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            specs = root / "requirements.exact"
            specs.write_text("Example_Package==1.2.3\n", encoding="utf-8")
            wheelhouse = root / "wheels"
            wheelhouse.mkdir()
            wheel = wheelhouse / "example_package-1.2.3-py3-none-any.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr(
                    "example_package-1.2.3.dist-info/METADATA",
                    "Metadata-Version: 2.1\nName: Example-Package\nVersion: 1.2.3\n",
                )
                archive.writestr(
                    "example_package/_vendor/nested-9.9.dist-info/METADATA",
                    "Metadata-Version: 2.1\nName: Nested\nVersion: 9.9\n",
                )

            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            rendered = render_lock(specs, wheelhouse)

            self.assertIn("example-package==1.2.3 \\", rendered)
            self.assertIn("--hash=sha256:{}".format(digest), rendered)

    def test_render_lock_rejects_missing_wheel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            specs = root / "requirements.exact"
            specs.write_text("missing==1.0\n", encoding="utf-8")
            wheelhouse = root / "wheels"
            wheelhouse.mkdir()

            with self.assertRaisesRegex(ValueError, "missing wheel"):
                render_lock(specs, wheelhouse)


if __name__ == "__main__":
    unittest.main()

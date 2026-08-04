import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "check_python_license_inventory",
    Path(__file__).with_name("check_python_license_inventory.py"),
)
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)


class PythonLicenseInventoryTests(unittest.TestCase):
    def test_current_inventory_and_sbom_match_the_lock(self):
        self.assertEqual(checker.validate(), [])

    def test_sbom_license_mismatch_fails_validation(self):
        document = json.loads(checker.SBOM.read_text(encoding="utf-8"))
        tampered = copy.deepcopy(document)
        component = next(item for item in tampered["components"] if item["name"] == "numba")
        component["licenses"] = [{"expression": "BSD-3-Clause"}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sbom.json"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            self.assertTrue(any("numba" in error for error in checker.validate(sbom=path)))

    def test_sbom_unlocked_wheel_hash_fails_validation(self):
        document = json.loads(checker.SBOM.read_text(encoding="utf-8"))
        tampered = copy.deepcopy(document)
        tampered["components"][0]["hashes"][0]["content"] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sbom.json"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            errors = checker.validate(sbom=path)
            self.assertTrue(any("hash" in error for error in errors))


if __name__ == "__main__":
    unittest.main()

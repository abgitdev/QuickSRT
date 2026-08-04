import hashlib
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from model_integrity import load_policy, validate_model, write_manifest


def npy_bytes(descriptor="<f4"):
    metadata = repr({"descr": descriptor, "fortran_order": False, "shape": (1,)})
    prefix = b"\x93NUMPY\x01\x00"
    padding = (64 - ((len(prefix) + 2 + len(metadata) + 1) % 64)) % 64
    header = (metadata + " " * padding + "\n").encode("latin1")
    payload = b"\0" * int(descriptor[-1])
    return prefix + struct.pack("<H", len(header)) + header + payload


class ModelIntegrityTests(unittest.TestCase):
    def make_fixture(self, root, descriptor="<f4"):
        model = root / "model"
        model.mkdir()
        config = {"model_type": "whisper", "n_vocab": 10}
        config_path = model / "config.json"
        config_path.write_text(json.dumps(config, separators=(",", ":")), encoding="utf-8")
        weights = model / "weights.npz"
        with zipfile.ZipFile(weights, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("tensor.npy", npy_bytes(descriptor))
        with zipfile.ZipFile(weights) as archive:
            entry = archive.infolist()[0]
        policy = {
            "schema_version": 1,
            "policy_id": "test-policy",
            "repository_id": "example/model",
            "revision": "a" * 40,
            "files": {
                "config.json": {
                    "sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
                    "size": config_path.stat().st_size,
                    "format": "json",
                },
                "weights.npz": {
                    "sha256": hashlib.sha256(weights.read_bytes()).hexdigest(),
                    "size": weights.stat().st_size,
                    "format": "npz",
                    "entries": 1,
                    "uncompressed_size": entry.file_size,
                    "maximum_entry_size": entry.file_size,
                },
            },
            "config": config,
        }
        policy_path = root / "policy.json"
        policy_path.write_text(json.dumps(policy, sort_keys=True), encoding="utf-8")
        return model, load_policy(policy_path)

    def test_verified_manifest_is_required_and_detects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            model, policy = self.make_fixture(Path(directory))
            validate_model(model, policy, require_manifest=False)
            write_manifest(model, policy)
            validate_model(model, policy, require_manifest=True)

            (model / "config.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                validate_model(model, policy, require_manifest=True)

    def test_object_dtype_is_rejected_without_loading_weights(self):
        with tempfile.TemporaryDirectory() as directory:
            model, policy = self.make_fixture(Path(directory), descriptor="|O8")
            with self.assertRaisesRegex(ValueError, "non-numeric"):
                validate_model(model, policy, require_manifest=False)

    def test_extra_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            model, policy = self.make_fixture(Path(directory))
            (model / "unexpected.txt").write_text("no", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected or missing"):
                validate_model(model, policy, require_manifest=False)


if __name__ == "__main__":
    unittest.main()

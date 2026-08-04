import importlib.util
import unittest
from email.parser import BytesParser
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "generate_runtime_sbom", Path(__file__).with_name("generate_runtime_sbom.py")
)
sbom = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(sbom)


class RuntimeSBOMGeneratorTests(unittest.TestCase):
    def metadata(self, name: str, version: str):
        return BytesParser().parsebytes(
            f"Name: {name}\nVersion: {version}\n"
            "Classifier: License :: OSI Approved :: BSD License\n\n".encode()
        )

    def test_verified_numba_wheel_uses_two_clause_license(self):
        metadata = self.metadata("numba", "0.66.0")
        self.assertEqual(
            sbom.license_expression(metadata, "numba", "0.66.0"),
            "BSD-2-Clause",
        )

    def test_generic_bsd_classifier_is_not_globally_reclassified(self):
        metadata = self.metadata("example-package", "1.0")
        self.assertEqual(
            sbom.license_expression(metadata, "example-package", "1.0"),
            "BSD-3-Clause",
        )


if __name__ == "__main__":
    unittest.main()

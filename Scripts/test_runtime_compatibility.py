import unittest

from runtime_compatibility import pip_target, validate, version_at_least, version_less_than


POLICY = {
    "schema_version": 1,
    "platform": {"system": "Darwin", "machine": "arm64", "minimum_macos": "15.0"},
    "python": {
        "bootstrap_minimum": "3.9.0",
        "minimum": "3.13.0",
        "maximum_exclusive": "3.14.0",
    },
    "components": {"mlx": "0.32.0", "mlx-metal": "0.32.0", "mlx-whisper": "0.4.3"},
}


class RuntimeCompatibilityTests(unittest.TestCase):
    def test_supported_matrix_passes(self):
        errors = validate(
            POLICY,
            system="Darwin",
            machine="arm64",
            macos_version="15.0",
            python_version="3.13.14",
            component_versions={"mlx": "0.32.0", "mlx-metal": "0.32.0", "mlx-whisper": "0.4.3"},
        )

        self.assertEqual(errors, [])

    def test_architecture_python_and_mlx_mismatches_are_reported(self):
        errors = validate(
            POLICY,
            system="Darwin",
            machine="x86_64",
            macos_version="13.6",
            python_version="3.14.1",
            component_versions={"mlx": "0.31.0"},
        )

        self.assertTrue(any("native arm64" in error for error in errors))
        self.assertTrue(any("macOS 15.0" in error for error in errors))
        self.assertTrue(any("CPython" in error for error in errors))
        self.assertTrue(any("mlx==0.32.0" in error for error in errors))
        self.assertTrue(any("mlx-metal==0.32.0" in error for error in errors))
        self.assertTrue(any("mlx-whisper==0.4.3" in error for error in errors))

    def test_version_boundaries(self):
        self.assertTrue(version_at_least("15.0", "15.0"))
        self.assertTrue(version_at_least("26.5.2", "15.0"))
        self.assertTrue(version_less_than("3.13.99", "3.14.0"))
        self.assertFalse(version_less_than("3.14.0", "3.14.0"))

    def test_pip_target_matches_policy(self):
        self.assertEqual(pip_target(POLICY), "macosx_15_0_arm64 313 cp313")


if __name__ == "__main__":
    unittest.main()

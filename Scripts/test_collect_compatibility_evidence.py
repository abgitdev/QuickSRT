import unittest

from collect_compatibility_evidence import (
    classify_signature,
    collect_host_evidence,
    version_at_least,
    version_parts,
)


class CompatibilityEvidenceTests(unittest.TestCase):
    def test_version_parsing_and_comparison(self):
        self.assertEqual(version_parts("26.5.2"), (26, 5, 2))
        self.assertEqual(version_parts("invalid"), ())
        self.assertTrue(version_at_least("26.0", "15.0"))
        self.assertTrue(version_at_least("15.0", "15.0"))
        self.assertFalse(version_at_least("14.7.6", "15.0"))

    def test_collects_only_allowlisted_host_fields(self):
        responses = {
            ("/usr/bin/uname", "-m"): (0, "arm64", ""),
            ("/usr/bin/sw_vers", "-productVersion"): (0, "26.5.2", ""),
            ("/usr/bin/sw_vers", "-buildVersion"): (0, "25F84", ""),
            ("/usr/sbin/sysctl", "-n", "hw.memsize"): (0, "34359738368", ""),
            ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"): (0, "Apple M4", ""),
            ("/usr/sbin/sysctl", "-n", "hw.model"): (0, "Mac16,10", ""),
            ("/usr/sbin/pkgutil", "--pkg-info", "com.apple.pkg.RosettaUpdateAuto"): (0, "receipt", ""),
            ("/usr/bin/arch", "-x86_64", "/usr/bin/true"): (0, "", ""),
        }

        evidence = collect_host_evidence(
            runner=lambda arguments: responses[tuple(arguments)],
            environment={
                "GITHUB_ACTIONS": "true",
                "RUNNER_ARCH": "ARM64",
                "ImageOS": "macos26",
                "ImageVersion": "20260801.1",
                "USER": "private-user",
                "RUNNER_NAME": "private-runner-name",
            },
            test_rosetta_execution=True,
        )

        self.assertEqual(evidence["host"]["chip"], "Apple M4")
        self.assertEqual(evidence["host"]["memory_gib"], 32.0)
        self.assertTrue(evidence["rosetta"]["receipt_present"])
        self.assertTrue(evidence["rosetta"]["x86_64_execution_tested"])
        self.assertTrue(evidence["rosetta"]["x86_64_execution_available"])
        self.assertEqual(evidence["ci"]["provider"], "github-actions")
        rendered = str(evidence)
        self.assertNotIn("private-user", rendered)
        self.assertNotIn("private-runner-name", rendered)
        self.assertNotIn("USER", rendered)
        self.assertNotIn("RUNNER_NAME", rendered)
        self.assertFalse(any(evidence["privacy"].values()))

    def test_classifies_distribution_security_without_exposing_identity(self):
        signature, timestamp = classify_signature(
            0,
            "Authority=Developer ID Application: Example Corp (ABCDE12345)\n"
            "Timestamp=Aug 4, 2026 at 10:00:00",
        )
        self.assertEqual(signature, "developer-id-application")
        self.assertTrue(timestamp)
        self.assertEqual(classify_signature(0, "Signature=adhoc\nTimestamp=none"), ("ad-hoc", False))
        self.assertEqual(classify_signature(1, "code object is not signed"), ("unsigned", False))


if __name__ == "__main__":
    unittest.main()

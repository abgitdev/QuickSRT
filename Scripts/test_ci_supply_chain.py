import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
AUDIT_LOCK = ROOT / "Runtime" / "audit-requirements.lock"


class CISupplyChainTests(unittest.TestCase):
    def test_every_github_action_is_pinned_to_a_full_commit(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        uses = re.findall(r"^\s*uses:\s*([^\s#]+)", workflow, flags=re.MULTILINE)
        self.assertTrue(uses)
        for reference in uses:
            self.assertRegex(reference, r"^[^@\s]+@[0-9a-f]{40}$")

    def test_whitespace_gate_checks_commits_and_pull_request_range(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('git diff --check "$BASE_SHA...$CURRENT_SHA"', workflow)
        self.assertIn('git log --check --format= "$BEFORE_SHA..$CURRENT_SHA"', workflow)
        self.assertNotIn("\n          git diff --check\n", workflow)

    def test_whitespace_gate_handles_rewritten_push_history(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('git cat-file -e "$BEFORE_SHA^{commit}"', workflow)
        self.assertIn(
            'git merge-base --is-ancestor "$BEFORE_SHA" "$CURRENT_SHA"',
            workflow,
        )
        self.assertIn("git log -1 --check --format=", workflow)

    def test_primary_ui_scheme_runs_in_hosted_ci(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("-scheme QuickSRTUI", workflow)
        self.assertIn("Run primary workflow UI tests", workflow)

    def test_audit_tool_graph_is_exact_and_hash_locked(self):
        contents = AUDIT_LOCK.read_text(encoding="utf-8")
        requirements = []
        current = []
        for line in contents.splitlines():
            if line and not line[0].isspace() and not line.startswith("#"):
                if current:
                    requirements.append("\n".join(current))
                current = [line]
            elif current:
                current.append(line)
        if current:
            requirements.append("\n".join(current))
        self.assertTrue(requirements)
        self.assertTrue(any(block.startswith("pip-audit==2.10.1") for block in requirements))
        for block in requirements:
            first_line = block.splitlines()[0]
            self.assertRegex(first_line, r"^[a-zA-Z0-9_.-]+==[^\s\\]+")
            self.assertIn("--hash=sha256:", block)

        audit_script = (ROOT / "Scripts" / "audit_runtime.sh").read_text(encoding="utf-8")
        self.assertIn('AUDIT_LOCK="$ROOT_DIR/Runtime/audit-requirements.lock"', audit_script)
        self.assertIn("--require-hashes", audit_script)
        self.assertNotIn("pip-audit==", audit_script)


if __name__ == "__main__":
    unittest.main()

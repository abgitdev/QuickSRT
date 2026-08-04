import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


spec = importlib.util.spec_from_file_location(
    "prepare_packaged_runtime", Path(__file__).with_name("prepare_packaged_runtime.py")
)
runtime = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(runtime)


class PreparePackagedRuntimeTests(unittest.TestCase):
    def test_dangling_symlinks_are_removed_but_valid_links_remain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("ok", encoding="utf-8")
            valid = root / "valid"
            valid.symlink_to("target")
            dangling = root / "dangling"
            dangling.symlink_to("missing")

            runtime.remove_dangling_symlinks(root)

            self.assertTrue(valid.is_symlink())
            self.assertEqual(valid.read_text(encoding="utf-8"), "ok")
            self.assertFalse(dangling.is_symlink())

    def test_record_removes_absolute_and_escaping_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "RECORD"
            with record.open("w", newline="", encoding="utf-8") as handle:
                csv.writer(handle).writerows([
                    ["package/module.py", "sha256=ok", "1"],
                    ["/" + "Users/example/cache/file", "", ""],
                    ["../../bin/tool", "", ""],
                ])

            runtime.clean_record(record)

            self.assertEqual(record.read_text(encoding="utf-8"), "package/module.py,sha256=ok,1\n")

    def test_console_entry_point_uses_relative_packaged_python(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "mlx_whisper"
            script.write_text("#!/tmp/build/python\nprint('ok')\n", encoding="utf-8")

            runtime.rewrite_console_script(script)

            contents = script.read_text(encoding="utf-8")
            self.assertTrue(contents.startswith("#!/bin/sh\n"))
            self.assertIn("/../..", contents)
            self.assertIn("/venv/bin/python", contents)
            self.assertNotIn("/tmp/build/python", contents)

    def test_private_paths_are_replaced_without_changing_size(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "binary"
            original = b"prefix /" + b"Users/builder/work /private/" + b"var/folders/cache suffix"
            target.write_bytes(original)

            runtime.replace_private_paths(target)

            updated = target.read_bytes()
            self.assertEqual(len(updated), len(original))
            self.assertNotIn(b"/" + b"Users/", updated)
            self.assertNotIn(b"/private/" + b"var/folders/", updated)

    def test_universal_macho_is_thinned_to_arm64_and_keeps_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"universal")
            target.chmod(0o751)
            commands: list[list[str]] = []

            def runner(command, **_kwargs):
                commands.append(command)
                if command[1] == "-archs":
                    output = "arm64\n" if target.read_bytes() == b"arm64" else "x86_64 arm64\n"
                    return SimpleNamespace(stdout=output)
                output = Path(command[-1])
                output.write_bytes(b"arm64")
                return SimpleNamespace(stdout="")

            runtime.thin_macho_to_arm64(target, runner)

            self.assertEqual(target.read_bytes(), b"arm64")
            self.assertEqual(target.stat().st_mode & 0o777, 0o751)
            self.assertTrue(any("-thin" in command for command in commands))

    def test_arm64_only_macho_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"arm64")

            def runner(command, **_kwargs):
                self.assertEqual(command[1], "-archs")
                return SimpleNamespace(stdout="arm64\n")

            runtime.thin_macho_to_arm64(target, runner)
            self.assertEqual(target.read_bytes(), b"arm64")

    def test_macho_without_arm64_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool"
            target.write_bytes(b"x86_64")

            def runner(_command, **_kwargs):
                return SimpleNamespace(stdout="x86_64\n")

            with self.assertRaisesRegex(ValueError, "lacks arm64"):
                runtime.thin_macho_to_arm64(target, runner)

    def test_known_python_intel_launcher_and_symlink_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "Python.framework/Versions/3.13/bin"
            bin_directory.mkdir(parents=True)
            launcher = bin_directory / "python3.13-intel64"
            launcher.write_bytes(b"intel")
            link = bin_directory / "python3-intel64"
            link.symlink_to(launcher.name)

            def runner(_command, **_kwargs):
                return SimpleNamespace(stdout="x86_64\n")

            retained = runtime.remove_known_intel_only_launchers(root, [launcher], runner)

            self.assertEqual(retained, [])
            self.assertFalse(launcher.exists())
            self.assertFalse(link.is_symlink())

    def test_unexpected_intel_only_macho_remains_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "site-packages/unexpected-tool"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"intel")

            def runner(_command, **_kwargs):
                return SimpleNamespace(stdout="x86_64\n")

            with self.assertRaisesRegex(ValueError, "unexpected packaged Mach-O lacks arm64"):
                runtime.remove_known_intel_only_launchers(root, [executable], runner)

    def test_framework_main_executable_is_detected_for_bundle_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "Python.framework/Versions/3.13/Frameworks/Tk.framework"
            main = framework / "Versions/8.6/Tk"
            nested = framework / "Versions/8.6/libtkstub8.6.a"

            self.assertTrue(runtime.is_framework_executable(main, root))
            self.assertFalse(runtime.is_framework_executable(nested, root))


if __name__ == "__main__":
    unittest.main()

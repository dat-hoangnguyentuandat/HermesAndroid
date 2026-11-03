import importlib.util
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
if sys.platform == "win32":
    sys.modules.setdefault("fcntl", types.SimpleNamespace())
spec = importlib.util.spec_from_file_location("hermesandroid_updater", ROOT / "hermes/update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.h = Path(self.tmp.name)
        self.releases = self.h / "releases"
        self.releases.mkdir()
        self.context = patch.multiple(updater, H=self.h, RELEASES=self.releases)
        self.context.start()
        self.addCleanup(self.context.stop)

    def test_unverified_and_outside_paths_cannot_activate(self):
        for directory in (self.h / "outside", self.releases / "incomplete"):
            directory.mkdir()
            if directory.name == "outside":
                (directory / ".ready").touch()
            with self.assertRaises(RuntimeError):
                updater.switch(str(directory))
        self.assertFalse((self.h / "current").exists())

    def test_failed_activation_restores_previous_before_restart(self):
        events = []
        with patch.object(updater, "current_target", return_value="old"), \
             patch.object(updater, "running_services", return_value=[(123, "dashboard")]), \
             patch.object(updater, "stop_services"), \
             patch.object(updater, "switch", side_effect=lambda target: events.append(target)), \
             patch.object(updater, "start_services", side_effect=[RuntimeError("health failed"), None]):
            with self.assertRaises(RuntimeError):
                updater.activate("new")
        self.assertEqual(events, ["new", "old"])
        self.assertFalse((self.h / "previous-release").exists())

    def test_success_records_previous_and_restarts_only_existing_services(self):
        with patch.object(updater, "current_target", return_value="old"), \
             patch.object(updater, "running_services", return_value=[(123, "dashboard")]), \
             patch.object(updater, "stop_services"), patch.object(updater, "switch"), \
             patch.object(updater, "start_services") as start:
            updater.activate("new")
            start.assert_called_once_with({"dashboard"})
        self.assertEqual((self.h / "previous-release").read_text(), "old")

    def test_failed_build_never_marks_ready_or_touches_active(self):
        release = self.releases / "new"
        (self.h / "release-sitecustomize.py").write_text("# compat")
        def fake_download(url, destination):
            with tarfile.open(destination, "w:gz") as tf:
                data = b"[project]\nname='test'"
                info = tarfile.TarInfo("hermes/pyproject.toml")
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
        with patch.object(updater, "fetch", side_effect=fake_download), \
             patch.object(updater.shutil, "disk_usage", return_value=types.SimpleNamespace(free=4 * 1024 ** 3)), \
             patch.object(updater, "run", side_effect=subprocess.CalledProcessError(1, "npm")), \
             patch.object(updater, "switch") as switch:
            with self.assertRaises(subprocess.CalledProcessError):
                updater.build_release(release, "a" * 40, "test")
            switch.assert_not_called()
        self.assertFalse((release / ".ready").exists())

    def test_build_environment_does_not_inherit_previous_python_release(self):
        with patch.dict("os.environ", {"PYTHONPATH": "/old", "HERMES_RELEASE": "/old", "PIP_TARGET": "/old"}):
            env = updater.build_env()
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("HERMES_RELEASE", env)
        self.assertNotIn("PIP_TARGET", env)
        self.assertEqual(env["npm_config_script_shell"], "/system/bin/sh")

    def test_old_python_fails_before_downloading_or_creating_release(self):
        release = self.releases / "new"
        with patch.object(updater.sys, "version_info", (3, 12, 16)), \
             patch.object(updater, "fetch") as fetch:
            with self.assertRaisesRegex(RuntimeError, "Python 3.14.*reflash"):
                updater.build_release(release, "a" * 40, "test")
        fetch.assert_not_called()
        self.assertFalse(release.exists())

    def test_installer_and_release_wrapper_use_same_python(self):
        release = self.releases / "new"
        release.mkdir()
        (self.h / "release-sitecustomize.py").write_text("# compat")
        updater.release_python(release)
        wrapper = (release / "bin/python").read_text()
        installer = (ROOT / "customize.sh").read_text(encoding="utf-8")
        self.assertIn("python/bin/python3.14", wrapper)
        self.assertIn('"$PY_DIR/bin/python3.14"', installer)
        self.assertIn('"$H/python/bin/python3.14"', installer)
        self.assertIn('"$PY_DIR/lib/python3.14/sitecustomize.py"', installer)
        self.assertNotIn("3.12", installer)

    def test_bundled_libatomic_is_aarch64_and_matches_provenance(self):
        with tarfile.open(ROOT / "glibc.tar.gz") as bundle:
            library = bundle.extractfile("lib/libatomic.so.1").read()
            license_text = bundle.extractfile("licenses/libatomic1-copyright").read()
        self.assertEqual(library[:6], b"\x7fELF\x02\x01")
        self.assertEqual(int.from_bytes(library[18:20], "little"), 183)
        provenance = (ROOT / "hermes/libatomic-source.txt").read_text()
        self.assertIn(hashlib.sha256(library).hexdigest(), provenance)
        self.assertIn(b"RUNTIME LIBRARY EXCEPTION", license_text.upper())

    def test_dependency_check_honors_lock_overrides_but_rejects_missing_packages(self):
        release = self.releases / "new"
        source = release / "source"
        source.mkdir(parents=True)
        (source / "uv.lock").write_text(
            '[manifest]\noverrides = [{name="pillow", specifier="==13.0.0"}]\n')
        packages = [types.SimpleNamespace(metadata={"Name": "browser-harness"}, version="0.1.13",
                                          requires=["pillow==12.3.0"]),
                    types.SimpleNamespace(metadata={"Name": "Pillow"}, version="13.0.0", requires=[])]
        with patch("importlib.metadata.distributions", return_value=packages):
            updater.check_dependencies(release)
            packages[1].version = "12.3.0"
            with self.assertRaisesRegex(RuntimeError, "pillow==13.0.0"):
                updater.check_dependencies(release)
            packages[1].version = "13.0.0"
            packages[0].requires.append("missing-package>=1")
            with self.assertRaisesRegex(RuntimeError, "missing-package"):
                updater.check_dependencies(release)

    def test_install_uses_frozen_lock_and_overrides(self):
        release = self.releases / "new"
        source = release / "source"
        source.mkdir(parents=True)
        (source / "uv.lock").write_text(
            '[manifest]\noverrides = [{name="pillow", specifier="==13.0.0"}]\n')
        with patch.object(updater, "run") as run:
            updater.install_dependencies(source, release, {})
        export = run.call_args_list[1].args[0]
        install = run.call_args_list[2].args[0]
        self.assertIn("--frozen", export)
        self.assertIn("--no-emit-project", export)
        self.assertIn("--override", install)
        self.assertIn("--requirements", install)
        self.assertNotIn("--no-deps", install)
        editable = run.call_args_list[3].args[0]
        self.assertEqual(editable[0], self.h / "bin/python")
        self.assertIn("--no-deps", editable)
        self.assertIn("--editable", editable)
        self.assertEqual((release / "overrides.txt").read_text(), "pillow==13.0.0\n")

    @unittest.skipUnless(shutil.which("node"), "Node is needed to verify installer compatibility checks")
    def test_installer_migrates_old_node_and_incompatible_npm(self):
        installer = (ROOT / "customize.sh").read_text(encoding="utf-8")
        script = installer.split('"$NODE_DIR/bin/node" -e \'', 1)[1].split("' >/dev/null", 1)[0]
        harness = """
const vm = require('node:vm');
const script = JSON.parse(process.argv[1]);
for (const [node, npm, expected] of [
    ['22.23.4', '10.9.9', 1], ['26.13.0', '11.20.0', 0],
    ['26.0.0', '11.10.0', 1], ['26.0.0', '11.16.0', 1],
    ['26.0.0', '11.17.0', 0], ['26.0.0', '10.9.9', 0],
    ['26.0.0', '12.0.0', 0]]) {
    let result;
    vm.runInNewContext(script, {
        process: {versions: {node}, exit: code => {result = code;}},
        require: () => ({version: npm})
    });
    if (result !== expected) throw Error(`Unexpected result for ${node}/${npm}`);
}
"""
        subprocess.run([shutil.which("node"), "-e", harness, json.dumps(script)], check=True)
        self.assertIn('if [ "$NODE_COMPATIBLE" = false ]; then', installer)
        self.assertNotIn('"v22\\.', installer)


if __name__ == "__main__":
    unittest.main()

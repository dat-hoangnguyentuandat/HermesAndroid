import importlib.util
import io
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()

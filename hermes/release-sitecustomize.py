"""Module-owned Python environment; never modify upstream Hermes sources."""
import os
import site
import sys

release = os.environ.get("HERMES_RELEASE")
if release:
    # Hide the legacy installation's packages: upgrades have independent deps.
    sys.path[:] = [p for p in sys.path if "/site-packages" not in p]
    site.addsitedir(os.path.join(release, "packages"))
wrapper = os.environ.get("HERMES_PY_WRAPPER")
if wrapper:
    sys.executable = wrapper
    sys._base_executable = wrapper

# HermesAndroid sitecustomize — fix interpreter identity under glibc loader.
#
# CPython runs as:  ld-linux-aarch64.so.1 --library-path <glibc> python3.12 ...
# so /proc/self/exe and sys.executable point at the LOADER, not python.
# subprocess/pip/venv keyed on sys.executable break. This repoints them at
# the wrapper script, which re-enters through the loader correctly.
import os
import sys

_WRAP = os.environ.get('HERMES_PY_WRAPPER', '')

if _WRAP and os.path.exists(_WRAP):
    try:
        sys.executable = _WRAP
        if hasattr(sys, '_base_executable'):
            sys._base_executable = _WRAP
    except Exception:
        pass

# Android root shells often have HOME unset or HOME=/ — give a sane default
_home = os.environ.get('HOME')
if not _home or _home == '/':
    os.environ['HOME'] = '/data/adb/hermes/home'

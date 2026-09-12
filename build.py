#!/usr/bin/env python3
"""Pack this module into ../version/HermesAndroid-v<version>.zip."""
from pathlib import Path
import re
import stat
import zipfile

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT.parent / "version"
EXCLUDED = {".git", "__pycache__", ".pytest_cache", ".cache", "tests", "dist", "version"}
EXECUTABLES = {"customize.sh", "service.sh", "action.sh", "uninstall.sh", "update-binary",
               "updater-script", "hermes", "hermes.service", "doh-proxy.py"}


def main():
    version = re.search(r"^version=(.+)$", (ROOT / "module.prop").read_text(), re.M).group(1).strip()
    bundle = ROOT / "glibc.tar.gz"
    if not bundle.is_file():
        raise FileNotFoundError("Missing bundled glibc.tar.gz; use a complete repository checkout")
    OUTPUT.mkdir(exist_ok=True)
    output = OUTPUT / f"HermesAndroid-v{version}.zip"
    temporary = output.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(ROOT.rglob("*")):
            rel = path.relative_to(ROOT)
            if not path.is_file() or any(part in EXCLUDED for part in rel.parts):
                continue
            if rel.as_posix() in {"build.py", ".gitignore", ".gitattributes"} or path.suffix in {".pyc", ".pyo"}:
                continue
            data = path.read_bytes()
            executable = rel.name in EXECUTABLES or rel.parent.as_posix() == "system/bin"
            if executable or path.suffix in {".sh", ".py", ".cjs", ".prop", ".md"}:
                data = data.replace(b"\r\n", b"\n")
            info = zipfile.ZipInfo(rel.as_posix())
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    temporary.replace(output)
    print(f"OK {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()

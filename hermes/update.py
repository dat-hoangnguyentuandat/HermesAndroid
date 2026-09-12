"""Download an upstream revision, build on Android, then activate atomically.

Python dependencies and JS assets live per revision. No upstream source patches.
The base CPython/Node/glibc are module-owned and shared between revisions.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import tomllib
import urllib.parse
import urllib.request

H = Path("/data/adb/hermes")
RELEASES = H / "releases"
API = "https://api.github.com/repos/NousResearch/hermes-agent"


def say(message):
    print(message, flush=True)


def fetch(url, destination=None):
    req = urllib.request.Request(url, headers={"User-Agent": "HermesAndroid/1.0.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as response:
                if destination is None:
                    return json.load(response)
                with destination.open("wb") as output:
                    shutil.copyfileobj(response, output)
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)


def run(args, *, cwd=None, env=None, timeout=1800):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True, timeout=timeout)


def write_executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def build_env():
    env = os.environ.copy()
    for key in ("PYTHONPATH", "HERMES_RELEASE", "NODE_OPTIONS", "PIP_TARGET"):
        env.pop(key, None)
    env.update(HOME=str(H / "home"), TMPDIR=str(H / "tmp"),
               SSL_CERT_FILE=str(H / "ca-bundle.pem"),
               NODE_EXTRA_CA_CERTS=str(H / "ca-bundle.pem"),
               HERMES_NODE=str(H / "node/bin/node"),
               NODE_OPTIONS=f"--require={H}/node-compat.cjs",
               npm_config_script_shell="/system/bin/sh",
               npm_config_cache=str(H / "npm-cache"),
               PATH=f"{H}/bin:{H}/node/bin:/system/bin:/system/xbin:" + env.get("PATH", ""))
    return env


def prepare_node_bins(source, release, env):
    # npm's generated command shims use /usr/bin/env, absent on Android.
    # Rewrite generated shims only; tracked upstream files remain unchanged.
    for directory in source.rglob(".bin"):
        if directory.parent.name != "node_modules" or not directory.is_dir():
            continue
        for shim in directory.iterdir():
            if not shim.is_symlink():
                continue
            target = shim.resolve()
            if not target.is_file():
                continue
            with target.open("rb") as stream:
                first = stream.readline(256)
            if first.startswith(b"#!") and b"node" in first:
                shim.unlink()
                write_executable(shim, f'#!/system/bin/sh\nexec "{H}/node/bin/node" "{target}" "$@"\n')
    # esbuild launches a separate ELF; its Linux interpreter path isn't on Android.
    candidates = list(source.glob("node_modules/@esbuild/linux-arm64/bin/esbuild"))
    if candidates:
        wrapper = release / "bin/esbuild"
        write_executable(wrapper, f'#!/system/bin/sh\nexec "{H}/glibc/lib/ld-linux-aarch64.so.1" --library-path "{H}/glibc/lib" "{candidates[0]}" "$@"\n')
        env["ESBUILD_BINARY_PATH"] = str(wrapper)


def release_python(release):
    (release / "bin").mkdir(exist_ok=True)
    (release / "compat").mkdir(exist_ok=True)
    shutil.copyfile(H / "release-sitecustomize.py", release / "compat/sitecustomize.py")
    write_executable(release / "bin/python", f'''#!/system/bin/sh
unset LD_PRELOAD
export HERMES_RELEASE="{release}"
export HERMES_PY_WRAPPER="{release}/bin/python"
export PYTHONPATH="{release}/compat:{release}/source:{release}/packages"
export PIP_TARGET="{release}/packages"
export PYTHONUTF8=1
exec "{H}/glibc/lib/ld-linux-aarch64.so.1" --library-path "{H}/glibc/lib" "{H}/python/bin/python3.12" "$@"
''')


def build_release(release, sha, ref):
    if shutil.disk_usage(H).free < 2 * 1024 ** 3:
        raise RuntimeError("At least 2 GB free on /data is required for a new build")
    release.mkdir()
    release_python(release)
    archive = release / "upstream.tar.gz"
    say(f"Downloading upstream {ref} ({sha[:12]})...")
    fetch(f"https://codeload.github.com/NousResearch/hermes-agent/tar.gz/{sha}", archive)
    with tarfile.open(archive) as tf:
        tf.extractall(release / "unpack", filter="data")
    roots = list((release / "unpack").iterdir())
    if len(roots) != 1 or not (roots[0] / "pyproject.toml").is_file():
        raise RuntimeError("Unexpected upstream archive layout")
    source = release / "source"
    roots[0].rename(source)
    (release / "unpack").rmdir()
    archive.unlink()
    from pip._vendor.packaging.specifiers import SpecifierSet
    project = tomllib.loads((source / "pyproject.toml").read_text(encoding="utf-8"))
    required_python = project.get("project", {}).get("requires-python", "")
    if required_python and sys.version.split()[0] not in SpecifierSet(required_python):
        raise RuntimeError(f"This Hermes revision requires Python {required_python}; update the module runtime first")
    env = build_env()
    npm = [H / "node/bin/node", H / "node/lib/node_modules/npm/bin/npm-cli.js"]
    say("Installing build dependencies for dashboard and TUI...")
    run(npm + ["ci", "--workspace", "web", "--workspace", "ui-tui", "--include-workspace-root",
               "--ignore-scripts", "--no-audit", "--no-fund"], cwd=source, env=env)
    prepare_node_bins(source, release, env)
    for workspace in ("web", "ui-tui"):
        say(f"Building {workspace} on this device...")
        run(npm + ["run", "build", "--workspace", workspace], cwd=source, env=env)
    for output in (source / "hermes_cli/web_dist/index.html", source / "ui-tui/dist/entry.js"):
        if not output.is_file():
            raise RuntimeError(f"Expected build output missing: {output}")
    # Official launcher supports this prebuilt location. Keep the source workspace too.
    shutil.copytree(source / "ui-tui/dist", source / "hermes_cli/tui_dist", dirs_exist_ok=True)
    say("Installing isolated Python dependencies...")
    run([H / "bin/python", "-m", "pip", "install", "--ignore-installed", "--no-cache-dir",
         "--progress-bar", "off", "--timeout", "120", "--retries", "5",
         "--target", release / "packages", "--editable", source, "pip"], env=env)
    for entry in (release / "packages/bin").glob("*"):
        if entry.is_file() and entry.read_bytes().startswith(b"#!"):
            contents = entry.read_bytes().split(b"\n", 1)
            if b"python" in contents[0]:
                entry.write_bytes(f"#!{release}/bin/python\n".encode() + contents[1])
    say("Checking Python imports and built assets...")
    run([release / "bin/python", "-c", "import hermes_cli, fastapi, openai, yaml; from hermes_cli import web_server"], cwd=release, env=env, timeout=120)
    run([release / "bin/python", "-m", "hermes_cli.main", "--version"], cwd=release, env=env, timeout=60)
    run([release / "bin/python", "-m", "pip", "check"], cwd=release, env=env, timeout=60)
    run([H / "node/bin/node", "--check", source / "hermes_cli/tui_dist/entry.js"], env=env, timeout=60)
    (release / ".ready").write_text(json.dumps({"commit": sha, "ref": ref, "built_at": time.time()}))


def current_target():
    return os.readlink(H / "current") if (H / "current").is_symlink() else "legacy"


def switch(target):
    link = H / "current"
    if target == "legacy":
        link.unlink(missing_ok=True)
        return
    resolved = Path(target).resolve()
    if resolved.parent != RELEASES.resolve() or not (resolved / ".ready").is_file():
        raise RuntimeError("Refusing to activate an unverified release")
    temporary = H / "current.new"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(resolved)
    temporary.replace(link)


def running_services():
    matches = []
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            args = (proc / "cmdline").read_bytes().decode(errors="replace").split("\0")
            if int(proc.name) == os.getpid() or not any(str(H) + "/" in arg for arg in args):
                continue
            kind = "dashboard" if "dashboard" in args else "gateway" if "gateway" in args else None
            if kind:
                matches.append((int(proc.name), kind))
        except (OSError, ValueError):
            pass
    return matches


def stop_services(processes):
    for pid, _ in processes:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(30):
        remaining = {pid for pid, _ in running_services()} & {pid for pid, _ in processes}
        if not remaining:
            return
        time.sleep(1)
    raise RuntimeError("Service did not stop gracefully; activation cancelled")


def start_services(kinds):
    env = build_env()
    env["HERMES_HOME"] = str(H / "home/.hermes")
    for kind in sorted(kinds):
        args = ["dashboard", "--skip-build", "--no-open", "--host", "127.0.0.1", "--port", "9119"] if kind == "dashboard" else ["gateway", "run"]
        with (H / ("dashboard.log" if kind == "dashboard" else "hermes.log")).open("ab") as output:
            proc = subprocess.Popen([str(H / "bin/hermes"), *args], env=env, stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=output, start_new_session=True)
        if kind == "gateway":
            (H / "gateway.pid").write_text(str(proc.pid))
    if "dashboard" in kinds:
        for _ in range(45):
            try:
                with urllib.request.urlopen("http://127.0.0.1:9119/", timeout=2) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
            time.sleep(1)
        raise RuntimeError("Dashboard health check failed")


def activate(target, *, restart=True):
    old = current_target()
    processes = running_services() if restart else []
    kinds = {kind for _, kind in processes}
    stop_services(processes)
    try:
        switch(target)
        start_services(kinds)
    except Exception:
        stop_services(running_services() if restart else [])
        switch(old)
        start_services(kinds)
        raise
    (H / "previous-release").write_text(old)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="Official tag, branch or commit; default: latest GitHub release")
    parser.add_argument("--rollback", action="store_true", help="Switch to the previously active release")
    parser.add_argument("--build-only", action="store_true", help="Build and validate without activation")
    parser.add_argument("--no-restart", action="store_true", help="For module installation; do not restart running services")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run as root (su -c hermes update)")
    RELEASES.mkdir(parents=True, exist_ok=True)
    (H / "tmp").mkdir(exist_ok=True)
    with (H / "update.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Hermes update is already running")
        if args.rollback:
            activate((H / "previous-release").read_text().strip(), restart=not args.no_restart)
            say("Previous release restored. User data was not changed.")
            return
        ref = args.ref or fetch(API + "/releases/latest")["tag_name"]
        sha = fetch(API + "/commits/" + urllib.parse.quote(ref, safe=""))["sha"]
        if not re.fullmatch(r"[a-f0-9]{40}", sha):
            raise RuntimeError("Invalid upstream commit")
        release = RELEASES / sha
        if not (release / ".ready").is_file():
            if release.exists():
                if release.resolve().parent != RELEASES.resolve() or release == Path(current_target()):
                    raise RuntimeError("Unsafe incomplete release path")
                shutil.rmtree(release)
            build_release(release, sha, ref)
        if args.build_only:
            say(f"Build verified; not activated: {release}")
        elif current_target() == str(release):
            say("Already on the latest selected upstream release.")
        else:
            activate(str(release), restart=not args.no_restart)
            say(f"Hermes activated: {ref} ({sha[:12]}). Rollback: hermes update --rollback")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        say(f"Update failed: {exc}")
        sys.exit(1)

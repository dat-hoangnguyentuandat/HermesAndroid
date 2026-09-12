# HermesAndroid

A Magisk/KernelSU module that installs [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Python) directly on a rooted Android device (aarch64) — no Termux, no proot, no compiling Rust on the phone.

## How it works

```
Android (bionic) ── exec ──> ld-linux-aarch64.so.1 (bundled glibc 2.44 loader)
                                │ --library-path /data/adb/hermes/glibc/lib
                                ▼
                     CPython 3.12 (python-build-standalone,
                     aarch64-unknown-linux-gnu, downloaded at flash)
                                │ all deps = manylinux2014_aarch64 wheels
                                ▼
                     hermes-agent (editable upstream source + prebuilt UI)
```

The same glibc-loader trick GlibClaw uses for Node.js, applied to CPython. Plus two Android-specific fixes Python needs and Node doesn't:

1. **DNS** — glibc reads `/etc/resolv.conf`, which doesn't exist on Android. A tiny stdlib DoH proxy (`hermes/doh-proxy.py`) listens on `127.0.0.1:5353` and iptables redirects all outbound port-53 traffic to it. Upstream is a DoH endpoint by IP literal, so resolving the resolver is never needed.
2. **TLS trust** — PBS CPython bundles no Android CA store. At flash and at boot we concatenate Android's system CAs (`/system/etc/security/cacerts` or the conscrypt apex) into `ca-bundle.pem` and export `SSL_CERT_FILE`/`SSL_CERT_DIR` in every wrapper.
3. **Interpreter identity** — running python via the loader makes `/proc/self/exe` the loader, breaking `venv`/`subprocess`/`pip` that key off `sys.executable`. `sitecustomize.py` repoints `sys.executable` at the wrapper, which re-enters through the loader.

## Requirements

- Rooted Android (Magisk or KernelSU), aarch64
- Internet during flash (~28 MB CPython + ~40 MB wheels)
- ~500 MB free on /data

## Install

1. With Python, Git, Node.js (22.22+ or 24.11+) and npm installed, `build.py` produces `dist/HermesAndroid-v<version>.zip`. It checks out the upstream commit pinned in `build.py`, builds the dashboard/TUI, and bundles the source and UI assets.
2. Flash in Magisk/KernelSU
3. Reboot

## After install

The module starts three services on boot: DoH DNS proxy, hermes gateway, and the **web dashboard on `http://127.0.0.1:9119/`** (prebuilt web_dist ships in the module — no npm needed on the phone; the session token is injected into the page automatically). Open that URL in any browser on the phone.

The **Action** button in Magisk/KSU manager: ensures DNS + gateway are up, starts the dashboard if needed, and opens it in the browser — one tap to chat.

```sh
su -c hermes setup      # provider + API key wizard
su -c hermes status     # component status
su -c hermes            # interactive chat (terminal)
su -c hermes doctor     # health check
hermes.service status   # gateway + doh + dashboard (root shell)
```

Messaging platforms (Telegram etc.) start on boot when `autostart=true` in `/data/adb/hermes/settings.ini`.

> **Mobile apps:** The dashboard web UI is the phone-friendly surface, including the Chat tab. The module bundles a Node.js runtime (glibc-loader, same as CPython) and a prebuilt `tui_dist/entry.js` for terminal chat.

## Layout

```
/data/adb/hermes/
├── bin/python           # loader wrapper (the real entrypoint)
├── bin/hermes           # CLI wrapper
├── python/              # PBS CPython 3.12 + site-packages (hermes-agent)
├── source-1.2.0/        # upstream source and prebuilt dashboard/TUI
├── glibc/lib/           # ld-linux + libc + libnss_dns & friends
├── doh-proxy.py         # DNS-over-HTTPS UDP proxy
├── ca-bundle.pem        # Android system CAs concatenated
└── home/.hermes/        # user config, sessions, keys (preserved on uninstall)
```

## Updating

Reflash the module and reboot. Upgrade mode preserves CPython and user data, and installs the bundled upstream source with `pip install --upgrade --editable`. Version 1.2.0 migrates existing PyPI installations automatically. `hermes update` prints module upgrade instructions; source/runtime updates are delivered together in module ZIPs. To bump the Python patch version, remove the module before flashing again.

PyPI distribution of Hermes is discontinued upstream. This module uses upstream source with matching built assets; it does not suppress the deprecation warning or impersonate a Git/Nix installation. The custom rooted-Android glibc runtime is community maintained, outside upstream's documented Android/Termux install method.

## Known limits

- Gateway auto-restart on crash is not supervised (no systemd); service.sh starts it once per boot, Action button restarts it.
- Dashboard binds loopback by default; on-phone browser only.
- `voice` extra unavailable (no ctranslate2 Android wheels).

## Credits

- Architecture follows GlibClaw (same author) — glibc-loader runtime pattern for Node.js on Android.
- CPython builds by [python-build-standalone](https://github.com/astral-sh/python-build-standalone).
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.

## License

MIT © TDat

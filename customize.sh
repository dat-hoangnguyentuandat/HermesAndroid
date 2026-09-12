#!/system/bin/sh
# ============================================================
# HermesAndroid — customize.sh
# Runs at flash time (root). Downloads CPython (python-build-standalone),
# downloads upstream Hermes and builds dashboard/TUI on the device.
#
# Order matters: CPython + CA bundle must exist BEFORE the DoH proxy
# starts (the proxy itself runs on that interpreter), and pip needs the
# proxy for DNS.
# ============================================================

INSTALL_DIR="/data/adb/hermes"
LOG="$INSTALL_DIR/install.log"
GLIBC_TAR="$MODPATH/glibc.tar.gz"
GLIBC_DIR="$INSTALL_DIR/glibc/lib"
PY_DIR="$INSTALL_DIR/python"
DOH_PROXY_SRC="$MODPATH/hermes/doh-proxy.py"
SITECUSTOM_SRC="$MODPATH/hermes/sitecustomize.py"
DOH_PORT=5353

# Pinned fallback: astral-sh/python-build-standalone (aarch64 glibc, stripped)
PBS_REPO="https://github.com/astral-sh/python-build-standalone"
PBS_FALLBACK_TAG="20260901"
PBS_FALLBACK_ASSET="cpython-3.12.14+20260901-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
PBS_BASE_URL="${PBS_BASE_URL:-$PBS_REPO/releases/download}"

abort() { ui_print ""; ui_print "ERROR: $1"; ui_print "Log: $LOG"; exit 1; }
log()   { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

ui_print ""
ui_print "  _  _                     ___     _       _     _     "
ui_print " | || |__ _ _  _ ___ _ _ / __|___| |__ _| |___| |___ "
ui_print " | __ / _\` | || / -_) '_| (_| / -_) / _\` | / _\` | / -_)"
ui_print " |_||_\__,_|\_,_\___|_|  \___\___|_\__,_|_\__,_|_\___|"
ui_print "        Hermes Agent for rooted Android (aarch64)"
ui_print ""

mkdir -p "$INSTALL_DIR"
log "===== Install start ====="

# ── fetch util (curl or busybox wget) ──────────────
fetch() { # fetch URL OUT
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 "$1" -o "$2"
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget --no-check-certificate -O "$2" "$1"
  else
    return 127
  fi
}

# ── Architecture check ─────────────────────────────
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || abort "Unsupported architecture: $ARCH (need aarch64)"
log "arch: $ARCH OK"

# ── Detect upgrade ─────────────────────────────────
IS_UPGRADE=false
if [ -x "$INSTALL_DIR/bin/python" ] && [ -f "$PY_DIR/bin/python3.12" ]; then
  IS_UPGRADE=true
  ui_print "- Upgrade mode — preserving existing CPython runtime"
  log "upgrade detected, python runtime preserved"
fi

mkdir -p "$GLIBC_DIR" "$INSTALL_DIR/home" "$INSTALL_DIR/tmp" "$INSTALL_DIR/bin"

# ── Extract glibc bundle (shipped in module) ───────
# ALWAYS extract (overwrite) — the bundle is the source of truth; an older
# install may miss libs a newer bundle ships (e.g. libstdc++ for Node).
[ -f "$GLIBC_TAR" ] || abort "Missing glibc.tar.gz in module"
rm -rf "$INSTALL_DIR/glibc"
mkdir -p "$GLIBC_DIR"
tar -xzf "$GLIBC_TAR" -C "$INSTALL_DIR/glibc" || abort "Failed to extract glibc.tar.gz"
chmod 755 "$GLIBC_DIR"/*.so* 2>/dev/null
log "glibc bundle extracted"
ui_print "- glibc runtime ready"

# ── Install helper scripts ─────────────────────────
[ -f "$DOH_PROXY_SRC" ] || abort "Missing hermes/doh-proxy.py in module"
cp "$DOH_PROXY_SRC" "$INSTALL_DIR/doh-proxy.py"
cp "$SITECUSTOM_SRC" "$INSTALL_DIR/sitecustomize.py"
chmod 644 "$INSTALL_DIR/doh-proxy.py" "$INSTALL_DIR/sitecustomize.py"

# ── Create python wrapper BEFORE first use ─────────
cat > "$INSTALL_DIR/bin/python" << 'PYWRAP'
#!/system/bin/sh
# HermesAndroid python wrapper — runs CPython through the glibc loader
H="/data/adb/hermes"
unset LD_PRELOAD
export HOME="${HOME:-$H/home}"
export TMPDIR="${TMPDIR:-$H/tmp}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$H/ca-bundle.pem}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-$H/ca-dir}"
export PYTHONUTF8=1
export HERMES_PY_WRAPPER="$H/bin/python"
exec "$H/glibc/lib/ld-linux-aarch64.so.1" \
     --library-path "$H/glibc/lib" \
     "$H/python/bin/python3.12" "$@"
PYWRAP
chmod 755 "$INSTALL_DIR/bin/python"

# ── Add default route if missing ───────────────────
if ! ip route show 2>/dev/null | grep -q "^default"; then
  for iface in rmnet_data1 rmnet_data0 rmnet_data3 wlan0 eth0; do
    if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
      ip route add default dev "$iface" 2>/dev/null && \
        log "Default route added via $iface" && break
    fi
  done
fi

# ── Wait for basic network (IP only, no DNS yet) ───
ui_print "- Waiting for network..."
RETRY=0
while :; do
  ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && break
  RETRY=$((RETRY+1))
  [ $RETRY -ge 45 ] && abort "Network not ready after 90 seconds"
  sleep 2
done
log "network ready"

# ── Build CA bundle from Android's cert store ──────
CADIR=/system/etc/security/cacerts
[ -d "$CADIR" ] || CADIR=/apex/com.android.conscrypt/cacerts
if [ -d "$CADIR" ]; then
  cat "$CADIR"/*.0 > "$INSTALL_DIR/ca-bundle.pem" 2>/dev/null
  NCERT=$(grep -c 'BEGIN CERTIFICATE' "$INSTALL_DIR/ca-bundle.pem" 2>/dev/null || echo 0)
  log "CA bundle: $NCERT certs from $CADIR"
  [ "$NCERT" -gt 0 ] || abort "Failed to build CA bundle"
else
  abort "No Android CA cert store found"
fi

# ── Download + extract CPython ─────────────────────
if [ "$IS_UPGRADE" = false ]; then
  ui_print "- Detecting latest python-build-standalone 3.12..."
  PBS_ASSET=""
  PBS_TAG=""
  if command -v curl >/dev/null 2>&1; then
    PBS_TAG=$(curl -fsSL --max-time 15 https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest 2>/dev/null \
      | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$PBS_TAG" ]; then
      PBS_ASSET=$(curl -fsSL --max-time 15 "$PBS_REPO/releases/expanded_assets/$PBS_TAG" 2>/dev/null \
        | grep -o 'cpython-3\.12[^"]*aarch64-unknown-linux-gnu-install_only_stripped\.tar\.gz' | head -1)
    fi
  fi
  if [ -z "$PBS_ASSET" ]; then
    PBS_TAG="$PBS_FALLBACK_TAG"
    PBS_ASSET="$PBS_FALLBACK_ASSET"
    ui_print "  fallback: $PBS_ASSET"
    log "PBS auto-detect failed, using fallback"
  else
    ui_print "  found: $PBS_ASSET"
    log "PBS auto-detected tag=$PBS_TAG asset=$PBS_ASSET"
  fi

  PBS_URL="$PBS_BASE_URL/$PBS_TAG/$(echo "$PBS_ASSET" | sed 's/+/%2B/g')"
  ui_print "- Downloading CPython (~28 MB)..."
  log "downloading: $PBS_URL"
  fetch "$PBS_URL" "$INSTALL_DIR/tmp/pbs.tar.gz" || abort "Failed to download CPython"

  ui_print "- Extracting CPython..."
  rm -rf "$PY_DIR"
  mkdir -p "$PY_DIR"
  tar -xzf "$INSTALL_DIR/tmp/pbs.tar.gz" -C "$PY_DIR" --strip-components=1 || abort "CPython extraction failed"
  rm -f "$INSTALL_DIR/tmp/pbs.tar.gz"
  chmod 755 "$PY_DIR/bin/"* 2>/dev/null
  [ -f "$PY_DIR/bin/python3.12" ] || abort "python3.12 not found after extraction"

  # Smoke test
  PY_VER=$("$INSTALL_DIR/bin/python" --version 2>&1) || abort "Python smoke test failed: $PY_VER"
  log "python OK: $PY_VER"
  ui_print "- $PY_VER ready"
else
  PY_VER=$("$INSTALL_DIR/bin/python" --version 2>&1) || abort "Existing Python broken: $PY_VER"
  ui_print "- Using existing $PY_VER"
fi

# ════════════════════════════════════════════════════
#  Node.js runtime (TUI: dashboard Chat tab runs the prebuilt
#  tui_dist/entry.js bundled with the source via `node --expose-gc`)
# ════════════════════════════════════════════════════
NODE_DIR="$INSTALL_DIR/node"
NODE_FALLBACK="v22.22.0"
if [ "$IS_UPGRADE" = false ] || [ ! -x "$NODE_DIR/bin/node" ]; then
  ui_print "- Detecting latest Node.js 22 LTS..."
  NODE_VERSION=""
  if command -v curl >/dev/null 2>&1; then
    NODE_VERSION=$(curl -fsSL --max-time 15 https://nodejs.org/dist/index.json 2>/dev/null \
      | grep -o '"v22\.[0-9]*\.[0-9]*"' | head -1 | tr -d '"')
  fi
  [ -n "$NODE_VERSION" ] || { NODE_VERSION="$NODE_FALLBACK"; ui_print "  fallback: $NODE_VERSION"; }
  ui_print "  using Node.js $NODE_VERSION"

  NODE_ARCHIVE="node-$NODE_VERSION-linux-arm64.tar.gz"
  ui_print "- Downloading Node.js (~30 MB)..."
  fetch "https://nodejs.org/dist/$NODE_VERSION/$NODE_ARCHIVE" "$INSTALL_DIR/tmp/$NODE_ARCHIVE" \
    || abort "Failed to download Node.js"

  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xzf "$INSTALL_DIR/tmp/$NODE_ARCHIVE" -C "$NODE_DIR" || abort "Node.js extraction failed"
  # flatten top-level dir (node-vX.Y.Z-linux-arm64/)
  NODE_TOP=$(ls -d "$NODE_DIR"/node-v*-linux-arm64 2>/dev/null | head -1)
  if [ -n "$NODE_TOP" ] && [ -d "$NODE_TOP" ]; then
    mv "$NODE_TOP"/* "$NODE_DIR/" 2>/dev/null || true
    rmdir "$NODE_TOP" 2>/dev/null || true
  fi
  rm -f "$INSTALL_DIR/tmp/$NODE_ARCHIVE"

  # node wrapper: runs the real binary through the bundled glibc loader
  mv "$NODE_DIR/bin/node" "$NODE_DIR/bin/node.real"
  cat > "$NODE_DIR/bin/node" << 'NODEWRAP'
#!/system/bin/sh
# HermesAndroid node wrapper — Node.js through the glibc loader
H="/data/adb/hermes"
unset LD_PRELOAD
export HOME="${HOME:-$H/home}"
export TMPDIR="${TMPDIR:-$H/tmp}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$H/ca-bundle.pem}"
exec "$H/glibc/lib/ld-linux-aarch64.so.1" \
     --library-path "$H/glibc/lib" \
     "$H/node/bin/node.real" "$@"
NODEWRAP
  chmod 755 "$NODE_DIR/bin/node"

  NODE_VER=$("$NODE_DIR/bin/node" --version 2>&1) || abort "Node smoke test failed: $NODE_VER"
  log "node OK: $NODE_VER"
  ui_print "- Node.js $NODE_VER ready"
else
  NODE_VER=$("$NODE_DIR/bin/node" --version 2>&1) || abort "Existing Node broken: $NODE_VER"
  ui_print "- Using existing Node.js $NODE_VER"
fi

# ── Install sitecustomize into stdlib ──────────────
cp "$INSTALL_DIR/sitecustomize.py" "$PY_DIR/lib/python3.12/sitecustomize.py"
log "sitecustomize installed"

# ════════════════════════════════════════════════════
#  DoH proxy — NOW the interpreter exists
# ════════════════════════════════════════════════════
pkill -f doh-proxy.py 2>/dev/null || true
sleep 0.5
DOH_PORT=$DOH_PORT "$INSTALL_DIR/bin/python" "$INSTALL_DIR/doh-proxy.py" >> "$LOG" 2>&1 &
DOH_PID=$!
sleep 2

if ! kill -0 $DOH_PID 2>/dev/null; then
  log "WARNING: DoH proxy failed to start — falling back to system DNS"
  ui_print "- WARNING: DoH proxy failed (see log), trying without it"
else
  iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
  iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT
  log "DoH proxy PID=$DOH_PID, iptables 53->$DOH_PORT"

  # Verify DNS actually resolves through the proxy before pip
  ui_print "- Verifying DNS..."
  if "$INSTALL_DIR/bin/python" -c 'import socket; socket.gethostbyname("pypi.org")' 2>>"$LOG"; then
    log "DNS via DoH proxy verified"
    ui_print "  DNS OK"
  else
    log "DNS verification failed — removing redirect, falling back"
    ui_print "  DNS via proxy failed — falling back to system DNS"
    iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
    kill $DOH_PID 2>/dev/null
  fi
fi

# ── Build upstream source and isolated dependencies on this device ──
export SSL_CERT_FILE="$INSTALL_DIR/ca-bundle.pem"
export SSL_CERT_DIR="$INSTALL_DIR/ca-dir"
export TMPDIR="$INSTALL_DIR/tmp"

for helper in update.py node-compat.cjs release-sitecustomize.py; do
  cp "$MODPATH/hermes/$helper" "$INSTALL_DIR/$helper" || abort "Missing updater helper: $helper"
done
cp "$MODPATH/hermes/launcher.sh" "$INSTALL_DIR/bin/hermes"
chmod 755 "$INSTALL_DIR/bin/hermes"
ui_print "- Downloading Hermes and building UI on this device..."
ui_print "  This may take several minutes. Build log: $LOG"
"$INSTALL_DIR/bin/python" "$INSTALL_DIR/update.py" --no-restart >> "$LOG" 2>&1 \
  || abort "Hermes build failed; previous release preserved. See log."

# ── Verify ─────────────────────────────────────────
HM_VER=$("$INSTALL_DIR/bin/hermes" --version 2>&1) || abort "hermes version command failed: $HM_VER"
case "$HM_VER" in
  Hermes*) ui_print "- $HM_VER installed" ;;
  *) abort "hermes wrapper verification failed: $HM_VER" ;;
esac
log "hermes verified: $HM_VER"

# ── Default settings ───────────────────────────────
if [ ! -f "$INSTALL_DIR/settings.ini" ]; then
  cat > "$INSTALL_DIR/settings.ini" << 'INIEOF'
# HermesAndroid settings
[runtime]
install_dir=/data/adb/hermes

[daemon]
# Start hermes gateway on boot (true/false)
autostart=true
log_level=info
INIEOF
fi

# ── Cleanup ────────────────────────────────────────
pkill -f doh-proxy.py 2>/dev/null || true
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
log "DoH proxy stopped (service.sh restarts it on boot)"

rm -rf "$INSTALL_DIR/tmp"
mkdir -p "$INSTALL_DIR/tmp"

set_perm "$MODPATH/system/bin/hermes"         root root 0755
set_perm "$MODPATH/system/bin/hermes.service" root root 0755

echo "done" > "$INSTALL_DIR/.install_state"
chmod 600 "$INSTALL_DIR/.install_state"

log "===== Install complete ====="
ui_print ""
ui_print "  Installation completed!"
ui_print ""
ui_print "  After reboot, in a root shell (adb / Termux+su):"
ui_print "    su -c hermes setup        # configure provider"
ui_print "    su -c hermes status       # check status"
ui_print "    su -c hermes              # chat"
ui_print ""
ui_print "  Reboot to activate."
ui_print ""

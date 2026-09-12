#!/system/bin/sh
# ============================================================
# HermesAndroid — service.sh
# Runs on every boot (root context)
# 1) builds CA bundle if missing
# 2) starts DoH proxy + iptables DNS redirect
# 3) starts hermes gateway if autostart=true
# ============================================================

H="/data/adb/hermes"
LOG="$H/hermes.log"
STATE_FILE="$H/.install_state"
PY="$H/bin/python"
DOH_PORT=5353

ts() { date '+%H:%M:%S'; }

STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "not_installed")
if [ "$STATE" != "done" ]; then
  echo "[$(ts)] Install not complete (state=$STATE) — skipping" >> "$LOG"
  exit 0
fi

[ -x "$PY" ] || { echo "[$(ts)] python wrapper missing" >> "$LOG"; exit 1; }

# ── default route if missing ───────────────────────
if ! ip route show 2>/dev/null | grep -q "^default"; then
  for iface in rmnet_data1 rmnet_data0 rmnet_data3 wlan0 eth0; do
    if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
      ip route add default dev "$iface" 2>/dev/null && \
        echo "[$(ts)] default route via $iface" >> "$LOG" && break
    fi
  done
fi

# ── rebuild CA bundle if missing ───────────────────
if [ ! -s "$H/ca-bundle.pem" ]; then
  CADIR=/system/etc/security/cacerts
  [ -d "$CADIR" ] || CADIR=/apex/com.android.conscrypt/cacerts
  [ -d "$CADIR" ] && cat "$CADIR"/*.0 > "$H/ca-bundle.pem" 2>/dev/null
  echo "[$(ts)] CA bundle rebuilt: $(grep -c 'BEGIN CERTIFICATE' "$H/ca-bundle.pem" 2>/dev/null || echo 0) certs" >> "$LOG"
fi

# ── DoH proxy ──────────────────────────────────────
pkill -f doh-proxy.py 2>/dev/null || true
sleep 0.5
DOH_PORT=$DOH_PORT "$PY" "$H/doh-proxy.py" >> "$LOG" 2>&1 &
DOH_PID=$!
echo $DOH_PID > "$H/doh-proxy.pid"
sleep 2
if kill -0 $DOH_PID 2>/dev/null; then
  echo "[$(ts)] DoH proxy running PID=$DOH_PID" >> "$LOG"
else
  echo "[$(ts)] WARNING: DoH proxy failed to start" >> "$LOG"
fi

iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || true
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT
iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT
echo "[$(ts)] iptables DNS redirect 53->$DOH_PORT" >> "$LOG"

# ── hermes gateway ─────────────────────────────────
AUTOSTART=$(grep -o 'autostart=[a-z]*' "$H/settings.ini" 2>/dev/null | cut -d= -f2)
[ "$AUTOSTART" = "false" ] && { echo "[$(ts)] autostart=false — skipping gateway" >> "$LOG"; exit 0; }

# Dashboard (web UI on phone browser) — module bundles prebuilt web_dist,
# so --skip-build works without npm. Loopback bind; token is injected into
# the SPA HTML automatically.
DASH_PORT=9119
if ! curl -fs --max-time 3 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1; then
  echo "[$(ts)] starting dashboard on :$DASH_PORT" >> "$LOG"
  HOME="$H/home" TMPDIR="$H/tmp" \
  SSL_CERT_FILE="$H/ca-bundle.pem" SSL_CERT_DIR="$H/ca-dir" \
  HERMES_HOME="$H/home/.hermes" PYTHONUTF8=1 \
  HERMES_NODE="$H/node/bin/node" \
  PATH="$H/node/bin:$PATH" \
  HERMES_SKIP_NODE_BOOTSTRAP=1 \
  nohup "$H/bin/hermes" dashboard --skip-build --no-open \
      --host 127.0.0.1 --port $DASH_PORT >> "$H/dashboard.log" 2>&1 &
fi

# Expose CLI on root PATH (/data/adb/ksu/bin ships in every KSU root shell;
# /system overlay is NOT used — this device's KSU magic-mount doesn't materialize
# module system/ dirs, and Termux su shells don't see Magisk overlays anyway).
if [ -d /data/adb/ksu/bin ]; then
  ln -sf "$H/bin/hermes" /data/adb/ksu/bin/hermes
  ln -sf "$H/bin/python" /data/adb/ksu/bin/hermes-python
fi
# service controller (absolute path — MODDIR is not guaranteed on KSU)
SVC_SRC="/data/adb/modules/hermesandroid/system/bin/hermes.service"
if [ -f "$SVC_SRC" ] && [ -d /data/adb/ksu/bin ]; then
  cp "$SVC_SRC" /data/adb/ksu/bin/hermes.service
  chmod 755 /data/adb/ksu/bin/hermes.service
fi

echo "[$(ts)] starting hermes gateway..." >> "$LOG"
HOME="$H/home" TMPDIR="$H/tmp" \
SSL_CERT_FILE="$H/ca-bundle.pem" SSL_CERT_DIR="$H/ca-dir" \
HERMES_HOME="$H/home/.hermes" PYTHONUTF8=1 \
"$H/bin/hermes" gateway run >> "$LOG" 2>&1 &
GATEWAY_PID=$!
echo $GATEWAY_PID > "$H/gateway.pid"
echo "[$(ts)] gateway PID=$GATEWAY_PID" >> "$LOG"

exit 0

#!/system/bin/sh
# ============================================================
# HermesAndroid — action.sh
# Action button in Magisk/KSU manager:
# 1) ensures DoH proxy is running
# 2) starts hermes gateway if not running
# 3) opens dashboard in browser (if running)
# ============================================================

H="/data/adb/hermes"
LOG="$H/hermes.log"
PY="$H/bin/python"
DOH_PORT=5353

ui_print() { echo "$1"; }

ui_print "================================"
ui_print "   HermesAndroid — Action"
ui_print "================================"

[ -f "$H/.install_state" ] || { ui_print "Not installed yet — reflash module"; exit 1; }

# ── Ensure DoH proxy ───────────────────────────────
if ! pgrep -f doh-proxy.py >/dev/null 2>&1; then
  ui_print "- Starting DoH proxy..."
  DOH_PORT=$DOH_PORT "$PY" "$H/doh-proxy.py" >> "$LOG" 2>&1 &
  echo $! > "$H/doh-proxy.pid"
  sleep 2
  iptables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || \
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port $DOH_PORT
  iptables -t nat -C OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT 2>/dev/null || \
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port $DOH_PORT
  ui_print "  DoH proxy started"
else
  ui_print "- DoH proxy already running"
fi

# ── Gateway status / start ─────────────────────────
GATEWAY_RUNNING=false
if [ -f "$H/gateway.pid" ]; then
  PID=$(cat "$H/gateway.pid" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    GATEWAY_RUNNING=true
  fi
fi

if [ "$GATEWAY_RUNNING" = true ]; then
  ui_print "- Gateway running (PID $PID)"
else
  ui_print "- Starting hermes gateway..."
  HOME="$H/home" TMPDIR="$H/tmp" \
  SSL_CERT_FILE="$H/ca-bundle.pem" SSL_CERT_DIR="$H/ca-dir" \
  HERMES_HOME="$H/home/.hermes" PYTHONUTF8=1 \
  "$H/bin/hermes" gateway run >> "$LOG" 2>&1 &
  NEW_PID=$!
  echo $NEW_PID > "$H/gateway.pid"
  sleep 3
  if kill -0 $NEW_PID 2>/dev/null; then
    ui_print "  Gateway started (PID $NEW_PID)"
  else
    ui_print "  WARNING: gateway may have failed — check $LOG"
  fi
fi

# ── Dashboard: start if not running, then open ─────
DASH_PORT=9119
DASH_LOG="$H/dashboard.log"
if ! curl -fs --max-time 3 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1; then
  ui_print "- Starting dashboard..."
  HOME="$H/home" TMPDIR="$H/tmp" \
  SSL_CERT_FILE="$H/ca-bundle.pem" SSL_CERT_DIR="$H/ca-dir" \
  HERMES_HOME="$H/home/.hermes" PYTHONUTF8=1 \
  HERMES_NODE="$H/node/bin/node" \
  PATH="$H/node/bin:$PATH" \
  HERMES_SKIP_NODE_BOOTSTRAP=1 \
  nohup "$H/bin/hermes" dashboard --skip-build --no-open \
      --host 127.0.0.1 --port $DASH_PORT > "$DASH_LOG" 2>&1 &
  sleep 6
fi

if curl -fs --max-time 3 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1; then
  am start -a android.intent.action.VIEW -d "http://127.0.0.1:$DASH_PORT/chat" >/dev/null 2>&1
  ui_print "- Dashboard: http://127.0.0.1:$DASH_PORT/chat"
else
  ui_print "- Dashboard failed to start — check $DASH_LOG"
fi

ui_print ""
ui_print "CLI:  su -c hermes"
ui_print "Log:  su -c tail -f /data/adb/hermes/hermes.log"
ui_print ""
exit 0

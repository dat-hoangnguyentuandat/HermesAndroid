#!/system/bin/sh
# ============================================================
# HermesAndroid — uninstall.sh
# Runs when the module is removed from Magisk/KSU.
# Preserves /data/adb/hermes/home (user data: sessions, keys, memory)
# ============================================================
H="/data/adb/hermes"

# Stop everything
pkill -f doh-proxy.py 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-port 5353 2>/dev/null
iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5353 2>/dev/null

if [ -f "$H/gateway.pid" ]; then
  kill "$(cat "$H/gateway.pid")" 2>/dev/null
fi

# Remove CLI exposure
rm -f /data/adb/ksu/bin/hermes /data/adb/ksu/bin/hermes-python /data/adb/ksu/bin/hermes.service

# Remove runtime (re-downloadable)
rm -rf "$H/glibc"
rm -rf "$H/python"
rm -rf "$H/node"
rm -rf "$H/source-1.2.0"
rm -rf "$H/bin"
rm -rf "$H/tmp"
rm -rf "$H/ca-dir"
rm -f  "$H/.install_state"
rm -f  "$H/doh-proxy.py"
rm -f  "$H/doh-proxy.pid"
rm -f  "$H/sitecustomize.py"
rm -f  "$H/ca-bundle.pem"
rm -f  "$H/gateway.pid"
rm -f  "$H/settings.ini"
rm -f  "$H/install.log"
rm -f  "$H/hermes.log"

echo "HermesAndroid uninstalled. User data preserved at $H/home"

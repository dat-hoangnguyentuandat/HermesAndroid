#!/system/bin/sh
H=/data/adb/hermes
export HOME="$H/home" TMPDIR="$H/tmp" HERMES_HOME="${HERMES_HOME:-$H/home/.hermes}"
export SSL_CERT_FILE="$H/ca-bundle.pem" SSL_CERT_DIR="$H/ca-dir"
export HERMES_NODE="$H/node/bin/node" PYTHONUTF8=1 HERMES_SKIP_NODE_BOOTSTRAP=1
export NODE_OPTIONS="--require=$H/node-compat.cjs ${NODE_OPTIONS:-}"
export PATH="$H/bin:$H/node/bin:$PATH"
if [ "${1:-}" = update ]; then
  shift
  unset PYTHONPATH HERMES_RELEASE
  exec "$H/bin/python" "$H/update.py" "$@"
fi
if [ -f "$H/current/.ready" ]; then
  export PATH="$H/current/bin:$H/current/packages/bin:$PATH"
  exec "$H/current/bin/python" -m hermes_cli.main "$@"
fi
# Existing 1.2.0 install remains available until first activation / on rollback.
exec "$H/bin/python" "$H/python/bin/hermes" "$@"

#!/bin/sh
set -eu

mkdir -p /etc/sing-box
if [ -n "${CAC_PROXY_BRIDGE_CONFIG_B64:-}" ]; then
  python3 - <<'PY' > /etc/sing-box/config.json
import base64
import os
import sys

raw = os.environ.get("CAC_PROXY_BRIDGE_CONFIG_B64", "")
try:
    sys.stdout.write(base64.b64decode(raw).decode("utf-8"))
except Exception as exc:
    print(f"Failed to decode CAC_PROXY_BRIDGE_CONFIG_B64: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
else
  python3 -m ccimage.bridge > /etc/sing-box/config.json
fi

exec /usr/local/bin/sing-box run -c /etc/sing-box/config.json

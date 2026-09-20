#!/usr/bin/env bash
set -euo pipefail
IP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])')"
KEY=""
for i in 1 2 3; do
  KEY="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    ubuntu@"${IP}" sudo cat /var/lib/headscale/laptop-preauth.key 2>/dev/null | tr -d '\n' || true)"
  if [ -n "${KEY}" ]; then
    export KEY
    python3 -c 'import json,os; print(json.dumps({"key": os.environ["KEY"]}))'
    exit 0
  fi
  sleep 60
done
echo "laptop-preauth.key not ready after 3 attempts" >&2
exit 1

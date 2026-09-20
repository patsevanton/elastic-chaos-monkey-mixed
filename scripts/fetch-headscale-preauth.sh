#!/usr/bin/env bash
set -euo pipefail
IP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])')"

ssh_cmd() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    ubuntu@"${IP}" "$@"
}

ready=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if ssh_cmd cloud-init status --wait >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 30
done
if [ "${ready}" != 1 ]; then
  echo "cloud-init not ready after 10 attempts" >&2
  exit 1
fi

KEY=""
for i in 1 2 3 4 5; do
  KEY="$(ssh_cmd sudo cat /var/lib/headscale/laptop-preauth.key 2>/dev/null | tr -d '\n' || true)"
  if [ -n "${KEY}" ]; then
    export KEY
    python3 -c 'import json,os; print(json.dumps({"key": os.environ["KEY"]}))'
    exit 0
  fi
  sleep 30
done
echo "laptop-preauth.key not ready after 5 attempts" >&2
exit 1

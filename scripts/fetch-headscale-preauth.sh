#!/usr/bin/env bash
set -euo pipefail
IP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])')"

ssh_cmd() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    ubuntu@"${IP}" "$@"
}

KEY=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  KEY="$(ssh_cmd sudo cat /var/lib/headscale/laptop-preauth.key 2>/dev/null | tr -d '\n' || true)"
  if [ -n "${KEY}" ]; then
    export KEY
    python3 -c 'import json,os; print(json.dumps({"key": os.environ["KEY"]}))'
    exit 0
  fi
  echo "laptop-preauth.key not ready (attempt ${i}/10)" >&2
  sleep 30
done

echo "laptop-preauth.key not ready after 10 attempts" >&2
echo "--- cloud-init status ---" >&2
ssh_cmd cloud-init status >&2 || true
echo "--- /var/log/cloud-init-output.log (tail) ---" >&2
ssh_cmd sudo tail -n 80 /var/log/cloud-init-output.log >&2 || true
exit 1

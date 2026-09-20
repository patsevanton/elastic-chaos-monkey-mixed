#!/usr/bin/env bash
set -euo pipefail
IP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])')"

ssh_cmd() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    ubuntu@"${IP}" "$@"
}

ACTIVE=""
for i in $(seq 1 120); do
  ACTIVE="$(ssh_cmd sudo systemctl is-active headscale 2>/dev/null | tr -d '\n' || true)"
  if [ "${ACTIVE}" = "active" ]; then
    python3 -c 'import json,os; print(json.dumps({"ready": "true"}))'
    exit 0
  fi
  echo "headscale service not ready (${ACTIVE:-no-answer}, attempt ${i}/120)" >&2
  sleep 15
done

echo "headscale service did not become active in time (last status: ${ACTIVE})" >&2
echo "--- systemctl status headscale ---" >&2
ssh_cmd sudo systemctl status headscale --no-pager -l >&2 || true
echo "--- journalctl -u headscale (tail) ---" >&2
ssh_cmd sudo journalctl -u headscale --no-pager -n 80 >&2 || true
exit 1
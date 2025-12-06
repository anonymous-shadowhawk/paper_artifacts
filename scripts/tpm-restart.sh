#!/usr/bin/env bash
set -euo pipefail
STATE="${HOME}/ft-pac/tpmstate"
mkdir -p "${STATE}"
pkill -f "swtpm socket --tpm2" >/dev/null 2>&1 || true
swtpm socket --tpm2 \
  --tpmstate dir="${STATE}" \
  --server type=unixio,path=/tmp/swtpm.sock \
  --ctrl   type=unixio,path=/tmp/swtpm.sock.ctrl \
  --flags startup-clear --daemon
echo "TPM up at /tmp/swtpm.sock"

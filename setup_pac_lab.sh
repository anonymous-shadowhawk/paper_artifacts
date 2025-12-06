#!/usr/bin/env bash
set -euo pipefail

echo "=== PAC Lab Setup (TPM2 + swtpm + QEMU) ==="

if ! command -v lsb_release >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y lsb-release
fi
DISTRO="$(lsb_release -is 2>/dev/null || echo Ubuntu)"
REL="$(lsb_release -rs 2>/dev/null || echo 22.04)"
echo "Detected: ${DISTRO} ${REL}"

echo "[1/6] Enabling 'universe' and refreshing APT..."
sudo add-apt-repository -y universe || true
sudo apt-get update

echo "[2/6] Installing swtpm / tpm2-tools / tpm2 libraries..."
sudo apt-get install -y \
  swtpm swtpm-tools tpm2-tools \
  libtss2-mu0 libtss2-sys1 libtss2-rc0 libtss2-tctildr0 libtss2-fapi1 \
  libtss2-tcti-device0 libtss2-tcti-mssim0 libtss2-tcti-swtpm0 libtss2-tcti-cmd0 \
  libtss2-esys-3.0.2-0 \
  python3-pip

echo "[3/6] Installing QEMU (arm64) and helpers..."
sudo apt-get install -y \
  qemu-system qemu-system-arm qemu-system-misc qemu-utils \
  ovmf qemu-efi-aarch64

echo "[4/6] Verifying toolchain..."
tpm2_getrandom --version || { echo "tpm2-tools missing"; exit 1; }
qemu-system-aarch64 --version | head -n1
dpkg -l | egrep -i 'swtpm|tpm2-tools|libtss2|qemu-system' || true

echo "[5/6] Starting software TPM (swtpm) daemon..."
mkdir -p "${HOME}/pac-lab/tpmstate"

pkill -f "swtpm socket --tpm2" >/dev/null 2>&1 || true

swtpm socket --tpm2 \
  --tpmstate dir="${HOME}/pac-lab/tpmstate" \
  --server type=unixio,path=/tmp/swtpm.sock \
  --ctrl   type=unixio,path=/tmp/swtpm.sock.ctrl \
  --flags startup-clear \
  --daemon

echo "[6/6] Wiring TPM2TOOLS_TCTI env var..."
export TPM2TOOLS_TCTI="swtpm:path=/tmp/swtpm.sock"
if ! grep -q 'TPM2TOOLS_TCTI=' "${HOME}/.bashrc"; then
  echo 'export TPM2TOOLS_TCTI="swtpm:path=/tmp/swtpm.sock"' >> "${HOME}/.bashrc"
fi

echo "Testing TPM..."
tpm2_startup -c
tpm2_getrandom 8 >/dev/null
tpm2_pcrread sha256:0 >/dev/null

cat <<'EOF'

=== PAC Lab Ready ===
Next steps:
  tpm2_startup -c
  tpm2_getrandom 8
  tpm2_pcrread sha256:0,1

QEMU launch example:
  qemu-system-aarch64 -M virt -cpu cortex-a57 -m 2048 -nographic \
    -chardev socket,id=chrtpm,path=/tmp/swtpm.sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -kernel u-boot.elf

To restart TPM:
  pkill -f "swtpm socket --tpm2" || true
  swtpm socket --tpm2 --tpmstate dir="$HOME/pac-lab/tpmstate" \
    --server type=unixio,path=/tmp/swtpm.sock \
    --ctrl   type=unixio,path=/tmp/swtpm.sock.ctrl \
    --flags startup-clear --daemon
EOF

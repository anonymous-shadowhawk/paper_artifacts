#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == "ft-pac" ]]; then
    FT="$(dirname "$SCRIPT_DIR")"
else
    FT="$SCRIPT_DIR"
fi

TPMSOCK="/tmp/swtpm_fault_${RANDOM}.sock"
TPMSTATE="/tmp/tpm-state-${RANDOM}"

rm -f "$TPMSOCK"
rm -rf "$TPMSTATE"
mkdir -p "$TPMSTATE"

swtpm socket \
    --tpmstate dir="$TPMSTATE" \
    --tpm2 \
    --ctrl type=unixio,path="$TPMSOCK" \
    --log level=0 \
    --daemon 2>/dev/null || true

sleep 1

TPM_OPTS=""
if [ -S "$TPMSOCK" ]; then
    TPM_OPTS="-chardev socket,id=chrtpm,path=$TPMSOCK -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0"
fi

MONITOR_SOCK="/tmp/qemu-monitor-${RANDOM}.sock"
rm -f "$MONITOR_SOCK"

exec qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a72 \
  -m 1024 \
  -nographic \
  -monitor unix:$MONITOR_SOCK,server,nowait \
  -serial stdio \
  -kernel "$FT/boot/fit/Image" \
  -initrd "$FT/tier1_initramfs/img/pac_initramfs.cpio.gz" \
  -append "console=ttyAMA0 earlycon loglevel=4 rdinit=/init" \
  -drive if=none,id=drv0,file="$FT/boot/fit/fake.img",format=raw,file.locking=off \
  -device virtio-blk-pci,drive=drv0 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -virtfs local,path=/tmp,mount_tag=host_tmp,security_model=none,id=host_tmp \
  $TPM_OPTS

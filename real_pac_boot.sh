#!/bin/bash

set -e

FT=~/ft-pac

clear
echo "PAC REAL BOOT - Full Interactive"
echo ""
echo "Controls:"
echo "  Ctrl+A then X : Exit QEMU"
echo "  Type 'poweroff' : Shutdown"
echo ""
echo "Boot files:"
echo "  Kernel:    $(ls -lh $FT/boot/fit/Image | awk '{print $5}')"
echo "  Initramfs: $(ls -lh $FT/tier1_initramfs/img/pac_initramfs.cpio.gz | awk '{print $5}')"
echo ""

TPMSOCK="/tmp/swtpm.sock"
rm -f "$TPMSOCK"
mkdir -p /tmp/tpm-state

echo "Starting TPM 2.0 emulator..."
swtpm socket \
    --tpmstate dir=/tmp/tpm-state \
    --tpm2 \
    --ctrl type=unixio,path="$TPMSOCK" \
    --log level=0 \
    --daemon 2>/dev/null || {
        echo "  TPM emulator failed (continuing without TPM)"
    }

if [ -S "$TPMSOCK" ]; then
    echo "  TPM emulator running"
    sleep 2
fi

echo ""
echo "STARTING PAC BOOT..."
echo ""
sleep 2

TPM_OPTS=""
if [ -S "$TPMSOCK" ]; then
    TPM_OPTS="-chardev socket,id=chrtpm,path=$TPMSOCK -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0"
fi

qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a72 \
  -m 1024 \
  -nographic \
  -serial mon:stdio \
  -kernel "$FT/boot/fit/Image" \
  -initrd "$FT/tier1_initramfs/img/pac_initramfs.cpio.gz" \
  -append "console=ttyAMA0 earlycon loglevel=4 rdinit=/init" \
  -drive if=none,id=drv0,file="$FT/boot/fit/fake.img",format=raw \
  -device virtio-blk-pci,drive=drv0 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  $TPM_OPTS

echo ""
echo "PAC Boot Session Ended"
echo ""

if [ -S "$TPMSOCK" ]; then
    echo "Stopping TPM emulator..."
    pkill -f "swtpm.*$TPMSOCK" 2>/dev/null || true
    rm -f "$TPMSOCK"
fi

echo "Done."

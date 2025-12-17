#!/usr/bin/env bash
set -euo pipefail
TPMSOCK="/tmp/swtpm.sock"
KIMG="${HOME}/ft-pac/boot/fit/Image"
INITRD="${HOME}/ft-pac/tier1_initramfs/img/initramfs.cpio.gz"
DTB="${HOME}/ft-pac/boot/fit/virt.dtb"
DISK="${HOME}/ft-pac/boot/fit/fake.img"

exec qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a72 \
  -m 1024 \
  -nographic \
  -kernel "${KIMG}" \
  -initrd "${INITRD}" \
  -dtb "${DTB}" \
  -append "console=ttyAMA0 earlycon rdinit=/init" \
  -drive if=none,id=drv0,file="${DISK}",format=raw \
  -device virtio-blk-pci,drive=drv0 \
  -chardev socket,id=chrtpm,path="${TPMSOCK}" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis-device,tpmdev=tpm0

#!/usr/bin/env bash
set -euo pipefail
FT="${HOME}/ft-pac"
TPMSOCK="/tmp/swtpm.sock"
UBOOT="${FT}/boot/u-boot/src/u-boot.elf"
FIT="${FT}/boot/fit/fit.itb"
DISK="${FT}/boot/fit/fake.img"

exec qemu-system-aarch64 \\
  -machine virt,gic-version=3 \\
  -cpu cortex-a57 \\
  -m 2048 \\
  -nographic \\
  -kernel "${UBOOT}" \\
  -append "console=ttyAMA0" \\
  -device virtio-blk-p,drive=drv0 \\
  -drive if=none,id=drv0,file="${DISK}",format=raw \\
  -chardev socket,id=chrtpm,path="${TPMSOCK}" \\
  -tpmdev emulator,id=tpm0,chardev=chrtpm \\
  -device tpm-tis,tpmdev=tpm0 \\
  -fsdev local,security_model=none,id=fsdev0,path="${FT}" \\
  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=host \\
  -no-reboot

# In U-Boot:
# => host bind 0 /host
# => load host 0:0 \${loadaddr} /host/boot/fit/fit.itb
# => bootm \${loadaddr}

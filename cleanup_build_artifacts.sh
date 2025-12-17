#!/bin/bash
set -e

FT="${HOME}/ft-pac"
cd "$FT"

echo "Cleaning ft-pac for GitHub..."

echo "  Removing external source repos..."
rm -rf kernel/src
rm -rf openssl/src
rm -rf boot/u-boot/src
rm -rf tier1_initramfs/src

echo "  Removing openssl install binary (will be rebuilt)..."
rm -f openssl/install/bin/openssl 2>/dev/null || true

echo "  Removing build artifacts..."
find . -type f \( -name "*.o" -o -name "*.a" -o -name "*.so" -o -name "*.ko" -o -name "*.cmd" -o -name "*.map" -o -name "*.out" \) -delete 2>/dev/null || true
find . -type d -name ".tmp_versions" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name ".output" -exec rm -rf {} + 2>/dev/null || true

echo "  Removing generated images..."
rm -rf boot/fit/*.img boot/fit/*.itb boot/fit/*.dtb boot/fit/Image boot/fit/initramfs.cpio.gz 2>/dev/null || true
rm -rf tier1_initramfs/img/*.gz tier1_initramfs/img/*.cpio 2>/dev/null || true
rm -rf tier1_initramfs/*.tar.gz 2>/dev/null || true
rm -rf tier2/img/* tier2/*.ext4 tier2/*.verity tier2/*.roothash tier2/*.img 2>/dev/null || true
rm -rf tier3/img/* tier3/*.img 2>/dev/null || true
rm -rf iso/*.iso iso/build/* 2>/dev/null || true

echo "  Removing binaries from rootfs (will be rebuilt)..."
find tier1_initramfs/rootfs -type f -executable \( -name "busybox" -o -name "journal_tool" -o -name "openssl" -o -name "bash" \) -delete 2>/dev/null || true
rm -rf tier1_initramfs/rootfs/tier2 tier1_initramfs/rootfs/tier3 2>/dev/null || true
rm -f tier1_initramfs/img/*.bak 2>/dev/null || true
echo "  Preserving lib directory (needed for OpenSSL)..."

echo "  Removing binaries and libraries from build (will be rebuilt)..."
find tier1_initramfs/build -type f -executable \( -name "busybox" -o -name "openssl" -o -name "bash" \) -delete 2>/dev/null || true
find tier1_initramfs/build -type f -name "*.so*" -delete 2>/dev/null || true
rm -rf tier1_initramfs/build/lib tier1_initramfs/build/lib64 tier1_initramfs/build/tier2 tier1_initramfs/build/tier3 2>/dev/null || true
mkdir -p tier1_initramfs/build/bin
cp -f journal/journal_tool_arm64 tier1_initramfs/build/bin/journal_tool 2>/dev/null || true
chmod +x tier1_initramfs/build/bin/journal_tool 2>/dev/null || true

echo "  Removing binaries from tier2/rootfs (will be rebuilt)..."
rm -rf tier2/rootfs/bin tier2/rootfs/sbin tier2/rootfs/usr/bin tier2/rootfs/lib tier2/rootfs/lib64 2>/dev/null || true

echo "  Removing binaries from tier3/rootfs (will be rebuilt)..."
rm -rf tier3/rootfs/bin tier3/rootfs/sbin tier3/rootfs/usr/bin tier3/rootfs/lib tier3/rootfs/lib64 2>/dev/null || true

echo "  Removing .git from external repos..."
rm -rf boot/u-boot/.git tier1_initramfs/.git 2>/dev/null || true

echo "  Removing runtime state..."
rm -rf var/* tpmstate/* 2>/dev/null || true

echo "  Removing logs and temp files..."
find . -type f -name "*.log" -delete 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

echo "  Recreating essential directories..."
mkdir -p kernel/src kernel/build kernel/config
mkdir -p openssl/src openssl/install
mkdir -p boot/u-boot/src boot/fit
mkdir -p tier1_initramfs/src tier1_initramfs/img tier1_initramfs/build tier1_initramfs/rootfs
mkdir -p tier2/img tier2/rootfs
mkdir -p tier3/img tier3/rootfs
mkdir -p iso/build
mkdir -p var/pac tpmstate

echo "Done."
du -sh .


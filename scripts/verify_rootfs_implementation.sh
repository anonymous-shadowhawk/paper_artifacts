#!/bin/bash

set -e

FT=~/ft-pac

echo ""
echo "    VERIFYING TIER 2/3 ROOTFS IMPLEMENTATION                       "
echo ""
echo ""

echo ""
echo "TIER 2 ROOTFS VERIFICATION"
echo ""

TIER2_ROOTFS="${FT}/tier2/img/tier2.ext4"
TIER2_VERITY="${FT}/tier2/img/tier2.verity"
TIER2_HASH="${FT}/tier2/img/tier2.roothash"
TIER2_INITRAMFS="${FT}/tier1_initramfs/rootfs/tier2/rootfs.img"
TIER2_VERITY_INITRAMFS="${FT}/tier1_initramfs/rootfs/tier2/verity.img"
TIER2_HASH_INITRAMFS="${FT}/tier1_initramfs/rootfs/tier2/verity.roothash"

if [ -f "$TIER2_ROOTFS" ]; then
    SIZE=$(du -h "$TIER2_ROOTFS" | cut -f1)
    echo "   Tier 2 rootfs image exists: $TIER2_ROOTFS ($SIZE)"
else
    echo "   Tier 2 rootfs image NOT FOUND: $TIER2_ROOTFS"
fi

if [ -f "$TIER2_VERITY" ]; then
    SIZE=$(du -h "$TIER2_VERITY" | cut -f1)
    echo "   Tier 2 verity metadata exists: $TIER2_VERITY ($SIZE)"
else
    echo "   Tier 2 verity metadata NOT FOUND: $TIER2_VERITY"
fi

if [ -f "$TIER2_HASH" ]; then
    HASH=$(cat "$TIER2_HASH" | tr -d ' \n')
    echo "   Tier 2 root hash exists: ${HASH:0:32}..."
else
    echo "   Tier 2 root hash NOT FOUND: $TIER2_HASH"
fi

if [ -f "$TIER2_INITRAMFS" ]; then
    SIZE=$(du -h "$TIER2_INITRAMFS" | cut -f1)
    echo "   Tier 2 rootfs in initramfs: $TIER2_INITRAMFS ($SIZE)"
else
    echo "   Tier 2 rootfs NOT in initramfs: $TIER2_INITRAMFS"
fi

if [ -f "$TIER2_VERITY_INITRAMFS" ]; then
    echo "   Tier 2 verity metadata in initramfs"
else
    echo "   Tier 2 verity metadata NOT in initramfs (optional)"
fi

if [ -f "$TIER2_HASH_INITRAMFS" ]; then
    echo "   Tier 2 root hash in initramfs"
else
    echo "   Tier 2 root hash NOT in initramfs (optional)"
fi

echo ""
echo ""
echo "TIER 3 ROOTFS VERIFICATION"
echo ""

TIER3_ROOTFS="${FT}/tier3/img/tier3.ext4"
TIER3_IMA_PRIV="${FT}/tier3/keys/ima_priv.pem"
TIER3_IMA_PUB="${FT}/tier3/keys/ima_pub.pem"
TIER3_INITRAMFS="${FT}/tier1_initramfs/rootfs/tier3/rootfs.img"
TIER3_IMA_INITRAMFS="${FT}/tier1_initramfs/rootfs/tier3/keys/ima_pub.pem"

if [ -f "$TIER3_ROOTFS" ]; then
    SIZE=$(du -h "$TIER3_ROOTFS" | cut -f1)
    echo "   Tier 3 rootfs image exists: $TIER3_ROOTFS ($SIZE)"
else
    echo "   Tier 3 rootfs image NOT FOUND: $TIER3_ROOTFS"
fi

if [ -f "$TIER3_IMA_PRIV" ]; then
    echo "   Tier 3 IMA private key exists"
else
    echo "   Tier 3 IMA private key NOT FOUND: $TIER3_IMA_PRIV"
fi

if [ -f "$TIER3_IMA_PUB" ]; then
    echo "   Tier 3 IMA public key exists"
else
    echo "   Tier 3 IMA public key NOT FOUND: $TIER3_IMA_PUB"
fi

if [ -f "$TIER3_INITRAMFS" ]; then
    SIZE=$(du -h "$TIER3_INITRAMFS" | cut -f1)
    echo "   Tier 3 rootfs in initramfs: $TIER3_INITRAMFS ($SIZE)"
else
    echo "   Tier 3 rootfs NOT in initramfs: $TIER3_INITRAMFS"
fi

if [ -f "$TIER3_IMA_INITRAMFS" ]; then
    echo "   Tier 3 IMA public key in initramfs"
else
    echo "   Tier 3 IMA public key NOT in initramfs (optional)"
fi

echo ""
echo ""
echo "INIT SCRIPT VERIFICATION"
echo ""

INIT_SCRIPT="${FT}/tier1_initramfs/rootfs/init"

if [ -f "$INIT_SCRIPT" ]; then
    echo "   Init script exists: $INIT_SCRIPT"
    
    if grep -q "TIER 2 ROOTFS MOUNT" "$INIT_SCRIPT"; then
        echo "   Init script contains Tier 2 rootfs mount logic"
    else
        echo "   Init script missing Tier 2 rootfs mount logic"
    fi
    
    if grep -q "TIER 3 ROOTFS MOUNT" "$INIT_SCRIPT"; then
        echo "   Init script contains Tier 3 rootfs mount logic"
    else
        echo "   Init script missing Tier 3 rootfs mount logic"
    fi
    
    if grep -q "switch_root" "$INIT_SCRIPT"; then
        echo "   Init script contains switch_root (pivot logic)"
    else
        echo "   Init script missing switch_root (pivot logic)"
    fi
else
    echo "   Init script NOT FOUND: $INIT_SCRIPT"
fi

echo ""
echo ""
echo "SUMMARY"
echo ""

TIER2_OK=0
TIER3_OK=0

[ -f "$TIER2_ROOTFS" ] && [ -f "$TIER2_INITRAMFS" ] && TIER2_OK=1
[ -f "$TIER3_ROOTFS" ] && [ -f "$TIER3_INITRAMFS" ] && TIER3_OK=1

if [ $TIER2_OK -eq 1 ] && [ $TIER3_OK -eq 1 ]; then
    echo "   Tier 2 and Tier 3 rootfs are properly implemented!"
    echo ""
    echo "  To verify at runtime:"
    echo "    1. Boot the system"
    echo "    2. Look for 'TIER 2 ROOTFS MOUNT' section in boot log"
    echo "    3. Look for 'TIER 3 ROOTFS MOUNT' section in boot log"
    echo "    4. Check if system pivots to separate rootfs (prompt changes)"
    exit 0
else
    echo "   Some components are missing. Run ~/Documents/PAC/tmp.sh to rebuild."
    exit 1
fi


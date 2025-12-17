#!/bin/bash

JOURNAL_PATH="${HOME}/ft-pac/tier1_initramfs/build/var/pac/journal.dat"

echo ""
echo "              Reset PAC Boot Journal to Tier 1                   "
echo ""
echo ""

if [ -f "$JOURNAL_PATH" ]; then
    echo "Found journal: $JOURNAL_PATH"
    echo ""
    echo "Current state:"
    "${HOME}/ft-pac/tier1_initramfs/build/bin/journal_tool" read "$JOURNAL_PATH" 2>/dev/null | grep -E "Tier:|Boot Count:" || echo "  (unable to read)"
    echo ""
    
    read -p "Reset journal to Tier 1? (y/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$JOURNAL_PATH"
        echo " Journal deleted - will be recreated at Tier 1 on next boot"
        echo ""
        echo "Next boot sequence:"
        echo "  Boot 1: Tier 1 -> Tier 2"
        echo "  Boot 2: Tier 2 -> Tier 3"
        echo "  Boot 3+: Tier 3 (steady state)"
    else
        echo " Journal not modified"
    fi
else
    echo " No journal found - will be created at Tier 1 on next boot"
fi

echo ""


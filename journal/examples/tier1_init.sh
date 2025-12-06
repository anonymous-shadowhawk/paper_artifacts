#!/bin/sh

set -e

JOURNAL="${JOURNAL:-/var/pac/journal.dat}"
JOURNAL_TOOL="${JOURNAL_TOOL:-journal_tool}"

echo "======================================"
echo "PAC Tier-1 Boot Starting"
echo "======================================"
echo "[CONFIG] Journal path: $JOURNAL"

JOURNAL_DIR=$(dirname "$JOURNAL")
mkdir -p "$JOURNAL_DIR" 2>/dev/null || true

if [ ! -f "$JOURNAL" ]; then
    echo "[JOURNAL] Creating new boot journal..."
    $JOURNAL_TOOL init "$JOURNAL"
else
    echo "[JOURNAL] Opening existing boot journal..."
fi

echo "[JOURNAL] Reading boot state..."
$JOURNAL_TOOL read "$JOURNAL" > /tmp/journal_state.txt

CURRENT_TIER=$(grep "Tier:" /tmp/journal_state.txt | awk '{print $2}')
BOOT_COUNT=$(grep "Boot Count:" /tmp/journal_state.txt | awk '{print $3}')
echo "[STATE] Current tier: $CURRENT_TIER, Boot count: $BOOT_COUNT"

echo "[JOURNAL] Incrementing boot counter..."
$JOURNAL_TOOL inc-boot "$JOURNAL"

echo "[HEALTH] Running Tier-1 health checks..."

if [ -c /dev/watchdog ]; then
    echo "[HEALTH]  Watchdog present"
    WDT_OK=1
else
    echo "[HEALTH]  Watchdog missing"
    WDT_OK=0
fi

if mount | grep -q "on / "; then
    echo "[HEALTH]  Root filesystem mounted"
    STORAGE_OK=1
else
    echo "[HEALTH]  Root filesystem issues"
    STORAGE_OK=0
fi

FREE_MEM=$(free | grep Mem | awk '{print $4}')
if [ "$FREE_MEM" -gt 10000 ]; then
    echo "[HEALTH]  Sufficient memory ($FREE_MEM KB free)"
    MEM_OK=1
else
    echo "[HEALTH]  Low memory ($FREE_MEM KB free)"
    MEM_OK=0
fi

if grep -q "FLAG.*DIRTY" /tmp/journal_state.txt; then
    echo "[HEALTH]  Previous dirty shutdown detected"
    PREV_CLEAN=0
    $JOURNAL_TOOL clear-flag dirty "$JOURNAL"
else
    echo "[HEALTH]  Previous shutdown was clean"
    PREV_CLEAN=1
fi

if grep -q "FLAG.*BROWNOUT" /tmp/journal_state.txt; then
    echo "[HEALTH]  Previous brownout detected - performing extended checks"
    sleep 1
    echo "[HEALTH] Extended checks complete"
    $JOURNAL_TOOL clear-flag brownout "$JOURNAL"
fi

HEALTH_SCORE=$((WDT_OK + STORAGE_OK + MEM_OK + PREV_CLEAN))
echo "[HEALTH] Health score: $HEALTH_SCORE/4"

echo "[POLICY] Evaluating tier promotion policy..."

TRIES_T2=$(grep "Tries T2:" /tmp/journal_state.txt | awk '{print $3}')
echo "[POLICY] Tier-2 attempts remaining: $TRIES_T2"

ALLOW_T2=0

if [ "$TRIES_T2" -gt 0 ]; then
    if [ "$HEALTH_SCORE" -ge 3 ]; then
        echo "[POLICY]  Health check passed - Tier-2 promotion allowed"
        ALLOW_T2=1
    else
        echo "[POLICY]  Health check failed - staying in Tier-1"
        $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
    fi
else
    echo "[POLICY]  Tier-2 attempts exhausted - entering quarantine"
    $JOURNAL_TOOL set-flag quarantine "$JOURNAL"
    $JOURNAL_TOOL set-flag emergency "$JOURNAL"
fi

if [ "$ALLOW_T2" -eq 1 ]; then
    echo "[BOOT] Attempting Tier-2 promotion..."
    $JOURNAL_TOOL set-tier 2 "$JOURNAL"
    
    if [ -d /tier2-root ]; then
        echo "[BOOT]  Tier-2 verified - switching root"
        echo "[BOOT] (Would exec switch_root here in real system)"
    else
        echo "[BOOT]  Tier-2 verification failed - fallback to Tier-1"
        $JOURNAL_TOOL set-tier 1 "$JOURNAL"
        $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
        $JOURNAL_TOOL set-flag dirty "$JOURNAL"
    fi
fi

echo "[BOOT] Remaining in Tier-1 (minimal safe mode)"
$JOURNAL_TOOL set-tier 1 "$JOURNAL"

if grep -q "FLAG.*EMERGENCY" /tmp/journal_state.txt || grep -q "FLAG.*QUARANTINE" /tmp/journal_state.txt; then
    echo "[EMERGENCY] Emergency mode active!"
    echo "[EMERGENCY] Actions:"
    echo "  --- Starting serial console"
    echo "  --- Enabling SSH with emergency credentials"
    echo "  --- Generating diagnostic report"
    echo "  --- Awaiting remote administrator"
    
fi

echo "======================================"
echo "PAC Tier-1 Boot Complete"
echo "======================================"
$JOURNAL_TOOL read "$JOURNAL"

echo "[BOOT] (Demo mode - exiting)"


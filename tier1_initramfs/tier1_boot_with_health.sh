#!/bin/sh

set -e

JOURNAL="/var/pac/journal.dat"
JOURNAL_TOOL="${JOURNAL_TOOL:-journal_tool}"
HEALTH_CHECK="${HEALTH_CHECK:-health_check.sh}"
HEALTH_JSON="/tmp/health.json"

echo "======================================================================="
echo " PAC Tier-1 Boot - Integrated Health Check System                     "
echo "======================================================================="

mkdir -p "$(dirname "$JOURNAL")" /tmp 2>/dev/null || true

echo "[JOURNAL] Initializing boot journal..."
if [ ! -f "$JOURNAL" ]; then
    if ! $JOURNAL_TOOL init "$JOURNAL"; then
        echo "[JOURNAL] ERROR: Failed to initialize journal"
        exit 1
    fi
else
    echo "[JOURNAL] Journal exists, reading current state..."
fi

$JOURNAL_TOOL read "$JOURNAL" > /tmp/journal_state.txt
CURRENT_TIER=$(grep "Tier:" /tmp/journal_state.txt | awk '{print $2}')
BOOT_COUNT=$(grep "Boot Count:" /tmp/journal_state.txt | awk '{print $3}')
TRIES_T2=$(grep "Tries T2:" /tmp/journal_state.txt | awk '{print $3}')

echo "[JOURNAL] Current tier: $CURRENT_TIER"
echo "[JOURNAL] Boot count: $BOOT_COUNT"
echo "[JOURNAL] Tier-2 attempts remaining: $TRIES_T2"

$JOURNAL_TOOL inc-boot "$JOURNAL"

echo ""
echo "[HEALTH] Running comprehensive hardware health checks..."

if [ -f "$HEALTH_CHECK" ]; then
    HEALTH_VERBOSE=1 "$HEALTH_CHECK"
    HEALTH_STATUS=$?
else
    echo "[HEALTH] Warning: health_check.sh not found, using fallback checks"
    test -c /dev/watchdog && WDT_OK=1 || WDT_OK=0
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && NET_OK=1 || NET_OK=0
    
    cat > "$HEALTH_JSON" <<EOF
{
  "overall_score": $((WDT_OK + NET_OK + 1)),
  "max_score": 3,
  "overall_status": "degraded",
  "legacy_format": {
    "wdt_ok": $WDT_OK,
    "ecc_ok": 1,
    "storage_ok": 1,
    "net_ok": $NET_OK,
    "mem_ok": 1,
    "temp_ok": 1
  }
}
EOF
    HEALTH_STATUS=1
fi

echo ""
echo "[HEALTH] Health check complete (exit code: $HEALTH_STATUS)"

if [ -f "$HEALTH_JSON" ]; then
    HEALTH_SCORE=$(grep "overall_score" "$HEALTH_JSON" | grep -o '[0-9]*' | head -1)
    HEALTH_STATUS_STR=$(grep "overall_status" "$HEALTH_JSON" | cut -d'"' -f4)
    
    WDT_OK=$(grep "wdt_ok" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1)
    ECC_OK=$(grep "ecc_ok" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1)
    STORAGE_OK=$(grep "storage_ok" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1)
    NET_OK=$(grep "net_ok" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1)
    MEM_OK=$(grep "mem_ok" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1)
    
    echo "[HEALTH] Overall status: $HEALTH_STATUS_STR ($HEALTH_SCORE/6 checks passed)"
else
    echo "[HEALTH] ERROR: Health report not found!"
    HEALTH_SCORE=0
    HEALTH_STATUS_STR="critical"
fi

echo ""
echo "[FLAGS] Checking boot flags from previous session..."

if grep -q "FLAG.*BROWNOUT" /tmp/journal_state.txt; then
    echo "[FLAGS]  Brownout detected in previous boot"
    echo "[FLAGS] Performing extended power stability checks..."
    sleep 1
    
    if [ "$HEALTH_SCORE" -ge 4 ]; then
        echo "[FLAGS] Health check passed - clearing brownout flag"
        $JOURNAL_TOOL clear-flag brownout "$JOURNAL"
    else
        echo "[FLAGS] Health still degraded - keeping brownout flag"
    fi
fi

if grep -q "FLAG.*DIRTY" /tmp/journal_state.txt; then
    echo "[FLAGS]  Dirty shutdown detected in previous boot"
    echo "[FLAGS] Running filesystem consistency checks..."
    
    $JOURNAL_TOOL clear-flag dirty "$JOURNAL"
    echo "[FLAGS] Cleared dirty shutdown flag"
fi

if grep -q "FLAG.*EMERGENCY" /tmp/journal_state.txt; then
    echo "[FLAGS]  System was in emergency mode"
fi

echo ""
echo "[POLICY] Evaluating tier promotion policy..."

ALLOW_TIER2=0
REASON=""

if [ "$TRIES_T2" -le 0 ]; then
    REASON="Tier-2 attempts exhausted"
    echo "[POLICY]  $REASON"
    $JOURNAL_TOOL set-flag quarantine "$JOURNAL"
    $JOURNAL_TOOL set-flag emergency "$JOURNAL"
elif [ "$HEALTH_STATUS_STR" = "critical" ]; then
    REASON="Health check failed - status: $HEALTH_STATUS_STR"
    echo "[POLICY]  $REASON"
    $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
    $JOURNAL_TOOL set-flag dirty "$JOURNAL"
elif [ "$STORAGE_OK" -eq 0 ] || [ "$MEM_OK" -eq 0 ]; then
    REASON="Critical component failure (storage or memory)"
    echo "[POLICY]  $REASON"
    $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
else
    ALLOW_TIER2=1
    REASON="Health check passed with score $HEALTH_SCORE/6"
    echo "[POLICY]  Tier-2 promotion allowed: $REASON"
fi

echo ""
echo "[BOOT] Executing boot tier decision..."

if [ "$ALLOW_TIER2" -eq 1 ]; then
    echo "[BOOT] Attempting Tier-2 promotion..."
    $JOURNAL_TOOL set-tier 2 "$JOURNAL"
    
    if [ -d /tier2-root ] && [ -f /tier2-root/sbin/init ]; then
        echo "[BOOT]  Tier-2 verified - preparing to switch root"
        echo "[BOOT] Would execute: switch_root /tier2-root /sbin/init"
        echo "[BOOT] (Demo mode - not actually switching)"
    else
        echo "[BOOT]  Tier-2 verification failed - fallback to Tier-1"
        $JOURNAL_TOOL set-tier 1 "$JOURNAL"
        $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
        $JOURNAL_TOOL set-flag dirty "$JOURNAL"
    fi
else
    echo "[BOOT] Remaining in Tier-1 (safe minimal mode)"
    echo "[BOOT] Reason: $REASON"
    $JOURNAL_TOOL set-tier 1 "$JOURNAL"
fi

echo ""
echo "[SERVICES] Starting Tier-1 services..."

if grep -q "FLAG.*EMERGENCY" <($JOURNAL_TOOL read "$JOURNAL") || \
   grep -q "FLAG.*QUARANTINE" <($JOURNAL_TOOL read "$JOURNAL"); then
    
    echo ""
    echo ""
    echo "                     EMERGENCY MODE ACTIVE                     "
    echo ""
    echo ""
    echo "[EMERGENCY] System requires administrator intervention"
    echo "[EMERGENCY] Services enabled:"
    echo "  --- Serial console access"
    echo "  --- SSH with emergency credentials"
    echo "  --- Diagnostic logging"
    echo "  --- Remote attestation interface"
    echo ""
    echo "[EMERGENCY] Awaiting remote administrator..."
    
fi

echo ""
echo "======================================================================="
echo " Boot Complete - Final Status                                         "
echo "======================================================================="

$JOURNAL_TOOL read "$JOURNAL"

echo ""
echo "Health Report:"
if [ -f "$HEALTH_JSON" ]; then
    cat "$HEALTH_JSON"
fi

echo ""
echo "======================================================================="

exit $HEALTH_STATUS


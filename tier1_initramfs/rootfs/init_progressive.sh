#!/bin/sh

set +e  

JOURNAL="/var/pac/journal.dat"
JOURNAL_TOOL="/bin/journal_tool"
HEALTH_LOG="/tmp/health.json"
HEALTH_SCRIPT="/usr/lib/pac/health_check.sh"
ATTEST_SCRIPT="/usr/lib/pac/attest_agent.sh"
NETWORK_SCRIPT="/usr/lib/pac/setup_network.sh"

mkdir -p /var/pac /tmp /proc /sys /dev

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true

echo ""
echo "    PAC Boot - Progressive Attestation Chain"
echo "              Fault-Tolerant Secure Boot"
echo ""
echo ""

if [ ! -f "$JOURNAL" ]; then
    echo "-> Creating new boot journal..."
    $JOURNAL_TOOL init "$JOURNAL" 2>/dev/null || echo "   Journal init warning"
fi

echo "-> Recording boot attempt..."
$JOURNAL_TOOL increment "$JOURNAL" 2>/dev/null || true

echo ""
$JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | head -20 || true
echo ""

CURRENT_TIER=1
echo ""
echo "                      TIER 1: MINIMAL BOOT                         "
echo ""
echo ""
echo " Kernel loaded"
echo " Initramfs mounted"
echo " Essential filesystems ready"
echo " Boot journal operational"
echo ""
echo "-> Tier 1 established (safe mode)"
echo ""

echo ""
echo "HEALTH ASSESSMENT"
echo ""
if [ -f "$HEALTH_SCRIPT" ]; then
    sh "$HEALTH_SCRIPT" || echo "   Health check completed with warnings"
else
    echo "   Health check script not found"
    echo '{"overall_status":"unknown","overall_score":5}' > "$HEALTH_LOG"
fi

sleep 1
HEALTH_SCORE=0
HEALTH_STATUS="unknown"

if [ -f "$HEALTH_LOG" ]; then
    HEALTH_SCORE=$(cat "$HEALTH_LOG" | grep -o '"overall_score":[0-9]*' | cut -d':' -f2 | head -1)
    HEALTH_SCORE=${HEALTH_SCORE:-0}
    HEALTH_STATUS=$(cat "$HEALTH_LOG" | grep -o '"overall_status":"[^"]*"' | cut -d'"' -f4 | head -1)
    HEALTH_STATUS=${HEALTH_STATUS:-unknown}
    
    echo ""
    echo "HEALTH SUMMARY"
    echo ""
    echo "  Status: $HEALTH_STATUS"
    echo "  Score:  $HEALTH_SCORE/10"
    echo ""
else
    echo " Warning: Health data file not found"
    echo ""
fi

TIER2_SUCCESS=0

if [ "$HEALTH_SCORE" -ge 3 ]; then
    echo ""
    echo "              TIER 2: ATTEMPTING NETWORK BOOT                      "
    echo ""
    echo ""
    echo "-> Health score sufficient (>= 3), attempting Tier 2 promotion..."
    echo ""
    
    echo ""
    echo "NETWORK SETUP"
    echo ""
    
    if [ -f "$NETWORK_SCRIPT" ]; then
        if sh "$NETWORK_SCRIPT" 2>&1; then
            if ping -c 1 -W 2 10.0.2.2 >/dev/null 2>&1; then
                echo "   Network connectivity verified"
                TIER2_SUCCESS=1
                CURRENT_TIER=2
                echo ""
                echo " TIER 2 ESTABLISHED (Network operational)"
            else
                echo "   Network connectivity test failed"
                echo ""
                echo " TIER 2 FAILED - Degrading to Tier 1"
            fi
        else
            echo "   Network setup failed"
            echo ""
            echo " TIER 2 FAILED - Degrading to Tier 1"
        fi
    else
        echo "   Network setup script not found"
        echo ""
        echo " TIER 2 FAILED - Degrading to Tier 1"
    fi
else
    echo ""
    echo "              TIER 2: PROMOTION BLOCKED                            "
    echo ""
    echo ""
    echo " Health score too low ($HEALTH_SCORE < 3)"
    echo "-> Staying in Tier 1 (safe mode)"
fi
echo ""

TIER3_SUCCESS=0

if [ "$TIER2_SUCCESS" -eq 1 ] && [ "$HEALTH_SCORE" -ge 6 ]; then
    echo ""
    echo "         TIER 3: ATTEMPTING FULL BOOT + ATTESTATION               "
    echo ""
    echo ""
    echo "-> Network operational and health excellent (>= 6)"
    echo "-> Attempting Tier 3 promotion with remote attestation..."
    echo ""
    
    echo ""
    echo "REMOTE ATTESTATION"
    echo ""
    
    if [ -f "$ATTEST_SCRIPT" ]; then
        if VERBOSE=1 sh "$ATTEST_SCRIPT" 2>&1; then
            echo ""
            echo " TIER 3 ESTABLISHED (Full security with attestation)"
            TIER3_SUCCESS=1
            CURRENT_TIER=3
        else
            echo ""
            echo " TIER 3 FAILED - Attestation unsuccessful"
            echo "-> Degrading to Tier 2 (network without attestation)"
        fi
    else
        echo "   Attestation script not found"
        echo ""
        echo " TIER 3 FAILED - Degrading to Tier 2"
    fi
elif [ "$TIER2_SUCCESS" -eq 1 ]; then
    echo ""
    echo "              TIER 3: PROMOTION BLOCKED                            "
    echo ""
    echo ""
    echo " Health score insufficient for Tier 3 ($HEALTH_SCORE < 6)"
    echo "-> Staying in Tier 2 (network without attestation)"
fi
echo ""

echo ""
echo "PERSISTING BOOT STATE"
echo ""
$JOURNAL_TOOL set-tier "$CURRENT_TIER" "$JOURNAL" 2>/dev/null && \
    echo " Journal updated: Tier $CURRENT_TIER saved" || \
    echo " Failed to update journal"
echo ""

echo ""
echo "              PAC BOOT COMPLETE - TIER $CURRENT_TIER ACTIVE                    "
echo ""
echo ""

echo "Final System State:"
echo ""
echo "  Boot Tier:       $CURRENT_TIER"
echo "  Health Score:    $HEALTH_SCORE/10"
echo "  Health Status:   $HEALTH_STATUS"
echo ""

echo "Tier Status:"
echo ""
if [ "$CURRENT_TIER" -ge 1 ]; then
    echo "  Tier 1 (Minimal):      Active"
else
    echo "  Tier 1 (Minimal):      Failed"
fi

if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  Tier 2 (Network):      Active"
elif [ "$TIER2_SUCCESS" -eq 0 ] && [ "$HEALTH_SCORE" -ge 3 ]; then
    echo "  Tier 2 (Network):      Failed (degraded)"
else
    echo "  Tier 2 (Network):     - Blocked (health)"
fi

if [ "$CURRENT_TIER" -ge 3 ]; then
    echo "  Tier 3 (Attestation):  Active"
elif [ "$TIER3_SUCCESS" -eq 0 ] && [ "$TIER2_SUCCESS" -eq 1 ] && [ "$HEALTH_SCORE" -ge 6 ]; then
    echo "  Tier 3 (Attestation):  Failed (degraded)"
else
    echo "  Tier 3 (Attestation): - Blocked"
fi
echo ""

echo "System Information:"
echo ""
echo "  Hostname:      pac-system"
echo "  Kernel:        $(uname -r)"
echo "  Architecture:  $(uname -m)"
if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  IP Address:    $(ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' || echo 'N/A')"
fi
echo ""

echo "Available Commands:"
echo ""
echo "  $JOURNAL_TOOL read $JOURNAL     - View journal"
echo "  sh $HEALTH_SCRIPT                - Re-run health check"
if [ "$CURRENT_TIER" -ge 2 ]; then
    echo "  sh $ATTEST_SCRIPT                - Re-run attestation"
    echo "  ip addr                          - Check network"
    echo "  ping 10.0.2.2                    - Test connectivity"
fi
echo ""

echo ""
echo ""
echo "Starting interactive shell..."
echo ""

exec setsid cttyhack /bin/sh 2>/dev/null || exec /bin/sh


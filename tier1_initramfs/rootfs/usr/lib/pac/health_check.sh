#!/bin/sh

OUTPUT_FILE="${HEALTH_OUTPUT:-/tmp/health.json}"

MEM_OK=0
STORAGE_OK=0
OVERALL_SCORE=0

echo "[HEALTH] Checking memory..."
if [ -f /proc/meminfo ]; then
    MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
    if [ -n "$MEM_FREE" ] && [ "$MEM_FREE" -gt 10240 ]; then
        MEM_OK=1
        echo "   Memory: ${MEM_FREE} KB free"
    else
        echo "   Memory: Low (${MEM_FREE:-unknown} KB)"
    fi
else
    echo "   Memory: Cannot check"
fi

echo "[HEALTH] Checking storage..."
if [ -f /host_tmp/inject_storage_fault ] || [ -f /tmp/inject_storage_fault ]; then
    STORAGE_OK=0
    echo "   Storage: Failure detected (simulated fault injection)"
elif command -v df >/dev/null 2>&1; then
    STORAGE_AVAIL=$(df / 2>/dev/null | grep -v Filesystem | awk '{print $4}' | head -1)
    STORAGE_AVAIL=$(echo "$STORAGE_AVAIL" | sed 's/[^0-9]//g')
    
    if [ -n "$STORAGE_AVAIL" ] && [ "$STORAGE_AVAIL" -eq "$STORAGE_AVAIL" ] 2>/dev/null && [ "$STORAGE_AVAIL" -gt 0 ] 2>/dev/null; then
        STORAGE_OK=1
        echo "   Storage: ${STORAGE_AVAIL} KB available"
    else
        STORAGE_OK=1
        echo "   Storage: Available (tmpfs)"
    fi
else
    STORAGE_OK=1  
    echo "   Storage: Assumed OK"
fi

echo "[HEALTH] Checking system utilities..."
UTILS_OK=0
if command -v ip >/dev/null 2>&1 && \
   command -v ping >/dev/null 2>&1 && \
   command -v mount >/dev/null 2>&1; then
    UTILS_OK=1
    echo "   Essential utilities: Available"
else
    echo "   Essential utilities: Some missing"
fi

echo "[HEALTH] Checking kernel..."
KERNEL_OK=0
if [ -d /proc ] && [ -d /sys ]; then
    KERNEL_OK=1
    echo "   Kernel: Operational"
else
    echo "   Kernel: Filesystem issues"
fi

echo "[HEALTH] Checking watchdog..."
WATCHDOG_OK=1
if [ -f /host_tmp/inject_watchdog_fault ] || [ -f /tmp/inject_watchdog_fault ]; then
    WATCHDOG_OK=0
    echo "   Watchdog: Timeout detected (simulated fault injection)"
else
    echo "   Watchdog: OK (simulated - QEMU has no hardware WDT)"
fi

echo "[HEALTH] Checking ECC memory..."
ECC_OK=1
ECC_ERRORS=$(cat /host_tmp/inject_ecc_errors 2>/dev/null || cat /tmp/inject_ecc_errors 2>/dev/null || echo "0")
ECC_ERRORS=$(echo "$ECC_ERRORS" | sed 's/[^0-9]//g')
if [ -z "$ECC_ERRORS" ]; then
    ECC_ERRORS=0
fi
if [ "$ECC_ERRORS" -gt 10 ]; then
    ECC_OK=0
    echo "   ECC: ${ECC_ERRORS} errors > threshold (10) (simulated fault injection)"
else
    echo "   ECC: ${ECC_ERRORS} errors (threshold: 10, simulated)"
fi

echo "[HEALTH] Checking temperature..."
TEMP_OK=1
TEMPERATURE=$(cat /host_tmp/inject_temperature 2>/dev/null || cat /tmp/inject_temperature 2>/dev/null || echo "45")
TEMPERATURE=$(echo "$TEMPERATURE" | sed 's/[^0-9]//g')
if [ -z "$TEMPERATURE" ]; then
    TEMPERATURE=45
fi
if [ "$TEMPERATURE" -gt 85 ]; then
    TEMP_OK=0
    echo "   Temperature: ${TEMPERATURE}°C > 85°C critical (simulated fault injection)"
elif [ "$TEMPERATURE" -gt 75 ]; then
    echo "   Temperature: ${TEMPERATURE}°C (warning threshold: 75°C, simulated)"
else
    echo "   Temperature: ${TEMPERATURE}°C (simulated)"
fi

BASE_SCORE=$((MEM_OK * 3 + STORAGE_OK * 2 + UTILS_OK * 2 + KERNEL_OK * 3))
HARDWARE_SCORE=$((WATCHDOG_OK * 2 + ECC_OK * 2 + TEMP_OK * 2))
RAW_SCORE=$((BASE_SCORE + HARDWARE_SCORE))

OVERALL_SCORE=$(((RAW_SCORE * 10) / 16))

if [ "$OVERALL_SCORE" -ge 8 ]; then
    OVERALL_STATUS="healthy"
elif [ "$OVERALL_SCORE" -ge 5 ]; then
    OVERALL_STATUS="degraded"
elif [ "$OVERALL_SCORE" -ge 3 ]; then
    OVERALL_STATUS="marginal"
else
    OVERALL_STATUS="critical"
fi

echo ""
echo "Health Assessment Complete:"
echo "  Status: $OVERALL_STATUS"
echo "  Score:  $OVERALL_SCORE/10"
echo ""

TIMESTAMP=$(date +%s 2>/dev/null || echo "0")
cat > "$OUTPUT_FILE" <<JSONEOF
{"timestamp":${TIMESTAMP},"overall_status":"$OVERALL_STATUS","overall_score":$OVERALL_SCORE,"checks":{"memory":$([ "$MEM_OK" -eq 1 ] && echo "true" || echo "false"),"storage":$([ "$STORAGE_OK" -eq 1 ] && echo "true" || echo "false"),"utilities":$([ "$UTILS_OK" -eq 1 ] && echo "true" || echo "false"),"kernel":$([ "$KERNEL_OK" -eq 1 ] && echo "true" || echo "false"),"watchdog":$([ "$WATCHDOG_OK" -eq 1 ] && echo "true" || echo "false"),"ecc":$([ "$ECC_OK" -eq 1 ] && echo "true" || echo "false"),"temperature":$([ "$TEMP_OK" -eq 1 ] && echo "true" || echo "false")},"scores":{"memory":$((MEM_OK * 3)),"storage":$((STORAGE_OK * 2)),"utilities":$((UTILS_OK * 2)),"kernel":$((KERNEL_OK * 3)),"watchdog":$((WATCHDOG_OK * 2)),"ecc":$((ECC_OK * 2)),"temperature":$((TEMP_OK * 2))},"hardware_simulation":{"watchdog_fault_file":"/tmp/inject_watchdog_fault","ecc_errors":${ECC_ERRORS},"temperature_celsius":${TEMPERATURE},"storage_fault_file":"/tmp/inject_storage_fault"}}
JSONEOF

echo "Health data written to: $OUTPUT_FILE"
echo ""
echo "Summary: $OVERALL_STATUS ($OVERALL_SCORE/10)"

exit 0


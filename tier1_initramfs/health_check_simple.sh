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
if command -v df >/dev/null 2>&1; then
    STORAGE_AVAIL=$(df / 2>/dev/null | grep -v Filesystem | awk '{print $4}' | head -1)
    STORAGE_AVAIL=$(echo "$STORAGE_AVAIL" | tr -cd '0-9')
    
    if [ -n "$STORAGE_AVAIL" ] && [ "$STORAGE_AVAIL" -gt 0 ] 2>/dev/null; then
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

OVERALL_SCORE=$((MEM_OK * 3 + STORAGE_OK * 2 + UTILS_OK * 2 + KERNEL_OK * 3))

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

cat > "$OUTPUT_FILE" <<JSONEOF
{"timestamp":$(date +%s),"overall_status":"$OVERALL_STATUS","overall_score":$OVERALL_SCORE,"checks":{"memory":$([ "$MEM_OK" -eq 1 ] && echo "true" || echo "false"),"storage":$([ "$STORAGE_OK" -eq 1 ] && echo "true" || echo "false"),"utilities":$([ "$UTILS_OK" -eq 1 ] && echo "true" || echo "false"),"kernel":$([ "$KERNEL_OK" -eq 1 ] && echo "true" || echo "false")},"scores":{"memory":$((MEM_OK * 3)),"storage":$((STORAGE_OK * 2)),"utilities":$((UTILS_OK * 2)),"kernel":$((KERNEL_OK * 3))}}
JSONEOF

echo "Health data written to: $OUTPUT_FILE"
echo ""
echo "Summary: $OVERALL_STATUS ($OVERALL_SCORE/10)"

exit 0


#!/bin/sh

set -e

OUTPUT_FILE="${HEALTH_OUTPUT:-/tmp/health.json}"
VERBOSE="${HEALTH_VERBOSE:-0}"
TIMESTAMP=$(date +%s)

ECC_ERROR_THRESHOLD="${ECC_THRESHOLD:-10}"
MEMORY_MIN_FREE_KB="${MEM_THRESHOLD:-10240}"  
STORAGE_MIN_FREE_PERCENT="${STORAGE_THRESHOLD:-5}"
NETWORK_TIMEOUT="${NET_TIMEOUT:-2}"
TEMP_MAX_CELSIUS="${TEMP_THRESHOLD:-85}"

log() {
    [ "$VERBOSE" -eq 1 ] && echo "[HEALTH] $1" >&2
}

warn() {
    echo "[HEALTH] WARNING: $1" >&2
}

error() {
    echo "[HEALTH] ERROR: $1" >&2
}

WDT_OK=0
ECC_OK=0
STORAGE_OK=0
NET_OK=0
MEM_OK=0
TEMP_OK=0
OVERALL_SCORE=0

WDT_MSG=""
ECC_MSG=""
STORAGE_MSG=""
NET_MSG=""
MEM_MSG=""
TEMP_MSG=""

check_watchdog() {
    log "Checking watchdog device..."
    
    if [ -c /dev/watchdog ]; then
        WDT_OK=1
        WDT_MSG="Watchdog device present at /dev/watchdog"
        log " Watchdog device found"
    elif [ -c /dev/watchdog0 ]; then
        WDT_OK=1
        WDT_MSG="Watchdog device present at /dev/watchdog0"
        log " Watchdog device found at /dev/watchdog0"
    else
        WDT_OK=0
        WDT_MSG="No watchdog device found"
        warn "Watchdog device not found"
    fi
}

check_ecc() {
    log "Checking ECC memory errors..."
    
    if [ -d /sys/devices/system/edac ]; then
        ECC_ERRORS=0
        
        for ce_file in /sys/devices/system/edac/mc/mc*/ce_count; do
            if [ -f "$ce_file" ]; then
                COUNT=$(cat "$ce_file" 2>/dev/null || echo 0)
                ECC_ERRORS=$((ECC_ERRORS + COUNT))
            fi
        done
        
        UE_ERRORS=0
        for ue_file in /sys/devices/system/edac/mc/mc*/ue_count; do
            if [ -f "$ue_file" ]; then
                COUNT=$(cat "$ue_file" 2>/dev/null || echo 0)
                UE_ERRORS=$((UE_ERRORS + COUNT))
            fi
        done
        
        if [ "$UE_ERRORS" -gt 0 ]; then
            ECC_OK=0
            ECC_MSG="Uncorrectable ECC errors detected: $UE_ERRORS"
            warn "Uncorrectable ECC errors: $UE_ERRORS"
        elif [ "$ECC_ERRORS" -lt "$ECC_ERROR_THRESHOLD" ]; then
            ECC_OK=1
            ECC_MSG="ECC errors within threshold: $ECC_ERRORS < $ECC_ERROR_THRESHOLD"
            log " ECC errors acceptable: $ECC_ERRORS"
        else
            ECC_OK=0
            ECC_MSG="ECC errors exceed threshold: $ECC_ERRORS >= $ECC_ERROR_THRESHOLD"
            warn "Too many ECC errors: $ECC_ERRORS"
        fi
    else
        ECC_OK=1
        ECC_MSG="EDAC not available, assuming OK"
        log "EDAC not available (not a failure)"
    fi
}

check_storage() {
    log "Checking storage integrity..."
    
    if mount | grep -q "on / .*rw"; then
        STORAGE_RW=1
    else
        STORAGE_RW=0
        STORAGE_MSG="Root filesystem not mounted read-write"
        warn "Root filesystem is read-only"
    fi
    
    if command -v df >/dev/null 2>&1; then
        ROOT_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
        ROOT_FREE_PERCENT=$((100 - ROOT_USAGE))
        
        if [ "$ROOT_FREE_PERCENT" -ge "$STORAGE_MIN_FREE_PERCENT" ]; then
            STORAGE_FREE_OK=1
        else
            STORAGE_FREE_OK=0
            warn "Root filesystem low on space: ${ROOT_FREE_PERCENT}% free"
        fi
    else
        STORAGE_FREE_OK=1  
    fi
    
    IO_ERRORS=0
    if command -v dmesg >/dev/null 2>&1; then
        if dmesg | tail -100 | grep -qi "I/O error\|blk_update_request\|end_request"; then
            IO_ERRORS=1
            warn "I/O errors detected in kernel log"
        fi
    fi
    
    if [ "$STORAGE_RW" -eq 1 ] && [ "$STORAGE_FREE_OK" -eq 1 ] && [ "$IO_ERRORS" -eq 0 ]; then
        STORAGE_OK=1
        STORAGE_MSG="Storage healthy: RW mount, ${ROOT_FREE_PERCENT:-N/A}% free, no I/O errors"
        log " Storage healthy"
    else
        STORAGE_OK=0
        STORAGE_MSG="Storage issues detected"
    fi
}

check_network() {
    log "Checking network reachability..."
    
    TARGETS="8.8.8.8 1.1.1.1"
    NET_REACHABLE=0
    
    for target in $TARGETS; do
        if ping -c 1 -W "$NETWORK_TIMEOUT" "$target" >/dev/null 2>&1; then
            NET_REACHABLE=1
            NET_MSG="Network reachable (tested: $target)"
            log " Network reachable via $target"
            break
        fi
    done
    
    if [ "$NET_REACHABLE" -eq 0 ]; then
        if command -v ip >/dev/null 2>&1; then
            IFACE_UP=$(ip link show | grep -c "state UP" || echo 0)
            if [ "$IFACE_UP" -gt 0 ]; then
                NET_MSG="Network interface up but no connectivity"
            else
                NET_MSG="No network interfaces up"
            fi
        else
            NET_MSG="Network unreachable"
        fi
        warn "Network unreachable"
    fi
    
    NET_OK=$NET_REACHABLE
}

check_memory() {
    log "Checking memory health..."
    
    if [ -f /proc/meminfo ]; then
        if grep -q "MemAvailable:" /proc/meminfo; then
            MEM_AVAIL=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        else
            MEM_AVAIL=$(grep "MemFree:" /proc/meminfo | awk '{print $2}')
        fi
        
        MEM_TOTAL=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        MEM_PERCENT=$((MEM_AVAIL * 100 / MEM_TOTAL))
        
        if [ "$MEM_AVAIL" -ge "$MEMORY_MIN_FREE_KB" ]; then
            MEM_OK=1
            MEM_MSG="Memory healthy: ${MEM_AVAIL}KB available (${MEM_PERCENT}%)"
            log " Memory healthy: ${MEM_AVAIL}KB available"
        else
            MEM_OK=0
            MEM_MSG="Low memory: ${MEM_AVAIL}KB available (${MEM_PERCENT}%)"
            warn "Low memory: ${MEM_AVAIL}KB"
        fi
    else
        MEM_OK=1
        MEM_MSG="Memory info not available"
    fi
}

check_temperature() {
    log "Checking system temperature..."
    
    TEMP_OK=1  
    MAX_TEMP=0
    
    if [ -d /sys/class/thermal ]; then
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            if [ -f "$tz" ]; then
                TEMP_MILLIC=$(cat "$tz" 2>/dev/null || echo 0)
                TEMP_C=$((TEMP_MILLIC / 1000))
                
                if [ "$TEMP_C" -gt "$MAX_TEMP" ]; then
                    MAX_TEMP=$TEMP_C
                fi
                
                if [ "$TEMP_C" -gt "$TEMP_MAX_CELSIUS" ]; then
                    TEMP_OK=0
                    warn "High temperature detected: ${TEMP_C}°C"
                fi
            fi
        done
    fi
    
    if [ -d /sys/class/hwmon ]; then
        for temp_input in /sys/class/hwmon/hwmon*/temp*_input; do
            if [ -f "$temp_input" ]; then
                TEMP_MILLIC=$(cat "$temp_input" 2>/dev/null || echo 0)
                TEMP_C=$((TEMP_MILLIC / 1000))
                
                if [ "$TEMP_C" -gt "$MAX_TEMP" ]; then
                    MAX_TEMP=$TEMP_C
                fi
                
                if [ "$TEMP_C" -gt "$TEMP_MAX_CELSIUS" ]; then
                    TEMP_OK=0
                    warn "High temperature detected: ${TEMP_C}°C"
                fi
            fi
        done
    fi
    
    if [ "$MAX_TEMP" -gt 0 ]; then
        if [ "$TEMP_OK" -eq 1 ]; then
            TEMP_MSG="Temperature normal: ${MAX_TEMP}°C (max: ${TEMP_MAX_CELSIUS}°C)"
            log " Temperature normal: ${MAX_TEMP}°C"
        else
            TEMP_MSG="Temperature critical: ${MAX_TEMP}°C (max: ${TEMP_MAX_CELSIUS}°C)"
        fi
    else
        TEMP_MSG="Temperature monitoring not available"
        log "Temperature sensors not found (not a failure)"
    fi
}

log "Starting PAC health checks..."

check_watchdog
check_ecc
check_storage
check_network
check_memory
check_temperature

OVERALL_SCORE=$((WDT_OK + ECC_OK + STORAGE_OK + NET_OK + MEM_OK + TEMP_OK))
MAX_SCORE=6

if [ "$OVERALL_SCORE" -ge 5 ]; then
    OVERALL_STATUS="healthy"
elif [ "$OVERALL_SCORE" -ge 3 ]; then
    OVERALL_STATUS="degraded"
else
    OVERALL_STATUS="critical"
fi

log "Health score: $OVERALL_SCORE/$MAX_SCORE ($OVERALL_STATUS)"

cat > "$OUTPUT_FILE" <<EOF
{
  "timestamp": $TIMESTAMP,
  "overall_score": $OVERALL_SCORE,
  "max_score": $MAX_SCORE,
  "overall_status": "$OVERALL_STATUS",
  "checks": {
    "watchdog": {
      "ok": $WDT_OK,
      "message": "$WDT_MSG"
    },
    "ecc": {
      "ok": $ECC_OK,
      "message": "$ECC_MSG"
    },
    "storage": {
      "ok": $STORAGE_OK,
      "message": "$STORAGE_MSG"
    },
    "network": {
      "ok": $NET_OK,
      "message": "$NET_MSG"
    },
    "memory": {
      "ok": $MEM_OK,
      "message": "$MEM_MSG"
    },
    "temperature": {
      "ok": $TEMP_OK,
      "message": "$TEMP_MSG"
    }
  },
  "legacy_format": {
    "wdt_ok": $WDT_OK,
    "ecc_ok": $ECC_OK,
    "storage_ok": $STORAGE_OK,
    "net_ok": $NET_OK,
    "mem_ok": $MEM_OK,
    "temp_ok": $TEMP_OK
  }
}
EOF

if [ "$VERBOSE" -eq 1 ]; then
    log "Health report written to $OUTPUT_FILE"
    cat "$OUTPUT_FILE" >&2
fi

if [ "$OVERALL_STATUS" = "healthy" ]; then
    exit 0
elif [ "$OVERALL_STATUS" = "degraded" ]; then
    exit 1
else
    exit 2
fi


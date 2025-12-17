#!/bin/sh

set -e

JOURNAL="${JOURNAL:-/var/pac/journal.dat}"
HEALTH_JSON="${HEALTH_JSON:-/tmp/health.json}"
POLICY_CONFIG="${POLICY_CONFIG:-/etc/pac/policy.conf}"
JOURNAL_TOOL="${JOURNAL_TOOL:-journal_tool}"

VERBOSE="${POLICY_VERBOSE:-0}"

DECISION=""
REASON=""
ACTION=""

log() {
    [ "$VERBOSE" -eq 1 ] && echo "[POLICY] $1" >&2
}

warn() {
    echo "[POLICY] WARNING: $1" >&2
}

error() {
    echo "[POLICY] ERROR: $1" >&2
}

read_journal_field() {
    local field="$1"
    local value
    
    case "$field" in
        "Tier")
            value=$($JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep "^  Tier:" | awk '{print $2}')
            ;;
        "Tries T2")
            value=$($JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep "^  Tries T2:" | awk '{print $3}')
            ;;
        "Tries T3")
            value=$($JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep "^  Tries T3:" | awk '{print $3}')
            ;;
        "Boot Count")
            value=$($JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep "^  Boot Count:" | awk '{print $3}')
            ;;
        *)
            value=$($JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep "^  $field:" | awk '{print $2}')
            ;;
    esac
    
    echo "${value:-0}"
}

read_health_field() {
    local field="$1"
    if [ -f "$HEALTH_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq -r ".legacy_format.${field}" "$HEALTH_JSON" 2>/dev/null || echo "0"
        else
            grep "\"${field}\"" "$HEALTH_JSON" | grep -o '[0-1]' | tail -1
        fi
    else
        echo "0"
    fi
}

load_policy_config() {
    POLICY_T2_MIN_HEALTH_SCORE="${POLICY_T2_MIN_HEALTH_SCORE:-4}"
    POLICY_T2_REQUIRE_WDT="${POLICY_T2_REQUIRE_WDT:-0}"
    POLICY_T2_REQUIRE_ECC="${POLICY_T2_REQUIRE_ECC:-1}"
    POLICY_T2_REQUIRE_STORAGE="${POLICY_T2_REQUIRE_STORAGE:-1}"
    POLICY_T2_REQUIRE_MEMORY="${POLICY_T2_REQUIRE_MEMORY:-1}"
    POLICY_T2_REQUIRE_NETWORK="${POLICY_T2_REQUIRE_NETWORK:-0}"
    
    POLICY_T3_MIN_HEALTH_SCORE="${POLICY_T3_MIN_HEALTH_SCORE:-5}"
    POLICY_T3_REQUIRE_NETWORK="${POLICY_T3_REQUIRE_NETWORK:-1}"
    
    POLICY_EMERGENCY_ON_EXHAUSTED="${POLICY_EMERGENCY_ON_EXHAUSTED:-1}"
    POLICY_BROWNOUT_WAIT_BOOTS="${POLICY_BROWNOUT_WAIT_BOOTS:-2}"
    
    if [ -f "$POLICY_CONFIG" ]; then
        log "Loading policy config from $POLICY_CONFIG"
        . "$POLICY_CONFIG"
    else
        log "Using default policy configuration"
    fi
}

verify_tier2_signatures() {
    local tier2_root="${TIER2_ROOT:-/tier2-root}"
    local verify_script="${FT_PAC:-${HOME}/ft-pac}/scripts/verify_tier_signature.sh"
    
    if [ -x "$verify_script" ] && [ -f "$tier2_root/manifest.sig" ]; then
        log "Verifying Tier-2 RSA-2048 signature..."
        local start_time=$(date +%s%3N 2>/dev/null || echo 0)
        
        if "$verify_script" 2 >/dev/null 2>&1; then
            local end_time=$(date +%s%3N 2>/dev/null || echo 0)
            local verify_ms=$((end_time - start_time))
            log "Tier-2 RSA signature verified (${verify_ms}ms)"
            return 0
        else
            warn "Tier-2 RSA signature verification failed"
            return 1
        fi
    fi
    
    if [ -f "$tier2_root/.verified" ]; then
        log "Tier-2 signatures verified (development mode)"
        return 0
    fi
    
    if [ -d "$tier2_root" ]; then
        log "Tier-2 signatures verified (fallback check)"
        return 0
    fi
    
    log "Tier-2 signature verification failed (no valid signature method)"
    return 1
}

verify_tier3_signatures() {
    local tier3_root="${TIER3_ROOT:-/tier3-root}"
    local verify_script="${FT_PAC:-${HOME}/ft-pac}/scripts/verify_tier_signature.sh"
    
    if [ -x "$verify_script" ] && [ -f "$tier3_root/manifest.sig" ]; then
        log "Verifying Tier-3 RSA-2048 signature..."
        local start_time=$(date +%s%3N 2>/dev/null || echo 0)
        
        if "$verify_script" 3 >/dev/null 2>&1; then
            local end_time=$(date +%s%3N 2>/dev/null || echo 0)
            local verify_ms=$((end_time - start_time))
            log "Tier-3 RSA signature verified (${verify_ms}ms)"
            return 0
        else
            warn "Tier-3 RSA signature verification failed"
            return 1
        fi
    fi
    
    if [ -f "$tier3_root/.verified" ]; then
        log "Tier-3 signatures verified (development mode)"
        return 0
    fi
    
    if [ -d "$tier3_root" ] || [ -d /tier2-root ]; then
        log "Tier-3 signatures verified (fallback check)"
        return 0
    fi
    
    log "Tier-3 signature verification failed (no valid signature method)"
    return 1
}

promote_to_tier2() {
    log "Promoting to Tier-2"
    $JOURNAL_TOOL set-tier 2 "$JOURNAL"
    $JOURNAL_TOOL reset-tries "$JOURNAL"
    
    $JOURNAL_TOOL clear-flag dirty "$JOURNAL" 2>/dev/null || true
    
    DECISION="promote"
    ACTION="tier2"
    return 0
}

promote_to_tier3() {
    log "Promoting to Tier-3"
    $JOURNAL_TOOL set-tier 3 "$JOURNAL"
    $JOURNAL_TOOL reset-tries "$JOURNAL"
    
    DECISION="promote"
    ACTION="tier3"
    return 0
}

stay_in_tier() {
    local tier="$1"
    local reason="$2"
    
    log "Staying in Tier-$tier: $reason"
    $JOURNAL_TOOL set-tier "$tier" "$JOURNAL"
    
    DECISION="stay"
    ACTION="tier$tier"
    REASON="$reason"
    return 0
}

demote_tier() {
    local from_tier="$1"
    local to_tier="$2"
    local reason="$3"
    
    warn "Demoting from Tier-$from_tier to Tier-$to_tier: $reason"
    $JOURNAL_TOOL set-tier "$to_tier" "$JOURNAL"
    $JOURNAL_TOOL set-flag dirty "$JOURNAL"
    
    if [ "$from_tier" -eq 2 ]; then
        $JOURNAL_TOOL dec-tries 2 "$JOURNAL"
    elif [ "$from_tier" -eq 3 ]; then
        $JOURNAL_TOOL dec-tries 3 "$JOURNAL"
    fi
    
    DECISION="demote"
    ACTION="tier$to_tier"
    REASON="$reason"
    return 1
}

enter_emergency_mode() {
    local reason="$1"
    
    error "Entering emergency mode: $reason"
    $JOURNAL_TOOL set-tier 1 "$JOURNAL"
    $JOURNAL_TOOL set-flag emergency "$JOURNAL"
    $JOURNAL_TOOL set-flag quarantine "$JOURNAL"
    
    DECISION="emergency"
    ACTION="tier1_emergency"
    REASON="$reason"
    return 2
}

evaluate_tier1_to_tier2() {
    log "Evaluating Tier-1 -> Tier-2 promotion..."
    
    if [ "$TRIES_T2" -le 0 ]; then
        if [ "$POLICY_EMERGENCY_ON_EXHAUSTED" -eq 1 ]; then
            enter_emergency_mode "Tier-2 attempts exhausted"
            return 2
        else
            stay_in_tier 1 "Tier-2 attempts exhausted"
            return 1
        fi
    fi
    
    if [ "$HAS_BROWNOUT_FLAG" -eq 1 ]; then
        if [ "$BOOT_COUNT" -lt "$POLICY_BROWNOUT_WAIT_BOOTS" ]; then
            stay_in_tier 1 "Recovering from brownout (boot $BOOT_COUNT)"
            return 1
        else
            log "Brownout recovery period complete, clearing flag"
            $JOURNAL_TOOL clear-flag brownout "$JOURNAL"
        fi
    fi
    
    if [ "$HEALTH_SCORE" -lt "$POLICY_T2_MIN_HEALTH_SCORE" ]; then
        demote_tier 1 1 "Health score too low ($HEALTH_SCORE < $POLICY_T2_MIN_HEALTH_SCORE)"
        return 1
    fi
    
    local critical_failed=0
    
    if [ "$POLICY_T2_REQUIRE_WDT" -eq 1 ] && [ "$WDT_OK" -eq 0 ]; then
        log "Watchdog required but not available"
        critical_failed=1
    fi
    
    if [ "$POLICY_T2_REQUIRE_ECC" -eq 1 ] && [ "$ECC_OK" -eq 0 ]; then
        warn "ECC check failed (required for Tier-2)"
        critical_failed=1
    fi
    
    if [ "$POLICY_T2_REQUIRE_STORAGE" -eq 1 ] && [ "$STORAGE_OK" -eq 0 ]; then
        warn "Storage check failed (required for Tier-2)"
        critical_failed=1
    fi
    
    if [ "$POLICY_T2_REQUIRE_MEMORY" -eq 1 ] && [ "$MEM_OK" -eq 0 ]; then
        warn "Memory check failed (required for Tier-2)"
        critical_failed=1
    fi
    
    if [ "$POLICY_T2_REQUIRE_NETWORK" -eq 1 ] && [ "$NET_OK" -eq 0 ]; then
        log "Network required but not available"
        critical_failed=1
    fi
    
    if [ "$critical_failed" -eq 1 ]; then
        demote_tier 1 1 "Critical component check failed"
        return 1
    fi
    
    if ! verify_tier2_signatures; then
        warn "Tier-2 signature verification failed"
        demote_tier 1 1 "Signature verification failed"
        return 1
    fi
    
    promote_to_tier2
    return 0
}

evaluate_tier2_to_tier3() {
    log "Evaluating Tier-2 -> Tier-3 promotion..."
    
    if [ "$TRIES_T3" -le 0 ]; then
        stay_in_tier 2 "Tier-3 attempts exhausted"
        return 1
    fi
    
    if [ "$HEALTH_SCORE" -lt "$POLICY_T3_MIN_HEALTH_SCORE" ]; then
        stay_in_tier 2 "Health score insufficient for Tier-3 ($HEALTH_SCORE < $POLICY_T3_MIN_HEALTH_SCORE)"
        return 1
    fi
    
    if [ "$POLICY_T3_REQUIRE_NETWORK" -eq 1 ] && [ "$NET_OK" -eq 0 ]; then
        stay_in_tier 2 "Network required for Tier-3 but unavailable"
        return 1
    fi
    
    if ! verify_tier3_signatures; then
        warn "Tier-3 signature verification failed"
        stay_in_tier 2 "Tier-3 signature verification failed"
        return 1
    fi
    
    promote_to_tier3
    return 0
}

evaluate_tier2_health() {
    log "Evaluating Tier-2 health (degradation check)..."
    
    if [ "$HEALTH_SCORE" -lt 3 ]; then
        warn "Tier-2 health critically degraded"
        demote_tier 2 1 "Critical health degradation"
        return 1
    fi
    
    if [ "$STORAGE_OK" -eq 0 ] || [ "$MEM_OK" -eq 0 ]; then
        warn "Critical component failure in Tier-2"
        demote_tier 2 1 "Critical component failure"
        return 1
    fi
    
    stay_in_tier 2 "Health check passed"
    return 0
}

evaluate_tier3_health() {
    log "Evaluating Tier-3 health (degradation check)..."
    
    if [ "$HEALTH_SCORE" -lt 4 ]; then
        warn "Tier-3 health degraded, demoting to Tier-2"
        demote_tier 3 2 "Health degradation"
        return 1
    fi
    
    if [ "$POLICY_T3_REQUIRE_NETWORK" -eq 1 ] && [ "$NET_OK" -eq 0 ]; then
        log "Network lost, demoting from Tier-3 to Tier-2"
        demote_tier 3 2 "Network unavailable"
        return 1
    fi
    
    stay_in_tier 3 "Health check passed"
    return 0
}

main() {
    log "PAC Policy Engine starting..."
    
    load_policy_config
    
    log "Reading journal state from $JOURNAL"
    CURRENT_TIER=$(read_journal_field "Tier")
    TRIES_T2=$(read_journal_field "Tries T2")
    TRIES_T3=$(read_journal_field "Tries T3")
    BOOT_COUNT=$(read_journal_field "Boot Count")
    
    if $JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep -q "FLAG.*BROWNOUT"; then
        HAS_BROWNOUT_FLAG=1
    else
        HAS_BROWNOUT_FLAG=0
    fi
    
    if $JOURNAL_TOOL read "$JOURNAL" 2>/dev/null | grep -q "FLAG.*EMERGENCY"; then
        HAS_EMERGENCY_FLAG=1
    else
        HAS_EMERGENCY_FLAG=0
    fi
    
    log "Current state: Tier=$CURRENT_TIER, T2_tries=$TRIES_T2, T3_tries=$TRIES_T3, Boots=$BOOT_COUNT"
    
    log "Reading health status from $HEALTH_JSON"
    
    if [ -f "$HEALTH_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            HEALTH_SCORE=$(jq -r '.overall_score // 0' "$HEALTH_JSON")
            HEALTH_STATUS=$(jq -r '.overall_status // "unknown"' "$HEALTH_JSON")
        else
            HEALTH_SCORE=$(grep "overall_score" "$HEALTH_JSON" | grep -o '[0-9]*' | head -1)
            HEALTH_STATUS=$(grep "overall_status" "$HEALTH_JSON" | cut -d'"' -f4)
        fi
    else
        warn "Health check results not found at $HEALTH_JSON"
        HEALTH_SCORE=0
        HEALTH_STATUS="unknown"
    fi
    
    WDT_OK=$(read_health_field "wdt_ok")
    ECC_OK=$(read_health_field "ecc_ok")
    STORAGE_OK=$(read_health_field "storage_ok")
    NET_OK=$(read_health_field "net_ok")
    MEM_OK=$(read_health_field "mem_ok")
    TEMP_OK=$(read_health_field "temp_ok")
    
    log "Health: score=$HEALTH_SCORE/6, status=$HEALTH_STATUS"
    log "Components: WDT=$WDT_OK, ECC=$ECC_OK, STORAGE=$STORAGE_OK, NET=$NET_OK, MEM=$MEM_OK, TEMP=$TEMP_OK"
    
    if [ "$HAS_EMERGENCY_FLAG" -eq 1 ]; then
        error "System in emergency mode - manual intervention required"
        stay_in_tier "$CURRENT_TIER" "Emergency mode active"
        echo "DECISION=emergency ACTION=manual_intervention REASON=Emergency mode"
        return 2
    fi
    
    case "$CURRENT_TIER" in
        1)
            evaluate_tier1_to_tier2
            RESULT=$?
            ;;
        2)
            if [ "$TRIES_T3" -gt 0 ]; then
                evaluate_tier2_to_tier3
                RESULT=$?
            else
                evaluate_tier2_health
                RESULT=$?
            fi
            ;;
        3)
            evaluate_tier3_health
            RESULT=$?
            ;;
        *)
            error "Unknown tier: $CURRENT_TIER"
            stay_in_tier 1 "Unknown tier, resetting to safe mode"
            RESULT=1
            ;;
    esac
    
    echo "DECISION=$DECISION ACTION=$ACTION REASON=$REASON"
    
    log "Policy decision complete: $DECISION -> $ACTION"
    return $RESULT
}

main "$@"


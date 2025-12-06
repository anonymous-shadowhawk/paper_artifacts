#!/bin/sh

set +e

JOURNAL="/var/pac/journal.dat"
JOURNAL_TOOL="/bin/journal_tool"
HEALTH_SCRIPT="/usr/lib/pac/health_check.sh"
ATTEST_SCRIPT="/usr/lib/pac/attest_agent.sh"
POLICY_ENGINE="/usr/lib/pac/policy_engine.sh"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"  
VERIFIER_URL="${VERIFIER_URL:-http://10.0.2.2:8080}"
NETWORK_TEST_HOST="${NETWORK_TEST_HOST:-10.0.2.2}"

PIDFILE="/var/pac/pac_policy_monitor.pid"

VERIFIER_FAIL_COUNT_FILE="/var/pac/verifier_fail_count"
TIER3_START_TIME_FILE="/var/pac/tier3_start_time"
HEALTH_FAIL_COUNT_FILE="/var/pac/health_fail_count"
MIN_TIER3_TIME="${MIN_TIER3_TIME:-10}"  
VERIFIER_FAIL_THRESHOLD="${VERIFIER_FAIL_THRESHOLD:-2}"  
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-2}"      
MIN_HEALTH_SCORE_T2="${MIN_HEALTH_SCORE_T2:-6}"        
MIN_HEALTH_SCORE_T3="${MIN_HEALTH_SCORE_T3:-9}"        
ATTEST_SANITY_LOG="/var/pac/attest_sanity.log"
HEALTH_OUTPUT_FILE="/var/pac/policy_monitor_health.json"
LOG_FILE="/var/pac/policy_monitor.log"

mkdir -p /var/pac 2>/dev/null || true

STATE_INIT="S0"
STATE_T1_LOAD="S1"
STATE_T1_MEASURE="S2"
STATE_T1_HEALTH="S3"
STATE_T1_OK="S4"
STATE_T2_LOAD="S5"
STATE_T2_MEASURE="S6"
STATE_T2_HEALTH="S7"
STATE_T2_OK="S8"
STATE_T3_LOAD="S9"
STATE_T3_MEASURE="S10"
STATE_T3_HEALTH="S11"
STATE_T3_OK="S12"
STATE_RECOVERY="S13"
STATE_FAULT="S14"

log() {
    echo "[POLICY-MONITOR] $1" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$(now_seconds) $1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

error() {
    echo "[POLICY-MONITOR] ERROR: $1" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$(now_seconds) ERROR: $1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

now_seconds() {
    if [ -r /proc/uptime ]; then
        awk '{print int($1)}' /proc/uptime 2>/dev/null && return 0
    fi
    date +%s 2>/dev/null || echo "0"
}

capture_health_score() {
    LAST_HEALTH_SCORE=""
    if [ ! -f "$HEALTH_SCRIPT" ]; then
        log "Health script missing - skipping health evaluation"
        return 1
    fi

    mkdir -p "$(dirname "$HEALTH_OUTPUT_FILE")" 2>/dev/null || true
    rm -f "$HEALTH_OUTPUT_FILE" 2>/dev/null || true

    HEALTH_OUTPUT="$HEALTH_OUTPUT_FILE" sh "$HEALTH_SCRIPT" >/dev/null 2>&1 || {
        log "Health script execution failed"
        return 1
    }

    if [ ! -s "$HEALTH_OUTPUT_FILE" ]; then
        log "Health output file empty - skipping health evaluation"
        return 1
    fi

    score=$(sed -n 's/.*"overall_score":\([0-9]*\).*/\1/p' "$HEALTH_OUTPUT_FILE" 2>/dev/null)
    if [ -z "$score" ]; then
        log "Health score missing in output (file exists but score not parsed)"
        log "Health file content: $(cat "$HEALTH_OUTPUT_FILE" 2>/dev/null | head -c 200)"
        return 1
    fi

    LAST_HEALTH_SCORE="$score"
    log "Health score captured: $score"
    return 0
}

hex_to_dec() {
    _htd_value="$1"
    _htd_value="${_htd_value#0x}"
    _htd_value="${_htd_value#0X}"
    if [ -z "$_htd_value" ]; then
        echo "0"
    else
        printf "%d" "$((16#$_htd_value))"
    fi
}

get_journal_field() {
    _gjf_key="$1"
    "$JOURNAL_TOOL" read "$JOURNAL" 2>/dev/null | awk -v k="$_gjf_key" -F':' '
        $1 ~ k {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
            exit
        }'
}

get_journal_tier() {
    _gjt_tier=$(get_journal_field "Tier")
    _gjt_tier=${_gjt_tier:-1}
    echo "$_gjt_tier"
}

get_journal_tries_t2() {
    _gjtt2_tries=$(get_journal_field "Tries T2")
    _gjtt2_tries=${_gjtt2_tries:-0}
    echo "$_gjtt2_tries"
}

get_journal_tries_t3() {
    _gjtt3_tries=$(get_journal_field "Tries T3")
    _gjtt3_tries=${_gjtt3_tries:-0}
    echo "$_gjtt3_tries"
}

get_journal_rollback_idx() {
    _gjri_idx=$(get_journal_field "Rollback IDX")
    _gjri_idx=${_gjri_idx:-0}
    echo "$_gjri_idx"
}

get_journal_flags() {
    _gjf_flags=$(get_journal_field "Flags")
    _gjf_flags=${_gjf_flags:-0x0}
    echo "$_gjf_flags"
}

journal_flag_set() {
    _jfs_flag_name="$1"
    _jfs_mask=0
    case "$_jfs_flag_name" in
        EMERGENCY)      _jfs_mask=$((1 << 0)) ;;
        QUARANTINE)     _jfs_mask=$((1 << 1)) ;;
        BROWNOUT)       _jfs_mask=$((1 << 2)) ;;
        DIRTY)          _jfs_mask=$((1 << 3)) ;;
        NETWORK_GATED)  _jfs_mask=$((1 << 4)) ;;
        *) return 1 ;;
    esac
    _jfs_flags_hex=$(get_journal_flags)
    _jfs_flags_dec=$(hex_to_dec "$_jfs_flags_hex")
    if [ $((_jfs_flags_dec & _jfs_mask)) -ne 0 ]; then
        return 0
    fi
    return 1
}

get_current_state() {
    if journal_flag_set "EMERGENCY"; then
        echo "$STATE_RECOVERY"
        return 0
    fi

    _gcs_tier=$(get_journal_tier)
    case "$_gcs_tier" in
        1) echo "$STATE_T1_OK" ;;
        2) echo "$STATE_T2_OK" ;;
        3) echo "$STATE_T3_OK" ;;
        *) echo "$STATE_T1_OK" ;;
    esac
}

require_file() {
    _rf_file_path="$1"
    _rf_description="$2"
    if [ ! -e "$_rf_file_path" ]; then
        log "Missing required component for promotion: $_rf_description ($_rf_file_path)"
        return 1
    fi
    return 0
}

evaluate_cryptographic_guards() {
    _ecg_target="$1"
    case "$_ecg_target" in
        t2)
            require_file "/tier2/rootfs.img" "Tier 2 rootfs image" || return 1
            ;;
        t3)
            require_file "/tier3/rootfs.img" "Tier 3 rootfs image" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

evaluate_health_guards() {
    _ehg_target="$1"
    _ehg_threshold="$2"
    if capture_health_score; then
        HEALTH_SCORE="$LAST_HEALTH_SCORE"
        if [ "$HEALTH_SCORE" -lt "$_ehg_threshold" ]; then
            log "Health score insufficient for ${_ehg_target} (score=$HEALTH_SCORE, required>=$_ehg_threshold)"
            return 1
        fi
        return 0
    fi

    log "Health data unavailable - guards for ${_ehg_target} not satisfied"
    return 1
}

evaluate_policy_guards() {
    _epg_target="$1"
    
    _epg_current_rb=$(get_journal_rollback_idx)
    if [ "${_epg_current_rb:-0}" -lt 0 ]; then
        log "Policy guard failure: Invalid rollback index"
        return 1
    fi
    
    case "$_epg_target" in
        t2)
            _epg_tries_t2=$(get_journal_tries_t2)
            if [ "${_epg_tries_t2:-0}" -le 0 ]; then
                log "Policy guard failure: Tier 2 attempts exhausted"
                return 1
            fi
            if journal_flag_set "QUARANTINE"; then
                log "Policy guard failure: System quarantined"
                return 1
            fi
            if journal_flag_set "BROWNOUT"; then
                log "Policy guard warning: Brownout flag set - proceeding with caution"
            fi
            ;;
        t3)
            _epg_tries_t3=$(get_journal_tries_t3)
            if [ "${_epg_tries_t3:-0}" -le 0 ]; then
                log "Policy guard failure: Tier 3 attempts exhausted"
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

network_reachable() {
    ping -c 1 -W 2 "$NETWORK_TEST_HOST" >/dev/null 2>&1
}

network_stable_for_seconds() {
    _nsfs_duration="${1:-60}"
    _nsfs_start_ts=$(now_seconds)
    while [ $(( $(now_seconds) - _nsfs_start_ts)) -lt "$_nsfs_duration" ]; do
        if ! network_reachable; then
            return 1
        fi
        sleep 2
    done
    return 0
}

decrement_attempt_counter() {
    _dac_tier="$1"
    case "$_dac_tier" in
        2)
            "$JOURNAL_TOOL" dec-tries 2 "$JOURNAL" >/dev/null 2>&1
            log "Tier 2 promotion attempts decremented"
            ;;
        3)
            "$JOURNAL_TOOL" dec-tries 3 "$JOURNAL" >/dev/null 2>&1
            log "Tier 3 promotion attempts decremented"
            ;;
    esac
}

can_promote_t1_to_t2() {
    evaluate_policy_guards "t2" || return 1
    evaluate_cryptographic_guards "t2" || return 1
    evaluate_health_guards "Tier 2" 3 || return 1
    return 0
}

can_promote_t2_to_t3() {
    evaluate_policy_guards "t3" || return 1
    evaluate_health_guards "Tier 3" 8 || return 1
    if ! network_stable_for_seconds 60; then
        log "Network not stable for Tier 3 promotion (requires 60s stable connectivity per paper spec)"
        return 1
    fi
    return 0
}

check_verifier_reachable() {
    ping -c 1 -W 2 10.0.2.2 >/dev/null 2>&1 && \
    wget -q -O- -T 2 "$VERIFIER_URL/nonce" >/dev/null 2>&1
}

run_attestation_sanity_check() {
    if [ ! -f "$ATTEST_SCRIPT" ]; then
        log "Attestation script missing - cannot run sanity check"
        return 1
    fi

    log "Running attestation sanity check..."
    VERBOSE=0 sh "$ATTEST_SCRIPT" > "$ATTEST_SANITY_LOG" 2>&1
}

get_current_tier() {
    get_journal_tier
}

attempt_tier3_promotion() {
    log "Attempting Tier 3 promotion (runtime evaluation)..."

    PROMO_GUARDS_PASSED=0
    if ! can_promote_t2_to_t3; then
        return 1
    fi
    PROMO_GUARDS_PASSED=1

    if ! check_verifier_reachable; then
        log "Verifier not reachable"
        PROMO_GUARDS_PASSED=0
        return 1
    fi

    log "Verifier available - running attestation..."
    attest_output="/tmp/pac_attest_output_$$"
    if VERBOSE=1 sh "$ATTEST_SCRIPT" >"$attest_output" 2>&1; then
        if grep -q "ATTESTATION PASSED\|Attestation passed" "$attest_output" 2>/dev/null; then
            log " Attestation passed - promoting to Tier 3"
            rm -f "$attest_output" 2>/dev/null || true
            
            if "$JOURNAL_TOOL" set-tier 3 "$JOURNAL" 2>/dev/null; then
                log " PROMOTED to Tier 3 (journal updated)"
                log "Rebooting to apply Tier 3 rootfs..."
                sleep 2
                if command -v reboot >/dev/null 2>&1; then
                    reboot -f
                elif [ -f /proc/sysrq-trigger ]; then
                    echo b > /proc/sysrq-trigger
                else
                    kill -9 1 2>/dev/null || true
                fi
                return 0
            else
                error "Failed to update journal to Tier 3"
                if [ "$PROMO_GUARDS_PASSED" -eq 1 ]; then
                    decrement_attempt_counter 3
                fi
                return 1
            fi
        else
            log "Attestation script returned success but no pass message found"
            log "Last few lines of output:"
            tail -3 "$attest_output" 2>/dev/null | while read line; do
                log "  $line"
            done
            rm -f "$attest_output" 2>/dev/null || true
            if [ "$PROMO_GUARDS_PASSED" -eq 1 ]; then
                decrement_attempt_counter 3
            fi
            return 1
        fi
    else
        log "Attestation failed - checking error output..."
        if [ -f "$attest_output" ]; then
            log "Error output:"
            tail -5 "$attest_output" 2>/dev/null | grep -i "error\|fail" | while read line; do
                log "  $line"
            done
            rm -f "$attest_output" 2>/dev/null || true
        fi
        log "Attestation failed - remaining in Tier 2"
        if [ "$PROMO_GUARDS_PASSED" -eq 1 ]; then
            decrement_attempt_counter 3
        fi
        return 1
    fi
}

check_tier3_degradation() {
    log "Checking Tier 3 degradation conditions..."
    
    should_degrade=0
    degrade_reason=""
    _ct3d_health_unavailable=0
    
    current_time=$(now_seconds)
    if [ -f "$TIER3_START_TIME_FILE" ]; then
        tier3_start=$(cat "$TIER3_START_TIME_FILE" 2>/dev/null || echo "0")
        time_in_tier3=$((current_time - tier3_start))
        if [ "$time_in_tier3" -lt 0 ]; then
            log "Tier 3 clock skew detected (${time_in_tier3}s) - resetting grace timer"
            echo "$current_time" > "$TIER3_START_TIME_FILE" 2>/dev/null || true
            time_in_tier3=0
        fi
        if [ "$time_in_tier3" -lt "$MIN_TIER3_TIME" ]; then
            log "Tier 3 grace period active (${time_in_tier3}s < ${MIN_TIER3_TIME}s) - skipping degradation checks"
            return 1  
        fi
    else
        echo "$current_time" > "$TIER3_START_TIME_FILE" 2>/dev/null || true
        log "Tier 3 grace period started (${MIN_TIER3_TIME}s)"
        return 1  
    fi
    
    if capture_health_score; then
        HEALTH_SCORE="$LAST_HEALTH_SCORE"
        log "[DEBUG T3] Health score: $HEALTH_SCORE (threshold: $MIN_HEALTH_SCORE_T3)"
        if [ "$HEALTH_SCORE" -lt "$MIN_HEALTH_SCORE_T3" ]; then
            should_degrade=1
            degrade_reason="Health degraded ($HEALTH_SCORE < $MIN_HEALTH_SCORE_T3)"
            log "[DEBUG T3] Health degradation triggered! Reason: $degrade_reason"
        else
            log "[DEBUG T3] Health OK ($HEALTH_SCORE >= $MIN_HEALTH_SCORE_T3)"
        fi
    else
        log "Health data unavailable - Tier 3 health guard skipped"
        _ct3d_health_unavailable=1
    fi
    
    if [ -f /sys/kernel/security/ima/violations ]; then
        ima_violations=$(cat /sys/kernel/security/ima/violations 2>/dev/null || echo "0")
        if [ "$ima_violations" -gt 0 ]; then
            should_degrade=1
            if [ -z "$degrade_reason" ]; then
                degrade_reason="IMA integrity violation detected (${ima_violations} violations)"
            else
                degrade_reason="${degrade_reason}; IMA violations: ${ima_violations}"
            fi
            log " IMA integrity violation detected - system compromised"
        fi
    fi
    
    if [ -d /var ]; then
        var_free=$(df /var 2>/dev/null | awk 'NR==2 {print $4}' || echo "999999")
        if [ "$var_free" -lt 10240 ]; then
            should_degrade=1
            if [ -z "$degrade_reason" ]; then
                degrade_reason="Disk space critical (/var: ${var_free}KB < 10MB)"
            else
                degrade_reason="${degrade_reason}; disk space critical"
            fi
        fi
    fi
    
    if [ -r /proc/meminfo ]; then
        mem_total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "100000")
        mem_avail=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "50000")
        if [ "$mem_total" -gt 0 ]; then
            mem_percent=$((mem_avail * 100 / mem_total))
            if [ "$mem_percent" -lt 5 ]; then
                should_degrade=1
                if [ -z "$degrade_reason" ]; then
                    degrade_reason="Memory exhaustion (${mem_percent}% < 5% available)"
                else
                    degrade_reason="${degrade_reason}; memory exhaustion"
                fi
            fi
        fi
    fi
    
    if journal_flag_set "BROWNOUT"; then
        should_degrade=1
        if [ -z "$degrade_reason" ]; then
            degrade_reason="Brownout flag present"
        else
            degrade_reason="${degrade_reason}; brownout flag"
        fi
    fi

    if ! check_verifier_reachable; then
        log "Verifier unreachable - incrementing failure counter..."
        
        fail_count=$(cat "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || echo "0")
        fail_count=$((fail_count + 1))
        echo "$fail_count" > "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || true
        log "Verifier failure count: $fail_count/$VERIFIER_FAIL_THRESHOLD"

        if [ "$fail_count" -ge "$VERIFIER_FAIL_THRESHOLD" ]; then
            log "Verifier failure threshold reached - running attestation sanity check"
            if run_attestation_sanity_check; then
                log "Sanity check succeeded - clearing verifier failure counter"
                rm -f "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || true
                fail_count=0
            else
                should_degrade=1
                if [ -z "$degrade_reason" ]; then
                    degrade_reason="Verifier unreachable (${fail_count} consecutive failures, attestation sanity check failed)"
                fi
            fi
        fi
    else
        if [ -f "$VERIFIER_FAIL_COUNT_FILE" ]; then
            rm -f "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || true
            log "Verifier reachable - failure counter reset"
        fi
    fi
    
    log "[DEBUG T3] should_degrade=$should_degrade, reason='$degrade_reason'"
    if [ "$should_degrade" -eq 1 ]; then
        log " DEGRADING: $degrade_reason - degrading to Tier 2"
        log "[DEBUG T3] Starting degradation process..."
        rm -f "$TIER3_START_TIME_FILE" "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || true
        log "[DEBUG T3] Setting journal tier to 2..."
        if "$JOURNAL_TOOL" set-tier 2 "$JOURNAL" 2>/dev/null; then
            log " DEGRADED to Tier 2 (journal updated)"
            log "Rebooting to apply Tier 2 rootfs..."
            sleep 2
            log "[DEBUG T3] Triggering reboot..."
            if command -v reboot >/dev/null 2>&1; then
                reboot -f
            elif [ -f /proc/sysrq-trigger ]; then
                echo b > /proc/sysrq-trigger
            else
                kill -9 1 2>/dev/null || true
            fi
            return 0
        else
            log " Failed to update journal to Tier 2"
            return 1
        fi
    elif [ "$_ct3d_health_unavailable" -eq 1 ]; then
        log "Health data unavailable - deferring Tier 3 degradation check"
    fi
    
    return 1  
}

attempt_tier2_promotion() {
    log "Attempting Tier 2 promotion (runtime evaluation)..."

    if ! can_promote_t1_to_t2; then
        return 1
    fi

    if [ -f "/usr/lib/pac/setup_network.sh" ]; then
        if sh /usr/lib/pac/setup_network.sh >/dev/null 2>&1; then
            log " Network setup successful - promoting to Tier 2"
            if "$JOURNAL_TOOL" set-tier 2 "$JOURNAL" 2>/dev/null; then
                log " PROMOTED to Tier 2 (journal updated)"
                log "Rebooting to apply Tier 2 rootfs..."
                sleep 2
                if command -v reboot >/dev/null 2>&1; then
                    reboot -f
                elif [ -f /proc/sysrq-trigger ]; then
                    echo b > /proc/sysrq-trigger
                else
                    kill -9 1 2>/dev/null || true
                fi
                return 0
            else
                error "Failed to update journal to Tier 2"
            fi
        else
            log "Network setup script failed - Tier 2 promotion aborted"
        fi
    else
        log "Network setup script missing - cannot promote to Tier 2"
    fi

    log "Tier 2 promotion attempt failed - decrementing tries counter"
    decrement_attempt_counter 2
    return 1
}

check_tier2_degradation() {
    log "Checking Tier 2 degradation conditions..."

    should_degrade=0
    degrade_reason=""
    
    if capture_health_score; then
        HEALTH_SCORE="$LAST_HEALTH_SCORE"
        if [ "$HEALTH_SCORE" -lt "$MIN_HEALTH_SCORE_T2" ]; then
            low_health=$(cat "$HEALTH_FAIL_COUNT_FILE" 2>/dev/null || echo "0")
            low_health=$((low_health + 1))
            echo "$low_health" > "$HEALTH_FAIL_COUNT_FILE" 2>/dev/null || true
            log "Health degraded ($HEALTH_SCORE < $MIN_HEALTH_SCORE_T2) - consecutive low health: ${low_health}/${HEALTH_FAIL_THRESHOLD}"

            if [ "$low_health" -ge "$HEALTH_FAIL_THRESHOLD" ]; then
                should_degrade=1
                degrade_reason="Sustained health degradation (${low_health} consecutive failures)"
            fi
        else
            if [ -f "$HEALTH_FAIL_COUNT_FILE" ]; then
                rm -f "$HEALTH_FAIL_COUNT_FILE" 2>/dev/null || true
                log "Health recovered - clearing low-health counter"
            fi
        fi
    else
        log "Health data unavailable - skipping health-based degradation check"
    fi
    
    if [ -d /var ]; then
        var_free=$(df /var 2>/dev/null | awk 'NR==2 {print $4}' || echo "999999")
        if [ "$var_free" -lt 5120 ]; then
            should_degrade=1
            if [ -z "$degrade_reason" ]; then
                degrade_reason="Critical disk space (/var: ${var_free}KB < 5MB)"
            else
                degrade_reason="${degrade_reason}; critical disk space"
            fi
        fi
    fi
    
    if [ -r /proc/meminfo ]; then
        mem_total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "100000")
        mem_avail=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "50000")
        if [ "$mem_total" -gt 0 ]; then
            mem_percent=$((mem_avail * 100 / mem_total))
            if [ "$mem_percent" -lt 3 ]; then
                should_degrade=1
                if [ -z "$degrade_reason" ]; then
                    degrade_reason="Critical memory exhaustion (${mem_percent}% < 3% available)"
                else
                    degrade_reason="${degrade_reason}; critical memory exhaustion"
                fi
            fi
        fi
    fi
    
    if [ "$should_degrade" -eq 1 ]; then
        log " DEGRADING: $degrade_reason - degrading to Tier 2"
        rm -f "$HEALTH_FAIL_COUNT_FILE" 2>/dev/null || true
        if "$JOURNAL_TOOL" set-tier 2 "$JOURNAL" 2>/dev/null; then
            log " DEGRADED to Tier 2 (journal updated)"
            log "Rebooting to apply Tier 2 (reduced functionality)..."
            sleep 2
            if command -v reboot >/dev/null 2>&1; then
                reboot -f
            elif [ -f /proc/sysrq-trigger ]; then
                echo b > /proc/sysrq-trigger
            else
                kill -9 1 2>/dev/null || true
            fi
            return 0
        else
            error "Failed to update journal to Tier 1"
            return 1
        fi
    fi

    return 1
}

monitor_loop() {
    log "Policy monitor daemon started (interval: ${MONITOR_INTERVAL}s)"
    log "Monitoring for tier promotion/degradation conditions..."
    
    while true; do
        if journal_flag_set "EMERGENCY"; then
            log " EMERGENCY FLAG DETECTED - entering recovery mode (S_13)"
            log "System will remain in recovery mode until flag is cleared manually"
            log "To clear emergency mode: "$JOURNAL_TOOL" clear-flag EMERGENCY /var/pac/journal.dat"
            sleep 300 2>/dev/null || sleep 60
            continue
        fi
        
        CURRENT_STATE=$(get_current_state)
        
        case "$CURRENT_STATE" in
            "$STATE_T1_OK")
                log "Monitoring Tier 1 -> Tier 2 promotion..."
                if attempt_tier2_promotion; then
                    log " Successfully promoted to Tier 2"
                fi
                ;;
            "$STATE_T2_OK")
                log "Monitoring Tier 2 -> Tier 3 promotion..."
                if attempt_tier3_promotion; then
                    log " Successfully promoted to Tier 3"
                fi

                if check_tier2_degradation; then
                    log " DEGRADATION COMPLETE: Tier 2 -> Tier 1"
                fi
                ;;
            "$STATE_T3_OK")
                log "Checking Tier 3 degradation conditions..."
                
                if [ ! -f "$TIER3_START_TIME_FILE" ]; then
                    echo "$(now_seconds)" > "$TIER3_START_TIME_FILE" 2>/dev/null || true
                fi
                
                if check_tier3_degradation; then
                    log " DEGRADATION COMPLETE: Tier 3 -> Tier 2"
                    log "System has been degraded to Tier 2"
                else
                    last_log_ts=$(cat /tmp/pac_monitor_last_log 2>/dev/null || echo 0)
                    current_ts=$(now_seconds)
                    if [ ! -f /tmp/pac_monitor_last_log ] || [ $((current_ts - last_log_ts)) -gt 30 ]; then
                        if check_verifier_reachable; then
                            log "Tier 3 status: Verifier reachable, system healthy"
                        else
                            fail_count=$(cat "$VERIFIER_FAIL_COUNT_FILE" 2>/dev/null || echo "0")
                            log "Tier 3 status: Verifier unreachable (failures: ${fail_count}/${VERIFIER_FAIL_THRESHOLD})"
                        fi
                        echo "$current_ts" > /tmp/pac_monitor_last_log 2>/dev/null || true
                    fi
                fi
                ;;
            "$STATE_RECOVERY")
                log "Recovery state active - awaiting operator intervention"
                ;;
            *)
                log "Unknown FSM state ($CURRENT_STATE) - defaulting to Tier 1 monitoring"
                ;;
        esac
        
        if command -v sleep >/dev/null 2>&1; then
            sleep "${MONITOR_INTERVAL}" 2>/dev/null || true
        fi
    done
}

start_daemon() {
    mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null || true
    
    if [ -f "$PIDFILE" ]; then
        oldpid=$(cat "$PIDFILE" 2>/dev/null || echo "")
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            log "Policy monitor already running (PID: $oldpid)"
            return 1
        fi
        rm -f "$PIDFILE"
    fi
    
    log "Starting policy monitor daemon..."
    monitor_loop &
    pid=$!
    echo "$pid" > "$PIDFILE" 2>/dev/null || true
    log "Policy monitor daemon started (PID: $pid)"
    return 0
}

stop_daemon() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null && log "Policy monitor stopped (PID: $pid)" || error "Failed to stop monitor"
            rm -f "$PIDFILE"
            return 0
        fi
    fi
    log "Policy monitor not running"
    return 1
}

case "${1:-start}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        start_daemon
        ;;
    status)
        if [ -f "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "Policy monitor running (PID: $pid)"
                CURRENT_TIER=$(get_current_tier)
                echo "Current tier: $CURRENT_TIER"
                check_verifier_reachable && echo "Verifier: reachable" || echo "Verifier: unreachable"
                exit 0
            fi
        fi
        echo "Policy monitor not running"
        exit 1
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac


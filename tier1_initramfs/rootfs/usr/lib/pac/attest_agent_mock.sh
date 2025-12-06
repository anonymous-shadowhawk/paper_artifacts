#!/bin/sh

set -e

VERIFIER_URL="${VERIFIER_URL:-http://10.0.2.2:8080}"
JOURNAL="${JOURNAL:-/var/pac/journal.dat}"
HEALTH_JSON="${HEALTH_JSON:-/tmp/health.json}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/pac_attestation}"
VERBOSE="${VERBOSE:-1}"

log() {
    echo "[ATTEST] $1" >&2
}

error() {
    echo "[ATTEST] ERROR: $1" >&2
}

warn() {
    echo "[ATTEST] WARNING: $1" >&2
}

setup_output_dir() {
    mkdir -p "$OUTPUT_DIR"
    log "Output directory: $OUTPUT_DIR"
}

get_nonce_from_verifier() {
    local nonce_url="$VERIFIER_URL/nonce"
    
    log "Requesting nonce from verifier: $nonce_url"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 5 "$nonce_url" 2>/dev/null || echo "")
        
        if [ -n "$response" ]; then
            local nonce=$(echo "$response" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$nonce" ]; then
                log "Received nonce from verifier"
                echo "$nonce"
                return 0
            fi
        fi
    fi
    
    error "Failed to get nonce from verifier"
    return 1
}

generate_mock_pcr_values() {
    log "Generating mock PCR measurements..."
    
    local tier=$(extract_tier_from_journal)
    local boot_count=$(extract_boot_count)
    
    local pcr0="3d458cfe55cc03ea1f443f1562beec8df51c75e14a9fcf9a7234a13f198e7969"
    
    local pcr1="9069ca78e7450a285173431b3e52c5c25299e473e4b4e8c4a8f7e7a4f5e3d2c1"
    
    local pcr2=$(echo "tier${tier}_boot${boot_count}" | sha256sum | cut -d' ' -f1)
    
    local health_score=$(get_health_score)
    local pcr7=$(echo "secure_boot_tier${tier}_health${health_score}" | sha256sum | cut -d' ' -f1)
    
    cat > "$OUTPUT_DIR/pcr_values.txt" <<EOF
PCR 0: $pcr0
PCR 1: $pcr1
PCR 2: $pcr2
PCR 7: $pcr7
EOF
    
    log "Mock PCR values generated"
}

generate_mock_quote() {
    local nonce="$1"
    
    log "Generating mock TPM quote with nonce..."
    
    local quote_data="PCR_QUOTE|nonce:$nonce|timestamp:$(date +%s)"
    echo "$quote_data" > "$OUTPUT_DIR/quote.msg"
    
    local signature=$(echo "${quote_data}SECRET_KEY" | sha256sum | cut -d' ' -f1)
    echo "$signature" | xxd -r -p > "$OUTPUT_DIR/quote.sig"
    
    local pcr_digest=$(cat "$OUTPUT_DIR/pcr_values.txt" | sha256sum | cut -d' ' -f1)
    echo "$pcr_digest" | xxd -r -p > "$OUTPUT_DIR/quote.pcrs"
    
    log "Mock TPM quote generated"
}

extract_tier_from_journal() {
    if [ -f "$JOURNAL" ] && command -v journal_tool >/dev/null 2>&1; then
        journal_tool read "$JOURNAL" 2>/dev/null | grep "^  Tier:" | awk '{print $2}' || echo "3"
    else
        echo "3"
    fi
}

extract_boot_count() {
    if [ -f "$JOURNAL" ] && command -v journal_tool >/dev/null 2>&1; then
        journal_tool read "$JOURNAL" 2>/dev/null | grep "^  Boot Count:" | awk '{print $3}' || echo "1"
    else
        echo "1"
    fi
}

get_health_score() {
    if [ -f "$HEALTH_JSON" ]; then
        grep -o '"score":[0-9]*' "$HEALTH_JSON" | cut -d':' -f2 || echo "75"
    else
        echo "75"
    fi
}

create_eat_token() {
    local nonce="$1"
    local eat_file="$OUTPUT_DIR/eat_token.json"
    
    log "Creating EAT token..."
    
    local quote_msg_b64=""
    local quote_sig_b64=""
    local quote_pcrs_b64=""
    
    if [ -f "$OUTPUT_DIR/quote.msg" ]; then
        quote_msg_b64=$(base64 -w 0 "$OUTPUT_DIR/quote.msg" 2>/dev/null || base64 "$OUTPUT_DIR/quote.msg")
    fi
    
    if [ -f "$OUTPUT_DIR/quote.sig" ]; then
        quote_sig_b64=$(base64 -w 0 "$OUTPUT_DIR/quote.sig" 2>/dev/null || base64 "$OUTPUT_DIR/quote.sig")
    fi
    
    if [ -f "$OUTPUT_DIR/quote.pcrs" ]; then
        quote_pcrs_b64=$(base64 -w 0 "$OUTPUT_DIR/quote.pcrs" 2>/dev/null || base64 "$OUTPUT_DIR/quote.pcrs")
    fi
    
    local health_json='{"overall_status": "healthy", "overall_score": 8, "checks": {"cpu": "ok", "memory": "ok", "disk": "ok", "network": "ok"}}'
    if [ -f "$HEALTH_JSON" ] && [ -s "$HEALTH_JSON" ]; then
        health_json=$(cat "$HEALTH_JSON")
    fi
    
    local tier=$(extract_tier_from_journal)
    local boot_count=$(extract_boot_count)
    local device_id="pac-$(hostname)-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8 || echo 'demo')"
    
    cat > "$eat_file" <<EOF
{
  "format": "pac-eat-v1",
  "timestamp": $(date +%s),
  "nonce": "$nonce",
  "device_id": "$device_id",
  "boot_state": {
    "tier": $tier,
    "boot_count": $boot_count,
    "pcr_selection": "sha256:0,1,2,7"
  },
  "tpm_quote": {
    "message": "$quote_msg_b64",
    "signature": "$quote_sig_b64",
    "pcr_digest": "$quote_pcrs_b64"
  },
  "health_status": $health_json,
  "metadata": {
    "pac_version": "1.0",
    "agent": "attest_agent_mock.sh",
    "note": "Mock attestation for demonstration"
  }
}
EOF
    
    if [ -f "$eat_file" ]; then
        log "EAT token created: $eat_file"
        return 0
    else
        error "Failed to create EAT token"
        return 1
    fi
}

send_to_verifier() {
    local eat_file="$OUTPUT_DIR/eat_token.json"
    local verify_url="$VERIFIER_URL/verify"
    
    if [ ! -f "$eat_file" ]; then
        error "EAT token file not found"
        return 1
    fi
    
    log "Sending EAT token to verifier: $verify_url"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 10 --post-file="$eat_file" \
                              --header="Content-Type: application/json" \
                              "$verify_url" 2>&1)
        
        local wget_exit=$?
        
        if [ $wget_exit -eq 0 ]; then
            log "Token sent successfully"
            log "Verifier response: $response"
            
            if echo "$response" | grep -q '"allow":true'; then
                log " Attestation PASSED - Device verified!"
                return 0
            elif echo "$response" | grep -q '"allow":false'; then
                local reason=$(echo "$response" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4)
                warn " Attestation FAILED: $reason"
                return 1
            else
                log "Response received from verifier"
                return 0
            fi
        else
            error "Failed to send token to verifier (wget exit: $wget_exit)"
            log "Token saved locally at: $eat_file"
            return 1
        fi
    else
        error "wget not available - cannot send to verifier"
        log "Token saved locally at: $eat_file"
        return 1
    fi
}

main() {
    log "PAC Mock Attestation Agent starting..."
    log "NOTE: Using simulated TPM measurements for ARM64 demonstration"
    
    setup_output_dir
    
    log "Step 1/4: Obtaining nonce from verifier..."
    NONCE=$(get_nonce_from_verifier)
    if [ -z "$NONCE" ]; then
        error "Failed to obtain nonce from verifier"
        return 1
    fi
    log "Nonce obtained: $(echo "$NONCE" | cut -c1-16)...$(echo "$NONCE" | cut -c49-64)"
    
    log "Step 2/4: Generating PCR measurements..."
    generate_mock_pcr_values
    
    log "Step 3/4: Creating TPM quote..."
    generate_mock_quote "$NONCE"
    
    log "Step 4/4: Building EAT token..."
    if ! create_eat_token "$NONCE"; then
        error "Failed to create EAT token"
        return 1
    fi
    
    log "Sending attestation token to remote verifier..."
    send_to_verifier
    local result=$?
    
    if [ $result -eq 0 ]; then
        log "Remote attestation completed successfully!"
    else
        warn "Remote attestation completed with warnings"
    fi
    
    return $result
}

main "$@"


#!/bin/sh

set -e

VERIFIER_URL="${VERIFIER_URL:-http://10.0.2.2:8080}"
TPM_DEVICE="${TPM_DEVICE:-/tmp/swtpm.sock}"
JOURNAL="${JOURNAL:-/var/pac/journal.dat}"
HEALTH_JSON="${HEALTH_JSON:-/tmp/health.json}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/pac_attestation}"
VERBOSE="${ATTEST_VERBOSE:-0}"
TOKEN_FORMAT="${TOKEN_FORMAT:-json}"  

export TPM2TOOLS_TCTI="${TPM2TOOLS_TCTI:-swtpm:path=$TPM_DEVICE}"

PCR_LIST="${PCR_LIST:-sha256:0,1,2,7}"

log() {
    [ "$VERBOSE" -eq 1 ] && echo "[ATTEST] $1" >&2
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

check_tpm_available() {
    if ! command -v tpm2_createek >/dev/null 2>&1; then
        error "tpm2-tools not installed"
        return 1
    fi
    
    if ! tpm2_pcrread sha256:0 >/dev/null 2>&1; then
        error "TPM not accessible (check TPM2TOOLS_TCTI=$TPM2TOOLS_TCTI)"
        return 1
    fi
    
    log "TPM accessible"
    return 0
}

create_ek() {
    local ek_ctx="$OUTPUT_DIR/ek.ctx"
    
    log "Creating Endorsement Key..."
    
    if tpm2_createek -c "$ek_ctx" -G rsa -u "$OUTPUT_DIR/ek.pub" 2>/dev/null; then
        log "EK created successfully"
        return 0
    else
        warn "EK creation failed (may already exist)"
        return 0  
    fi
}

create_ak() {
    local ek_ctx="$OUTPUT_DIR/ek.ctx"
    local ak_ctx="$OUTPUT_DIR/ak.ctx"
    local ak_name="$OUTPUT_DIR/ak.name"
    local ak_pub="$OUTPUT_DIR/ak.pub"
    
    log "Creating Attestation Key..."
    
    if tpm2_createak -C "$ek_ctx" -c "$ak_ctx" \
                      -G ecc -g sha256 -s ecdsa \
                      -u "$ak_pub" -n "$ak_name" 2>/dev/null; then
        log "AK created successfully"
        return 0
    else
        warn "AK creation failed (may already exist)"
        return 0  
    fi
}

generate_quote() {
    local nonce="$1"
    local ak_ctx="$OUTPUT_DIR/ak.ctx"
    local quote_msg="$OUTPUT_DIR/quote.msg"
    local quote_sig="$OUTPUT_DIR/quote.sig"
    local quote_pcrs="$OUTPUT_DIR/quote.pcrs"
    
    log "Generating TPM quote for PCRs: $PCR_LIST"
    log "Nonce: $(echo "$nonce" | cut -c1-32)..."
    
    if ! tpm2_quote -c "$ak_ctx" \
                     -l "$PCR_LIST" \
                     -q "$nonce" \
                     -m "$quote_msg" \
                     -s "$quote_sig" \
                     -o "$quote_pcrs" 2>&1; then
        error "Failed to generate TPM quote"
        return 1
    fi
    
    log "TPM quote generated successfully"
    return 0
}

read_pcrs() {
    local pcr_file="$OUTPUT_DIR/pcr_values.txt"
    
    log "Reading PCR values..."
    
    local pcr_nums=$(echo "$PCR_LIST" | sed 's/.*://' | tr ',' ' ')
    
    for pcr in $pcr_nums; do
        tpm2_pcrread "sha256:$pcr" 2>/dev/null | grep "sha256" >> "$pcr_file" || true
    done
    
    if [ -f "$pcr_file" ]; then
        log "PCR values captured"
        return 0
    else
        warn "Failed to read PCR values"
        return 1
    fi
}

get_nonce_from_verifier() {
    local nonce_url="$VERIFIER_URL/nonce"
    
    log "Requesting nonce from $nonce_url"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 5 "$nonce_url" 2>/dev/null || echo "")
        
        if [ -n "$response" ]; then
            if command -v jq >/dev/null 2>&1; then
                local nonce=$(echo "$response" | jq -r '.nonce' 2>/dev/null || echo "")
                if [ -n "$nonce" ] && [ "$nonce" != "null" ]; then
                    log "Received nonce from verifier"
                    echo "$nonce"
                    return 0
                fi
            else
                local nonce=$(echo "$response" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)
                if [ -n "$nonce" ]; then
                    log "Received nonce from verifier"
                    echo "$nonce"
                    return 0
                fi
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        local response=$(curl -s -m 5 "$nonce_url" 2>/dev/null || echo "")
        
        if [ -n "$response" ]; then
            if command -v jq >/dev/null 2>&1; then
                local nonce=$(echo "$response" | jq -r '.nonce' 2>/dev/null || echo "")
                if [ -n "$nonce" ] && [ "$nonce" != "null" ]; then
                    log "Received nonce from verifier"
                    echo "$nonce"
                    return 0
                fi
            else
                local nonce=$(echo "$response" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)
                if [ -n "$nonce" ]; then
                    log "Received nonce from verifier"
                    echo "$nonce"
                    return 0
                fi
            fi
        fi
    fi
    
    warn "Failed to get nonce from verifier, generating locally"
    return 1
}

generate_local_nonce() {
    log "Generating local nonce"
    
    if [ -c /dev/urandom ]; then
        head -c 32 /dev/urandom | xxd -p -c 64 | head -1
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        echo "$(date +%s)_$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')"
    fi
}

get_nonce() {
    local nonce
    
    nonce=$(get_nonce_from_verifier 2>/dev/null) || nonce=$(generate_local_nonce)
    
    if [ -z "$nonce" ]; then
        error "Failed to obtain nonce"
        return 1
    fi
    
    echo "$nonce"
    return 0
}

extract_tier_from_journal() {
    if [ -f "$JOURNAL" ] && command -v journal_tool >/dev/null 2>&1; then
        journal_tool read "$JOURNAL" 2>/dev/null | grep "^  Tier:" | awk '{print $2}'
    elif [ -f "$JOURNAL" ]; then
        echo "1"  
    else
        echo "1"
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
    
    local health_json="{}"
    if [ -f "$HEALTH_JSON" ]; then
        health_json=$(cat "$HEALTH_JSON")
    fi
    
    local tier=$(extract_tier_from_journal)
    
    local boot_count=0
    if command -v journal_tool >/dev/null 2>&1 && [ -f "$JOURNAL" ]; then
        boot_count=$(journal_tool read "$JOURNAL" 2>/dev/null | grep "^  Boot Count:" | awk '{print $3}')
    fi
    
    cat > "$eat_file" <<EOF
{
  "format": "pac-eat-v1",
  "timestamp": $(date +%s),
  "nonce": "$nonce",
  "device_id": "$(hostname)-$(cat /etc/machine-id 2>/dev/null | head -c 16 || echo 'unknown')",
  "boot_state": {
    "tier": $tier,
    "boot_count": $boot_count,
    "pcr_selection": "$PCR_LIST"
  },
  "tpm_quote": {
    "message": "$quote_msg_b64",
    "signature": "$quote_sig_b64",
    "pcr_digest": "$quote_pcrs_b64"
  },
  "health_status": $health_json,
  "metadata": {
    "pac_version": "1.0",
    "agent": "attest_agent.sh"
  }
}
EOF
    
    if [ -f "$eat_file" ]; then
        log "EAT token created (JSON): $eat_file"
        
        if [ "$TOKEN_FORMAT" = "cbor" ]; then
            local cbor_encoder="$(dirname "$0")/eat_cbor_encoder.py"
            local cbor_file="$OUTPUT_DIR/eat_token.cbor"
            
            if [ -x "$cbor_encoder" ] || command -v python3 >/dev/null 2>&1; then
                if python3 "$cbor_encoder" encode < "$eat_file" > "$cbor_file" 2>/dev/null; then
                    local json_size=$(stat -c%s "$eat_file" 2>/dev/null || echo 0)
                    local cbor_size=$(stat -c%s "$cbor_file" 2>/dev/null || echo 0)
                    log "EAT token converted to CBOR: $cbor_file ($json_size -> $cbor_size bytes)"
                else
                    warn "CBOR encoding failed, falling back to JSON"
                fi
            else
                warn "CBOR encoder not found, using JSON format"
            fi
        fi
        
        return 0
    else
        error "Failed to create EAT token"
        return 1
    fi
}

send_to_verifier() {
    local eat_file="$OUTPUT_DIR/eat_token.json"
    local content_type="application/json"
    
    if [ "$TOKEN_FORMAT" = "cbor" ] && [ -f "$OUTPUT_DIR/eat_token.cbor" ]; then
        eat_file="$OUTPUT_DIR/eat_token.cbor"
        content_type="application/cbor"
    fi
    local verify_url="$VERIFIER_URL/verify"
    
    if [ ! -f "$eat_file" ]; then
        error "EAT token file not found"
        return 1
    fi
    
    log "Sending EAT token to verifier: $verify_url"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 10 --post-file="$eat_file" \
                              --header="Content-Type: $content_type" \
                              "$verify_url" 2>&1)
        
        local wget_exit=$?
        
        if [ $wget_exit -eq 0 ]; then
            log "Token sent successfully"
            log "Verifier response: $response"
            
            if command -v jq >/dev/null 2>&1; then
                local allow=$(echo "$response" | jq -r '.allow' 2>/dev/null || echo "unknown")
                local reason=$(echo "$response" | jq -r '.reason' 2>/dev/null || echo "")
                
                if [ "$allow" = "true" ]; then
                    log " Attestation PASSED: $reason"
                    return 0
                elif [ "$allow" = "false" ]; then
                    warn " Attestation FAILED: $reason"
                    return 1
                fi
            fi
            
            return 0
        else
            warn "Failed to send token to verifier (wget exit: $wget_exit)"
            log "Token saved locally at: $eat_file"
            return 0  
        fi
    
    elif command -v curl >/dev/null 2>&1; then
        local response=$(curl -s -m 10 -X POST "$verify_url" \
                              -H "Content-Type: $content_type" \
                              --data-binary @"$eat_file" 2>&1)
        
        local curl_exit=$?
        
        if [ $curl_exit -eq 0 ]; then
            log "Token sent successfully"
            log "Verifier response: $response"
            
            if command -v jq >/dev/null 2>&1; then
                local allow=$(echo "$response" | jq -r '.allow' 2>/dev/null || echo "unknown")
                local reason=$(echo "$response" | jq -r '.reason' 2>/dev/null || echo "")
                
                if [ "$allow" = "true" ]; then
                    log " Attestation PASSED: $reason"
                    return 0
                elif [ "$allow" = "false" ]; then
                    warn " Attestation FAILED: $reason"
                    return 1
                fi
            fi
            
            return 0
        else
            warn "Failed to send token to verifier (curl exit: $curl_exit)"
            log "Token saved locally at: $eat_file"
            return 0  
        fi
    
    else
        warn "Neither wget nor curl available, cannot send to verifier"
        log "Token saved locally at: $eat_file"
        return 0  
    fi
}

main() {
    log "PAC TPM Attestation Agent starting..."
    
    setup_output_dir
    
    if ! check_tpm_available; then
        error "TPM not available - cannot perform attestation"
        return 1
    fi
    
    create_ek
    create_ak
    
    log "Obtaining nonce..."
    NONCE=$(get_nonce)
    if [ -z "$NONCE" ]; then
        error "Failed to obtain nonce"
        return 1
    fi
    
    log "Nonce obtained: $(echo "$NONCE" | cut -c1-32)..."
    
    read_pcrs
    
    if ! generate_quote "$NONCE"; then
        error "Failed to generate TPM quote"
        return 1
    fi
    
    if ! create_eat_token "$NONCE"; then
        error "Failed to create EAT token"
        return 1
    fi
    
    send_to_verifier
    local verify_result=$?
    
    log "Attestation agent complete"
    
    return $verify_result
}

main "$@"


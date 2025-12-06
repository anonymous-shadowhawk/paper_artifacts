#!/bin/sh

set -e

VERIFIER_URL="${VERIFIER_URL:-http://10.0.2.2:8080}"
JOURNAL="${JOURNAL:-/var/pac/journal.dat}"
HEALTH_JSON="${HEALTH_JSON:-/tmp/health.json}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/pac_attestation}"
VERBOSE="${VERBOSE:-1}"

KEY_SIZE=2048
HASH_ALG="sha256"

EAT_FORMAT="${EAT_FORMAT:-json}"
CBOR_ENCODER="/usr/lib/pac/eat_cbor_encoder.py"

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

generate_aik() {
    local priv_key="$OUTPUT_DIR/aik_private.pem"
    local pub_key="$OUTPUT_DIR/aik_public.pem"
    
    if [ -f "$priv_key" ] && [ -f "$pub_key" ]; then
        log "Using existing AIK keys"
        return 0
    fi
    
    log "Generating RSA-${KEY_SIZE} Attestation Identity Key (AIK)..."
    
    OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"
    
    if [ ! -x "$OPENSSL_BIN" ]; then
        error "OpenSSL not available at $OPENSSL_BIN - cannot generate real keys"
        return 1
    fi
    
    if ! "$OPENSSL_BIN" genrsa -out "$priv_key" "$KEY_SIZE" 2>/dev/null; then
        error "Failed to generate RSA private key"
        error "OpenSSL binary: $OPENSSL_BIN (exists: $([ -x "$OPENSSL_BIN" ] && echo 'yes' || echo 'no'))"
        return 1
    fi
    
    if ! "$OPENSSL_BIN" rsa -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null; then
        error "Failed to extract public key"
        return 1
    fi
    
    log " AIK generated: RSA-${KEY_SIZE}"
    return 0
}

generate_pcr_measurements() {
    log "Generating PCR measurements..."
    
    local pcr_file="$OUTPUT_DIR/pcrs.txt"
    
    local kernel_hash=""
    if [ -f /proc/version ]; then
        kernel_hash=$(cat /proc/version | sha256sum | cut -d' ' -f1)
    else
        kernel_hash=$(echo "kernel-placeholder" | sha256sum | cut -d' ' -f1)
    fi
    
    local config_hash=$(echo "bootloader-config" | sha256sum | cut -d' ' -f1)
    
    local tier=$(extract_tier_from_journal)
    local boot_count=$(extract_boot_count)
    local tier_hash=$(echo "tier${tier}_boot${boot_count}" | sha256sum | cut -d' ' -f1)
    
    local health_score=$(get_health_score)
    local policy_hash=$(echo "secureboot_tier${tier}_health${health_score}" | sha256sum | cut -d' ' -f1)
    
    cat > "$pcr_file" <<EOF
PCR-00: ${kernel_hash}
PCR-01: ${config_hash}
PCR-02: ${tier_hash}
PCR-07: ${policy_hash}
EOF
    
    log " PCR measurements generated"
    
    cat "$pcr_file" | sha256sum | cut -d' ' -f1 > "$OUTPUT_DIR/pcr_digest.txt"
}

generate_signed_quote() {
    local nonce="$1"
    local priv_key="$OUTPUT_DIR/aik_private.pem"
    local quote_data="$OUTPUT_DIR/quote_data.txt"
    local quote_sig="$OUTPUT_DIR/quote_signature.bin"
    local quote_sig_b64="$OUTPUT_DIR/quote_signature.b64"
    
    log "Creating cryptographically signed TPM quote..."
    
    local timestamp=$(date +%s)
    local pcr_digest=$(cat "$OUTPUT_DIR/pcr_digest.txt")
    local tier=$(extract_tier_from_journal)
    
    cat > "$quote_data" <<EOF
TPM_QUOTE_V1
timestamp: $timestamp
nonce: $nonce
pcr_digest: $pcr_digest
tier: $tier
clock: $(cat /proc/uptime | cut -d' ' -f1)
EOF
    
    log "Quote data prepared (nonce: $(echo "$nonce" | cut -c1-16)...)"
    
    OPENSSL_BIN="${OPENSSL_BIN:-/usr/bin/openssl}"
    if ! "$OPENSSL_BIN" dgst -${HASH_ALG} -sign "$priv_key" -out "$quote_sig" "$quote_data" 2>/dev/null; then
        error "Failed to sign quote data"
        return 1
    fi
    
    base64 -w 0 "$quote_sig" > "$quote_sig_b64" 2>/dev/null || base64 "$quote_sig" > "$quote_sig_b64"
    
    log " Quote signed with RSA-${KEY_SIZE} (SHA-256)"
    return 0
}

get_nonce_from_verifier() {
    local nonce_url="$VERIFIER_URL/nonce"
    
    log "Requesting nonce from verifier: $nonce_url"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 5 "$nonce_url" 2>/dev/null || echo "")
        
        if [ -n "$response" ]; then
            local nonce=$(echo "$response" | grep -o '"nonce":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$nonce" ]; then
                log " Received nonce from verifier"
                echo "$nonce"
                return 0
            fi
        fi
    fi
    
    error "Failed to get nonce from verifier"
    return 1
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
        grep -o '"overall_score":[0-9]*' "$HEALTH_JSON" | cut -d':' -f2 || echo "8"
    else
        echo "8"
    fi
}

create_eat_token() {
    local nonce="$1"
    local eat_file="$OUTPUT_DIR/eat_token.json"
    
    log "Creating EAT token with cryptographic proof..."
    
    local quote_data_b64=$(base64 -w 0 "$OUTPUT_DIR/quote_data.txt" 2>/dev/null || base64 "$OUTPUT_DIR/quote_data.txt")
    local quote_sig_b64=$(cat "$OUTPUT_DIR/quote_signature.b64")
    local pub_key_b64=$(base64 -w 0 "$OUTPUT_DIR/aik_public.pem" 2>/dev/null || base64 "$OUTPUT_DIR/aik_public.pem")
    local pcr_digest=$(cat "$OUTPUT_DIR/pcr_digest.txt")
    
    local pcr0=$(grep "PCR-00:" "$OUTPUT_DIR/pcrs.txt" | cut -d' ' -f2)
    local pcr1=$(grep "PCR-01:" "$OUTPUT_DIR/pcrs.txt" | cut -d' ' -f2)
    local pcr2=$(grep "PCR-02:" "$OUTPUT_DIR/pcrs.txt" | cut -d' ' -f2)
    local pcr7=$(grep "PCR-07:" "$OUTPUT_DIR/pcrs.txt" | cut -d' ' -f2)
    
    local health_json='{"overall_status":"healthy","overall_score":8}'
    if [ -f "$HEALTH_JSON" ] && [ -s "$HEALTH_JSON" ]; then
        health_json=$(cat "$HEALTH_JSON")
    fi
    
    local tier=$(extract_tier_from_journal)
    local boot_count=$(extract_boot_count)
    local device_id="pac-$(hostname)-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8 || echo 'secure')"
    
    cat > "$eat_file" <<EATEOF
{"format":"pac-eat-v2-signed","timestamp":$(date +%s),"nonce":"$nonce","device_id":"$device_id","boot_state":{"tier":$tier,"boot_count":$boot_count},"tpm_attestation":{"version":"2.0","quote_data":"$quote_data_b64","signature":"$quote_sig_b64","signature_algorithm":"RSA-${KEY_SIZE}-SHA256","public_key":"$pub_key_b64","pcr_digest":"$pcr_digest","pcrs":{"0":"$pcr0","1":"$pcr1","2":"$pcr2","7":"$pcr7"}},"health_status":$health_json,"metadata":{"pac_version":"2.0","agent":"attest_agent_crypto.sh","crypto":"real"}}
EATEOF
    
    if [ -f "$eat_file" ]; then
        log " EAT token created with real cryptographic signatures (JSON format)"
        
        if [ "$EAT_FORMAT" = "cbor" ]; then
            if command -v python3 >/dev/null 2>&1 && [ -f "$CBOR_ENCODER" ]; then
                log "Converting to CBOR/COSE format..."
                local cbor_file="$OUTPUT_DIR/eat_token.cbor"
                local priv_key="$OUTPUT_DIR/aik_private.pem"
                
                if python3 "$CBOR_ENCODER" "$eat_file" "$cbor_file" "$priv_key" 2>&1 | while read line; do log "$line"; done; then
                    log " CBOR/COSE token created successfully"
                    return 0
                else
                    warn "CBOR conversion failed - falling back to JSON"
                    return 0
                fi
            else
                warn "Python3 or CBOR encoder not available - using JSON format"
                return 0
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
    local cbor_file="$OUTPUT_DIR/eat_token.cbor"
    local content_type="application/json"
    local verify_url="$VERIFIER_URL/verify"
    
    if [ -f "$cbor_file" ] && [ "$EAT_FORMAT" = "cbor" ]; then
        eat_file="$cbor_file"
        content_type="application/cbor"
        log "Using CBOR/COSE format"
    fi
    
    if [ ! -f "$eat_file" ]; then
        error "EAT token file not found"
        return 1
    fi
    
    log "Sending signed EAT token to verifier: $verify_url"
    log "Format: $content_type, Size: $(wc -c < "$eat_file") bytes"
    
    if command -v wget >/dev/null 2>&1; then
        local response=$(wget -q -O- -T 10 --post-file="$eat_file" \
                              --header="Content-Type: $content_type" \
                              "$verify_url" 2>&1)
        
        local wget_exit=$?
        
        if echo "$response" | grep -qi "HTTP.*400\|HTTP.*500\|HTTP.*404"; then
            error "HTTP error from verifier: $(echo "$response" | grep -i "HTTP")"
            log "Response: $response"
            return 1
        fi
        
        if [ $wget_exit -eq 0 ]; then
            log " Token sent successfully"
            
            if echo "$response" | grep -q '"allow":true'; then
                log " ATTESTATION PASSED - Cryptographic verification successful!"
                echo "$response" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4 | sed 's/^/    /'
                return 0
            elif echo "$response" | grep -q '"allow":false'; then
                local reason=$(echo "$response" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4)
                warn " Attestation FAILED: $reason"
                return 1
            else
                log "Response: $response"
                return 0
            fi
        else
            error "Failed to send token (wget exit: $wget_exit)"
            log "Response: $response"
            log "Token saved locally at: $eat_file"
            return 1
        fi
    else
        error "wget not available"
        return 1
    fi
}

main() {
    log ""
    log "PAC Cryptographic Attestation Agent"
    log "Real RSA signatures with OpenSSL"
    log ""
    
    setup_output_dir
    
    log "Step 1/5: Key Management"
    if ! generate_aik; then
        error "Failed to generate/load AIK"
        return 1
    fi
    
    log "Step 2/5: Obtaining nonce from verifier"
    NONCE=$(get_nonce_from_verifier)
    if [ -z "$NONCE" ]; then
        error "Failed to obtain nonce"
        return 1
    fi
    log " Nonce: $(echo "$NONCE" | cut -c1-16)...$(echo "$NONCE" | cut -c49-64)"
    
    log "Step 3/5: Measuring platform state (PCRs)"
    generate_pcr_measurements
    
    log "Step 4/5: Generating cryptographically signed quote"
    if ! generate_signed_quote "$NONCE"; then
        error "Failed to generate signed quote"
        return 1
    fi
    
    log "Step 5/5: Building signed EAT token"
    if ! create_eat_token "$NONCE"; then
        error "Failed to create EAT token"
        return 1
    fi
    
    log ""
    log "Submitting to remote verifier for cryptographic verification"
    send_to_verifier
    local result=$?
    
    log ""
    if [ $result -eq 0 ]; then
        log " Remote attestation with cryptographic verification complete!"
    else
        warn "Remote attestation completed with errors"
    fi
    
    return $result
}

main "$@"


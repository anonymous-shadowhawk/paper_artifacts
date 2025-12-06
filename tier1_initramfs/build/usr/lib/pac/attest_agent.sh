#!/bin/sh

CRYPTO_AGENT="/usr/lib/pac/attest_agent_crypto.sh"

if command -v openssl >/dev/null 2>&1; then
    echo "[ATTEST] OpenSSL available - using cryptographic attestation"
    if [ -f "$CRYPTO_AGENT" ]; then
        exec sh "$CRYPTO_AGENT" "$@"
    else
        echo "[ATTEST] ERROR: Cryptographic agent not found at $CRYPTO_AGENT" >&2
        exit 1
    fi
else
    echo "[ATTEST] ERROR: OpenSSL not available - cryptographic attestation required" >&2
    echo "[ATTEST] Install OpenSSL ARM64 or rebuild with tmp.sh to include crypto support" >&2
    exit 1
fi


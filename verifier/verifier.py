#!/usr/bin/env python3
import os
import sys
import time
import json
import base64
import hashlib
import secrets
from flask import Flask, request, jsonify
from datetime import datetime, timedelta

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.backends import default_backend
    CRYPTO_AVAILABLE = True
except ImportError:
    CRYPTO_AVAILABLE = False
    print("Warning: cryptography not available, signature verification disabled", file=sys.stderr)

app = Flask(__name__)

NONCE_TIMEOUT = int(os.environ.get('NONCE_TIMEOUT', '60'))  
NONCE_LENGTH = int(os.environ.get('NONCE_LENGTH', '32'))  

nonces = {}  
attestation_history = []  

def cleanup_expired_nonces():
    
    current_time = time.time()
    expired = [n for n, t in nonces.items() 
               if current_time - t > NONCE_TIMEOUT]
    for n in expired:
        del nonces[n]

def log_attestation(result):
    
    attestation_history.append({
        'timestamp': time.time(),
        'result': result
    })
    
    if len(attestation_history) > 100:
        attestation_history.pop(0)

def verify_rsa_signature(quote_data_b64, signature_b64, public_key_b64):
    
    if not CRYPTO_AVAILABLE:
        return False, "Cryptography library not available"
    
    try:
        quote_data = base64.b64decode(quote_data_b64)
        signature = base64.b64decode(signature_b64)
        public_key_pem = base64.b64decode(public_key_b64)
        
        public_key = serialization.load_pem_public_key(
            public_key_pem,
            backend=default_backend()
        )
        
        public_key.verify(
            signature,
            quote_data,
            padding.PKCS1v15(),
            hashes.SHA256()
        )
        
        return True, "Signature verification successful"
        
    except Exception as e:
        return False, f"Signature verification failed: {str(e)}"

@app.route('/')
def index():
    
    return jsonify({
        'service': 'PAC Remote Attestation Verifier',
        'version': '1.0',
        'status': 'running',
        'active_nonces': len(nonces),
        'total_attestations': len(attestation_history)
    })

@app.route('/nonce', methods=['GET'])
def get_nonce():
    
    cleanup_expired_nonces()
    
    nonce = secrets.token_hex(NONCE_LENGTH)
    nonces[nonce] = time.time()
    
    app.logger.info(f"Generated nonce: {nonce[:16]}... (valid for {NONCE_TIMEOUT}s)")
    
    return jsonify({
        'nonce': nonce,
        'expires_in': NONCE_TIMEOUT
    })

@app.route('/verify', methods=['POST'])
def verify_attestation():
    
    cleanup_expired_nonces()
    
    try:
        eat_token = request.get_json()
        app.logger.info("Received JSON attestation token")
    except Exception as e:
        return jsonify({
            'allow': False,
            'reason': f'Invalid token format: {str(e)}'
        }), 400
    
    if not eat_token:
        return jsonify({
            'allow': False,
            'reason': 'Empty request body'
        }), 400
    
    app.logger.info(f"Received attestation from device: {eat_token.get('device_id', 'unknown')}")
    
    nonce = eat_token.get('nonce', '')
    timestamp = eat_token.get('timestamp', 0)
    boot_state = eat_token.get('boot_state', {})
    tpm_quote = eat_token.get('tpm_quote', {})
    tpm_attestation = eat_token.get('tpm_attestation', {})  
    health_status = eat_token.get('health_status', {})
    token_format = eat_token.get('format', 'pac-eat-v1')
    
    checks = {
        'nonce_valid': False,
        'nonce_fresh': False,
        'timestamp_valid': False,
        'tpm_quote_present': False,
        'signature_valid': False,
        'health_acceptable': False,
        'tier_valid': False
    }
    
    reasons = []
    
    if nonce in nonces:
        checks['nonce_valid'] = True
        
        nonce_age = time.time() - nonces[nonce]
        if nonce_age <= NONCE_TIMEOUT:
            checks['nonce_fresh'] = True
        else:
            reasons.append(f'Nonce expired ({int(nonce_age)}s old)')
        
        del nonces[nonce]
    else:
        reasons.append('Invalid or already-used nonce')
    
    current_time = time.time()
    time_diff = abs(current_time - timestamp)
    if time_diff < 300:  
        checks['timestamp_valid'] = True
    else:
        reasons.append(f'Timestamp too old/future ({int(time_diff)}s diff)')
    
    if tpm_attestation:
        quote_data = tpm_attestation.get('quote_data', '')
        signature = tpm_attestation.get('signature', '')
        public_key = tpm_attestation.get('public_key', '')
        
        if quote_data and signature and public_key:
            checks['tpm_quote_present'] = True
            
            sig_valid, sig_msg = verify_rsa_signature(quote_data, signature, public_key)
            if sig_valid:
                checks['signature_valid'] = True
                app.logger.info(f" RSA signature verified: {sig_msg}")
            else:
                reasons.append(f'Signature verification failed: {sig_msg}')
                app.logger.warning(f" {sig_msg}")
        else:
            reasons.append('TPM attestation data incomplete')
    elif tpm_quote.get('message') and tpm_quote.get('signature'):
        checks['tpm_quote_present'] = True
        checks['signature_valid'] = False
        app.logger.info("TPM quote present (mock format, not verified)")
    else:
        reasons.append('TPM quote missing or incomplete')
    
    if isinstance(health_status, dict):
        overall_status = health_status.get('overall_status', 'unknown')
        overall_score = health_status.get('overall_score', 0)
        
        if overall_status in ['healthy', 'degraded'] and overall_score >= 3:
            checks['health_acceptable'] = True
        else:
            reasons.append(f'Health unacceptable: {overall_status} (score: {overall_score})')
    else:
        reasons.append('Health status missing')
    
    tier = boot_state.get('tier', 0)
    if tier in [1, 2, 3]:
        checks['tier_valid'] = True
    else:
        reasons.append(f'Invalid tier: {tier}')
    
    if checks['signature_valid']:
        required_checks = [
            'nonce_valid',
            'nonce_fresh',
            'timestamp_valid',
            'tpm_quote_present',
            'signature_valid',
            'health_acceptable',
            'tier_valid'
        ]
    else:
        required_checks = [
            'nonce_valid',
            'nonce_fresh',
            'timestamp_valid',
            'tpm_quote_present',
            'health_acceptable',
            'tier_valid'
        ]
    
    passed_checks = sum(1 for check in required_checks if checks[check])
    total_checks = len(required_checks)
    
    allow = all(checks[check] for check in required_checks)
    
    if allow:
        reason = f'Attestation passed ({passed_checks}/{total_checks} checks)'
        app.logger.info(f" ALLOW: {reason}")
    else:
        reason = f'Attestation failed: {", ".join(reasons)}'
        app.logger.warning(f" DENY: {reason}")
    
    response = {
        'allow': allow,
        'reason': reason,
        'checks': checks,
        'device_id': eat_token.get('device_id', 'unknown'),
        'tier': tier,
        'verified_at': datetime.utcnow().isoformat()
    }
    
    log_attestation(response)
    
    return jsonify(response)

@app.route('/stats', methods=['GET'])
def get_stats():
    
    total = len(attestation_history)
    allowed = sum(1 for a in attestation_history if a['result'].get('allow', False))
    denied = total - allowed
    
    return jsonify({
        'total_attestations': total,
        'allowed': allowed,
        'denied': denied,
        'success_rate': f'{(allowed/total*100):.1f}%' if total > 0 else 'N/A',
        'active_nonces': len(nonces)
    })

@app.route('/health', methods=['GET'])
def health_check():
    
    return jsonify({'status': 'healthy'}), 200

if __name__ == '__main__':
    import logging
    
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(levelname)s: %(message)s'
    )
    
    host = os.environ.get('VERIFIER_HOST', '0.0.0.0')
    port = int(os.environ.get('VERIFIER_PORT', '8080'))
    debug = os.environ.get('VERIFIER_DEBUG', 'False').lower() == 'true'
    
    print("")
    print("  PAC Remote Attestation Verifier                          ")
    print("")
    print(f"")
    print(f"Starting verifier service...")
    print(f"  Host: {host}")
    print(f"  Port: {port}")
    print(f"  Nonce Timeout: {NONCE_TIMEOUT}s")
    print(f"")
    print(f"Endpoints:")
    print(f"  GET  /          - Service status")
    print(f"  GET  /nonce     - Get nonce for attestation")
    print(f"  POST /verify    - Verify EAT token")
    print(f"  GET  /stats     - Attestation statistics")
    print(f"  GET  /health    - Health check")
    print(f"")
    
    app.run(host=host, port=port, debug=debug)


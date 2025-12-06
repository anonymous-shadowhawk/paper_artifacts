#!/usr/bin/env python3

import sys
import json
import cbor2
from datetime import datetime, timezone
import base64

def json_to_eat_cbor(json_data):
    
    
    if isinstance(json_data, str):
        token = json.loads(json_data)
    else:
        token = json_data
    
    eat_claims = {}
    
    if 'timestamp' in token:
        eat_claims[6] = token['timestamp']
    
    if 'nonce' in token:
        eat_claims[10] = bytes.fromhex(token['nonce']) if isinstance(token['nonce'], str) else token['nonce']
    
    if 'tier' in token:
        eat_claims[-70000] = token['tier']
    
    if 'pcrs' in token or 'quote_msg' in token or 'quote_sig' in token:
        measurements = {}
        if 'pcrs' in token:
            try:
                measurements[1] = base64.b64decode(token['pcrs'])
            except:
                measurements[1] = token['pcrs'].encode() if isinstance(token['pcrs'], str) else token['pcrs']
        
        if 'quote_msg' in token:
            try:
                measurements[2] = base64.b64decode(token['quote_msg'])
            except:
                measurements[2] = token['quote_msg'].encode() if isinstance(token['quote_msg'], str) else token['quote_msg']
        
        if 'quote_sig' in token:
            try:
                measurements[3] = base64.b64decode(token['quote_sig'])
            except:
                measurements[3] = token['quote_sig'].encode() if isinstance(token['quote_sig'], str) else token['quote_sig']
        
        eat_claims[-70001] = measurements
    
    if 'health' in token:
        health = token['health']
        health_cbor = {}
        
        if isinstance(health, dict):
            health_cbor[1] = health.get('wdt_ok', health.get('watchdog_ok', False))
            health_cbor[2] = health.get('ecc_ok', True)
            health_cbor[3] = health.get('storage_ok', True)
            health_cbor[4] = health.get('net_ok', health.get('network_ok', False))
        
        eat_claims[-70002] = health_cbor
    
    cbor_bytes = cbor2.dumps(eat_claims)
    
    return cbor_bytes

def eat_cbor_to_json(cbor_bytes):
    
    eat_claims = cbor2.loads(cbor_bytes)
    
    token = {}
    
    if 6 in eat_claims:
        token['timestamp'] = eat_claims[6]
    
    if 10 in eat_claims:
        nonce_bytes = eat_claims[10]
        token['nonce'] = nonce_bytes.hex() if isinstance(nonce_bytes, bytes) else str(nonce_bytes)
    
    if -70000 in eat_claims:
        token['tier'] = eat_claims[-70000]
    
    if -70001 in eat_claims:
        measurements = eat_claims[-70001]
        if 1 in measurements:
            token['pcrs'] = base64.b64encode(measurements[1]).decode() if isinstance(measurements[1], bytes) else str(measurements[1])
        if 2 in measurements:
            token['quote_msg'] = base64.b64encode(measurements[2]).decode() if isinstance(measurements[2], bytes) else str(measurements[2])
        if 3 in measurements:
            token['quote_sig'] = base64.b64encode(measurements[3]).decode() if isinstance(measurements[3], bytes) else str(measurements[3])
    
    if -70002 in eat_claims:
        health_cbor = eat_claims[-70002]
        token['health'] = {
            'wdt_ok': health_cbor.get(1, False),
            'ecc_ok': health_cbor.get(2, True),
            'storage_ok': health_cbor.get(3, True),
            'network_ok': health_cbor.get(4, False)
        }
    
    return token

def main():
    
    if len(sys.argv) < 2:
        print("Usage: eat_cbor_encoder.py {encode|decode}", file=sys.stderr)
        print("  encode: Convert JSON to CBOR", file=sys.stderr)
        print("  decode: Convert CBOR to JSON", file=sys.stderr)
        sys.exit(1)
    
    mode = sys.argv[1]
    
    if mode == 'encode':
        json_data = sys.stdin.read()
        cbor_bytes = json_to_eat_cbor(json_data)
        sys.stdout.buffer.write(cbor_bytes)
    
    elif mode == 'decode':
        cbor_bytes = sys.stdin.buffer.read()
        token_json = eat_cbor_to_json(cbor_bytes)
        print(json.dumps(token_json, indent=2))
    
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()


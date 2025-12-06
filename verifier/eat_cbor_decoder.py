#!/usr/bin/env python3
import sys
import json
import cbor2
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

def decode_cbor_eat(cbor_data):
    
    try:
        eat_dict = cbor2.loads(cbor_data)
        
        json_eat = {
            'format': eat_dict.get(1, 'pac-eat-v2-cbor'),
            'timestamp': eat_dict.get(2),
            'nonce': eat_dict.get(3),
            'device_id': eat_dict.get(4),
            'boot_state': eat_dict.get(5, {}),
            'tpm_attestation': eat_dict.get(6, {}),
            'health_status': eat_dict.get(7, {}),
            'metadata': eat_dict.get(8, {})
        }
        
        return json_eat
        
    except Exception as e:
        print(f"ERROR: Failed to decode CBOR: {e}", file=sys.stderr)
        return None

def verify_cose_sign1(cose_data, public_key_pem=None):
    
    try:
        cose_sign1 = cbor2.loads(cose_data)
        
        if not isinstance(cose_sign1, list) or len(cose_sign1) != 4:
            print("ERROR: Invalid COSE_Sign1 structure", file=sys.stderr)
            return None, False
        
        protected_encoded, unprotected, payload, signature = cose_sign1
        
        protected = cbor2.loads(protected_encoded)
        alg = protected.get(1)
        
        if alg != -257:  
            print(f"ERROR: Unsupported algorithm: {alg}", file=sys.stderr)
            return None, False
        
        sig_structure = cbor2.dumps([
            "Signature1",
            protected_encoded,
            b'',  
            payload
        ])
        
        signature_valid = False
        if public_key_pem:
            try:
                public_key = serialization.load_pem_public_key(
                    public_key_pem.encode() if isinstance(public_key_pem, str) else public_key_pem,
                    backend=default_backend()
                )
                
                public_key.verify(
                    signature,
                    sig_structure,
                    padding.PKCS1v15(),
                    hashes.SHA256()
                )
                signature_valid = True
            except Exception as e:
                print(f"ERROR: Signature verification failed: {e}", file=sys.stderr)
                signature_valid = False
        else:
            signature_valid = None  
        
        return payload, signature_valid
        
    except Exception as e:
        print(f"ERROR: Failed to verify COSE_Sign1: {e}", file=sys.stderr)
        return None, False

def cbor_to_json(cbor_data, is_cose=True):
    
    if is_cose:
        payload, sig_valid = verify_cose_sign1(cbor_data)
        if payload is None:
            return None
        cbor_data = payload
    
    eat_dict = decode_cbor_eat(cbor_data)
    if eat_dict is None:
        return None
    
    return json.dumps(eat_dict, indent=2)

def main():
    
    if len(sys.argv) < 2:
        print("Usage: eat_cbor_decoder.py <input_cbor> [--cose]", file=sys.stderr)
        print("", file=sys.stderr)
        print("Options:", file=sys.stderr)
        print("  input_cbor  - CBOR or COSE_Sign1 file", file=sys.stderr)
        print("  --cose      - Input is COSE_Sign1 format", file=sys.stderr)
        sys.exit(1)
    
    input_file = sys.argv[1]
    is_cose = "--cose" in sys.argv
    
    try:
        with open(input_file, 'rb') as f:
            cbor_data = f.read()
    except Exception as e:
        print(f"ERROR: Failed to read input file: {e}", file=sys.stderr)
        sys.exit(1)
    
    json_output = cbor_to_json(cbor_data, is_cose=is_cose)
    
    if json_output:
        print(json_output)
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()


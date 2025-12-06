#!/usr/bin/env python3

import sys
import json
import cbor2
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend
import base64

def load_private_key(key_path):
    
    try:
        with open(key_path, 'rb') as f:
            return serialization.load_pem_private_key(
                f.read(),
                password=None,
                backend=default_backend()
            )
    except Exception as e:
        print(f"ERROR: Failed to load private key: {e}", file=sys.stderr)
        sys.exit(1)

def json_to_cbor_eat(json_data, private_key=None):
    
    try:
        if isinstance(json_data, str):
            eat_dict = json.loads(json_data)
        else:
            eat_dict = json_data
        
        cbor_eat = {
            1: eat_dict.get('format', 'pac-eat-v2-cbor'),  
            2: eat_dict.get('timestamp'),  
            3: eat_dict.get('nonce'),  
            4: eat_dict.get('device_id'),  
            5: {  
                'tier': eat_dict['boot_state']['tier'],
                'boot_count': eat_dict['boot_state']['boot_count']
            },
            6: {  
                'version': eat_dict['tpm_attestation']['version'],
                'quote_data': eat_dict['tpm_attestation']['quote_data'],
                'signature': eat_dict['tpm_attestation']['signature'],
                'signature_algorithm': eat_dict['tpm_attestation']['signature_algorithm'],
                'public_key': eat_dict['tpm_attestation']['public_key'],
                'pcr_digest': eat_dict['tpm_attestation']['pcr_digest'],
                'pcrs': eat_dict['tpm_attestation']['pcrs']
            },
            7: eat_dict.get('health_status', {}),  
            8: eat_dict.get('metadata', {})  
        }
        
        cbor_data = cbor2.dumps(cbor_eat)
        
        return cbor_data, cbor_eat
        
    except Exception as e:
        print(f"ERROR: Failed to convert to CBOR: {e}", file=sys.stderr)
        sys.exit(1)

def create_cose_sign1(cbor_payload, private_key):
    
    try:
        protected = {
            1: -257  
        }
        protected_encoded = cbor2.dumps(protected)
        
        unprotected = {
            4: b'pac-aik'  
        }
        
        sig_structure = cbor2.dumps([
            "Signature1",
            protected_encoded,
            b'',  
            cbor_payload
        ])
        
        signature = private_key.sign(
            sig_structure,
            padding.PKCS1v15(),
            hashes.SHA256()
        )
        
        cose_sign1 = [
            protected_encoded,
            unprotected,
            cbor_payload,
            signature
        ]
        
        cose_sign1_cbor = cbor2.dumps(cose_sign1)
        
        return cose_sign1_cbor
        
    except Exception as e:
        print(f"ERROR: Failed to create COSE_Sign1: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    
    if len(sys.argv) < 3:
        print("Usage: eat_cbor_encoder.py <input_json> <output_cbor> [private_key.pem]", file=sys.stderr)
        print("", file=sys.stderr)
        print("Options:", file=sys.stderr)
        print("  input_json     - JSON EAT token file", file=sys.stderr)
        print("  output_cbor    - Output CBOR/COSE file", file=sys.stderr)
        print("  private_key    - (Optional) PEM private key for COSE_Sign1", file=sys.stderr)
        print("", file=sys.stderr)
        print("If private_key is provided, output will be COSE_Sign1 format.", file=sys.stderr)
        print("Otherwise, output will be plain CBOR format.", file=sys.stderr)
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    private_key_file = sys.argv[3] if len(sys.argv) > 3 else None
    
    try:
        with open(input_file, 'r') as f:
            json_data = f.read()
    except Exception as e:
        print(f"ERROR: Failed to read input file: {e}", file=sys.stderr)
        sys.exit(1)
    
    print(f"[CBOR] Converting JSON EAT token to CBOR format...", file=sys.stderr)
    cbor_data, cbor_dict = json_to_cbor_eat(json_data)
    
    json_size = len(json_data)
    cbor_size = len(cbor_data)
    reduction = ((json_size - cbor_size) / json_size) * 100
    
    print(f"[CBOR] Size: JSON={json_size}B, CBOR={cbor_size}B (reduction: {reduction:.1f}%)", file=sys.stderr)
    
    if private_key_file:
        print(f"[COSE] Creating COSE_Sign1 signature...", file=sys.stderr)
        private_key = load_private_key(private_key_file)
        output_data = create_cose_sign1(cbor_data, private_key)
        cose_size = len(output_data)
        print(f"[COSE] COSE_Sign1 size: {cose_size}B", file=sys.stderr)
    else:
        output_data = cbor_data
    
    try:
        with open(output_file, 'wb') as f:
            f.write(output_data)
        print(f"[CBOR]  Output written to {output_file}", file=sys.stderr)
    except Exception as e:
        print(f"ERROR: Failed to write output: {e}", file=sys.stderr)
        sys.exit(1)
    
    if private_key_file:
        print(f"[CBOR]  COSE_Sign1 token created successfully", file=sys.stderr)
    else:
        print(f"[CBOR]  CBOR token created successfully", file=sys.stderr)

if __name__ == '__main__':
    main()


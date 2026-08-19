#!/usr/bin/env python3
"""Mint a JSON Web Token for the App Store Connect API.

Exists because ES256 is awkward everywhere else in this toolchain. `openssl`
signs happily but emits the signature as a DER SEQUENCE of two INTEGERs, while
JOSE wants the raw r and s concatenated as fixed 32-byte big-endian values.
Converting between them in bash means byte-slicing with `xxd`; here it is a
dozen readable lines. The crypto still belongs to openssl - nothing below
implements a cipher, and no third-party package is imported, so this runs on a
stock macOS with the Xcode command line tools and nothing else.

    tools/asc-jwt.py --key <path.p8> --key-id <kid> --issuer-id <iss>
    tools/asc-jwt.py --selftest      # round-trips the DER conversion, no key needed

Tokens are valid for 20 minutes, which is Apple's maximum; a longer exp is
rejected outright rather than clamped.
"""
import argparse
import base64
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

AUDIENCE = 'appstoreconnect-v1'
LIFETIME_SECONDS = 20 * 60
# P-256: r and s are each exactly 32 bytes once padded.
COORDINATE_BYTES = 32


def b64url(raw: bytes) -> str:
    """Base64url with the padding stripped, as JOSE requires."""
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


def der_to_jose(der: bytes) -> bytes:
    """Convert an ECDSA signature from DER to the raw r||s form JOSE wants.

    DER is SEQUENCE { INTEGER r, INTEGER s }. The INTEGERs are signed and
    minimally encoded, so r may carry a leading zero byte (when its top bit is
    set, to keep it positive) or be shorter than 32 bytes (when it has leading
    zero bits). Both cases have to be normalised to exactly 32 bytes.
    """
    if not der or der[0] != 0x30:
        raise ValueError('signature is not a DER SEQUENCE')

    index = 2
    # A P-256 signature is at most 72 bytes, so the length is always short form.
    # Handle the long form anyway rather than silently misparse if that changes.
    if der[1] & 0x80:
        index = 2 + (der[1] & 0x7F)

    def read_integer(at: int):
        if der[at] != 0x02:
            raise ValueError('expected a DER INTEGER in the signature')
        length = der[at + 1]
        value = der[at + 2:at + 2 + length]
        return value.lstrip(b'\x00'), at + 2 + length

    r, index = read_integer(index)
    s, _ = read_integer(index)

    if len(r) > COORDINATE_BYTES or len(s) > COORDINATE_BYTES:
        raise ValueError('signature component is too large for P-256')

    return r.rjust(COORDINATE_BYTES, b'\x00') + s.rjust(COORDINATE_BYTES, b'\x00')


def sign(key_path: Path, message: bytes) -> bytes:
    """Sign with openssl and hand back a DER signature."""
    result = subprocess.run(
        ['openssl', 'dgst', '-sha256', '-sign', str(key_path)],
        input=message, capture_output=True)
    if result.returncode != 0:
        raise SystemExit('openssl could not sign with %s:\n%s'
                         % (key_path, result.stderr.decode('utf-8', 'replace').strip()))
    return result.stdout


def mint(key_path: Path, key_id: str, issuer_id: str, issued_at: int) -> str:
    header = {'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}
    payload = {
        'iss': issuer_id,
        'iat': issued_at,
        'exp': issued_at + LIFETIME_SECONDS,
        'aud': AUDIENCE,
    }
    # separators to keep the JSON compact - whitespace would be signed too.
    encode = lambda part: b64url(json.dumps(part, separators=(',', ':')).encode())
    signing_input = ('%s.%s' % (encode(header), encode(payload))).encode('ascii')
    signature = der_to_jose(sign(key_path, signing_input))
    return '%s.%s' % (signing_input.decode('ascii'), b64url(signature))


def selftest() -> int:
    """Round-trip the DER conversion against a throwaway key.

    This is the part worth testing offline: a token that is malformed only in
    its signature comes back from Apple as a bare 401, which looks exactly like
    a key with the wrong role or a mistyped issuer id.
    """
    with tempfile.TemporaryDirectory() as workspace:
        key = Path(workspace) / 'test.p8'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC',
                        '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-out', str(key)], check=True, capture_output=True)

        token = mint(key, 'TESTKEYID', 'test-issuer-id', int(time.time()))
        header_b64, payload_b64, signature_b64 = token.split('.')

        def decode(part):
            return json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))

        header, payload = decode(header_b64), decode(payload_b64)
        assert header == {'alg': 'ES256', 'kid': 'TESTKEYID', 'typ': 'JWT'}, header
        assert payload['aud'] == AUDIENCE, payload
        assert payload['iss'] == 'test-issuer-id', payload
        assert payload['exp'] - payload['iat'] == LIFETIME_SECONDS, payload

        raw = base64.urlsafe_b64decode(signature_b64 + '=' * (-len(signature_b64) % 4))
        assert len(raw) == 2 * COORDINATE_BYTES, len(raw)

        # Rebuild DER from r||s and let openssl verify it. If der_to_jose dropped
        # or misplaced a byte, this is where it shows up.
        def der_integer(value: bytes) -> bytes:
            trimmed = value.lstrip(b'\x00') or b'\x00'
            if trimmed[0] & 0x80:
                trimmed = b'\x00' + trimmed
            return b'\x02' + bytes([len(trimmed)]) + trimmed

        body = der_integer(raw[:COORDINATE_BYTES]) + der_integer(raw[COORDINATE_BYTES:])
        der = b'\x30' + bytes([len(body)]) + body

        signature_file = Path(workspace) / 'sig.der'
        signature_file.write_bytes(der)
        public_key = Path(workspace) / 'public.pem'
        subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout',
                        '-out', str(public_key)], check=True, capture_output=True)
        verify = subprocess.run(
            ['openssl', 'dgst', '-sha256', '-verify', str(public_key),
             '-signature', str(signature_file)],
            input=('%s.%s' % (header_b64, payload_b64)).encode(), capture_output=True)
        if verify.returncode != 0:
            print('selftest FAILED: openssl rejected the reconstructed signature',
                  file=sys.stderr)
            return 1

    print('selftest passed: header, claims and DER round-trip are all correct')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key')
    parser.add_argument('--key-id')
    parser.add_argument('--issuer-id')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if not (args.key and args.key_id and args.issuer_id):
        parser.error('--key, --key-id and --issuer-id are all required')

    key_path = Path(args.key).expanduser()
    if not key_path.is_file():
        raise SystemExit('no App Store Connect API key at %s' % key_path)

    print(mint(key_path, args.key_id, args.issuer_id, int(time.time())))
    return 0


if __name__ == '__main__':
    sys.exit(main())

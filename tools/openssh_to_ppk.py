#!/usr/bin/env python3
"""Convert an unencrypted OpenSSH private key (ed25519 or rsa) to PuTTY PPK v2.

Test helper: an independent implementation of the PPK format so the Swift
converter is checked against a second implementation.
Usage: python3 -I tools/openssh_to_ppk.py <openssh-key> <out.ppk> [passphrase]
Encryption (aes256-cbc) uses the `openssl` command-line tool.
"""
import base64, hashlib, hmac, os, struct, subprocess, sys


def read_string(buf, pos):
    n = struct.unpack(">I", buf[pos:pos + 4])[0]
    return buf[pos + 4:pos + 4 + n], pos + 4 + n


def string(b):
    return struct.pack(">I", len(b)) + b


def mpint(b):
    b = b.lstrip(b"\0")
    if b and b[0] & 0x80:
        b = b"\0" + b
    return string(b)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    passphrase = sys.argv[3] if len(sys.argv) > 3 else ""
    text = open(src).read()
    body = "".join(l for l in text.splitlines() if not l.startswith("-----"))
    raw = base64.b64decode(body)
    assert raw.startswith(b"openssh-key-v1\0")
    pos = len(b"openssh-key-v1\0")
    cipher, pos = read_string(raw, pos)
    assert cipher == b"none", "key must be unencrypted"
    _, pos = read_string(raw, pos)  # kdf
    _, pos = read_string(raw, pos)  # kdf options
    pos += 4  # number of keys
    pub, pos = read_string(raw, pos)
    priv, pos = read_string(raw, pos)
    p = 8  # check ints
    algo, p = read_string(priv, p)
    if algo == b"ssh-ed25519":
        _, p = read_string(priv, p)  # public
        sk, p = read_string(priv, p)  # seed + public
        seed = sk[:32]
        private_blob = mpint(seed[::-1])  # PuTTY: mpint of the little-endian value
    elif algo == b"ssh-rsa":
        fields = []
        for _ in range(6):  # n e d iqmp p q
            v, p = read_string(priv, p)
            fields.append(v)
        n, e, d, iqmp, pp, q = fields
        pub = string(b"ssh-rsa") + mpint(e) + mpint(n)
        private_blob = mpint(d) + mpint(pp) + mpint(q) + mpint(iqmp)
    else:
        raise SystemExit("unsupported " + algo.decode())
    comment, p = read_string(priv, p)

    encryption = "aes256-cbc" if passphrase else "none"
    if passphrase:
        private_blob += os.urandom(16 - len(private_blob) % 16) if len(private_blob) % 16 else b""
    mac_key = hashlib.sha1(b"putty-private-key-file-mac-key" + passphrase.encode()).digest()
    mac_data = string(algo) + string(encryption.encode()) + string(comment) + string(pub) + string(private_blob)
    mac = hmac.new(mac_key, mac_data, hashlib.sha1).hexdigest()
    if passphrase:
        pw = passphrase.encode()
        key = (hashlib.sha1(b"\0\0\0\0" + pw).digest() + hashlib.sha1(b"\0\0\0\1" + pw).digest())[:32]
        private_blob = subprocess.run(
            ["openssl", "enc", "-aes-256-cbc", "-nopad", "-K", key.hex(), "-iv", "00" * 16],
            input=private_blob, capture_output=True, check=True).stdout

    def lines(b):
        s = base64.b64encode(b).decode()
        return [s[i:i + 64] for i in range(0, len(s), 64)]

    pub_lines, priv_lines = lines(pub), lines(private_blob)
    out = ["PuTTY-User-Key-File-2: " + algo.decode(), "Encryption: " + encryption,
           "Comment: " + comment.decode(), "Public-Lines: %d" % len(pub_lines), *pub_lines,
           "Private-Lines: %d" % len(priv_lines), *priv_lines, "Private-MAC: " + mac]
    with open(dst, "w") as f:
        f.write("\r\n".join(out) + "\r\n")


main()

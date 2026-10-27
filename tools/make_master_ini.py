#!/usr/bin/env python3
"""Generate a fake WinSCP.ini protected by a master password ("master123").

Independent implementation of WinSCP's AES (WinZip-AES/fcrypt) password format:
PBKDF2-HMAC-SHA1 x1000 -> AES key | HMAC key | verifier, AES-256-CTR with a
little-endian counter from 1 (keystream via `openssl enc -aes-256-ecb`),
HMAC-SHA1 over ciphertext truncated to 10 bytes. Stored as hex("FF01" + salt + ct + mac).
Usage: python3 -I tools/make_master_ini.py > fixtures/winscp.master.sample.ini
"""
import hashlib, hmac, random, subprocess

MASTER = "master123"
rng = random.Random(42)


def keys(password, salt):
    k = hashlib.pbkdf2_hmac("sha1", password.encode(), salt, 1000, 66)
    return k[:32], k[32:64]


def ctr(data, key):
    blocks = (len(data) + 15) // 16
    counters = b"".join(i.to_bytes(8, "little") + b"\0" * 8 for i in range(1, blocks + 1))
    stream = subprocess.run(["openssl", "enc", "-aes-256-ecb", "-nopad", "-K", key.hex()],
                            input=counters, capture_output=True, check=True).stdout
    return bytes(a ^ b for a, b in zip(data, stream))


def encrypt(plain, salt):
    aes, mac_key = keys(MASTER, salt)
    ct = ctr(plain, aes)
    return salt + ct + hmac.new(mac_key, ct, hashlib.sha1).digest()[:10]


def rand(n):
    return bytes(rng.randrange(256) for _ in range(n))


verifier_salt, dummy = rand(16), rand(16)
aes, mac_key = keys(MASTER, verifier_salt)
verifier = verifier_salt + dummy + hmac.new(mac_key, ctr(dummy, aes), hashlib.sha1).digest()[:10]

lines = [
    "[Configuration\\Security]",
    "UseMasterPassword=1",
    "MasterPasswordVerifier=" + verifier.hex().upper(),
    "",
    "[Sessions\\Secure/prod]",
    "HostName=prod.example.com",
    "UserName=admin",
    "FSProtocol=2",
    "Password=" + (b"\xff\x01" + encrypt("Sup3r-secret ✓".encode(), rand(16))).hex().upper(),
    "",
    "[Sessions\\Secure/My%20Workspace/0000]",
    "HostName=prod.example.com",
    "UserName=admin",
    "IsWorkspace=1",
    "RemoteDirectory=%2Fvar%2Flog",
    "Password=" + (b"\xff\x01" + encrypt(b"ws-pass", rand(16))).hex().upper(),
    "",
    "[Sessions\\Secure/My%20Workspace/0001]",
    "HostName=db.example.com",
    "UserName=dba",
    "IsWorkspace=1",
    "FSProtocol=0",
    "",
]
print("\r\n".join(lines), end="")

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate a fake WinSCP.ini for tests and demos.

Independent Python implementation of WinSCP's simple password obfuscation,
so the Swift decoder is cross-checked against a second implementation.
Usage: python3 -I tools/make_fake_ini.py > fixtures/winscp.sample.ini
"""
import random
import urllib.parse

MAGIC = 0xA3
FLAG = 0xFF
MAXLEN = 50
HEX = "0123456789ABCDEF"

rng = random.Random(1234)  # deterministic output


def enc_char(c):
    c = (~c ^ MAGIC) & 0xFF
    return HEX[c >> 4] + HEX[c & 0xF]


def encrypt(password, user, host):
    data = (user + host + password).encode("utf-8")
    shift = rng.randrange(MAXLEN - len(data)) if len(data) < MAXLEN else 0
    out = enc_char(FLAG) + enc_char(0) + enc_char(len(data)) + enc_char(shift)
    out += "".join(enc_char(rng.randrange(256)) for _ in range(shift))
    out += "".join(enc_char(b) for b in data)
    while len(out) < MAXLEN * 2:
        out += enc_char(rng.randrange(256))
    return out


def munge(s):
    # WinSCP escapes everything that is not alphanumeric as %XX (UTF-8 bytes)
    return urllib.parse.quote(s, safe="")


def session(name, **kv):
    lines = ["[Sessions\\%s]" % "/".join(munge(p) for p in name.split("/"))]
    pw = kv.pop("Password", None)
    for k, v in kv.items():
        lines.append("%s=%s" % (k, munge(str(v)) if isinstance(v, str) else v))
    if pw is not None:
        lines.append("Password=%s" % encrypt(pw, kv.get("UserName", ""), kv.get("HostName", "")))
    return "\r\n".join(lines) + "\r\n"


parts = [
    "[Configuration\\Interface]\r\nInterface=1\r\nShowAdvancedLoginOptions=0\r\n",
    "[Configuration\\Security]\r\nUseMasterPassword=0\r\n",
    session("Default Settings", HostName="", UserName=""),
    session("Production/web-01", HostName="web01.example.com", UserName="deploy",
            Password="S3cr3t!pass", FSProtocol=2, RemoteDirectory="/var/www",
            LocalDirectory="C:\\Projects\\web", Color=4227327, Note="Main web node"),
    session("Production/db server", HostName="db.example.com", UserName="root",
            FSProtocol=0, PortNumber=2200,
            PublicKeyFile="C:\\Users\\me\\.ssh\\id_ed25519.ppk"),
    session("Staging/ftp.example.org", HostName="ftp.example.org", UserName="ftpuser",
            Password="pässwörd €", FSProtocol=5, Ftps=3),
    session("Clients/Acme/legacy-ftp", HostName="legacy.acme.test", UserName="acme",
            Password="plain", FSProtocol=5, PortNumber=2121, FtpPasvMode=0),
    session("localhost test", HostName="127.0.0.1", UserName="tester",
            Password="a-very-long-password-that-exceeds-the-fifty-byte-padding-limit",
            PortNumber=2222),
    session("webdav box", HostName="dav.example.com", UserName="dav", FSProtocol=6),
    session("s3 bucket", HostName="s3.amazonaws.com", UserName="AKIAEXAMPLE", FSProtocol=7),
    session("My Workspace/0000", HostName="web01.example.com", UserName="deploy",
            IsWorkspace=1, FSProtocol=2),
    "[SshHostKeys]\r\nssh-ed25519@22:web01.example.com=0x1d7c4f3c0a3f6d6f3b1c2b0f4e3d2c1b0a99887766554433221100ffeeddccbb,0x5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a392817061\r\n",
]
print("\r\n".join(parts), end="")

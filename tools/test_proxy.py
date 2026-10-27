#!/usr/bin/env python3
"""Throwaway SOCKS4a / SOCKS5 / HTTP CONNECT proxy for integration tests.

Usage: test_proxy.py <port> <logfile>
SOCKS5 and HTTP accept no auth, or user "puser" / password "ppass"; wrong
credentials are refused. Every tunnel is logged as "<kind> <host>:<port>".
"""
import base64, socket, struct, sys, threading

PORT, LOG = int(sys.argv[1]), sys.argv[2]
lock = threading.Lock()


def log(line):
    with lock, open(LOG, "a") as f:
        f.write(line + "\n")


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def relay(a, b):
    def pipe(src, dst):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    break
                dst.sendall(d)
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
    threading.Thread(target=pipe, args=(a, b), daemon=True).start()
    pipe(b, a)


def handle(c):
    try:
        first = c.recv(1, socket.MSG_PEEK)
        if first == b"\x05":
            _, n = recv_exact(c, 2)
            methods = recv_exact(c, n)
            if 2 in methods:
                c.sendall(b"\x05\x02")
                recv_exact(c, 1)
                user = recv_exact(c, recv_exact(c, 1)[0]).decode()
                pw = recv_exact(c, recv_exact(c, 1)[0]).decode()
                ok = (user, pw) == ("puser", "ppass")
                c.sendall(b"\x01" + (b"\x00" if ok else b"\x01"))
                if not ok:
                    return log("socks5 auth-failed")
            else:
                c.sendall(b"\x05\x00")
            _, cmd, _, atyp = recv_exact(c, 4)
            if atyp == 3:
                host = recv_exact(c, recv_exact(c, 1)[0]).decode()
            elif atyp == 1:
                host = socket.inet_ntoa(recv_exact(c, 4))
            else:
                host = socket.inet_ntop(socket.AF_INET6, recv_exact(c, 16))
            port = struct.unpack(">H", recv_exact(c, 2))[0]
            up = socket.create_connection((host, port))
            c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + b"\x00\x00")
            log(f"socks5 {host}:{port}")
            return relay(c, up)
        if first == b"\x04":
            _, cmd, port = struct.unpack(">BBH", recv_exact(c, 4))
            ip = recv_exact(c, 4)
            while recv_exact(c, 1) != b"\0":  # user id
                pass
            host = socket.inet_ntoa(ip)
            if ip[:3] == b"\0\0\0":  # SOCKS4a: hostname follows
                name = b""
                while (ch := recv_exact(c, 1)) != b"\0":
                    name += ch
                host = name.decode()
            up = socket.create_connection((host, port))
            c.sendall(b"\x00\x5a" + b"\0" * 6)
            log(f"socks4 {host}:{port}")
            return relay(c, up)
        head = b""
        while b"\r\n\r\n" not in head:
            head += recv_exact(c, 1)
        lines = head.decode().split("\r\n")
        method, target, _ = lines[0].split(" ")
        auth = [l for l in lines if l.lower().startswith("proxy-authorization:")]
        if auth and base64.b64decode(auth[0].split()[-1]).decode() != "puser:ppass":
            c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
            return log("http auth-failed")
        host, port = target.rsplit(":", 1)
        up = socket.create_connection((host.strip("[]"), int(port)))
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        log(f"http {host}:{port}")
        relay(c, up)
    except Exception as e:  # noqa: BLE001 - test helper
        log(f"error {e}")
    finally:
        c.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(64)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()

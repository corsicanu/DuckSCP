#!/usr/bin/env python3
"""Throwaway FTP + explicit FTPS server for integration tests (pyftpdlib).

Usage: test_ftpd.py <root-dir> <port> <certfile>
User "tester" / password "secret" with full rights under <root-dir>.
"""
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.servers import FTPServer

root, port, cert = sys.argv[1], int(sys.argv[2]), sys.argv[3]
auth = DummyAuthorizer()
auth.add_user("tester", "secret", root, perm="elradfmwMT")
handler = TLS_FTPHandler
handler.certfile = cert
handler.authorizer = auth
handler.tls_control_required = False  # plain FTP and explicit TLS on the same port
handler.tls_data_required = False
handler.passive_ports = range(30000, 30100)
FTPServer(("127.0.0.1", port), handler).serve_forever()

#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts throwaway WebDAV (WsgiDAV, 127.0.0.1:2180, tester/secret) and S3 (moto, 127.0.0.1:2190)
# servers for integration tests. Uses the venv created by scripts/test_ftpd.sh (needs network once).
# Usage: scripts/test_httpd.sh start|stop
set -euo pipefail
DIR="${HTTPD_DIR:-${TMPDIR:-/tmp}/duckscp-test-httpd}"
VENV="${FTPD_DIR:-${TMPDIR:-/tmp}/duckscp-test-ftpd}/venv"
case "${1:-start}" in
  start)
    mkdir -p "$DIR/dav"
    [[ -x $VENV/bin/python ]] || { python3 -m venv "$VENV"; }
    [[ -x $VENV/bin/wsgidav && -x $VENV/bin/moto_server ]] || "$VENV/bin/pip" install -q wsgidav cheroot "moto[server]"
    cat > "$DIR/wsgidav.yaml" <<YAML
host: 127.0.0.1
port: 2180
provider_mapping:
  "/": "$DIR/dav"
http_authenticator:
  domain_controller: null
  accept_basic: true
  accept_digest: true
  default_to_digest: false
simple_dc:
  user_mapping:
    "*":
      "tester":
        password: "secret"
verbose: 1
logging:
  enable: false
YAML
    for p in dav s3; do [[ -f $DIR/$p.pid ]] && kill "$(cat $DIR/$p.pid)" 2>/dev/null || true; done
    "$VENV/bin/wsgidav" --config "$DIR/wsgidav.yaml" > "$DIR/dav.log" 2>&1 &
    echo $! > "$DIR/dav.pid"
    "$VENV/bin/moto_server" -H 127.0.0.1 -p 2190 > "$DIR/s3.log" 2>&1 &
    echo $! > "$DIR/s3.pid"
    sleep 3
    echo "WebDAV on 127.0.0.1:2180 (tester/secret), S3 (moto) on 127.0.0.1:2190"
    ;;
  stop)
    for p in dav s3; do [[ -f $DIR/$p.pid ]] && kill "$(cat $DIR/$p.pid)" 2>/dev/null; rm -f "$DIR/$p.pid"; done
    ;;
esac

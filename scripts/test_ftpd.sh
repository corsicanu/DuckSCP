#!/bin/zsh
# Starts a throwaway FTP/FTPS server on 127.0.0.1:${PORT:-2121} and a SOCKS/HTTP proxy on PORT+1000
# for integration tests.
# Needs network once to install pyftpdlib into a private venv.
# Usage: scripts/test_ftpd.sh start|stop
set -euo pipefail
DIR="${FTPD_DIR:-${TMPDIR:-/tmp}/duckscp-test-ftpd}"
PORT="${PORT:-2121}"
TOOLS="$(cd "$(dirname "$0")/../tools" && pwd)"
case "${1:-start}" in
  start)
    mkdir -p "$DIR/root"
    [[ -x $DIR/venv/bin/python ]] || { python3 -m venv "$DIR/venv" && "$DIR/venv/bin/pip" install -q pyftpdlib pyopenssl; }
    [[ -f $DIR/cert.pem ]] || openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=127.0.0.1" \
      -keyout "$DIR/cert.pem" -out "$DIR/cert.pem.crt" 2>/dev/null && cat "$DIR/cert.pem.crt" >> "$DIR/cert.pem"
    [[ -f $DIR/ftpd.pid ]] && kill "$(cat $DIR/ftpd.pid)" 2>/dev/null || true
    "$DIR/venv/bin/python" -I "$TOOLS/test_ftpd.py" "$DIR/root" "$PORT" "$DIR/cert.pem" > "$DIR/ftpd.log" 2>&1 &
    echo $! > "$DIR/ftpd.pid"
    # SOCKS4a/SOCKS5/HTTP CONNECT test proxy on PORT+1000 (default 3121).
    [[ -f $DIR/proxy.pid ]] && kill "$(cat $DIR/proxy.pid)" 2>/dev/null || true
    : > "$DIR/proxy.log"
    python3 -I "$TOOLS/test_proxy.py" "$((PORT + 1000))" "$DIR/proxy.log" > /dev/null 2>&1 &
    echo $! > "$DIR/proxy.pid"
    sleep 1
    echo "ftpd on 127.0.0.1:$PORT (tester/secret), root $DIR/root"
    ;;
  stop)
    [[ -f $DIR/ftpd.pid ]] && kill "$(cat $DIR/ftpd.pid)" && rm -f "$DIR/ftpd.pid"
    [[ -f $DIR/proxy.pid ]] && kill "$(cat $DIR/proxy.pid)" && rm -f "$DIR/proxy.pid"
    ;;
esac

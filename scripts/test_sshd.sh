#!/bin/zsh
# Starts a throwaway OpenSSH server on 127.0.0.1:${PORT:-2222} as the current user,
# for integration tests. Key-based login only. State lives in $DIR (default: a temp dir).
# Usage: scripts/test_sshd.sh start|stop|env
set -euo pipefail
DIR="${SSHD_DIR:-${TMPDIR:-/tmp}/macscp-test-sshd}"
PORT="${PORT:-2222}"
case "${1:-start}" in
  start)
    mkdir -p "$DIR/home"
    chmod 700 "$DIR"
    [[ -f $DIR/host_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/host_ed25519"
    [[ -f $DIR/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C test -f "$DIR/id_ed25519"
    [[ -f $DIR/id_rsa ]] || ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C test -f "$DIR/id_rsa"
    [[ -f $DIR/id_ed25519_enc ]] || ssh-keygen -q -t ed25519 -N 'testpass' -C test -f "$DIR/id_ed25519_enc"
    [[ -f $DIR/id_rsa_openssh ]] || ssh-keygen -q -t rsa -b 2048 -N '' -C test -f "$DIR/id_rsa_openssh"
    # PuTTY copies of the keys, made by an independent converter.
    TOOLS="$(cd "$(dirname "$0")/../tools" && pwd)"
    python3 -I "$TOOLS/openssh_to_ppk.py" "$DIR/id_ed25519" "$DIR/id_ed25519.ppk"
    python3 -I "$TOOLS/openssh_to_ppk.py" "$DIR/id_rsa_openssh" "$DIR/id_rsa.ppk"
    python3 -I "$TOOLS/openssh_to_ppk.py" "$DIR/id_ed25519" "$DIR/id_ed25519_enc.ppk" testpass
    cat "$DIR"/id_*.pub > "$DIR/authorized_keys"
    chmod 600 "$DIR/authorized_keys"
    cat > "$DIR/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
CFG
    [[ -f $DIR/sshd.pid ]] && kill "$(cat $DIR/sshd.pid)" 2>/dev/null || true
    /usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"
    sleep 0.5
    echo "sshd on 127.0.0.1:$PORT, keys in $DIR"
    ;;
  stop)
    [[ -f $DIR/sshd.pid ]] && kill "$(cat $DIR/sshd.pid)" && rm -f "$DIR/sshd.pid"
    ;;
  env)
    echo "MACSCP_TEST_SSH_DIR=$DIR MACSCP_TEST_SSH_PORT=$PORT"
    ;;
esac

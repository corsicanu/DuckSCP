// Thin C helpers around libssh2: wraps macros Swift cannot call and keeps
// callback plumbing (keyboard-interactive) out of Swift.
#ifndef MACSCP_SSH_H
#define MACSCP_SSH_H

#include "libssh2.h"
#include "libssh2_sftp.h"

/// Connects a TCP socket with a timeout. Returns fd or -1 (errno set / *gai_error set).
/// family: 0 = any, 4 = IPv4 only, 6 = IPv6 only.
int macscp_tcp_connect(const char *host, int port, int timeout_ms, int family, int *gai_error);

LIBSSH2_SESSION *macscp_session_init(void);

/// Answers every keyboard-interactive prompt with `password`.
int macscp_userauth_kbdint(LIBSSH2_SESSION *s, const char *user, const char *password);
int macscp_userauth_password(LIBSSH2_SESSION *s, const char *user, const char *password);

/// Last libssh2 error message (static storage owned by libssh2) and code.
const char *macscp_last_error(LIBSSH2_SESSION *s, int *code);

LIBSSH2_SFTP_HANDLE *macscp_sftp_open(LIBSSH2_SFTP *sftp, const char *path, unsigned long flags, long mode);
LIBSSH2_SFTP_HANDLE *macscp_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path);
int macscp_sftp_stat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int macscp_sftp_lstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int macscp_sftp_setstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int macscp_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, long mode);
int macscp_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path);
int macscp_sftp_unlink(LIBSSH2_SFTP *sftp, const char *path);
int macscp_sftp_rename(LIBSSH2_SFTP *sftp, const char *from, const char *to);
int macscp_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len);
int macscp_sftp_readlink(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len);

LIBSSH2_CHANNEL *macscp_channel_open_session(LIBSSH2_SESSION *s);
int macscp_channel_exec(LIBSSH2_CHANNEL *c, const char *command);
ssize_t macscp_channel_read_stderr(LIBSSH2_CHANNEL *c, char *buf, size_t len);
LIBSSH2_CHANNEL *macscp_scp_send(LIBSSH2_SESSION *s, const char *path, int mode, int64_t size, long mtime, long atime);

#endif

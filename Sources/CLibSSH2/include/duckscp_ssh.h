// SPDX-License-Identifier: GPL-3.0-or-later
// Thin C helpers around libssh2: wraps macros Swift cannot call and keeps
// callback plumbing (keyboard-interactive) out of Swift.
#ifndef DUCKSCP_SSH_H
#define DUCKSCP_SSH_H

#include "libssh2.h"
#include "libssh2_sftp.h"

/// Connects a TCP socket with a timeout. Returns fd or -1 (errno set / *gai_error set).
/// family: 0 = any, 4 = IPv4 only, 6 = IPv6 only.
int duckscp_tcp_connect(const char *host, int port, int timeout_ms, int family, int *gai_error);

LIBSSH2_SESSION *duckscp_session_init(void);

/// Answers every keyboard-interactive prompt with `password`.
int duckscp_userauth_kbdint(LIBSSH2_SESSION *s, const char *user, const char *password);
int duckscp_userauth_password(LIBSSH2_SESSION *s, const char *user, const char *password);

/// Last libssh2 error message (static storage owned by libssh2) and code.
const char *duckscp_last_error(LIBSSH2_SESSION *s, int *code);

LIBSSH2_SFTP_HANDLE *duckscp_sftp_open(LIBSSH2_SFTP *sftp, const char *path, unsigned long flags, long mode);
LIBSSH2_SFTP_HANDLE *duckscp_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path);
int duckscp_sftp_stat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int duckscp_sftp_lstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int duckscp_sftp_setstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int duckscp_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, long mode);
int duckscp_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path);
int duckscp_sftp_unlink(LIBSSH2_SFTP *sftp, const char *path);
int duckscp_sftp_rename(LIBSSH2_SFTP *sftp, const char *from, const char *to);
int duckscp_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len);
int duckscp_sftp_readlink(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len);

LIBSSH2_CHANNEL *duckscp_channel_open_session(LIBSSH2_SESSION *s);
int duckscp_channel_exec(LIBSSH2_CHANNEL *c, const char *command);
ssize_t duckscp_channel_read_stderr(LIBSSH2_CHANNEL *c, char *buf, size_t len);
LIBSSH2_CHANNEL *duckscp_scp_send(LIBSSH2_SESSION *s, const char *path, int mode, int64_t size, long mtime, long atime);

#endif

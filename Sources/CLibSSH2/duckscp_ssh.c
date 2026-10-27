#include "duckscp_ssh.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int duckscp_tcp_connect(const char *host, int port, int timeout_ms, int family, int *gai_error) {
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    int fd = -1;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = family == 4 ? AF_INET : family == 6 ? AF_INET6 : AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof portstr, "%d", port);
    *gai_error = getaddrinfo(host, portstr, &hints, &res);
    if (*gai_error != 0) return -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int nosigpipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof nosigpipe);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd p = { .fd = fd, .events = POLLOUT };
            rc = poll(&p, 1, timeout_ms);
            if (rc == 1) {
                int err = 0;
                socklen_t len = sizeof err;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                rc = err ? -1 : 0;
                if (err) errno = err;
            } else {
                if (rc == 0) errno = ETIMEDOUT;
                rc = -1;
            }
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
            break;
        }
        int saved = errno;
        close(fd);
        errno = saved;
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

LIBSSH2_SESSION *duckscp_session_init(void) {
    return libssh2_session_init_ex(NULL, NULL, NULL, NULL);
}

static void kbdint_cb(const char *name, int name_len, const char *instruction, int instruction_len,
                      int num_prompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                      LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses, void **abstract) {
    (void)name; (void)name_len; (void)instruction; (void)instruction_len; (void)prompts;
    const char *password = (const char *)*abstract;
    for (int i = 0; i < num_prompts; i++) {
        size_t len = password ? strlen(password) : 0;
        responses[i].text = malloc(len + 1);
        if (!responses[i].text) { responses[i].length = 0; continue; }
        memcpy(responses[i].text, password ? password : "", len + 1);
        responses[i].length = (unsigned int)len;
    }
}

int duckscp_userauth_kbdint(LIBSSH2_SESSION *s, const char *user, const char *password) {
    void **abstract = libssh2_session_abstract(s);
    void *saved = *abstract;
    *abstract = (void *)password;
    int rc = libssh2_userauth_keyboard_interactive_ex(s, user, (unsigned int)strlen(user), kbdint_cb);
    *abstract = saved;
    return rc;
}

int duckscp_userauth_password(LIBSSH2_SESSION *s, const char *user, const char *password) {
    return libssh2_userauth_password_ex(s, user, (unsigned int)strlen(user), password, (unsigned int)strlen(password), NULL);
}

const char *duckscp_last_error(LIBSSH2_SESSION *s, int *code) {
    char *msg = NULL;
    *code = libssh2_session_last_error(s, &msg, NULL, 0);
    return msg ? msg : "";
}

LIBSSH2_SFTP_HANDLE *duckscp_sftp_open(LIBSSH2_SFTP *sftp, const char *path, unsigned long flags, long mode) {
    return libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), flags, mode, LIBSSH2_SFTP_OPENFILE);
}

LIBSSH2_SFTP_HANDLE *duckscp_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), 0, 0, LIBSSH2_SFTP_OPENDIR);
}

int duckscp_sftp_stat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_stat_ex(sftp, path, (unsigned int)strlen(path), LIBSSH2_SFTP_STAT, attrs);
}

int duckscp_sftp_lstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_stat_ex(sftp, path, (unsigned int)strlen(path), LIBSSH2_SFTP_LSTAT, attrs);
}

int duckscp_sftp_setstat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_stat_ex(sftp, path, (unsigned int)strlen(path), LIBSSH2_SFTP_SETSTAT, attrs);
}

int duckscp_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, long mode) {
    return libssh2_sftp_mkdir_ex(sftp, path, (unsigned int)strlen(path), mode);
}

int duckscp_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_rmdir_ex(sftp, path, (unsigned int)strlen(path));
}

int duckscp_sftp_unlink(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_unlink_ex(sftp, path, (unsigned int)strlen(path));
}

int duckscp_sftp_rename(LIBSSH2_SFTP *sftp, const char *from, const char *to) {
    return libssh2_sftp_rename_ex(sftp, from, (unsigned int)strlen(from), to, (unsigned int)strlen(to),
                                  LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE);
}

int duckscp_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len) {
    return libssh2_sftp_symlink_ex(sftp, path, (unsigned int)strlen(path), out, out_len, LIBSSH2_SFTP_REALPATH);
}

int duckscp_sftp_readlink(LIBSSH2_SFTP *sftp, const char *path, char *out, unsigned int out_len) {
    return libssh2_sftp_symlink_ex(sftp, path, (unsigned int)strlen(path), out, out_len, LIBSSH2_SFTP_READLINK);
}

LIBSSH2_CHANNEL *duckscp_channel_open_session(LIBSSH2_SESSION *s) {
    return libssh2_channel_open_ex(s, "session", sizeof("session") - 1, LIBSSH2_CHANNEL_WINDOW_DEFAULT,
                                   LIBSSH2_CHANNEL_PACKET_DEFAULT, NULL, 0);
}

int duckscp_channel_exec(LIBSSH2_CHANNEL *c, const char *command) {
    return libssh2_channel_process_startup(c, "exec", sizeof("exec") - 1, command, (unsigned int)strlen(command));
}

ssize_t duckscp_channel_read_stderr(LIBSSH2_CHANNEL *c, char *buf, size_t len) {
    return libssh2_channel_read_ex(c, SSH_EXTENDED_DATA_STDERR, buf, len);
}

LIBSSH2_CHANNEL *duckscp_scp_send(LIBSSH2_SESSION *s, const char *path, int mode, int64_t size, long mtime, long atime) {
    return libssh2_scp_send64(s, path, mode, size, mtime, atime);
}

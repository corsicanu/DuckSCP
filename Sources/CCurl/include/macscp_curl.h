// Non-variadic wrappers for libcurl (Swift cannot call curl_easy_setopt directly).
#ifndef MACSCP_CURL_H
#define MACSCP_CURL_H

#include <curl/curl.h>

typedef size_t (*macscp_io_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*macscp_seek_cb)(void *userdata, curl_off_t offset, int origin);
typedef int (*macscp_progress_cb)(void *userdata, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow);

CURLcode macscp_curl_long(CURL *h, CURLoption o, long v);
CURLcode macscp_curl_off(CURL *h, CURLoption o, curl_off_t v);
CURLcode macscp_curl_str(CURL *h, CURLoption o, const char *v);
CURLcode macscp_curl_ptr(CURL *h, CURLoption o, void *v);
CURLcode macscp_curl_write_cb(CURL *h, macscp_io_cb cb, void *userdata);
CURLcode macscp_curl_read_cb(CURL *h, macscp_io_cb cb, void *userdata);
/// Lets libcurl rewind uploads (needed when auth negotiation resends the body).
CURLcode macscp_curl_seek_cb(CURL *h, macscp_seek_cb cb, void *userdata);
CURLcode macscp_curl_progress_cb(CURL *h, macscp_progress_cb cb, void *userdata);
CURLcode macscp_curl_info_str(CURL *h, CURLINFO i, const char **out);
CURLcode macscp_curl_info_long(CURL *h, CURLINFO i, long *out);
/// Copies CERTINFO of the first (server) certificate as "Key:value" lines. Returns bytes written.
size_t macscp_curl_first_cert(CURL *h, char *out, size_t len);

#endif

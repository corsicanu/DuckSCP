// SPDX-License-Identifier: GPL-3.0-or-later
// Non-variadic wrappers for libcurl (Swift cannot call curl_easy_setopt directly).
#ifndef DUCKSCP_CURL_H
#define DUCKSCP_CURL_H

#include <curl/curl.h>

typedef size_t (*duckscp_io_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*duckscp_seek_cb)(void *userdata, curl_off_t offset, int origin);
typedef int (*duckscp_progress_cb)(void *userdata, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow);

CURLcode duckscp_curl_long(CURL *h, CURLoption o, long v);
CURLcode duckscp_curl_off(CURL *h, CURLoption o, curl_off_t v);
CURLcode duckscp_curl_str(CURL *h, CURLoption o, const char *v);
CURLcode duckscp_curl_ptr(CURL *h, CURLoption o, void *v);
CURLcode duckscp_curl_write_cb(CURL *h, duckscp_io_cb cb, void *userdata);
CURLcode duckscp_curl_read_cb(CURL *h, duckscp_io_cb cb, void *userdata);
/// Lets libcurl rewind uploads (needed when auth negotiation resends the body).
CURLcode duckscp_curl_seek_cb(CURL *h, duckscp_seek_cb cb, void *userdata);
CURLcode duckscp_curl_progress_cb(CURL *h, duckscp_progress_cb cb, void *userdata);
CURLcode duckscp_curl_info_str(CURL *h, CURLINFO i, const char **out);
CURLcode duckscp_curl_info_long(CURL *h, CURLINFO i, long *out);
/// Copies CERTINFO of the first (server) certificate as "Key:value" lines. Returns bytes written.
size_t duckscp_curl_first_cert(CURL *h, char *out, size_t len);

#endif

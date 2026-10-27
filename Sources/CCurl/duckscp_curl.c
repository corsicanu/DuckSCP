#include "duckscp_curl.h"

#include <string.h>

CURLcode duckscp_curl_long(CURL *h, CURLoption o, long v) { return curl_easy_setopt(h, o, v); }
CURLcode duckscp_curl_off(CURL *h, CURLoption o, curl_off_t v) { return curl_easy_setopt(h, o, v); }
CURLcode duckscp_curl_str(CURL *h, CURLoption o, const char *v) { return curl_easy_setopt(h, o, v); }
CURLcode duckscp_curl_ptr(CURL *h, CURLoption o, void *v) { return curl_easy_setopt(h, o, v); }

CURLcode duckscp_curl_write_cb(CURL *h, duckscp_io_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}

CURLcode duckscp_curl_read_cb(CURL *h, duckscp_io_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_READFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_READDATA, userdata);
}

CURLcode duckscp_curl_seek_cb(CURL *h, duckscp_seek_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_SEEKFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_SEEKDATA, userdata);
}

CURLcode duckscp_curl_progress_cb(CURL *h, duckscp_progress_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, cb);
    if (!rc) rc = curl_easy_setopt(h, CURLOPT_XFERINFODATA, userdata);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
}

CURLcode duckscp_curl_info_str(CURL *h, CURLINFO i, const char **out) { return curl_easy_getinfo(h, i, out); }
CURLcode duckscp_curl_info_long(CURL *h, CURLINFO i, long *out) { return curl_easy_getinfo(h, i, out); }

size_t duckscp_curl_first_cert(CURL *h, char *out, size_t len) {
    struct curl_certinfo *ci = NULL;
    if (len == 0 || curl_easy_getinfo(h, CURLINFO_CERTINFO, &ci) != CURLE_OK || !ci || ci->num_of_certs < 1) return 0;
    size_t used = 0;
    for (struct curl_slist *s = ci->certinfo[0]; s; s = s->next) {
        size_t n = strlen(s->data);
        if (used + n + 2 > len) break;
        memcpy(out + used, s->data, n);
        used += n;
        out[used++] = '\n';
    }
    out[used] = 0;
    return used;
}

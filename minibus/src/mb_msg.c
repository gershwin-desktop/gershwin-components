/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "mb.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------ buffer */

void mb_buf_free(mb_buf *b)
{
    free(b->p);
    b->p = NULL;
    b->len = b->cap = 0;
}

bool mb_buf_reserve(mb_buf *b, size_t extra)
{
    if (b->len + extra < b->len) return false;
    if (b->len + extra <= b->cap) return true;
    size_t ncap = b->cap ? b->cap : 256;
    while (ncap < b->len + extra) {
        if (ncap > SIZE_MAX / 2) return false;
        ncap *= 2;
    }
    uint8_t *np = realloc(b->p, ncap);
    if (!np) return false;
    b->p = np;
    b->cap = ncap;
    return true;
}

bool mb_buf_append(mb_buf *b, const void *d, size_t n)
{
    if (!mb_buf_reserve(b, n)) return false;
    if (n) memcpy(b->p + b->len, d, n);
    b->len += n;
    return true;
}

void mb_buf_consume(mb_buf *b, size_t n)
{
    if (n >= b->len) { b->len = 0; return; }
    memmove(b->p, b->p + n, b->len - n);
    b->len -= n;
}

/* ------------------------------------------------------------ name syntax */

bool mb_valid_utf8(const uint8_t *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        /* most text is ASCII: skip it eight bytes at a time */
        while (i + 8 <= n) {
            uint64_t w;
            memcpy(&w, s + i, 8);
            if (w & 0x8080808080808080ull) break;
            i += 8;
        }
        if (i >= n) break;
        uint8_t c = s[i];
        if (c < 0x80) { i++; continue; }
        size_t need;
        uint32_t cp;
        if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
        else return false;
        if (i + need >= n) return false;
        for (size_t k = 1; k <= need; k++) {
            if ((s[i + k] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (s[i + k] & 0x3F);
        }
        if ((need == 1 && cp < 0x80) || (need == 2 && cp < 0x800) ||
            (need == 3 && cp < 0x10000) || cp > 0x10FFFF ||
            (cp >= 0xD800 && cp <= 0xDFFF))
            return false;
        i += need + 1;
    }
    return true;
}

static bool is_basic(char c)
{
    switch (c) {
    case 'y': case 'b': case 'n': case 'q': case 'i': case 'u': case 'x':
    case 't': case 'd': case 's': case 'o': case 'g': case 'h':
        return true;
    default:
        return false;
    }
}

/* Parse one complete type at s[*i]. */
static bool sig_one(const char *s, size_t n, size_t *i, int adepth, int sdepth)
{
    if (*i >= n) return false;
    char c = s[*i];
    if (is_basic(c) || c == 'v') { (*i)++; return true; }
    if (c == 'a') {
        if (adepth + 1 > 32) return false;
        (*i)++;
        if (*i < n && s[*i] == '{') {
            if (sdepth + 1 > 32) return false;
            (*i)++;
            if (*i >= n || !is_basic(s[*i])) return false;
            (*i)++;
            if (!sig_one(s, n, i, adepth + 1, sdepth + 1)) return false;
            if (*i >= n || s[*i] != '}') return false;
            (*i)++;
            return true;
        }
        return sig_one(s, n, i, adepth + 1, sdepth);
    }
    if (c == '(') {
        if (sdepth + 1 > 32) return false;
        (*i)++;
        size_t members = 0;
        while (*i < n && s[*i] != ')') {
            if (!sig_one(s, n, i, adepth, sdepth + 1)) return false;
            members++;
        }
        if (*i >= n || members == 0) return false;
        (*i)++;
        return true;
    }
    return false;
}

bool mb_valid_signature(const char *s, size_t n)
{
    if (n > MB_MAX_SIG) return false;
    size_t i = 0;
    while (i < n) {
        if (!sig_one(s, n, &i, 0, 0)) return false;
    }
    return true;
}

bool mb_valid_single_type(const char *s, size_t n)
{
    size_t i = 0;
    if (n == 0 || n > MB_MAX_SIG) return false;
    return sig_one(s, n, &i, 0, 0) && i == n;
}

static bool is_alpha_(unsigned char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
static bool is_alnum_(unsigned char c)
{
    return is_alpha_(c) || (c >= '0' && c <= '9');
}

bool mb_valid_object_path(const char *s)
{
    if (s[0] != '/') return false;
    if (s[1] == 0) return true;
    size_t i = 1;
    for (;;) {
        size_t start = i;
        while (is_alnum_((unsigned char)s[i])) i++;
        if (i == start) return false;
        if (s[i] == 0) return true;
        if (s[i] != '/') return false;
        i++;
    }
}

bool mb_valid_member(const char *s)
{
    size_t n = strlen(s);
    if (n == 0 || n > MB_MAX_NAME || !is_alpha_((unsigned char)s[0])) return false;
    for (size_t i = 1; i < n; i++)
        if (!is_alnum_((unsigned char)s[i])) return false;
    return true;
}

static bool dotted(const char *s, bool allow_dash, bool allow_digit_first)
{
    size_t n = strlen(s);
    if (n == 0 || n > MB_MAX_NAME) return false;
    int elements = 0;
    size_t i = 0;
    while (i <= n) {
        size_t start = i;
        while (i < n && s[i] != '.') {
            unsigned char c = (unsigned char)s[i];
            bool ok = is_alnum_(c) || (allow_dash && c == '-');
            if (!ok) return false;
            i++;
        }
        if (i == start) return false;
        unsigned char f = (unsigned char)s[start];
        if (!allow_digit_first && f >= '0' && f <= '9') return false;
        elements++;
        if (i == n) break;
        i++;
        if (i == n) return false;
    }
    return elements >= 2;
}

bool mb_valid_interface(const char *s)
{
    return dotted(s, false, false);
}

bool mb_valid_well_known_name(const char *s)
{
    return s[0] != ':' && dotted(s, true, false);
}

bool mb_is_unique_name(const char *s)
{
    return s[0] == ':';
}

bool mb_valid_bus_name(const char *s)
{
    if (s[0] == ':') {
        /* unique names: elements may start with a digit */
        return strlen(s) > 1 && dotted(s + 1, true, true);
    }
    return mb_valid_well_known_name(s);
}

/* ---------------------------------------------------------------- writer */

void mb_w_init(mb_w *w, bool big)
{
    memset(w, 0, sizeof *w);
    w->big = big;
}

void mb_w_free(mb_w *w)
{
    mb_buf_free(&w->b);
}

void mb_w_align(mb_w *w, size_t a)
{
    static const uint8_t zeros[8] = {0};
    size_t pad = (a - (w->b.len % a)) % a;
    if (pad && !mb_buf_append(&w->b, zeros, pad)) w->failed = true;
}

void mb_w_u8(mb_w *w, uint8_t v)
{
    if (!mb_buf_append(&w->b, &v, 1)) w->failed = true;
}

static void w_int(mb_w *w, uint64_t v, int bytes)
{
    uint8_t t[8];
    for (int i = 0; i < bytes; i++) {
        int shift = w->big ? (bytes - 1 - i) * 8 : i * 8;
        t[i] = (uint8_t)(v >> shift);
    }
    if (!mb_buf_append(&w->b, t, (size_t)bytes)) w->failed = true;
}

void mb_w_u32(mb_w *w, uint32_t v)
{
    mb_w_align(w, 4);
    w_int(w, v, 4);
}

void mb_w_bool(mb_w *w, bool v)
{
    mb_w_u32(w, v ? 1 : 0);
}

void mb_w_str(mb_w *w, const char *s)
{
    size_t n = strlen(s);
    mb_w_u32(w, (uint32_t)n);
    if (!mb_buf_append(&w->b, s, n + 1)) w->failed = true;
}

void mb_w_sig(mb_w *w, const char *s)
{
    size_t n = strlen(s);
    mb_w_u8(w, (uint8_t)n);
    if (!mb_buf_append(&w->b, s, n + 1)) w->failed = true;
}

size_t mb_w_array_begin(mb_w *w, size_t elem_align)
{
    mb_w_u32(w, 0);
    size_t token = w->b.len - 4;
    mb_w_align(w, elem_align);
    return token;
}

void mb_w_array_end(mb_w *w, size_t token, size_t elem_align)
{
    /* The length counts from the first element, after the alignment padding. */
    size_t start = token + 4;
    start = (start + elem_align - 1) / elem_align * elem_align;
    uint32_t v = (uint32_t)(w->b.len - start);
    for (int i = 0; i < 4; i++) {
        int shift = w->big ? (3 - i) * 8 : i * 8;
        w->b.p[token + (size_t)i] = (uint8_t)(v >> shift);
    }
}

/* ---------------------------------------------------------------- reader */

void mb_r_init(mb_r *r, const uint8_t *p, size_t len, bool big)
{
    r->p = p; r->len = len; r->pos = 0; r->big = big; r->bad = false;
}

static bool r_align(mb_r *r, size_t a, bool strict)
{
    size_t pad = (a - (r->pos % a)) % a;
    if (r->pos + pad > r->len) { r->bad = true; return false; }
    if (strict) {
        for (size_t i = 0; i < pad; i++)
            if (r->p[r->pos + i] != 0) { r->bad = true; return false; }
    }
    r->pos += pad;
    return true;
}

static uint64_t r_int(mb_r *r, int bytes)
{
    if (r->bad || !r_align(r, (size_t)bytes, true)) return 0;
    if (r->pos + (size_t)bytes > r->len) { r->bad = true; return 0; }
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    if (!r->big) {
        /* the common case: little-endian data on a little-endian host */
        uint64_t v = 0;
        memcpy(&v, r->p + r->pos, (size_t)bytes);
        r->pos += (size_t)bytes;
        return v;
    }
#endif
    uint64_t v = 0;
    for (int i = 0; i < bytes; i++) {
        uint8_t b = r->p[r->pos + (size_t)i];
        if (r->big) v = (v << 8) | b; else v |= (uint64_t)b << (8 * i);
    }
    r->pos += (size_t)bytes;
    return v;
}

uint8_t mb_r_u8(mb_r *r)
{
    if (r->bad || r->pos + 1 > r->len) { r->bad = true; return 0; }
    return r->p[r->pos++];
}

uint32_t mb_r_u32(mb_r *r) { return (uint32_t)r_int(r, 4); }

static const char *r_string(mb_r *r, uint32_t n)
{
    if (r->bad || r->pos > r->len || (size_t)n + 1 > r->len - r->pos) { r->bad = true; return NULL; }
    const uint8_t *s = r->p + r->pos;
    if (s[n] != 0) { r->bad = true; return NULL; }
    if (memchr(s, 0, n) != NULL) { r->bad = true; return NULL; }
    if (!mb_valid_utf8(s, n)) { r->bad = true; return NULL; }
    r->pos += (size_t)n + 1;
    return (const char *)s;
}

const char *mb_r_str(mb_r *r)
{
    uint32_t n = mb_r_u32(r);
    if (r->bad) return NULL;
    return r_string(r, n);
}

const char *mb_r_sig(mb_r *r)
{
    uint8_t n = mb_r_u8(r);
    if (r->bad) return NULL;
    const char *s = r_string(r, n);
    if (s && !mb_valid_signature(s, n)) { r->bad = true; return NULL; }
    return s;
}

static size_t type_align(char c)
{
    switch (c) {
    case 'y': case 'g': case 'v': return 1;
    case 'n': case 'q': return 2;
    case 'b': case 'i': case 'u': case 'h': case 's': case 'o': case 'a': return 4;
    case 'x': case 't': case 'd': case '(': case '{': return 8;
    default: return 1;
    }
}

/* Index just past the complete type starting at sig[i] (signature already valid). */
static size_t type_end(const char *sig, size_t i)
{
    char c = sig[i];
    if (c == 'a') return type_end(sig, i + 1);
    if (c == '(' || c == '{') {
        char close = c == '(' ? ')' : '}';
        i++;
        while (sig[i] != close) i = type_end(sig, i);
        return i + 1;
    }
    return i + 1;
}

/* Walk a value of the type at sig[*si], validating it. */
static bool walk(mb_r *r, const char *sig, size_t *si, int depth, uint32_t nfds)
{
    if (depth > MB_MAX_DEPTH) return false;
    char c = sig[*si];
    switch (c) {
    case 'y': mb_r_u8(r); (*si)++; return !r->bad;
    case 'b': { uint32_t v = mb_r_u32(r); (*si)++; return !r->bad && v <= 1; }
    case 'n': case 'q': r_int(r, 2); (*si)++; return !r->bad;
    case 'i': case 'u': r_int(r, 4); (*si)++; return !r->bad;
    case 'x': case 't': case 'd': r_int(r, 8); (*si)++; return !r->bad;
    case 'h': { uint32_t v = mb_r_u32(r); (*si)++; return !r->bad && v < nfds; }
    case 's': mb_r_str(r); (*si)++; return !r->bad;
    case 'o': { const char *s = mb_r_str(r); (*si)++; return s && mb_valid_object_path(s); }
    case 'g': mb_r_sig(r); (*si)++; return !r->bad;
    case 'v': {
        const char *vs = mb_r_sig(r);
        (*si)++;
        if (!vs || !mb_valid_single_type(vs, strlen(vs))) return false;
        size_t k = 0;
        return walk(r, vs, &k, depth + 1, nfds);
    }
    case 'a': {
        uint32_t n = mb_r_u32(r);
        size_t elem = *si + 1;
        size_t end = type_end(sig, *si);
        if (r->bad || n > MB_MAX_ARRAY) return false;
        if (!r_align(r, type_align(sig[elem]), true)) return false;
        if ((size_t)n > r->len - r->pos) return false;
        size_t stop = r->pos + n;
        while (r->pos < stop) {
            size_t k = elem;
            if (!walk(r, sig, &k, depth + 1, nfds)) return false;
        }
        if (r->pos != stop) return false;
        *si = end;
        return true;
    }
    case '(': {
        if (!r_align(r, 8, true)) return false;
        size_t k = *si + 1;
        while (sig[k] != ')')
            if (!walk(r, sig, &k, depth + 1, nfds)) return false;
        *si = k + 1;
        return true;
    }
    case '{': {
        if (!r_align(r, 8, true)) return false;
        size_t k = *si + 1;
        if (!walk(r, sig, &k, depth + 1, nfds)) return false;
        if (!walk(r, sig, &k, depth + 1, nfds)) return false;
        *si = k + 1;
        return true;
    }
    default:
        return false;
    }
}

static void find_args(mb_msg *m)
{
    m->nargs = 0;
    const char *sig = m->signature;
    if (!sig) return;
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    size_t si = 0;
    while (sig[si] && m->nargs < 8) {
        char c = sig[si];
        int i = m->nargs++;
        m->argtype[i] = c;
        m->arg[i] = NULL;
        if (c == 's' || c == 'o' || c == 'g') {
            m->arg[i] = c == 'g' ? mb_r_sig(&r) : mb_r_str(&r);
            si++;
            if (r.bad) return;
        } else if (!walk(&r, sig, &si, 0, 0xFFFFFFFFu)) {
            return;
        }
    }
}

const char *mb_msg_arg_string(const mb_msg *cm, unsigned index, char *type)
{
    mb_msg *m = (mb_msg *)cm;   /* the cache is not part of the message's value */
    if (index < 8) {
        if (m->nargs < 0) find_args(m);
        if ((int)index >= m->nargs) return NULL;
        if (type) *type = m->argtype[index];
        return m->arg[index];
    }
    const char *sig = m->signature;
    if (!sig) return NULL;
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    size_t si = 0;
    for (unsigned i = 0;; i++) {
        if (!sig[si]) return NULL;
        char c = sig[si];
        if (i == index) {
            if (c != 's' && c != 'o' && c != 'g') return NULL;
            if (type) *type = c;
            const char *s = c == 'g' ? mb_r_sig(&r) : mb_r_str(&r);
            return r.bad ? NULL : s;
        }
        if (!walk(&r, sig, &si, 0, 0xFFFFFFFFu)) return NULL;
    }
}

/* -------------------------------------------------------------- messages */

mb_msg *mb_msg_ref(mb_msg *m)
{
    m->refs++;
    return m;
}

void mb_msg_unref(mb_msg *m)
{
    if (!m || --m->refs > 0) return;
    for (int i = 0; i < m->nfds; i++) close(m->fds[i]);
    free(m->fds);
    free(m);
}

static uint32_t get32(const uint8_t *p, bool big)
{
    return big ? ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3])
               : ((uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]);
}

mb_parse_result mb_msg_peek(const uint8_t *p, size_t avail, size_t *total)
{
    if (avail < 16) return MB_PARSE_NEED_MORE;
    if (p[0] != 'l' && p[0] != 'B') return MB_PARSE_INVALID;
    if (p[3] != 1) return MB_PARSE_INVALID;
    bool big = p[0] == 'B';
    uint32_t body = get32(p + 4, big);
    uint32_t flen = get32(p + 12, big);
    if (flen > MB_MAX_ARRAY || body > MB_MAX_MESSAGE) return MB_PARSE_INVALID;
    uint64_t hdr = (16u + (uint64_t)flen + 7u) & ~7ull;
    uint64_t all = hdr + body;
    if (all > MB_MAX_MESSAGE) return MB_PARSE_INVALID;
    *total = (size_t)all;
    return MB_PARSE_OK;
}

static bool fail(const char **why, const char *msg)
{
    if (why) *why = msg;
    return false;
}

/* Parse header fields into m. */
static bool parse_header(mb_msg *m, const char **why)
{
    const uint8_t *d = m->data;
    mb_r r;
    uint32_t flen = get32(d + 12, m->big);
    size_t hdr_end = 16u + flen;
    mb_r_init(&r, d, hdr_end, m->big);
    r.pos = 16;
    uint32_t seen = 0;
    while (r.pos < hdr_end) {
        if (!r_align(&r, 8, true)) return fail(why, "bad header field padding");
        if (r.pos >= hdr_end) return fail(why, "header field array overrun");
        uint8_t code = mb_r_u8(&r);
        const char *vsig = mb_r_sig(&r);
        if (r.bad || !vsig) return fail(why, "bad header field");
        if (!mb_valid_single_type(vsig, strlen(vsig))) return fail(why, "bad header field signature");
        if (code == 0) return fail(why, "header field code 0");
        char want = 0;
        switch (code) {
        case MB_F_PATH: want = 'o'; break;
        case MB_F_INTERFACE: case MB_F_MEMBER: case MB_F_ERROR_NAME:
        case MB_F_DESTINATION: case MB_F_SENDER: want = 's'; break;
        case MB_F_REPLY_SERIAL: case MB_F_UNIX_FDS: want = 'u'; break;
        case MB_F_SIGNATURE: want = 'g'; break;
        default: break;
        }
        if (want) {
            if (vsig[0] != want || vsig[1]) return fail(why, "header field has wrong type");
            if (seen & (1u << code)) return fail(why, "duplicate header field");
            seen |= 1u << code;
        }
        size_t si = 0;
        switch (want) {
        case 'o': case 's': {
            const char *s = mb_r_str(&r);
            if (!s) return fail(why, "bad header string");
            switch (code) {
            case MB_F_PATH: if (!mb_valid_object_path(s)) return fail(why, "invalid path"); m->path = s; break;
            case MB_F_INTERFACE: if (!mb_valid_interface(s)) return fail(why, "invalid interface"); m->interface = s; break;
            case MB_F_MEMBER: if (!mb_valid_member(s)) return fail(why, "invalid member"); m->member = s; break;
            case MB_F_ERROR_NAME: if (!mb_valid_interface(s)) return fail(why, "invalid error name"); m->error_name = s; break;
            case MB_F_DESTINATION: if (!mb_valid_bus_name(s)) return fail(why, "invalid destination"); m->destination = s; break;
            case MB_F_SENDER: if (!mb_valid_bus_name(s)) return fail(why, "invalid sender"); m->sender = s; break;
            }
            break;
        }
        case 'g': {
            const char *s = mb_r_sig(&r);
            if (!s) return fail(why, "bad signature field");
            m->signature = s;
            break;
        }
        case 'u': {
            uint32_t v = mb_r_u32(&r);
            if (r.bad) return fail(why, "bad header integer");
            if (code == MB_F_REPLY_SERIAL) {
                if (v == 0) return fail(why, "reply serial 0");
                m->reply_serial = v; m->has_reply_serial = true;
            } else {
                m->unix_fds = v;
            }
            break;
        }
        default:
            if (!walk(&r, vsig, &si, 1, 0xFFFFFFFFu)) return fail(why, "bad unknown header field value");
            break;
        }
    }
    if (r.pos != hdr_end) return fail(why, "header field array length mismatch");
    /* padding after the fields up to the body must be zero */
    size_t body_off = (hdr_end + 7u) & ~(size_t)7;
    for (size_t i = hdr_end; i < body_off; i++)
        if (d[i] != 0) return fail(why, "nonzero header padding");
    m->body_off = body_off;
    return true;
}

/* check_body is false only for messages minibus put together itself from parts
 * it had already validated. */
/* Fill m (whose data already points at n bytes) and check all of it. */
static bool check(mb_msg *m, size_t n, const char **why)
{
    const uint8_t *p = m->data;
    m->len = n;
    m->nargs = -1;
    m->big = p[0] == 'B';
    m->type = p[1];
    m->flags = p[2];
    m->body_len = get32(p + 4, m->big);
    m->serial = get32(p + 8, m->big);
    if (m->serial == 0) return fail(why, "serial 0");
    if (!parse_header(m, why)) return false;
    if (m->body_off + m->body_len != n) return fail(why, "body length mismatch");
    if (m->type == 0) return fail(why, "invalid message type");

    bool ok = true;
    switch (m->type) {
    case MB_METHOD_CALL: ok = m->path && m->member; break;
    case MB_SIGNAL: ok = m->path && m->interface && m->member; break;
    case MB_ERROR: ok = m->error_name && m->has_reply_serial; break;
    case MB_METHOD_RETURN: ok = m->has_reply_serial; break;
    default: break;
    }
    if (!ok) return fail(why, "missing required header field");
    if (m->type == MB_SIGNAL && m->interface && strcmp(m->interface, "org.freedesktop.DBus.Local") == 0)
        return fail(why, "reserved Local interface");
    if (m->path && strcmp(m->path, "/org/freedesktop/DBus/Local") == 0)
        return fail(why, "reserved Local path");

    /* Body must match the signature exactly. */
    const char *sig = m->signature ? m->signature : "";
    mb_r br;
    mb_r_init(&br, m->data + m->body_off, m->body_len, m->big);
    size_t si = 0;
    while (sig[si])
        if (!walk(&br, sig, &si, 0, m->unix_fds)) return fail(why, "body does not match signature");
    if (br.pos != m->body_len) return fail(why, "body does not match signature");
    return true;
}

static mb_parse_result frame(const uint8_t *p, size_t n, const char **why)
{
    size_t total;
    mb_parse_result pr = mb_msg_peek(p, n, &total);
    if (pr == MB_PARSE_INVALID) { if (why) *why = "bad fixed header"; return pr; }
    if (pr == MB_PARSE_NEED_MORE || n < total) return MB_PARSE_NEED_MORE;
    if (n != total) { if (why) *why = "length mismatch"; return MB_PARSE_INVALID; }
    return MB_PARSE_OK;
}

mb_parse_result mb_msg_view(const uint8_t *p, size_t n, mb_msg *view, const char **why)
{
    mb_parse_result pr = frame(p, n, why);
    if (pr != MB_PARSE_OK) return pr;
    memset(view, 0, sizeof *view);
    view->refs = 1;
    view->data = (uint8_t *)p;
    return check(view, n, why) ? MB_PARSE_OK : MB_PARSE_INVALID;
}

/* Offset of the string just written (it ends right before the writer's end). */
static size_t written_at(const mb_w *w, const char *str)
{
    return w->b.len - strlen(str) - 1;
}

mb_msg *mb_msg_build(const mb_msg_spec *s)
{
    /* The header is written into a buffer that lives as long as the process and
     * the message is assembled from it and the body in one allocation. Nothing is
     * parsed again: every part was valid before. */
    static mb_w w;
    w.b.len = 0;
    w.big = s->big;
    w.failed = false;
    size_t off_path = 0, off_iface = 0, off_member = 0, off_err = 0, off_dest = 0, off_sender = 0, off_sig = 0;
    mb_w_u8(&w, s->big ? 'B' : 'l');
    mb_w_u8(&w, s->type);
    mb_w_u8(&w, s->flags);
    mb_w_u8(&w, 1);
    mb_w_u32(&w, (uint32_t)s->body_len);
    mb_w_u32(&w, s->serial);
    size_t arr = mb_w_array_begin(&w, 8);
    size_t first = w.b.len;
#define FIELD_STR(code, sigc, val, off) \
    if (val) { mb_w_align(&w, 8); mb_w_u8(&w, code); mb_w_sig(&w, sigc); mb_w_str(&w, val); off = written_at(&w, val); }
    FIELD_STR(MB_F_PATH, "o", s->path, off_path)
    FIELD_STR(MB_F_INTERFACE, "s", s->interface, off_iface)
    FIELD_STR(MB_F_MEMBER, "s", s->member, off_member)
    FIELD_STR(MB_F_ERROR_NAME, "s", s->error_name, off_err)
    if (s->has_reply_serial) { mb_w_align(&w, 8); mb_w_u8(&w, MB_F_REPLY_SERIAL); mb_w_sig(&w, "u"); mb_w_u32(&w, s->reply_serial); }
    FIELD_STR(MB_F_DESTINATION, "s", s->destination, off_dest)
    FIELD_STR(MB_F_SENDER, "s", s->sender, off_sender)
    if (s->signature && s->signature[0]) {
        mb_w_align(&w, 8); mb_w_u8(&w, MB_F_SIGNATURE); mb_w_sig(&w, "g"); mb_w_sig(&w, s->signature);
        off_sig = written_at(&w, s->signature);
    }
    if (s->unix_fds) { mb_w_align(&w, 8); mb_w_u8(&w, MB_F_UNIX_FDS); mb_w_sig(&w, "u"); mb_w_u32(&w, s->unix_fds); }
#undef FIELD_STR
    size_t flen = w.b.len - first;
    for (int i = 0; i < 4; i++) {
        int shift = w.big ? (3 - i) * 8 : i * 8;
        w.b.p[arr + (size_t)i] = (uint8_t)((uint32_t)flen >> shift);
    }
    mb_w_align(&w, 8);
    size_t hlen = w.b.len, n = hlen + s->body_len;
    if (w.failed || n > MB_MAX_MESSAGE) return NULL;

    mb_msg *m = malloc(sizeof *m + n);
    if (!m) return NULL;
    memset(m, 0, sizeof *m);
    m->refs = 1;
    m->nargs = -1;
    m->data = (uint8_t *)(m + 1);
    memcpy(m->data, w.b.p, hlen);
    if (s->body_len) memcpy(m->data + hlen, s->body, s->body_len);
    m->len = n;
    m->big = s->big;
    m->type = s->type;
    m->flags = s->flags;
    m->serial = s->serial;
    m->reply_serial = s->reply_serial;
    m->has_reply_serial = s->has_reply_serial;
    m->body_len = (uint32_t)s->body_len;
    m->unix_fds = s->unix_fds;
    m->body_off = hlen;
    const char *d = (const char *)m->data;
    if (s->path) m->path = d + off_path;
    if (s->interface) m->interface = d + off_iface;
    if (s->member) m->member = d + off_member;
    if (s->error_name) m->error_name = d + off_err;
    if (s->destination) m->destination = d + off_dest;
    if (s->sender) m->sender = d + off_sender;
    if (off_sig) m->signature = d + off_sig;
    /* an unusually long header does not keep its buffer */
    if (w.b.cap > 65536) mb_w_free(&w);
    return m;
}

mb_msg *mb_msg_with_sender(mb_msg *m, const char *sender, bool big_out)
{
    (void)big_out;
    mb_msg_spec s;
    memset(&s, 0, sizeof s);
    s.big = m->big;
    s.type = m->type;
    s.flags = m->flags;
    s.serial = m->serial;
    s.reply_serial = m->reply_serial;
    s.has_reply_serial = m->has_reply_serial;
    s.path = m->path; s.interface = m->interface; s.member = m->member;
    s.error_name = m->error_name; s.destination = m->destination;
    s.sender = sender; s.signature = m->signature;
    s.unix_fds = m->unix_fds;
    s.body = m->data + m->body_off;
    s.body_len = m->body_len;
    mb_msg *n = mb_msg_build(&s);
    if (n && m->nfds) {
        /* descriptors travel with the stamped copy */
        n->fds = m->fds;
        n->nfds = m->nfds;
        m->fds = NULL;
        m->nfds = 0;
    }
    return n;
}

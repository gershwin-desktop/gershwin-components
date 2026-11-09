/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "mb_int.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define READ_CHUNK (64u * 1024u)
#define MAX_AUTH_FAILURES 32
#define MAX_FDQ 1024
#define MB_MAX_QUEUED (32u * 1024u * 1024u)

int64_t mb_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* --------------------------------------------------------- peer credentials */

static void peer_credentials(mb_conn *c)
{
#if defined(__linux__)
    struct ucred cr;
    socklen_t l = sizeof cr;
    if (getsockopt(c->fd, SOL_SOCKET, SO_PEERCRED, &cr, &l) == 0) {
        c->uid = cr.uid; c->have_uid = true;
        c->pid = (uint32_t)cr.pid; c->have_pid = cr.pid > 0;
    }
#elif defined(__OpenBSD__)
    struct sockpeercred cr;
    socklen_t l = sizeof cr;
    if (getsockopt(c->fd, SOL_SOCKET, SO_PEERCRED, &cr, &l) == 0) {
        c->uid = cr.uid; c->have_uid = true;
        c->pid = (uint32_t)cr.pid; c->have_pid = cr.pid > 0;
    }
#else
    uid_t u; gid_t g;
    if (getpeereid(c->fd, &u, &g) == 0) { c->uid = u; c->have_uid = true; }
#if defined(LOCAL_PEERCRED) && defined(__FreeBSD__)
    struct xucred xc;
    socklen_t l = sizeof xc;
    if (getsockopt(c->fd, 0, LOCAL_PEERCRED, &xc, &l) == 0) {
#if defined(__FreeBSD_version) && __FreeBSD_version >= 1300000
        if (xc.cr_pid > 0) { c->pid = (uint32_t)xc.cr_pid; c->have_pid = true; }
#endif
    }
#endif
#endif
}

/* ------------------------------------------------------------------- conn */

mb_conn *mb_conn_new(mb_bus *b, int fd)
{
    mb_conn *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->bus = b;
    c->fd = fd;
    c->state = MBC_AUTH;
    c->id = 0;
    peer_credentials(c);
    c->deadline_ms = b->auth_timeout_ms > 0 ? mb_now_ms() + b->auth_timeout_ms : 0;
    return c;
}

/* Queue entries are reused instead of going back to malloc for every message. */
static mb_out *spare_outs;
static int nspare_outs;

static mb_out *out_new(void)
{
    mb_out *o = spare_outs;
    if (o) {
        spare_outs = o->next;
        nspare_outs--;
        memset(o, 0, sizeof *o);
        return o;
    }
    return calloc(1, sizeof *o);
}

static void out_free(mb_out *o)
{
    free(o->raw);
    if (o->msg) mb_msg_unref(o->msg);
    if (nspare_outs < 1024) {
        o->next = spare_outs;
        spare_outs = o;
        nspare_outs++;
        return;
    }
    free(o);
}

void mb_conn_free(mb_conn *c)
{
    if (!c) return;
    if (c->fd >= 0) close(c->fd);
    mb_buf_free(&c->rbuf);
    for (int i = 0; i < c->nfdq; i++) close(c->fdq[i]);
    free(c->fdq);
    while (c->outh) { mb_out *n = c->outh->next; out_free(c->outh); c->outh = n; }
    free(c->names);
    for (int i = 0; i < c->nrules; i++) mb_rule_free(&c->rules[i]);
    free(c->rules);
    free(c);
}

static bool enqueue(mb_conn *c, mb_out *o, size_t len)
{
    if (c->closing || c->state == MBC_DEAD) { out_free(o); return false; }
    if (c->outbytes > 0 && c->outbytes + len > MB_MAX_QUEUED) {
        /* a reader this far behind loses messages rather than the bus its memory;
         * one message always fits, however large */
        out_free(o);
        return false;
    }
    o->len = len;
    o->next = NULL;
    if (c->outt) c->outt->next = o; else c->outh = o;
    c->outt = o;
    c->outbytes += len;
    return true;
}

bool mb_conn_queue_raw(mb_conn *c, const void *d, size_t n)
{
    mb_out *o = out_new();
    if (!o) { c->closing = true; return false; }
    o->raw = malloc(n ? n : 1);
    if (!o->raw) { free(o); c->closing = true; return false; }
    memcpy(o->raw, d, n);
    return enqueue(c, o, n);
}

bool mb_conn_queue_msg(mb_conn *c, mb_msg *m)
{
    if (m->nfds && !c->fd_ok) return false;
    mb_out *o = out_new();
    if (!o) { c->closing = true; return false; }
    o->msg = mb_msg_ref(m);
    return enqueue(c, o, m->len);
}

bool mb_conn_wants_write(const mb_conn *c)
{
    return c->outh != NULL;
}

bool mb_conn_flush(mb_conn *c)
{
    while (c->outh) {
        mb_out *o = c->outh;
        const uint8_t *data = o->msg ? o->msg->data : o->raw;
        struct iovec iov[16];
        int niov = 0;
        size_t total = 0;
        iov[niov].iov_base = (void *)(data + o->off);
        iov[niov].iov_len = o->len - o->off;
        total += iov[niov].iov_len;
        niov++;

        struct msghdr mh;
        memset(&mh, 0, sizeof mh);
        union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int) * MB_MAX_UNIX_FDS)]; } ctl;
        bool with_fds = o->msg && o->msg->nfds > 0 && !o->fds_sent;
        if (with_fds) {
            /* descriptors ride on the first byte of their message */
            iov[0].iov_len = o->len - o->off;
            memset(&ctl, 0, sizeof ctl);
            mh.msg_control = ctl.buf;
            mh.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)o->msg->nfds);
            struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
            cm->cmsg_level = SOL_SOCKET;
            cm->cmsg_type = SCM_RIGHTS;
            cm->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)o->msg->nfds);
            memcpy(CMSG_DATA(cm), o->msg->fds, sizeof(int) * (size_t)o->msg->nfds);
        } else {
            /* gather following descriptor-free entries into one syscall */
            for (mb_out *n = o->next; n && niov < 16 && !(n->msg && n->msg->nfds); n = n->next) {
                iov[niov].iov_base = (void *)(n->msg ? n->msg->data : n->raw);
                iov[niov].iov_len = n->len;
                total += n->len;
                niov++;
            }
        }
        mh.msg_iov = iov;
        mh.msg_iovlen = (size_t)niov;
        ssize_t w = sendmsg(c->fd, &mh, MSG_NOSIGNAL);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return true;
            return false;
        }
        if (with_fds) o->fds_sent = true;
        size_t left = (size_t)w;
        while (left > 0 && c->outh) {
            mb_out *h = c->outh;
            size_t remain = h->len - h->off;
            if (left >= remain) {
                left -= remain;
                c->outbytes -= remain;
                c->outh = h->next;
                if (!c->outh) c->outt = NULL;
                out_free(h);
            } else {
                h->off += left;
                c->outbytes -= left;
                left = 0;
            }
        }
        if ((size_t)w < total) return true;
    }
    return true;
}

/* ------------------------------------------------------------------- SASL */

static int hexval(int ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

/* Decode hex into out; returns length or -1. */
static int unhex(const char *s, size_t n, char *out, size_t cap)
{
    if (n % 2 || n / 2 >= cap) return -1;
    for (size_t i = 0; i < n / 2; i++) {
        int h = hexval((unsigned char)s[2 * i]), l = hexval((unsigned char)s[2 * i + 1]);
        if (h < 0 || l < 0) return -1;
        out[i] = (char)(h * 16 + l);
    }
    out[n / 2] = 0;
    return (int)(n / 2);
}

static void say(mb_conn *c, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void say(mb_conn *c, const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) mb_conn_queue_raw(c, buf, (size_t)n);
}

static void reject(mb_conn *c)
{
    c->auth_external_wait = false;
    if (++c->auth_failures > MAX_AUTH_FAILURES) { c->closing = true; return; }
    c->state = MBC_AUTH;
    say(c, "REJECTED EXTERNAL\r\n");
}

static void auth_ok(mb_conn *c)
{
    c->state = MBC_AUTH_OK;
    c->auth_external_wait = false;
    say(c, "OK %s\r\n", mb_bus_id(c->bus));
}

static bool external_identity_ok(mb_conn *c, const char *id, int idlen)
{
    if (idlen == 0) return c->have_uid;
    /* the claimed identity is a decimal uid; it must be the one the kernel saw,
     * or the peer is root (which may claim any identity) */
    char *end;
    unsigned long v = strtoul(id, &end, 10);
    if (*end || end == id) return false;
    if (!c->have_uid) return false;
    if (v != c->uid && c->uid != 0) return false;
    c->uid = (uint32_t)v;
    return true;
}

/* The session bus belongs to one user; the system bus is open to all. */
static bool admitted(mb_conn *c)
{
    if (c->bus->system || c->uid == c->bus->my_uid || c->uid == 0) return true;
    mb_log(0, "rejected uid %u on the session bus of uid %u", c->uid, c->bus->my_uid);
    return false;
}

/* Check a hex identity and finish the EXTERNAL exchange. */
static void external_response(mb_conn *c, const char *hex)
{
    char id[64];
    size_t hl = strlen(hex);
    for (size_t i = 0; i < hl; i++)
        if (hexval((unsigned char)hex[i]) < 0) { say(c, "ERROR \"Invalid hex encoding\"\r\n"); return; }
    int idl = unhex(hex, hl, id, sizeof id);
    if (idl < 0 || !external_identity_ok(c, id, idl) || !admitted(c)) { reject(c); return; }
    auth_ok(c);
}

static void auth_line(mb_conn *c, char *line, size_t n)
{
    if (memchr(line, 0, n)) { say(c, "ERROR \"Command contained non-ASCII\"\r\n"); return; }
    line[n] = 0;
    char *cmd = line, *arg = NULL;
    char *sp = strchr(line, ' ');
    if (sp) { *sp = 0; arg = sp + 1; }
    bool expecting_begin = c->state == MBC_AUTH_OK;

    if (strcmp(cmd, "AUTH") == 0) {
        if (expecting_begin) { say(c, "ERROR \"Sent AUTH while expecting BEGIN\"\r\n"); return; }
        if (c->auth_external_wait) { say(c, "ERROR \"Sent AUTH while another AUTH in progress\"\r\n"); return; }
        if (!arg || !*arg) { reject(c); return; }
        char *mech = arg, *resp = NULL;
        char *s2 = strchr(arg, ' ');
        if (s2) { *s2 = 0; resp = s2 + 1; }
        if (strcmp(mech, "EXTERNAL") != 0) { reject(c); return; }
        if (!resp) { c->auth_external_wait = true; say(c, "DATA\r\n"); return; }
        external_response(c, resp);
        return;
    }
    if (strcmp(cmd, "DATA") == 0) {
        if (expecting_begin) { say(c, "ERROR \"Sent DATA while expecting BEGIN\"\r\n"); return; }
        if (!c->auth_external_wait) { say(c, "ERROR \"Not currently in an auth conversation\"\r\n"); return; }
        c->auth_external_wait = false;
        external_response(c, arg ? arg : "");
        return;
    }
    if (strcmp(cmd, "CANCEL") == 0) {
        if (!expecting_begin && !c->auth_external_wait) {
            say(c, "ERROR \"Not currently in an auth conversation\"\r\n");
            return;
        }
        reject(c);
        return;
    }
    if (strcmp(cmd, "ERROR") == 0) { reject(c); return; }
    if (strcmp(cmd, "BEGIN") == 0) {
        /* a client that begins without being authenticated has lost track of the protocol */
        if (!expecting_begin) { c->closing = true; return; }
        c->state = MBC_HELLO;
        c->deadline_ms = c->bus->auth_timeout_ms > 0 ? mb_now_ms() + c->bus->auth_timeout_ms : 0;
        return;
    }
    if (strcmp(cmd, "NEGOTIATE_UNIX_FD") == 0) {
        if (!expecting_begin) { say(c, "ERROR \"Need to authenticate first\"\r\n"); return; }
        c->fd_ok = true;
        say(c, "AGREE_UNIX_FD\r\n");
        return;
    }
    say(c, "ERROR \"Unknown command\"\r\n");
}

/* ----------------------------------------------------------------- reading */

static bool fdq_push(mb_conn *c, int fd)
{
    if (c->nfdq >= MAX_FDQ) return false;
    if (c->nfdq == c->capfdq) {
        int ncap = c->capfdq ? c->capfdq * 2 : 16;
        int *n = realloc(c->fdq, sizeof(int) * (size_t)ncap);
        if (!n) return false;
        c->fdq = n; c->capfdq = ncap;
    }
    c->fdq[c->nfdq++] = fd;
    return true;
}

/* Handle the n bytes at p. Returns how many were used, or -1 to close. */
static long process(mb_conn *c, const uint8_t *p, size_t n)
{
    size_t off = 0;
    for (;;) {
        if (c->closing) return -1;
        if (c->state == MBC_DEAD) return (long)off;
        if (c->state == MBC_AUTH || c->state == MBC_AUTH_OK) {
            if (!c->sent_nul) {
                if (off == n) return (long)off;
                if (p[off] != 0) return -1;
                c->sent_nul = true;
                off++;
            }
            size_t i = off;
            bool found = false;
            for (; i + 1 < n; i++)
                if (p[i] == '\r' && p[i + 1] == '\n') { found = true; break; }
            if (!found) return n - off > MB_MAX_AUTH_LINE ? -1 : (long)off;
            size_t llen = i - off;
            if (llen > MB_MAX_AUTH_LINE) return -1;
            char line[MB_MAX_AUTH_LINE + 1];
            memcpy(line, p + off, llen);
            off = i + 2;
            auth_line(c, line, llen);
            continue;
        }
        /* message mode */
        size_t total;
        mb_parse_result pr = mb_msg_peek(p + off, n - off, &total);
        if (pr == MB_PARSE_INVALID) {
            mb_log(0, "dropping %s (uid %u): invalid message header",
                   c->unique[0] ? c->unique : "unregistered connection", c->uid);
            return -1;
        }
        if (pr == MB_PARSE_NEED_MORE || n - off < total) {
            c->need = pr == MB_PARSE_NEED_MORE ? 0 : total;
            return (long)off;
        }
        mb_msg m;
        const char *why = NULL;
        if (mb_msg_view(p + off, total, &m, &why) != MB_PARSE_OK) {
            mb_log(0, "dropping %s (uid %u): invalid message: %s",
                   c->unique[0] ? c->unique : "unregistered connection", c->uid, why ? why : "?");
            return -1;
        }
        off += total;
        c->need = 0;
        if (m.unix_fds) {
            if (!c->fd_ok || (int)m.unix_fds > c->nfdq || m.unix_fds > MB_MAX_MSG_FDS) return -1;
            m.fds = malloc(sizeof(int) * m.unix_fds);
            if (!m.fds) return -1;
            memcpy(m.fds, c->fdq, sizeof(int) * m.unix_fds);
            m.nfds = (int)m.unix_fds;
            memmove(c->fdq, c->fdq + m.unix_fds, sizeof(int) * (size_t)(c->nfdq - (int)m.unix_fds));
            c->nfdq -= (int)m.unix_fds;
        }
        mb_bus_conn_message(c->bus, c, &m);
        /* descriptors that were not passed on with a routed copy are closed here */
        for (int k = 0; k < m.nfds; k++) close(m.fds[k]);
        free(m.fds);
    }
}

bool mb_conn_read(mb_conn *c)
{
    /* An idle connection keeps no read buffer: data is read into one shared
     * buffer and only an unfinished message is kept per connection. */
    static uint8_t shared[READ_CHUNK];
    uint8_t *dst;
    size_t room;
    bool direct = c->rbuf.len == 0;
    if (direct) {
        dst = shared;
        room = sizeof shared;
    } else {
        size_t want = c->need > c->rbuf.len ? c->need - c->rbuf.len : READ_CHUNK;
        if (want < READ_CHUNK) want = READ_CHUNK;
        if (!mb_buf_reserve(&c->rbuf, want)) return false;
        dst = c->rbuf.p + c->rbuf.len;
        room = want;
    }
    struct iovec iov = { dst, room };
    struct msghdr mh;
    memset(&mh, 0, sizeof mh);
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int) * MB_MAX_UNIX_FDS)]; } ctl;
    mh.msg_iov = &iov;
    mh.msg_iovlen = 1;
    mh.msg_control = ctl.buf;
    mh.msg_controllen = sizeof ctl.buf;
    int flags = 0;
#ifdef MSG_CMSG_CLOEXEC
    flags |= MSG_CMSG_CLOEXEC;
#endif
    ssize_t r = recvmsg(c->fd, &mh, flags);
    if (r < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return true;
        return false;
    }
    bool ok = true;
    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&mh); cm; cm = CMSG_NXTHDR(&mh, cm)) {
        if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS) continue;
        size_t nfd = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < nfd; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(cm) + i * sizeof(int), sizeof fd);
#ifndef MSG_CMSG_CLOEXEC
            fcntl(fd, F_SETFD, FD_CLOEXEC);
#endif
            if (!c->fd_ok || !fdq_push(c, fd)) { close(fd); ok = false; }
        }
    }
    if (mh.msg_flags & MSG_CTRUNC) ok = false;
    if (r == 0 || !ok) return false;

    if (direct) {
        long used = process(c, shared, (size_t)r);
        if (used < 0) return false;
        /* keep what belongs to a message that is still arriving */
        if ((size_t)used < (size_t)r) {
            size_t rest = (size_t)r - (size_t)used;
            if (!mb_buf_reserve(&c->rbuf, c->need > rest ? c->need : rest)) return false;
            mb_buf_append(&c->rbuf, shared + used, rest);
        }
        return true;
    }
    c->rbuf.len += (size_t)r;
    long used = process(c, c->rbuf.p, c->rbuf.len);
    if (used < 0) return false;
    mb_buf_consume(&c->rbuf, (size_t)used);
    if (c->rbuf.len == 0) mb_buf_free(&c->rbuf);
    return true;
}

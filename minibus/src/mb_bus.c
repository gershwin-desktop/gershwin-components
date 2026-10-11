/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "mb_int.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DBUS_NAME "org.freedesktop.DBus"
#define DBUS_PATH "/org/freedesktop/DBus"

enum { REQ_PRIMARY = 1, REQ_QUEUE = 2, REQ_EXISTS = 3, REQ_ALREADY = 4 };
enum { FLAG_ALLOW_REPLACE = 1, FLAG_REPLACE = 2, FLAG_DO_NOT_QUEUE = 4 };

uint32_t mb_bus_next_serial(void)
{
    static uint32_t serial = 0;
    if (++serial == 0) serial = 1;
    return serial;
}

/* ------------------------------------------------------------- hash tables */

static unsigned hash_str(const char *s)
{
    unsigned h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h;
}

mb_name *mb_bus_find_name(mb_bus *b, const char *name)
{
    for (mb_name *n = b->names[hash_str(name) % MB_NAME_BUCKETS]; n; n = n->hnext)
        if (strcmp(n->name, name) == 0) return n;
    return NULL;
}

static mb_name *name_get(mb_bus *b, const char *name)
{
    mb_name *n = mb_bus_find_name(b, name);
    if (n) return n;
    n = calloc(1, sizeof *n);
    if (!n) return NULL;
    n->name = strdup(name);
    if (!n->name) { free(n); return NULL; }
    unsigned h = hash_str(name) % MB_NAME_BUCKETS;
    n->hnext = b->names[h];
    b->names[h] = n;
    return n;
}

static void name_delete(mb_bus *b, mb_name *n)
{
    mb_name **pp = &b->names[hash_str(n->name) % MB_NAME_BUCKETS];
    while (*pp && *pp != n) pp = &(*pp)->hnext;
    if (*pp) *pp = n->hnext;
    free(n->owners);
    free(n->name);
    free(n);
}

mb_conn *mb_bus_find_unique(mb_bus *b, const char *name)
{
    if (strncmp(name, ":1.", 3) != 0) return NULL;
    char *end;
    unsigned long long id = strtoull(name + 3, &end, 10);
    if (*end || end == name + 3) return NULL;
    for (mb_conn *c = b->by_id[id % MB_CONN_BUCKETS]; c; c = c->hnext)
        if (c->id == id && strcmp(c->unique, name) == 0) return c;
    return NULL;
}

mb_conn *mb_bus_find_owner(mb_bus *b, const char *name)
{
    mb_name *n = mb_bus_find_name(b, name);
    return n && n->nowners ? n->owners[0].conn : NULL;
}

bool mb_conn_owns_name(const mb_conn *c, const char *name)
{
    mb_name *n = mb_bus_find_name(c->bus, name);
    return n && n->nowners && n->owners[0].conn == c;
}

/* ----------------------------------------------------------- pending replies */

static unsigned reply_bucket(uint64_t caller, uint32_t serial)
{
    return (unsigned)((caller * 31u + serial) % MB_REPLY_BUCKETS);
}

static bool reply_add(mb_bus *b, mb_conn *caller, mb_conn *callee, uint32_t serial)
{
    mb_reply *r = calloc(1, sizeof *r);
    if (!r) return false;
    r->caller = caller->id; r->callee = callee->id; r->serial = serial;
    unsigned h = reply_bucket(r->caller, serial);
    r->next = b->replies[h];
    b->replies[h] = r;
    callee->npending++;
    return true;
}

/* Remove the entry for a reply from callee to caller. */
static bool reply_take(mb_bus *b, mb_conn *callee, mb_conn *caller, uint32_t serial)
{
    mb_reply **pp = &b->replies[reply_bucket(caller->id, serial)];
    while (*pp) {
        mb_reply *r = *pp;
        if (r->caller == caller->id && r->callee == callee->id && r->serial == serial) {
            *pp = r->next;
            free(r);
            callee->npending--;
            return true;
        }
        pp = &r->next;
    }
    return false;
}

static mb_conn *conn_by_id(mb_bus *b, uint64_t id)
{
    for (mb_conn *c = b->by_id[id % MB_CONN_BUCKETS]; c; c = c->hnext)
        if (c->id == id) return c;
    return NULL;
}

/* ------------------------------------------------------------------ sending */

static void send_to(mb_conn *c, mb_msg *m)
{
    if (c->state == MBC_DEAD || c->closing) return;
    mb_conn_queue_msg(c, m);
}

static mb_msg *build_bus_msg(uint8_t type, uint32_t reply_serial, bool has_reply, const char *dest,
                             const char *iface, const char *member, const char *errname,
                             const char *sig, const uint8_t *body, size_t blen)
{
    mb_msg_spec s;
    memset(&s, 0, sizeof s);
    s.type = type;
    s.flags = MB_FLAG_NO_REPLY;
    s.serial = mb_bus_next_serial();
    s.reply_serial = reply_serial;
    s.has_reply_serial = has_reply;
    s.destination = dest;
    s.sender = DBUS_NAME;
    s.interface = iface;
    s.member = member;
    s.error_name = errname;
    if (type == MB_SIGNAL) s.path = DBUS_PATH;
    s.signature = sig;
    s.body = body;
    s.body_len = blen;
    return mb_msg_build(&s);
}

void mb_bus_send_signal(mb_bus *b, const char *dest, const char *iface, const char *member,
                        const char *sig, const uint8_t *body, size_t blen)
{
    mb_msg *m = build_bus_msg(MB_SIGNAL, 0, false, dest, iface, member, NULL, sig, body, blen);
    if (!m) return;
    mb_bus_route(b, m, NULL);
    mb_msg_unref(m);
}

void mb_bus_send_error(mb_bus *b, mb_msg *call, const char *errname, const char *fmt, ...)
{
    if (!call->sender) return;
    char text[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    mb_w w;
    mb_w_init(&w, false);
    mb_w_str(&w, text);
    mb_msg *m = build_bus_msg(MB_ERROR, call->serial, true, call->sender, NULL, NULL, errname,
                              "s", w.b.p, w.b.len);
    mb_w_free(&w);
    if (!m) return;
    mb_bus_route(b, m, NULL);
    mb_msg_unref(m);
}

static void name_owner_changed(mb_bus *b, const char *name, const char *old, const char *new)
{
    if (name[0] != ':') mb_log(1, "name %s: owner '%s' -> '%s'", name, old, new);
    mb_w w;
    mb_w_init(&w, false);
    mb_w_str(&w, name);
    mb_w_str(&w, old);
    mb_w_str(&w, new);
    mb_bus_send_signal(b, NULL, DBUS_NAME, "NameOwnerChanged", "sss", w.b.p, w.b.len);
    mb_w_free(&w);
}

static void name_signal(mb_bus *b, const char *member, mb_conn *to, const char *name)
{
    mb_w w;
    mb_w_init(&w, false);
    mb_w_str(&w, name);
    mb_bus_send_signal(b, to->unique, DBUS_NAME, member, "s", w.b.p, w.b.len);
    mb_w_free(&w);
}

/* ------------------------------------------------------------------ routing */

static void to_monitors(mb_bus *b, mb_msg *m, mb_conn *from, const char *recipient)
{
    for (int i = 0; i < b->nconns; i++) {
        mb_conn *c = b->conns[i];
        if (c->state != MBC_MONITOR || c->closing) continue;
        bool match = c->nrules == 0;
        for (int r = 0; r < c->nrules && !match; r++)
            match = mb_rule_matches(&c->rules[r], m, from, recipient);
        if (match) send_to(c, m);
    }
}

static void broadcast(mb_bus *b, mb_msg *m, mb_conn *from)
{
    for (int i = 0; i < b->nconns; i++) {
        mb_conn *c = b->conns[i];
        if (c->state != MBC_ACTIVE || c->closing) continue;
        if (m->nfds && !c->fd_ok) continue;
        for (int r = 0; r < c->nrules; r++) {
            if (mb_rule_matches(&c->rules[r], m, from, c->unique)) {
                send_to(c, m);
                break;
            }
        }
    }
}

void mb_bus_route(mb_bus *b, mb_msg *m, mb_conn *from)
{
    if (m->type > MB_SIGNAL) return;

    mb_conn *to = NULL;
    bool to_driver = false;
    if (m->destination) {
        if (strcmp(m->destination, DBUS_NAME) == 0) to_driver = true;
        else if (mb_is_unique_name(m->destination)) to = mb_bus_find_unique(b, m->destination);
        else to = mb_bus_find_owner(b, m->destination);
        if (to && to->state != MBC_ACTIVE) to = NULL;
    }
    to_monitors(b, m, from, to ? to->unique : (to_driver ? DBUS_NAME : NULL));

    if (!m->destination) {
        if (m->type == MB_SIGNAL) broadcast(b, m, from);
        return;
    }
    if (to_driver) {
        if (m->type == MB_METHOD_CALL && from) mb_driver_handle(b, from, m);
        return;
    }
    if (!to) {
        mb_log(1, "no recipient %s for a message from %s", m->destination, from ? from->unique : "the bus");
        if ((m->type == MB_METHOD_CALL || m->type == MB_SIGNAL) && from)
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.ServiceUnknown",
                              "The name %s was not provided by any .service files", m->destination);
        return;
    }
    if (m->nfds && !to->fd_ok) {
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.NotSupported",
                          "Tried to send message with Unix file descriptors to a client that "
                          "doesn't support that.");
        return;
    }
    if (from) {
        if (m->type == MB_METHOD_CALL && !(m->flags & MB_FLAG_NO_REPLY)) {
            if (to->npending >= 1024 * 8) {
                mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.LimitsExceeded",
                                  "The maximum number of pending replies per connection has been reached");
                return;
            }
            if (!reply_add(b, from, to, m->serial)) return;
        } else if (m->type == MB_METHOD_RETURN || m->type == MB_ERROR) {
            /* only answers to calls that expect one are passed on */
            if (!reply_take(b, from, to, m->reply_serial)) return;
        }
    }
    if (to->state == MBC_DEAD || to->closing) return;
    if (!mb_conn_queue_msg(to, m) && from && m->type == MB_METHOD_CALL) {
        if (!(m->flags & MB_FLAG_NO_REPLY)) reply_take(b, to, from, m->serial);
        mb_log(1, "%s is not reading; a call from %s was dropped", to->unique, from->unique);
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.LimitsExceeded",
                          "The maximum number of bytes queued for %s has been reached", to->unique);
    }
}

static void conn_hash_add(mb_bus *b, mb_conn *c)
{
    unsigned h = (unsigned)(c->id % MB_CONN_BUCKETS);
    c->hnext = b->by_id[h];
    b->by_id[h] = c;
}

static void conn_hash_remove(mb_bus *b, mb_conn *c)
{
    mb_conn **pp = &b->by_id[c->id % MB_CONN_BUCKETS];
    while (*pp && *pp != c) pp = &(*pp)->hnext;
    if (*pp) *pp = c->hnext;
}

bool mb_bus_hello(mb_bus *b, mb_conn *c, mb_msg *call)
{
    c->id = b->next_id++;
    snprintf(c->unique, sizeof c->unique, ":1.%llu", (unsigned long long)c->id);
    mb_log(1, "%s connected (uid %u pid %u)", c->unique, c->uid, c->pid);
    c->state = MBC_ACTIVE;
    c->deadline_ms = 0;
    conn_hash_add(b, c);

    mb_w w;
    mb_w_init(&w, false);
    mb_w_str(&w, c->unique);
    mb_msg *r = build_bus_msg(MB_METHOD_RETURN, call->serial, true, c->unique, NULL, NULL, NULL,
                              "s", w.b.p, w.b.len);
    mb_w_free(&w);
    if (!r) return false;
    if (!(call->flags & MB_FLAG_NO_REPLY)) mb_bus_route(b, r, NULL);
    mb_msg_unref(r);
    name_owner_changed(b, c->unique, "", c->unique);
    name_signal(b, "NameAcquired", c, c->unique);
    return true;
}

/* An error for a connection that has no unique name yet, so it cannot be routed. */
static void pre_hello_error(mb_conn *c, mb_msg *call, const char *errname, const char *text)
{
    if (call->flags & MB_FLAG_NO_REPLY) return;
    mb_w w;
    mb_w_init(&w, false);
    mb_w_str(&w, text);
    mb_msg *e = build_bus_msg(MB_ERROR, call->serial, true, NULL, NULL, NULL, errname, "s", w.b.p, w.b.len);
    mb_w_free(&w);
    if (e) { mb_conn_queue_msg(c, e); mb_msg_unref(e); }
}

void mb_bus_conn_message(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (c->state == MBC_HELLO) {
        bool to_bus = m->type == MB_METHOD_CALL && m->destination &&
                      strcmp(m->destination, DBUS_NAME) == 0;
        if (!to_bus) { c->closing = true; return; }
        bool is_hello = strcmp(m->member, "Hello") == 0 &&
                        (!m->interface || strcmp(m->interface, DBUS_NAME) == 0);
        if (is_hello && (!m->signature || !m->signature[0])) {
            if (!mb_bus_hello(b, c, m)) c->closing = true;
            return;
        }
        /* answered, as the reference daemon does, so a client learns why */
        pre_hello_error(c, m, is_hello ? "org.freedesktop.DBus.Error.InvalidArgs"
                                       : "org.freedesktop.DBus.Error.AccessDenied",
                        is_hello ? "Hello takes no arguments"
                                 : "Client tried to send a message other than Hello without being registered");
        return;
    }
    if (c->state == MBC_MONITOR) {
        /* monitors only listen (spec: "Monitoring") */
        mb_log(0, "dropping monitor %s: monitors may not send messages", c->unique);
        c->closing = true;
        return;
    }
    if (c->state != MBC_ACTIVE) { c->closing = true; return; }
    if (m->type > MB_SIGNAL) return;
    mb_msg *s = mb_msg_with_sender(m, c->unique, false);
    if (!s) { c->closing = true; return; }
    mb_bus_route(b, s, c);
    mb_msg_unref(s);
}

/* -------------------------------------------------------------------- names */

static bool conn_track(mb_conn *c, mb_name *n)
{
    for (int i = 0; i < c->nnames; i++) if (c->names[i] == n) return true;
    if (c->nnames == c->capnames) {
        int ncap = c->capnames ? c->capnames * 2 : 8;
        mb_name **p = realloc(c->names, sizeof *p * (size_t)ncap);
        if (!p) return false;
        c->names = p; c->capnames = ncap;
    }
    c->names[c->nnames++] = n;
    return true;
}

static void conn_untrack(mb_conn *c, mb_name *n)
{
    /* order kept: names are released in reverse order of acquisition */
    for (int i = 0; i < c->nnames; i++)
        if (c->names[i] == n) {
            memmove(c->names + i, c->names + i + 1, sizeof *c->names * (size_t)(c->nnames - i - 1));
            c->nnames--;
            return;
        }
}

static int owner_index(mb_name *n, mb_conn *c)
{
    for (int i = 0; i < n->nowners; i++) if (n->owners[i].conn == c) return i;
    return -1;
}

static bool owners_insert(mb_name *n, int at, mb_owner o)
{
    if (n->nowners == n->capowners) {
        int ncap = n->capowners ? n->capowners * 2 : 2;
        mb_owner *p = realloc(n->owners, sizeof *p * (size_t)ncap);
        if (!p) return false;
        n->owners = p; n->capowners = ncap;
    }
    memmove(n->owners + at + 1, n->owners + at, sizeof(mb_owner) * (size_t)(n->nowners - at));
    n->owners[at] = o;
    n->nowners++;
    return true;
}

static void owners_remove(mb_name *n, int at)
{
    memmove(n->owners + at, n->owners + at + 1, sizeof(mb_owner) * (size_t)(n->nowners - at - 1));
    n->nowners--;
}

unsigned mb_bus_request_name(mb_bus *b, mb_conn *c, const char *name, uint32_t flags)
{
    mb_name *n = name_get(b, name);
    if (!n) return 0;
    mb_owner me = { c, (flags & FLAG_ALLOW_REPLACE) != 0, (flags & FLAG_DO_NOT_QUEUE) != 0 };
    int idx = owner_index(n, c);

    if (n->nowners == 0) {
        if (!owners_insert(n, 0, me) || !conn_track(c, n)) { if (!n->nowners) name_delete(b, n); return 0; }
        name_owner_changed(b, name, "", c->unique);
        name_signal(b, "NameAcquired", c, name);
        return REQ_PRIMARY;
    }
    if (idx == 0) {
        n->owners[0].allow_replace = me.allow_replace;
        return REQ_ALREADY;
    }
    mb_owner *prim = &n->owners[0];
    if ((flags & FLAG_REPLACE) && prim->allow_replace) {
        mb_conn *old = prim->conn;
        bool old_queues = !prim->do_not_queue;
        if (idx > 0) owners_remove(n, idx);
        if (old_queues) {
            mb_owner oo = n->owners[0];
            n->owners[0] = me;
            if (!owners_insert(n, 1, oo)) return 0;
        } else {
            conn_untrack(old, n);
            n->owners[0] = me;
        }
        conn_track(c, n);
        name_owner_changed(b, name, old->unique, c->unique);
        name_signal(b, "NameLost", old, name);
        name_signal(b, "NameAcquired", c, name);
        return REQ_PRIMARY;
    }
    if (flags & FLAG_DO_NOT_QUEUE) {
        if (idx > 0) { owners_remove(n, idx); conn_untrack(c, n); }
        return REQ_EXISTS;
    }
    if (idx > 0) { n->owners[idx] = me; return REQ_QUEUE; }
    if (!owners_insert(n, n->nowners, me) || !conn_track(c, n)) return 0;
    return REQ_QUEUE;
}

/* Remove c from the owner list of n; announce the change. */
static void drop_owner(mb_bus *b, mb_name *n, mb_conn *c, bool send_lost)
{
    int idx = owner_index(n, c);
    if (idx < 0) return;
    char *name = strdup(n->name);
    if (!name) return;
    owners_remove(n, idx);
    conn_untrack(c, n);
    if (idx == 0) {
        if (n->nowners) {
            mb_conn *next = n->owners[0].conn;
            name_owner_changed(b, name, c->unique, next->unique);
            if (send_lost) name_signal(b, "NameLost", c, name);
            name_signal(b, "NameAcquired", next, name);
        } else {
            name_owner_changed(b, name, c->unique, "");
            if (send_lost) name_signal(b, "NameLost", c, name);
            name_delete(b, n);
        }
    }
    free(name);
}

unsigned mb_bus_release_name(mb_bus *b, mb_conn *c, const char *name)
{
    mb_name *n = mb_bus_find_name(b, name);
    if (!n) return 2;
    if (owner_index(n, c) < 0) return 3;
    drop_owner(b, n, c, true);
    return 1;
}

void mb_bus_release_all_names(mb_bus *b, mb_conn *c)
{
    while (c->nnames > 0) {
        mb_name *n = c->names[c->nnames - 1];
        /* a connection that is going away is not told about it */
        drop_owner(b, n, c, false);
    }
}

void mb_bus_monitor_lost_name(mb_bus *b, mb_conn *c)
{
    name_signal(b, "NameLost", c, c->unique);
    name_owner_changed(b, c->unique, c->unique, "");
}

void mb_bus_drop_rules(mb_conn *c)
{
    for (int i = 0; i < c->nrules; i++) mb_rule_free(&c->rules[i]);
    c->nrules = 0;
}

void mb_bus_conn_closed(mb_bus *b, mb_conn *c)
{
    bool announced = c->id != 0 || c->unique[0];
    /* a monitor already announced the loss of its name when it became one */
    bool was_monitor = c->state == MBC_MONITOR;
    c->state = MBC_DEAD;
    if (announced) conn_hash_remove(b, c);

    /* callers waiting for this peer get told it is gone */
    for (int h = 0; h < MB_REPLY_BUCKETS; h++) {
        mb_reply **pp = &b->replies[h];
        while (*pp) {
            mb_reply *r = *pp;
            if (r->callee == c->id && announced) {
                mb_conn *caller = conn_by_id(b, r->caller);
                *pp = r->next;
                if (caller && caller->state == MBC_ACTIVE) {
                    mb_w w;
                    mb_w_init(&w, false);
                    mb_w_str(&w, "Message recipient disconnected from message bus without replying");
                    mb_msg *e = build_bus_msg(MB_ERROR, r->serial, true, caller->unique, NULL, NULL,
                                              "org.freedesktop.DBus.Error.NoReply", "s", w.b.p, w.b.len);
                    mb_w_free(&w);
                    if (e) { mb_bus_route(b, e, NULL); mb_msg_unref(e); }
                }
                free(r);
                continue;
            }
            if (r->caller == c->id && announced) {
                mb_conn *callee = conn_by_id(b, r->callee);
                if (callee) callee->npending--;
                *pp = r->next;
                free(r);
                continue;
            }
            pp = &r->next;
        }
    }
    mb_bus_release_all_names(b, c);
    mb_bus_drop_rules(c);
    if (announced && !was_monitor) {
        name_owner_changed(b, c->unique, c->unique, "");
        mb_log(1, "%s disconnected", c->unique);
    }
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Internal structures shared by the bus implementation files. */

#ifndef MB_INT_H
#define MB_INT_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "mb.h"

#include <sys/types.h>

typedef enum {
    MBC_AUTH,        /* SASL in progress */
    MBC_AUTH_OK,     /* OK sent, waiting for BEGIN */
    MBC_HELLO,       /* authenticated, waiting for Hello */
    MBC_ACTIVE,
    MBC_MONITOR,
    MBC_DEAD
} mb_conn_state;

/* A parsed match rule (spec: "Match Rules"). */
typedef struct {
    int idx;          /* argN */
    int kind;         /* 0 exact, 1 path, 2 namespace */
    char *val;
} mb_match_arg;

typedef struct mb_rule {
    int type;         /* 0 any, else MB_* */
    char *sender, *interface, *member, *path, *path_ns, *destination;
    mb_match_arg *args;
    int nargs;
    bool eavesdrop;
} mb_rule;

typedef struct mb_out {
    uint8_t *raw;       /* raw bytes (auth replies), or NULL */
    mb_msg *msg;        /* message, or NULL */
    size_t len, off;
    bool fds_sent;
    struct mb_out *next;
} mb_out;

typedef struct mb_name mb_name;

struct mb_conn {
    mb_bus *bus;
    int fd;
    uint64_t id;
    char unique[40];
    mb_conn_state state;
    bool have_uid, have_pid, fd_ok, closing;
    uint32_t uid, pid;
    mb_buf rbuf;          /* only an unfinished message */
    size_t need;          /* its full size, when known */
    int *fdq; int nfdq, capfdq;
    mb_out *outh, *outt;
    size_t outbytes;
    mb_name **names; int nnames, capnames;
    mb_rule *rules; int nrules, caprules;
    int npending;
    int64_t deadline_ms;       /* auth deadline, 0 when none */
    bool sent_nul;
    char auth_user_hex[64];
    bool auth_external_wait;
    int auth_failures;
    mb_conn *hnext;
};

/* One owner-queue entry. */
typedef struct { mb_conn *conn; bool allow_replace; bool do_not_queue; } mb_owner;

struct mb_name {
    char *name;
    mb_owner *owners;  /* [0] is the primary owner */
    int nowners, capowners;
    mb_name *hnext;
};

typedef struct mb_reply {
    uint64_t caller, callee;
    uint32_t serial;
    struct mb_reply *next;
} mb_reply;

#define MB_NAME_BUCKETS 1024
#define MB_CONN_BUCKETS 1024
#define MB_REPLY_BUCKETS 4096

typedef struct { int fd; char *path; bool is_abstract; } mb_listener;

struct mb_bus {
    char guid[33];
    mb_listener *listeners; int nlisteners;
    mb_conn **conns; int nconns, capconns;
    mb_conn *by_id[MB_CONN_BUCKETS];
    mb_name *names[MB_NAME_BUCKETS];
    mb_reply *replies[MB_REPLY_BUCKETS];
    uint64_t next_id;
    bool running;
    int max_conn, max_incomplete, auth_timeout_ms;
    int wakefd[2];
    uint32_t my_uid, my_pid;
    /* Who may do what. The session bus admits only its owner; the system bus
     * admits everyone and limits name ownership to root, daemon accounts and
     * an optional group, so a user cannot pose as a system service. */
    bool system;
    uint32_t sys_uid_max;
    bool have_owner_gid;
    gid_t owner_gid;
    mb_buf scratch;
};

/* mb_conn.c */
mb_conn *mb_conn_new(mb_bus *b, int fd);
void mb_conn_free(mb_conn *c);
/* Read what is available. Returns false when the connection must be closed. */
bool mb_conn_read(mb_conn *c);
/* Write queued data. Returns false when the connection must be closed. */
bool mb_conn_flush(mb_conn *c);
bool mb_conn_queue_msg(mb_conn *c, mb_msg *m);
bool mb_conn_queue_raw(mb_conn *c, const void *d, size_t n);
bool mb_conn_wants_write(const mb_conn *c);
int64_t mb_now_ms(void);

/* mb_match.c */
bool mb_rule_parse(const char *text, mb_rule *out, const char **errname, const char **errmsg);
void mb_rule_free(mb_rule *r);
bool mb_rule_equal(const mb_rule *a, const mb_rule *b);
/* sender_conn may be NULL for messages from the bus driver. */
bool mb_rule_matches(const mb_rule *r, const mb_msg *m, const mb_conn *sender_conn,
                     const char *recipient_unique);

/* mb_bus.c */
void mb_bus_conn_message(mb_bus *b, mb_conn *c, mb_msg *m);
void mb_bus_conn_closed(mb_bus *b, mb_conn *c);
mb_conn *mb_bus_find_unique(mb_bus *b, const char *name);
mb_conn *mb_bus_find_owner(mb_bus *b, const char *name);
mb_name *mb_bus_find_name(mb_bus *b, const char *name);
void mb_bus_route(mb_bus *b, mb_msg *m, mb_conn *from);
void mb_bus_send_error(mb_bus *b, mb_msg *call, const char *errname, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
void mb_bus_send_signal(mb_bus *b, const char *dest, const char *iface, const char *member,
                        const char *sig, const uint8_t *body, size_t blen);
/* Hello handling: assign the unique name and announce. */
bool mb_bus_hello(mb_bus *b, mb_conn *c, mb_msg *call);
void mb_bus_release_all_names(mb_bus *b, mb_conn *c);
void mb_bus_monitor_lost_name(mb_bus *b, mb_conn *c);
void mb_bus_drop_rules(mb_conn *c);
bool mb_conn_owns_name(const mb_conn *c, const char *name);
unsigned mb_bus_request_name(mb_bus *b, mb_conn *c, const char *name, uint32_t flags);
unsigned mb_bus_release_name(mb_bus *b, mb_conn *c, const char *name);
uint32_t mb_bus_next_serial(void);

/* mb_driver.c */
bool mb_may_own_names(mb_bus *b, const mb_conn *c);
bool mb_may_monitor(mb_bus *b, const mb_conn *c);

void mb_driver_handle(mb_bus *b, mb_conn *c, mb_msg *m);
bool mb_read_machine_id(char out[33]);

#endif

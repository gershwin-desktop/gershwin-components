/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Independent D-Bus wire client for the minibus conformance tests. It
 * shares no code with the daemon on purpose. */

#ifndef MBT_WIRE_H
#define MBT_WIRE_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

#define WIRE_MAXFDS 64

#define W_CALL   1
#define W_RETURN 2
#define W_ERROR  3
#define W_SIGNAL 4

#define W_F_NOREPLY 0x1
#define W_F_NOAUTOSTART 0x2
#define W_F_ALLOWINTERACT 0x4

/* header field codes */
#define WF_PATH 1
#define WF_IFACE 2
#define WF_MEMBER 3
#define WF_ERRNAME 4
#define WF_REPLYSERIAL 5
#define WF_DEST 6
#define WF_SENDER 7
#define WF_SIG 8
#define WF_UNIXFDS 9

typedef struct { uint8_t *d; size_t len, cap; } wbuf;

void wbuf_free (wbuf *b);
void wbuf_put (wbuf *b, const void *p, size_t n);
void wbuf_pad (wbuf *b, size_t align);          /* zero pad to align */

typedef struct wmsg {
  int endian;                 /* 'l' or 'B' */
  int type, flags, version;
  uint32_t serial;
  uint32_t reply_serial;
  int has_reply_serial;
  char *path, *iface, *member, *errname, *dest, *sender, *sig;
  uint32_t unix_fds;
  int has_unix_fds;
  wbuf body;
  int fds[WIRE_MAXFDS];
  int nfds;
  uint32_t declared_body_len; /* decode only */
} wmsg;

/* construction */
extern int wire_endian;   /* default for new messages: 'l' or 'B' */
wmsg *wm_new (int type, int endian);  /* endian 0 = wire_endian */
wmsg *wm_call (const char *dest, const char *path, const char *iface,
               const char *member);
wmsg *wm_signal (const char *path, const char *iface, const char *member);
wmsg *wm_return (const wmsg *call);
wmsg *wm_error (const wmsg *call, const char *name, const char *text);
void wm_free (wmsg *m);
void wm_setstr (char **dst, const char *v);

/* body appenders (alignment relative to body start, honour m->endian) */
void wm_byte (wmsg *m, uint8_t v);
void wm_bool (wmsg *m, int v);
void wm_i16 (wmsg *m, int16_t v);
void wm_u16 (wmsg *m, uint16_t v);
void wm_i32 (wmsg *m, int32_t v);
void wm_u32 (wmsg *m, uint32_t v);
void wm_i64 (wmsg *m, int64_t v);
void wm_u64 (wmsg *m, uint64_t v);
void wm_dbl (wmsg *m, double v);
void wm_str (wmsg *m, const char *s);          /* 's' and 'o' */
void wm_strn (wmsg *m, const void *s, size_t n); /* length-prefixed, NUL added; bytes unchecked */
void wm_sigstr (wmsg *m, const char *s);        /* 'g' */
void wm_fd (wmsg *m, int fd);                   /* 'h': adds fd + index */
size_t wm_array_begin (wmsg *m, int elem_align);/* returns token */
void wm_array_end (wmsg *m, size_t token, int elem_align);
void wm_struct_begin (wmsg *m);                 /* align 8 */
void wm_variant_begin (wmsg *m, const char *sig);
void wm_raw (wmsg *m, const void *p, size_t n);
/* simple typed varargs: y b n q i u x t d s o g h; "as" takes (const char **, int) */
void wm_args (wmsg *m, const char *sig, ...);
wmsg *wm_call_args (const char *dest, const char *path, const char *iface,
                    const char *member, const char *sig, ...);
wmsg *wm_bus (const char *member, const char *sig, ...);  /* to org.freedesktop.DBus */

/* header field builders for raw construction */
void wf_str (wbuf *f, int endian, int code, char type, const char *s);
void wf_u32 (wbuf *f, int endian, int code, uint32_t v);
void wf_sig (wbuf *f, int endian, int code, const char *s);

/* encoding */
void wm_encode (const wmsg *m, wbuf *out);
/* fully manual: fields content already built (starts at message offset 16) */
void wm_encode_raw (int endian, int type, int flags, int version,
                    uint32_t serial, const wbuf *fields, const void *body,
                    size_t bodylen, wbuf *out);
/* decode one message from buf: 1 ok (consumed set), 0 need more, -1 invalid */
int wm_decode (const uint8_t *buf, size_t len, wmsg *m, size_t *consumed);

/* body reader */
typedef struct { const uint8_t *d; size_t len, pos; int endian; int err; } wr;
void wr_init (wr *r, const wmsg *m);
uint32_t wr_u32 (wr *r);
uint64_t wr_u64 (wr *r);
uint8_t wr_byte (wr *r);
const char *wr_str (wr *r);   /* valid until message freed; NULL on error */
const char *wr_sig (wr *r);
/* printable form of the body according to m->sig */
char *wm_dump (const wmsg *m);
/* first body argument if it is a string or object path, else NULL */
char *wm_arg_str (const wmsg *m, int idx);  /* idx-th top-level arg, string types only */
int wm_arg_u32 (const wmsg *m, int idx, uint32_t *out);

/* connection */
typedef struct wconn {
  int fd;
  uint8_t *rb; size_t rlen, rcap;
  int fdq[WIRE_MAXFDS]; int nfdq;
  wmsg **inbox; int ninbox, incap;
  uint32_t next_serial;
  int endian;
  char unique[128];
  int eof;
  int unix_fds_ok;
  int invalid;                /* server sent undecodable data */
  char err[256];              /* last error name from helpers */
} wconn;

wconn *wc_connect (const char *path);
void wc_close (wconn *c);
int wc_send_raw (wconn *c, const void *p, size_t n);
int wc_send_raw_fds (wconn *c, const void *p, size_t n, const int *fds, int nfds);
int wc_send_line (wconn *c, const char *line);        /* adds CRLF */
/* line without CRLF: len>=0, -1 timeout, -2 eof */
int wc_read_line (wconn *c, char *out, size_t cap, int timeout_ms);
int wc_expect_line (wconn *c, const char *prefix, int timeout_ms); /* 1 if next line starts with prefix */

#define WA_EXTERNAL 0
#define WA_EXTERNAL_NOINIT 1
#define WA_ANONYMOUS 2
#define WA_FD 0x100       /* negotiate unix fd */
#define WA_NOBEGIN 0x200  /* stop after OK/AGREE, do not send BEGIN */
#define WA_NONUL 0x400    /* caller already sent the NUL byte */
/* 0 on success */
int wc_auth (wconn *c, int mode);
int wc_send_nul (wconn *c);
char *wc_hex (const char *s);   /* malloc'd lower-case hex */
char *wc_uidhex (void);

uint32_t wc_send (wconn *c, wmsg *m);       /* assigns serial if 0; returns serial or 0 */
/* 1 ok, 0 timeout, -1 eof, -2 invalid data from server */
int wc_recv (wconn *c, wmsg **out, int timeout_ms);
/* returns reply type (W_RETURN/W_ERROR), 0 timeout, -1 eof; reply may be NULL-checked */
int wc_call (wconn *c, wmsg *m, wmsg **reply, int timeout_ms);
typedef int (*wc_pred) (const wmsg *m, void *ctx);
wmsg *wc_wait (wconn *c, wc_pred p, void *ctx, int timeout_ms);
wmsg *wc_wait_sig (wconn *c, const char *member, int timeout_ms);
/* signal with member and string arg0 */
wmsg *wc_wait_sig_arg0 (wconn *c, const char *member, const char *arg0, int timeout_ms);
wmsg *wc_wait_call (wconn *c, const char *member, int timeout_ms);
int wc_drain (wconn *c, int ms);            /* read for ms into inbox; returns count in inbox */
int wc_silent (wconn *c, int ms);           /* 1 if nothing at all arrives within ms */
int wc_wait_eof (wconn *c, int timeout_ms); /* 1 if server closed */
wmsg *wc_take (wconn *c, int idx);          /* remove inbox[idx] */
void wc_clear (wconn *c);                   /* discard inbox */
int wc_inbox_find (wconn *c, int type, const char *member, const char *arg0);

/* helpers; all use a 5 s reply timeout unless noted */
int wc_hello (wconn *c);                    /* 0 ok */
const char *wc_errname (const wmsg *reply); /* NULL unless error */
/* send call to the bus, return error name copy in c->err ("" on success), 0 ok / -1 error */
int wc_bus (wconn *c, wmsg *m, wmsg **reply);
int wc_request_name (wconn *c, const char *name, uint32_t flags);   /* code or -1 */
int wc_release_name (wconn *c, const char *name);                   /* code or -1 */
int wc_add_match (wconn *c, const char *rule);                      /* 0 or -1 (c->err) */
int wc_remove_match (wconn *c, const char *rule);
int wc_name_has_owner (wconn *c, const char *name);                 /* 1/0/-1 */
char *wc_get_name_owner (wconn *c, const char *name);               /* malloc or NULL (c->err) */
/* send a method return with given serial from c */
void wc_reply_empty (wconn *c, const wmsg *call);
/* ping a peer; 0 ok */
int wc_ping (wconn *c, const char *dest);
/* sync: call a bus method so everything before it is processed */
int wc_sync (wconn *c);

int wire_ms (void);                         /* monotonic ms */
#endif

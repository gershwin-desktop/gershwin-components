/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* minibus: a dbus-daemon replacement that passes messages and nothing else.
 * No policy, no XML, no activation. Plain C, single threaded, poll(2). */

#ifndef MB_H
#define MB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MB_VERSION "1.0"

/* Protocol limits (match the reference daemon). */
#define MB_MAX_MESSAGE      (128u * 1024u * 1024u)
#define MB_MAX_ARRAY        (64u * 1024u * 1024u)
#define MB_MAX_NAME         255
#define MB_MAX_SIG          255
#define MB_MAX_DEPTH        64
#define MB_MAX_UNIX_FDS     253    /* per sendmsg, kernel limit */
#define MB_MAX_MSG_FDS      16     /* per message, as the reference daemon */
#define MB_MAX_AUTH_LINE    16384
#define MB_MAX_FIELDS       64

enum { MB_METHOD_CALL = 1, MB_METHOD_RETURN = 2, MB_ERROR = 3, MB_SIGNAL = 4 };
enum { MB_FLAG_NO_REPLY = 0x1, MB_FLAG_NO_AUTOSTART = 0x2, MB_FLAG_INTERACTIVE = 0x4 };
enum { MB_F_PATH = 1, MB_F_INTERFACE, MB_F_MEMBER, MB_F_ERROR_NAME, MB_F_REPLY_SERIAL,
       MB_F_DESTINATION, MB_F_SENDER, MB_F_SIGNATURE, MB_F_UNIX_FDS };

/* ---- buffer ---- */
typedef struct { uint8_t *p; size_t len, cap; } mb_buf;
void mb_buf_free(mb_buf *b);
bool mb_buf_reserve(mb_buf *b, size_t extra);
bool mb_buf_append(mb_buf *b, const void *d, size_t n);
void mb_buf_consume(mb_buf *b, size_t n);

/* ---- syntax checks (spec "Valid names") ---- */
bool mb_valid_utf8(const uint8_t *s, size_t n);
bool mb_valid_signature(const char *s, size_t n);          /* any complete types sequence */
bool mb_valid_single_type(const char *s, size_t n);
bool mb_valid_object_path(const char *s);
bool mb_valid_member(const char *s);
bool mb_valid_interface(const char *s);                    /* also error names */
bool mb_valid_bus_name(const char *s);                     /* unique or well-known */
bool mb_valid_well_known_name(const char *s);
bool mb_is_unique_name(const char *s);

/* ---- messages ----
 * A message is immutable once built and shared by reference count between
 * recipients. data holds the full wire bytes in the sender's byte order. */
typedef struct mb_msg {
    int refs;
    uint8_t *data;
    size_t len;
    bool big;
    uint8_t type, flags;
    uint32_t serial, reply_serial, body_len, unix_fds;
    bool has_reply_serial;
    /* Strings point into data (valid for the life of the message). */
    const char *path, *interface, *member, *error_name, *destination, *sender, *signature;
    size_t body_off;
    int *fds;      /* attached descriptors (owned) */
    int nfds;
    /* The first top-level arguments, found once for match rules (argN). */
    int8_t nargs;  /* -1 until looked at */
    char argtype[8];
    const char *arg[8];
} mb_msg;

typedef enum { MB_PARSE_OK = 0, MB_PARSE_NEED_MORE, MB_PARSE_INVALID } mb_parse_result;

/* Inspect the 16 byte fixed header. On OK sets *total to the full message size. */
mb_parse_result mb_msg_peek(const uint8_t *p, size_t avail, size_t *total);
/* Validate a complete message in place, without copying it. The view's strings
 * point into p; it must not be referenced or unreferenced. */
mb_parse_result mb_msg_view(const uint8_t *p, size_t n, mb_msg *view, const char **why);
mb_msg *mb_msg_ref(mb_msg *m);
void mb_msg_unref(mb_msg *m);

/* Build a message. Fields that are NULL are omitted. Body is copied. */
typedef struct {
    bool big;
    uint8_t type, flags;
    uint32_t serial, reply_serial;
    bool has_reply_serial;
    const char *path, *interface, *member, *error_name, *destination, *sender, *signature;
    uint32_t unix_fds;
    const uint8_t *body;
    size_t body_len;
} mb_msg_spec;
mb_msg *mb_msg_build(const mb_msg_spec *s);
/* Copy of m with the sender (and optionally destination) replaced. */
mb_msg *mb_msg_with_sender(mb_msg *m, const char *sender, bool big_out);

/* ---- body writer / reader (native little-endian host assumed from host test) ---- */
typedef struct { mb_buf b; bool big; bool failed; } mb_w;
void mb_w_init(mb_w *w, bool big);
void mb_w_free(mb_w *w);
void mb_w_align(mb_w *w, size_t a);
void mb_w_u8(mb_w *w, uint8_t v);
void mb_w_u32(mb_w *w, uint32_t v);
void mb_w_str(mb_w *w, const char *s);        /* STRING / OBJECT_PATH */
void mb_w_sig(mb_w *w, const char *s);        /* SIGNATURE */
void mb_w_bool(mb_w *w, bool v);
/* Arrays: call begin, write elements, then end. */
size_t mb_w_array_begin(mb_w *w, size_t elem_align);
void mb_w_array_end(mb_w *w, size_t token, size_t elem_align);

typedef struct { const uint8_t *p; size_t len, pos; bool big; bool bad; } mb_r;
void mb_r_init(mb_r *r, const uint8_t *p, size_t len, bool big);
uint8_t mb_r_u8(mb_r *r);
uint32_t mb_r_u32(mb_r *r);
const char *mb_r_str(mb_r *r);                 /* STRING / OBJECT_PATH, NULL on error */
const char *mb_r_sig(mb_r *r);
/* Read the first value of a body as a STRING-like arg i (for arg matching). Returns
 * NULL when arg i is not a string/object path/signature. */
const char *mb_msg_arg_string(const mb_msg *m, unsigned index, char *type);

/* ---- bus ---- */
typedef struct mb_bus mb_bus;
typedef struct mb_conn mb_conn;


mb_bus *mb_bus_new(void);
void mb_bus_free(mb_bus *b);
bool mb_bus_listen(mb_bus *b, const char *address, char **actual_address, char *err, size_t errlen);
void mb_bus_run(mb_bus *b);
const char *mb_bus_id(mb_bus *b);

/* Diagnostics. Level 0 is always logged, level 1 only with --verbose. Message
 * bodies are never logged. */
void mb_log(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

int mb_main(int argc, char **argv);

#endif

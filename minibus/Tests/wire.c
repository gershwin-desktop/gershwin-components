/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#define _GNU_SOURCE
#include "wire.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>

/* ---------------------------------------------------------------- wbuf */

void wbuf_free (wbuf *b) { free (b->d); b->d = NULL; b->len = b->cap = 0; }

void wbuf_put (wbuf *b, const void *p, size_t n)
{
  if (b->len + n > b->cap)
    {
      size_t nc = b->cap ? b->cap : 64;
      while (nc < b->len + n) nc *= 2;
      b->d = realloc (b->d, nc);
      b->cap = nc;
    }
  if (n) { if (p) memcpy (b->d + b->len, p, n); else memset (b->d + b->len, 0, n); }
  b->len += n;
}

void wbuf_pad (wbuf *b, size_t a)
{
  while (b->len % a) { uint8_t z = 0; wbuf_put (b, &z, 1); }
}

static void put16 (wbuf *b, int e, uint16_t v)
{
  uint8_t t[2];
  if (e == 'l') { t[0] = v; t[1] = v >> 8; } else { t[1] = v; t[0] = v >> 8; }
  wbuf_put (b, t, 2);
}
static void put32 (wbuf *b, int e, uint32_t v)
{
  uint8_t t[4];
  for (int i = 0; i < 4; i++)
    t[e == 'l' ? i : 3 - i] = (v >> (8 * i)) & 0xff;
  wbuf_put (b, t, 4);
}
static void put64 (wbuf *b, int e, uint64_t v)
{
  uint8_t t[8];
  for (int i = 0; i < 8; i++)
    t[e == 'l' ? i : 7 - i] = (v >> (8 * i)) & 0xff;
  wbuf_put (b, t, 8);
}
static uint32_t get32 (const uint8_t *p, int e)
{
  uint32_t v = 0;
  for (int i = 0; i < 4; i++)
    v |= (uint32_t) p[e == 'l' ? i : 3 - i] << (8 * i);
  return v;
}
static uint64_t get64 (const uint8_t *p, int e)
{
  uint64_t v = 0;
  for (int i = 0; i < 8; i++)
    v |= (uint64_t) p[e == 'l' ? i : 7 - i] << (8 * i);
  return v;
}
static uint16_t get16 (const uint8_t *p, int e)
{
  return e == 'l' ? (p[0] | (p[1] << 8)) : (p[1] | (p[0] << 8));
}

/* ---------------------------------------------------------------- wmsg */

void wm_setstr (char **dst, const char *v)
{
  free (*dst);
  *dst = v ? strdup (v) : NULL;
}

int wire_endian = 'l';

wmsg *wm_new (int type, int endian)
{
  wmsg *m = calloc (1, sizeof *m);
  m->type = type;
  m->endian = endian ? endian : wire_endian;
  m->version = 1;
  return m;
}

wmsg *wm_call (const char *dest, const char *path, const char *iface,
               const char *member)
{
  wmsg *m = wm_new (W_CALL, 0);
  wm_setstr (&m->dest, dest);
  wm_setstr (&m->path, path);
  wm_setstr (&m->iface, iface);
  wm_setstr (&m->member, member);
  return m;
}

wmsg *wm_signal (const char *path, const char *iface, const char *member)
{
  wmsg *m = wm_new (W_SIGNAL, 0);
  wm_setstr (&m->path, path);
  wm_setstr (&m->iface, iface);
  wm_setstr (&m->member, member);
  return m;
}

wmsg *wm_return (const wmsg *call)
{
  wmsg *m = wm_new (W_RETURN, call->endian);
  m->reply_serial = call->serial;
  m->has_reply_serial = 1;
  wm_setstr (&m->dest, call->sender);
  return m;
}

wmsg *wm_error (const wmsg *call, const char *name, const char *text)
{
  wmsg *m = wm_new (W_ERROR, call->endian);
  m->reply_serial = call->serial;
  m->has_reply_serial = 1;
  wm_setstr (&m->dest, call->sender);
  wm_setstr (&m->errname, name);
  if (text)
    {
      wm_setstr (&m->sig, "s");
      wm_str (m, text);
    }
  return m;
}

void wm_free (wmsg *m)
{
  if (!m) return;
  free (m->path); free (m->iface); free (m->member); free (m->errname);
  free (m->dest); free (m->sender); free (m->sig);
  wbuf_free (&m->body);
  free (m);
}

static void al (wmsg *m, size_t a) { wbuf_pad (&m->body, a); }
void wm_byte (wmsg *m, uint8_t v) { wbuf_put (&m->body, &v, 1); }
void wm_bool (wmsg *m, int v) { al (m, 4); put32 (&m->body, m->endian, v ? 1 : 0); }
void wm_i16 (wmsg *m, int16_t v) { al (m, 2); put16 (&m->body, m->endian, (uint16_t) v); }
void wm_u16 (wmsg *m, uint16_t v) { al (m, 2); put16 (&m->body, m->endian, v); }
void wm_i32 (wmsg *m, int32_t v) { al (m, 4); put32 (&m->body, m->endian, (uint32_t) v); }
void wm_u32 (wmsg *m, uint32_t v) { al (m, 4); put32 (&m->body, m->endian, v); }
void wm_i64 (wmsg *m, int64_t v) { al (m, 8); put64 (&m->body, m->endian, (uint64_t) v); }
void wm_u64 (wmsg *m, uint64_t v) { al (m, 8); put64 (&m->body, m->endian, v); }
void wm_dbl (wmsg *m, double v)
{
  uint64_t u; memcpy (&u, &v, 8); al (m, 8); put64 (&m->body, m->endian, u);
}
void wm_strn (wmsg *m, const void *s, size_t n)
{
  uint8_t z = 0;
  al (m, 4); put32 (&m->body, m->endian, (uint32_t) n);
  wbuf_put (&m->body, s, n); wbuf_put (&m->body, &z, 1);
}
void wm_str (wmsg *m, const char *s) { wm_strn (m, s, strlen (s)); }
void wm_sigstr (wmsg *m, const char *s)
{
  uint8_t l = (uint8_t) strlen (s), z = 0;
  wbuf_put (&m->body, &l, 1); wbuf_put (&m->body, s, l); wbuf_put (&m->body, &z, 1);
}
void wm_fd (wmsg *m, int fd)
{
  wm_u32 (m, (uint32_t) m->nfds);
  m->fds[m->nfds++] = fd;
}
size_t wm_array_begin (wmsg *m, int ea)
{
  size_t tok;
  al (m, 4); tok = m->body.len; put32 (&m->body, m->endian, 0);
  al (m, ea);
  return tok;
}
void wm_array_end (wmsg *m, size_t tok, int ea)
{
  size_t start = tok + 4, n;
  (void) ea;
  /* start of element data is after padding to ea */
  while (start % (ea ? ea : 1)) start++;
  n = m->body.len - start;
  {
    wbuf t = { 0 };
    put32 (&t, m->endian, (uint32_t) n);
    memcpy (m->body.d + tok, t.d, 4);
    wbuf_free (&t);
  }
}
void wm_struct_begin (wmsg *m) { al (m, 8); }
void wm_variant_begin (wmsg *m, const char *sig) { wm_sigstr (m, sig); }
void wm_raw (wmsg *m, const void *p, size_t n) { wbuf_put (&m->body, p, n); }

static void wm_vargs (wmsg *m, const char *sig, va_list ap)
{
  if (sig[0]) wm_setstr (&m->sig, sig);
  for (const char *p = sig; *p; p++)
    switch (*p)
      {
      case 'y': wm_byte (m, (uint8_t) va_arg (ap, int)); break;
      case 'b': wm_bool (m, va_arg (ap, int)); break;
      case 'n': wm_i16 (m, (int16_t) va_arg (ap, int)); break;
      case 'q': wm_u16 (m, (uint16_t) va_arg (ap, int)); break;
      case 'i': wm_i32 (m, va_arg (ap, int32_t)); break;
      case 'u': wm_u32 (m, va_arg (ap, uint32_t)); break;
      case 'x': wm_i64 (m, va_arg (ap, int64_t)); break;
      case 't': wm_u64 (m, va_arg (ap, uint64_t)); break;
      case 'd': wm_dbl (m, va_arg (ap, double)); break;
      case 's': case 'o': wm_str (m, va_arg (ap, const char *)); break;
      case 'g': wm_sigstr (m, va_arg (ap, const char *)); break;
      case 'h': wm_fd (m, va_arg (ap, int)); break;
      case 'a':
        {
          const char **arr = va_arg (ap, const char **);
          int n = va_arg (ap, int);
          size_t tok = wm_array_begin (m, 4);
          p++;  /* element type: s, o or g are the only supported ones */
          for (int i = 0; i < n; i++)
            {
              if (*p == 'g') wm_sigstr (m, arr[i]); else wm_str (m, arr[i]);
            }
          wm_array_end (m, tok, 4);
          break;
        }
      default: abort ();
      }
}

void wm_args (wmsg *m, const char *sig, ...)
{
  va_list ap; va_start (ap, sig); wm_vargs (m, sig, ap); va_end (ap);
}

wmsg *wm_call_args (const char *dest, const char *path, const char *iface,
                    const char *member, const char *sig, ...)
{
  wmsg *m = wm_call (dest, path, iface, member);
  va_list ap; va_start (ap, sig); wm_vargs (m, sig, ap); va_end (ap);
  return m;
}

wmsg *wm_bus (const char *member, const char *sig, ...)
{
  wmsg *m = wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus", member);
  va_list ap; va_start (ap, sig); wm_vargs (m, sig, ap); va_end (ap);
  return m;
}

/* ------------------------------------------------------------- fields */

void wf_str (wbuf *f, int e, int code, char type, const char *s)
{
  uint8_t hd[4] = { (uint8_t) code, 1, (uint8_t) type, 0 }, z = 0;
  size_t n = strlen (s);
  wbuf_pad (f, 8);
  wbuf_put (f, hd, 4);
  put32 (f, e, (uint32_t) n);
  wbuf_put (f, s, n); wbuf_put (f, &z, 1);
}
void wf_u32 (wbuf *f, int e, int code, uint32_t v)
{
  uint8_t hd[4] = { (uint8_t) code, 1, 'u', 0 };
  wbuf_pad (f, 8);
  wbuf_put (f, hd, 4);
  put32 (f, e, v);
}
void wf_sig (wbuf *f, int e, int code, const char *s)
{
  uint8_t hd[4] = { (uint8_t) code, 1, 'g', 0 }, l = (uint8_t) strlen (s), z = 0;
  (void) e;
  wbuf_pad (f, 8);
  wbuf_put (f, hd, 4);
  wbuf_put (f, &l, 1); wbuf_put (f, s, l); wbuf_put (f, &z, 1);
}

void wm_encode_raw (int e, int type, int flags, int version, uint32_t serial,
                    const wbuf *fields, const void *body, size_t bodylen,
                    wbuf *out)
{
  uint8_t h[4] = { (uint8_t) e, (uint8_t) type, (uint8_t) flags, (uint8_t) version };
  size_t base = out->len;   /* the buffer may already hold earlier messages */
  wbuf_put (out, h, 4);
  put32 (out, e, (uint32_t) bodylen);
  put32 (out, e, serial);
  put32 (out, e, (uint32_t) fields->len);
  wbuf_put (out, fields->d, fields->len);
  while ((out->len - base) % 8) wbuf_put (out, NULL, 1);
  wbuf_put (out, body, bodylen);
}

void wm_encode (const wmsg *m, wbuf *out)
{
  wbuf f = { 0 };
  int e = m->endian;
  if (m->path) wf_str (&f, e, WF_PATH, 'o', m->path);
  if (m->iface) wf_str (&f, e, WF_IFACE, 's', m->iface);
  if (m->member) wf_str (&f, e, WF_MEMBER, 's', m->member);
  if (m->errname) wf_str (&f, e, WF_ERRNAME, 's', m->errname);
  if (m->has_reply_serial) wf_u32 (&f, e, WF_REPLYSERIAL, m->reply_serial);
  if (m->dest) wf_str (&f, e, WF_DEST, 's', m->dest);
  if (m->sender) wf_str (&f, e, WF_SENDER, 's', m->sender);
  if (m->sig) wf_sig (&f, e, WF_SIG, m->sig);
  if (m->has_unix_fds) wf_u32 (&f, e, WF_UNIXFDS, m->unix_fds);
  else if (m->nfds) wf_u32 (&f, e, WF_UNIXFDS, (uint32_t) m->nfds);
  wm_encode_raw (e, m->type, m->flags, m->version, m->serial, &f,
                 m->body.d, m->body.len, out);
  wbuf_free (&f);
}

int wm_decode (const uint8_t *b, size_t len, wmsg *m, size_t *consumed)
{
  int e; uint32_t blen, flen; size_t hdr, total, pos;
  if (len < 16) return 0;
  e = b[0];
  if (e != 'l' && e != 'B') return -1;
  blen = get32 (b + 4, e); flen = get32 (b + 12, e);
  if (blen > 134217728u || flen > 67108864u) return -1;
  hdr = (16 + (size_t) flen + 7) & ~(size_t) 7;
  total = hdr + blen;
  if (len < total) return 0;
  memset (m, 0, sizeof *m);
  m->endian = e; m->type = b[1]; m->flags = b[2]; m->version = b[3];
  m->serial = get32 (b + 8, e);
  m->declared_body_len = blen;
  pos = 16;
  while (pos < 16 + (size_t) flen)
    {
      uint8_t code, sl; char t; size_t end = 16 + flen;
      pos = (pos + 7) & ~(size_t) 7;
      if (pos >= end) break;
      code = b[pos++];
      sl = b[pos++];
      if (sl != 1 || pos + 2 > end) return -1;
      t = (char) b[pos++];
      pos++;
      if (t == 's' || t == 'o')
        {
          uint32_t n; char *s;
          pos = (pos + 3) & ~(size_t) 3;
          if (pos + 4 > end) return -1;
          n = get32 (b + pos, e); pos += 4;
          if (pos + n + 1 > end) return -1;
          s = malloc (n + 1); memcpy (s, b + pos, n); s[n] = 0;
          pos += n + 1;
          switch (code)
            {
            case WF_PATH: m->path = s; break;
            case WF_IFACE: m->iface = s; break;
            case WF_MEMBER: m->member = s; break;
            case WF_ERRNAME: m->errname = s; break;
            case WF_DEST: m->dest = s; break;
            case WF_SENDER: m->sender = s; break;
            default: free (s);
            }
        }
      else if (t == 'g')
        {
          uint8_t n; char *s;
          if (pos + 1 > end) return -1;
          n = b[pos++];
          if (pos + n + 1 > end) return -1;
          s = malloc (n + 1); memcpy (s, b + pos, n); s[n] = 0;
          pos += n + 1;
          if (code == WF_SIG) m->sig = s; else free (s);
        }
      else if (t == 'u')
        {
          uint32_t v;
          pos = (pos + 3) & ~(size_t) 3;
          if (pos + 4 > end) return -1;
          v = get32 (b + pos, e); pos += 4;
          if (code == WF_REPLYSERIAL) { m->reply_serial = v; m->has_reply_serial = 1; }
          if (code == WF_UNIXFDS) { m->unix_fds = v; m->has_unix_fds = 1; }
        }
      else return -1;
    }
  wbuf_put (&m->body, b + hdr, blen);
  *consumed = total;
  return 1;
}

/* ------------------------------------------------------------- reader */

void wr_init (wr *r, const wmsg *m)
{
  r->d = m->body.d; r->len = m->body.len; r->pos = 0; r->endian = m->endian; r->err = 0;
}
static int wr_al (wr *r, size_t a)
{
  r->pos = (r->pos + a - 1) & ~(a - 1);
  if (r->pos > r->len) { r->err = 1; return 0; }
  return 1;
}
uint8_t wr_byte (wr *r)
{
  if (r->pos + 1 > r->len) { r->err = 1; return 0; }
  return r->d[r->pos++];
}
uint32_t wr_u32 (wr *r)
{
  uint32_t v;
  if (!wr_al (r, 4) || r->pos + 4 > r->len) { r->err = 1; return 0; }
  v = get32 (r->d + r->pos, r->endian); r->pos += 4; return v;
}
uint64_t wr_u64 (wr *r)
{
  uint64_t v;
  if (!wr_al (r, 8) || r->pos + 8 > r->len) { r->err = 1; return 0; }
  v = get64 (r->d + r->pos, r->endian); r->pos += 8; return v;
}
const char *wr_str (wr *r)
{
  uint32_t n; const char *s;
  n = wr_u32 (r);
  if (r->err || r->pos + n + 1 > r->len) { r->err = 1; return NULL; }
  s = (const char *) r->d + r->pos; r->pos += n + 1;
  return s;
}
const char *wr_sig (wr *r)
{
  uint8_t n; const char *s;
  n = wr_byte (r);
  if (r->err || r->pos + n + 1 > r->len) { r->err = 1; return NULL; }
  s = (const char *) r->d + r->pos; r->pos += n + 1;
  return s;
}

static const char *sig_skip (const char *s)
{
  switch (*s)
    {
    case 'a': return sig_skip (s + 1);
    case '(': s++; while (*s != ')') s = sig_skip (s); return s + 1;
    case '{': s++; while (*s != '}') s = sig_skip (s); return s + 1;
    default: return s + 1;
    }
}

static void sapp (wbuf *o, const char *fmt, ...)
{
  char t[512]; va_list ap;
  va_start (ap, fmt); vsnprintf (t, sizeof t, fmt, ap); va_end (ap);
  wbuf_put (o, t, strlen (t));
}

static const char *dump_one (wr *r, const char *sig, wbuf *o)
{
  switch (*sig)
    {
    case 'y': sapp (o, "%u", wr_byte (r)); return sig + 1;
    case 'b': sapp (o, wr_u32 (r) ? "true" : "false"); return sig + 1;
    case 'n': wr_al (r, 2); if (r->pos + 2 <= r->len) { sapp (o, "%d", (int16_t) get16 (r->d + r->pos, r->endian)); r->pos += 2; } else r->err = 1; return sig + 1;
    case 'q': wr_al (r, 2); if (r->pos + 2 <= r->len) { sapp (o, "%u", get16 (r->d + r->pos, r->endian)); r->pos += 2; } else r->err = 1; return sig + 1;
    case 'i': sapp (o, "%d", (int32_t) wr_u32 (r)); return sig + 1;
    case 'u': sapp (o, "%u", wr_u32 (r)); return sig + 1;
    case 'h': sapp (o, "fd#%u", wr_u32 (r)); return sig + 1;
    case 'x': sapp (o, "%lld", (long long) (int64_t) wr_u64 (r)); return sig + 1;
    case 't': sapp (o, "%llu", (unsigned long long) wr_u64 (r)); return sig + 1;
    case 'd': { uint64_t u = wr_u64 (r); double d; memcpy (&d, &u, 8); sapp (o, "%g", d); return sig + 1; }
    case 's': case 'o':
      { const char *s = wr_str (r); sapp (o, "\"%s\"", s ? s : "?"); return sig + 1; }
    case 'g':
      { const char *s = wr_sig (r); sapp (o, "\"%s\"", s ? s : "?"); return sig + 1; }
    case 'v':
      {
        const char *s = wr_sig (r);
        sapp (o, "<");
        if (s) dump_one (r, s, o);
        sapp (o, ">");
        return sig + 1;
      }
    case 'a':
      {
        uint32_t n = wr_u32 (r);
        const char *el = sig + 1, *next = sig_skip (el);
        size_t end;
        int al = 1, first = 1;
        switch (*el)
          {
          case 'n': case 'q': al = 2; break;
          case 'b': case 'i': case 'u': case 's': case 'o': case 'a': case 'h': al = 4; break;
          case 'x': case 't': case 'd': case '(': case '{': al = 8; break;
          }
        wr_al (r, al);
        end = r->pos + n;
        if (end > r->len) { r->err = 1; return next; }
        sapp (o, "[");
        while (!r->err && r->pos < end)
          {
            if (!first) sapp (o, ",");
            first = 0;
            dump_one (r, el, o);
          }
        sapp (o, "]");
        return next;
      }
    case '(':
      {
        const char *s = sig + 1; int first = 1;
        wr_al (r, 8);
        sapp (o, "(");
        while (*s != ')' && !r->err)
          {
            if (!first) sapp (o, ",");
            first = 0;
            s = dump_one (r, s, o);
          }
        sapp (o, ")");
        return s + 1;
      }
    case '{':
      {
        const char *s = sig + 1;
        wr_al (r, 8);
        sapp (o, "{");
        s = dump_one (r, s, o);
        sapp (o, ":");
        s = dump_one (r, s, o);
        sapp (o, "}");
        return s + 1;
      }
    default:
      r->err = 1; return sig + 1;
    }
}

char *wm_dump (const wmsg *m)
{
  wbuf o = { 0 }; wr r; const char *s = m->sig ? m->sig : ""; int first = 1;
  uint8_t z = 0;
  wr_init (&r, m);
  while (*s && !r.err)
    {
      if (!first) sapp (&o, ",");
      first = 0;
      s = dump_one (&r, s, &o);
    }
  if (r.err) sapp (&o, "!ERR");
  wbuf_put (&o, &z, 1);
  return (char *) o.d;
}

char *wm_arg_str (const wmsg *m, int idx)
{
  wr r; const char *s = m->sig ? m->sig : ""; int i = 0;
  wr_init (&r, m);
  while (*s && !r.err)
    {
      if (i == idx)
        {
          const char *v;
          if (*s == 's' || *s == 'o') v = wr_str (&r);
          else if (*s == 'g') v = wr_sig (&r);
          else return NULL;
          return v && !r.err ? strdup (v) : NULL;
        }
      { wbuf o = { 0 }; s = dump_one (&r, s, &o); wbuf_free (&o); }
      i++;
    }
  return NULL;
}

int wm_arg_u32 (const wmsg *m, int idx, uint32_t *out)
{
  wr r; const char *s = m->sig ? m->sig : ""; int i = 0;
  wr_init (&r, m);
  while (*s && !r.err)
    {
      if (i == idx)
        {
          if (*s != 'u' && *s != 'i' && *s != 'b') return 0;
          *out = wr_u32 (&r);
          return !r.err;
        }
      { wbuf o = { 0 }; s = dump_one (&r, s, &o); wbuf_free (&o); }
      i++;
    }
  return 0;
}

/* --------------------------------------------------------- connection */

int wire_ms (void)
{
  struct timespec ts;
  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (int) ((ts.tv_sec % 1000000) * 1000 + ts.tv_nsec / 1000000);
}

wconn *wc_connect (const char *path)
{
  struct sockaddr_un sa; int fd; wconn *c;
  fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return NULL;
  memset (&sa, 0, sizeof sa);
  sa.sun_family = AF_UNIX;
  if (strlen (path) >= sizeof sa.sun_path) { close (fd); return NULL; }
  strcpy (sa.sun_path, path);
  if (connect (fd, (struct sockaddr *) &sa, sizeof sa) < 0) { close (fd); return NULL; }
  c = calloc (1, sizeof *c);
  c->fd = fd; c->endian = 'l'; c->next_serial = 1;
  return c;
}

void wc_close (wconn *c)
{
  if (!c) return;
  if (c->fd >= 0) close (c->fd);
  for (int i = 0; i < c->nfdq; i++) close (c->fdq[i]);
  for (int i = 0; i < c->ninbox; i++) wm_free (c->inbox[i]);
  free (c->inbox); free (c->rb); free (c);
}

static int send_all (wconn *c, const void *p, size_t n, const int *fds, int nfds)
{
  const uint8_t *b = p; size_t off = 0;
  while (off < n)
    {
      struct iovec iov = { (void *) (b + off), n - off };
      struct msghdr mh; char cb[CMSG_SPACE (sizeof (int) * WIRE_MAXFDS)];
      ssize_t r;
      memset (&mh, 0, sizeof mh);
      mh.msg_iov = &iov; mh.msg_iovlen = 1;
      if (off == 0 && nfds > 0)
        {
          struct cmsghdr *ch;
          memset (cb, 0, sizeof cb);
          mh.msg_control = cb; mh.msg_controllen = CMSG_SPACE (sizeof (int) * nfds);
          ch = CMSG_FIRSTHDR (&mh);
          ch->cmsg_level = SOL_SOCKET; ch->cmsg_type = SCM_RIGHTS;
          ch->cmsg_len = CMSG_LEN (sizeof (int) * nfds);
          memcpy (CMSG_DATA (ch), fds, sizeof (int) * nfds);
        }
      r = sendmsg (c->fd, &mh, MSG_NOSIGNAL);
      if (r < 0)
        {
          if (errno == EINTR) continue;
          if (errno == EAGAIN)
            {
              struct pollfd pf = { c->fd, POLLOUT, 0 };
              if (poll (&pf, 1, 10000) <= 0) return -1;
              continue;
            }
          return -1;
        }
      off += (size_t) r;
    }
  return 0;
}

int wc_send_raw (wconn *c, const void *p, size_t n) { return send_all (c, p, n, NULL, 0); }
int wc_send_raw_fds (wconn *c, const void *p, size_t n, const int *fds, int nfds)
{
  return send_all (c, p, n, fds, nfds);
}
int wc_send_line (wconn *c, const char *line)
{
  size_t n = strlen (line);
  char *t = malloc (n + 3); int r;
  memcpy (t, line, n); t[n] = '\r'; t[n + 1] = '\n';
  r = send_all (c, t, n + 2, NULL, 0);
  free (t);
  return r;
}
int wc_send_nul (wconn *c) { uint8_t z = 0; return send_all (c, &z, 1, NULL, 0); }

/* 1 data, 0 timeout, -1 eof/error */
static int fill (wconn *c, int timeout_ms)
{
  struct pollfd pf = { c->fd, POLLIN, 0 };
  int pr;
  if (c->eof) return -1;
  do pr = poll (&pf, 1, timeout_ms); while (pr < 0 && errno == EINTR);
  if (pr == 0) return 0;
  if (pr < 0) { c->eof = 1; return -1; }
  if (c->rcap - c->rlen < 65536)
    {
      c->rcap = c->rcap ? c->rcap * 2 : 131072;
      c->rb = realloc (c->rb, c->rcap);
    }
  {
    struct iovec iov = { c->rb + c->rlen, c->rcap - c->rlen };
    struct msghdr mh; char cb[CMSG_SPACE (sizeof (int) * WIRE_MAXFDS)];
    ssize_t r;
    memset (&mh, 0, sizeof mh);
    mh.msg_iov = &iov; mh.msg_iovlen = 1;
    mh.msg_control = cb; mh.msg_controllen = sizeof cb;
    r = recvmsg (c->fd, &mh, MSG_CMSG_CLOEXEC);
    if (r <= 0)
      {
        if (r < 0 && (errno == EINTR || errno == EAGAIN)) return 0;
        c->eof = 1; return -1;
      }
    for (struct cmsghdr *ch = CMSG_FIRSTHDR (&mh); ch; ch = CMSG_NXTHDR (&mh, ch))
      if (ch->cmsg_level == SOL_SOCKET && ch->cmsg_type == SCM_RIGHTS)
        {
          int n = (int) ((ch->cmsg_len - CMSG_LEN (0)) / sizeof (int));
          int *p = (int *) CMSG_DATA (ch);
          for (int i = 0; i < n; i++)
            {
              if (c->nfdq < WIRE_MAXFDS) c->fdq[c->nfdq++] = p[i]; else close (p[i]);
            }
        }
    c->rlen += (size_t) r;
  }
  return 1;
}

int wc_read_line (wconn *c, char *out, size_t cap, int timeout_ms)
{
  int start = wire_ms ();
  for (;;)
    {
      for (size_t i = 0; i + 1 < c->rlen + 0 || i < c->rlen; i++)
        if (i + 1 < c->rlen && c->rb[i] == '\r' && c->rb[i + 1] == '\n')
          {
            size_t n = i < cap - 1 ? i : cap - 1;
            memcpy (out, c->rb, n); out[n] = 0;
            memmove (c->rb, c->rb + i + 2, c->rlen - i - 2);
            c->rlen -= i + 2;
            return (int) n;
          }
      {
        int left = timeout_ms - (wire_ms () - start), r;
        if (left < 0) left = 0;
        r = fill (c, left);
        if (r < 0) return -2;
        if (r == 0 && left == 0) return -1;
      }
    }
}

int wc_expect_line (wconn *c, const char *prefix, int timeout_ms)
{
  char l[1024];
  int n = wc_read_line (c, l, sizeof l, timeout_ms);
  if (n < 0) return 0;
  return strncmp (l, prefix, strlen (prefix)) == 0;
}

char *wc_hex (const char *s)
{
  size_t n = strlen (s); char *o = malloc (n * 2 + 1);
  for (size_t i = 0; i < n; i++) sprintf (o + 2 * i, "%02x", (unsigned char) s[i]);
  return o;
}
char *wc_uidhex (void)
{
  char t[32]; snprintf (t, sizeof t, "%u", (unsigned) getuid ());
  return wc_hex (t);
}

int wc_auth (wconn *c, int mode)
{
  char l[1024], *hx; int base = mode & 0xff, rc = -1;
  if (!(mode & WA_NONUL) && wc_send_nul (c) < 0) return -1;
  if (base == WA_EXTERNAL || base == WA_EXTERNAL_NOINIT || base == WA_ANONYMOUS)
    {
      if (base == WA_EXTERNAL)
        {
          hx = wc_uidhex ();
          snprintf (l, sizeof l, "AUTH EXTERNAL %s", hx); free (hx);
          wc_send_line (c, l);
        }
      else if (base == WA_EXTERNAL_NOINIT)
        {
          wc_send_line (c, "AUTH EXTERNAL");
          if (!wc_expect_line (c, "DATA", 5000)) return -1;
          hx = wc_uidhex ();
          snprintf (l, sizeof l, "DATA %s", hx); free (hx);
          wc_send_line (c, l);
        }
      else
        {
          hx = wc_hex ("minibus-test");
          snprintf (l, sizeof l, "AUTH ANONYMOUS %s", hx); free (hx);
          wc_send_line (c, l);
        }
      if (wc_read_line (c, l, sizeof l, 5000) < 0 || strncmp (l, "OK ", 3)) return -1;
      if (mode & WA_FD)
        {
          wc_send_line (c, "NEGOTIATE_UNIX_FD");
          if (wc_read_line (c, l, sizeof l, 5000) < 0 || strncmp (l, "AGREE_UNIX_FD", 13)) return -1;
          c->unix_fds_ok = 1;
        }
      if (!(mode & WA_NOBEGIN)) wc_send_line (c, "BEGIN");
      rc = 0;
    }
  return rc;
}

/* ------------------------------------------------------------ messages */

uint32_t wc_send (wconn *c, wmsg *m)
{
  wbuf b = { 0 }; int r;
  if (!m->serial) m->serial = c->next_serial++;
  wm_encode (m, &b);
  r = send_all (c, b.d, b.len, m->nfds ? m->fds : NULL, m->nfds);
  wbuf_free (&b);
  return r < 0 ? 0 : m->serial;
}

static int read_msg (wconn *c, wmsg **out, int timeout_ms)
{
  int start = wire_ms ();
  for (;;)
    {
      wmsg *m = malloc (sizeof *m); size_t used = 0;
      int r = wm_decode (c->rb, c->rlen, m, &used);
      if (r < 0) { free (m); c->invalid = 1; return -2; }
      if (r > 0)
        {
          memmove (c->rb, c->rb + used, c->rlen - used);
          c->rlen -= used;
          if (m->unix_fds)
            {
              int n = (int) m->unix_fds < c->nfdq ? (int) m->unix_fds : c->nfdq;
              for (int i = 0; i < n; i++) m->fds[i] = c->fdq[i];
              memmove (c->fdq, c->fdq + n, sizeof (int) * (c->nfdq - n));
              c->nfdq -= n; m->nfds = n;
            }
          *out = m;
          return 1;
        }
      free (m);
      {
        int left = timeout_ms - (wire_ms () - start), fr;
        if (left < 0) left = 0;
        fr = fill (c, left);
        if (fr < 0)
          {
            /* data may have arrived with the EOF */
            wmsg *m2 = malloc (sizeof *m2); size_t u2 = 0;
            int r2 = wm_decode (c->rb, c->rlen, m2, &u2);
            if (r2 > 0)
              {
                memmove (c->rb, c->rb + u2, c->rlen - u2); c->rlen -= u2;
                *out = m2; return 1;
              }
            free (m2);
            return -1;
          }
        if (fr == 0 && left == 0) return 0;
      }
    }
}

static void inbox_add (wconn *c, wmsg *m)
{
  if (c->ninbox == c->incap)
    {
      c->incap = c->incap ? c->incap * 2 : 16;
      c->inbox = realloc (c->inbox, sizeof (wmsg *) * c->incap);
    }
  c->inbox[c->ninbox++] = m;
}

wmsg *wc_take (wconn *c, int idx)
{
  wmsg *m;
  if (idx < 0 || idx >= c->ninbox) return NULL;
  m = c->inbox[idx];
  memmove (c->inbox + idx, c->inbox + idx + 1, sizeof (wmsg *) * (c->ninbox - idx - 1));
  c->ninbox--;
  return m;
}

void wc_clear (wconn *c)
{
  while (c->ninbox) wm_free (wc_take (c, 0));
}

int wc_recv (wconn *c, wmsg **out, int timeout_ms)
{
  if (c->ninbox) { *out = wc_take (c, 0); return 1; }
  return read_msg (c, out, timeout_ms);
}

int wc_call (wconn *c, wmsg *m, wmsg **reply, int timeout_ms)
{
  uint32_t s = wc_send (c, m);
  int start = wire_ms ();
  if (!s) return -1;
  for (;;)
    {
      wmsg *r; int left = timeout_ms - (wire_ms () - start), rc;
      if (left < 0) left = 0;
      rc = read_msg (c, &r, left);
      if (rc <= 0) return rc == -2 ? -1 : rc;
      if ((r->type == W_RETURN || r->type == W_ERROR) && r->has_reply_serial
          && r->reply_serial == s)
        {
          int t = r->type;
          if (reply) *reply = r; else wm_free (r);
          return t;
        }
      inbox_add (c, r);
    }
}

wmsg *wc_wait (wconn *c, wc_pred p, void *ctx, int timeout_ms)
{
  int start = wire_ms ();
  for (int i = 0; i < c->ninbox; i++)
    if (p (c->inbox[i], ctx)) return wc_take (c, i);
  for (;;)
    {
      wmsg *r; int left = timeout_ms - (wire_ms () - start), rc;
      if (left < 0) left = 0;
      rc = read_msg (c, &r, left);
      if (rc <= 0) return NULL;
      if (p (r, ctx)) return r;
      inbox_add (c, r);
    }
}

struct sigctx { int type; const char *member; const char *arg0; };
static int sig_pred (const wmsg *m, void *x)
{
  struct sigctx *s = x; int ok;
  if (m->type != s->type) return 0;
  if (s->member && (!m->member || strcmp (m->member, s->member))) return 0;
  if (!s->arg0) return 1;
  { char *a = wm_arg_str (m, 0); ok = a && !strcmp (a, s->arg0); free (a); }
  return ok;
}
wmsg *wc_wait_sig (wconn *c, const char *member, int t)
{
  struct sigctx s = { W_SIGNAL, member, NULL };
  return wc_wait (c, sig_pred, &s, t);
}
wmsg *wc_wait_sig_arg0 (wconn *c, const char *member, const char *a0, int t)
{
  struct sigctx s = { W_SIGNAL, member, a0 };
  return wc_wait (c, sig_pred, &s, t);
}
wmsg *wc_wait_call (wconn *c, const char *member, int t)
{
  struct sigctx s = { W_CALL, member, NULL };
  return wc_wait (c, sig_pred, &s, t);
}

int wc_drain (wconn *c, int ms)
{
  int start = wire_ms ();
  for (;;)
    {
      wmsg *r; int left = ms - (wire_ms () - start), rc;
      if (left < 0) left = 0;
      rc = read_msg (c, &r, left);
      if (rc <= 0) break;
      inbox_add (c, r);
    }
  return c->ninbox;
}

int wc_silent (wconn *c, int ms)
{
  int before = c->ninbox;
  wc_drain (c, ms);
  return c->ninbox == before && !c->eof;
}

int wc_wait_eof (wconn *c, int timeout_ms)
{
  int start = wire_ms ();
  for (;;)
    {
      int left = timeout_ms - (wire_ms () - start), r;
      if (left < 0) left = 0;
      if (c->eof) return 1;
      r = fill (c, left);
      if (r < 0) return 1;
      if (r == 0 && left == 0) return 0;
      /* discard whatever arrived */
      c->rlen = 0;
    }
}

int wc_inbox_find (wconn *c, int type, const char *member, const char *arg0)
{
  struct sigctx s = { type, member, arg0 };
  for (int i = 0; i < c->ninbox; i++)
    if (sig_pred (c->inbox[i], &s)) return i;
  return -1;
}

/* ------------------------------------------------------------- helpers */

const char *wc_errname (const wmsg *r) { return r && r->type == W_ERROR ? r->errname : NULL; }

int wc_bus (wconn *c, wmsg *m, wmsg **reply)
{
  wmsg *r = NULL; int t = wc_call (c, m, &r, 5000);
  wm_free (m);
  c->err[0] = 0;
  if (t == W_RETURN) { if (reply) *reply = r; else wm_free (r); return 0; }
  if (t == W_ERROR) snprintf (c->err, sizeof c->err, "%s", r->errname ? r->errname : "?");
  else snprintf (c->err, sizeof c->err, "(%s)", t == 0 ? "timeout" : "eof");
  wm_free (r);
  if (reply) *reply = NULL;
  return -1;
}

int wc_hello (wconn *c)
{
  wmsg *r = NULL;
  if (wc_bus (c, wm_bus ("Hello", ""), &r)) return -1;
  { char *s = wm_arg_str (r, 0); if (s) { snprintf (c->unique, sizeof c->unique, "%s", s); free (s); } }
  wm_free (r);
  return c->unique[0] ? 0 : -1;
}

static int u32_result (wconn *c, wmsg *m)
{
  wmsg *r = NULL; uint32_t v = 0; int ok;
  if (wc_bus (c, m, &r)) return -1;
  ok = wm_arg_u32 (r, 0, &v);
  wm_free (r);
  return ok ? (int) v : -1;
}

int wc_request_name (wconn *c, const char *n, uint32_t f)
{ return u32_result (c, wm_bus ("RequestName", "su", n, f)); }
int wc_release_name (wconn *c, const char *n)
{ return u32_result (c, wm_bus ("ReleaseName", "s", n)); }
int wc_add_match (wconn *c, const char *r)
{ return wc_bus (c, wm_bus ("AddMatch", "s", r), NULL); }
int wc_remove_match (wconn *c, const char *r)
{ return wc_bus (c, wm_bus ("RemoveMatch", "s", r), NULL); }
int wc_name_has_owner (wconn *c, const char *n)
{ int v = u32_result (c, wm_bus ("NameHasOwner", "s", n)); return v; }
char *wc_get_name_owner (wconn *c, const char *n)
{
  wmsg *r = NULL; char *s;
  if (wc_bus (c, wm_bus ("GetNameOwner", "s", n), &r)) return NULL;
  s = wm_arg_str (r, 0); wm_free (r);
  return s;
}

void wc_reply_empty (wconn *c, const wmsg *call)
{
  wmsg *r = wm_return (call);
  wc_send (c, r); wm_free (r);
}

int wc_ping (wconn *c, const char *dest)
{
  return wc_bus (c, wm_call_args (dest, "/", "org.freedesktop.DBus.Peer", "Ping", ""), NULL);
}

int wc_sync (wconn *c) { return wc_ping (c, "org.freedesktop.DBus"); }

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Malformed and unusual messages. A message the bus cannot parse makes it
 * drop that one connection; everybody else must be unaffected. */

#include "t.h"

static tdaemon *D;
static wconn *B;           /* bystander */
static int probe;          /* TV_PROBE=1: only print what happened */

/* Description of a message to build. NULL strings are left out. */
typedef struct {
  int endian, type, flags, version;
  uint32_t serial;
  const char *path, *iface, *member, *err, *dest, *sig;
  int has_rs; uint32_t rs;
  wbuf extra;            /* raw additional header fields */
  wbuf body;
  long body_len;         /* override of the declared body length, -1: real */
  long fields_len;       /* override of the declared fields length, -1 */
  int pad_garbage;       /* non-zero bytes in the padding after the fields */
} M;

static void m_init (M *m)
{
  memset (m, 0, sizeof *m);
  m->endian = 'l'; m->type = W_CALL; m->version = 1; m->serial = 1;
  m->path = "/org/freedesktop/DBus"; m->iface = "org.freedesktop.DBus";
  m->member = "GetId"; m->dest = "org.freedesktop.DBus";
  m->body_len = -1; m->fields_len = -1;
}

static void m_build (M *m, wbuf *out)
{
  wbuf f = { 0 }; int e = m->endian;
  if (m->path) wf_str (&f, e, WF_PATH, 'o', m->path);
  if (m->iface) wf_str (&f, e, WF_IFACE, 's', m->iface);
  if (m->member) wf_str (&f, e, WF_MEMBER, 's', m->member);
  if (m->err) wf_str (&f, e, WF_ERRNAME, 's', m->err);
  if (m->has_rs) wf_u32 (&f, e, WF_REPLYSERIAL, m->rs);
  if (m->dest) wf_str (&f, e, WF_DEST, 's', m->dest);
  if (m->sig) wf_sig (&f, e, WF_SIG, m->sig);
  if (m->extra.len) { wbuf_pad (&f, 8); wbuf_put (&f, m->extra.d, m->extra.len); }
  wm_encode_raw (e, m->type, m->flags, m->version, m->serial, &f, m->body.d,
                 m->body.len, out);
  /* patch declared lengths when asked */
  if (m->body_len >= 0 || m->fields_len >= 0)
    {
      uint32_t bl = m->body_len >= 0 ? (uint32_t) m->body_len : (uint32_t) m->body.len;
      uint32_t fl = m->fields_len >= 0 ? (uint32_t) m->fields_len : (uint32_t) f.len;
      for (int i = 0; i < 4; i++)
        {
          out->d[4 + (e == 'l' ? i : 3 - i)] = (bl >> (8 * i)) & 0xff;
          out->d[12 + (e == 'l' ? i : 3 - i)] = (fl >> (8 * i)) & 0xff;
        }
    }
  if (m->pad_garbage)
    {
      size_t end = 16 + f.len, pad = ((end + 7) & ~(size_t) 7) - end;
      for (size_t i = 0; i < pad; i++) out->d[end + i] = 0x55;
    }
  wbuf_free (&f);
}

static void body_str (M *m, const void *s, size_t n, int nul)
{
  /* a raw string argument: length, bytes, optional terminator */
  uint8_t z = 0; uint32_t l = (uint32_t) n;
  wbuf_free (&m->body);
  wbuf_put (&m->body, &l, 4); wbuf_put (&m->body, s, n);
  if (nul) wbuf_put (&m->body, &z, 1);
  m->member = "NameHasOwner"; m->sig = "s";
}

/* Send the bytes on a fresh client, return a classification. */
static const char *run (const void *bytes, size_t len, int settle_ms)
{
  static char cls[16]; int k = 0; wconn *a = th_client (D); wmsg *r;
  cls[0] = 0;
  if (!a) return "?noclient";
  wc_send_raw (a, bytes, len);
  { wmsg *p = wm_bus ("GetId", ""); wc_send (a, p); wm_free (p); }  /* marker after the attack */
  for (;;)
    {
      int rc = wc_recv (a, &r, settle_ms);
      if (rc == 1)
        {
          if (r->type == W_ERROR && k < 12) cls[k++] = 'E';
          else if (r->type == W_RETURN && k < 12) cls[k++] = 'R';
          wm_free (r);
          continue;
        }
      if (rc == 0) { /* alive, nothing more */ break; }
      cls[k++] = 'D'; break;
    }
  cls[k] = 0;
  wc_close (a);
  if (!k) strcpy (cls, "-");
  return cls;
}

/* want: set of acceptable classifications, e.g. "D" or "ER|R" */
static void expect (const char *name, M *m, const char *want)
{
  wbuf b = { 0 }; const char *got; int ok = 0; char w[64], *tok, *sv;
  m_build (m, &b);
  got = run (b.d, b.len, 700);
  wbuf_free (&b);
  if (probe) { fprintf (stderr, "PROBE %-50s -> %s\n", name, got); return; }
  snprintf (w, sizeof w, "%s", want);
  for (tok = strtok_r (w, "|", &sv); tok; tok = strtok_r (NULL, "|", &sv))
    if (strcmp (tok, got) == 0) ok = 1;
  T (ok, "%s: %s (got '%s')", name, want, got);
  T (wc_sync (B) == 0, "bystander unaffected by '%s'", name);
}

/* raw prefix: arbitrary bytes */
static void expect_raw (const char *name, const void *p, size_t n, const char *want)
{
  const char *got = run (p, n, 700); int ok = 0; char w[64], *tok, *sv;
  if (probe) { fprintf (stderr, "PROBE %-50s -> %s\n", name, got); return; }
  snprintf (w, sizeof w, "%s", want);
  for (tok = strtok_r (w, "|", &sv); tok; tok = strtok_r (NULL, "|", &sv))
    if (strcmp (tok, got) == 0) ok = 1;
  T (ok, "%s: %s (got '%s')", name, want, got);
  T (wc_sync (B) == 0, "bystander unaffected by '%s'", name);
}

#define CASE(name, want, ...) do { M m; m_init (&m); { __VA_ARGS__; } expect (name, &m, want); wbuf_free (&m.extra); wbuf_free (&m.body); } while (0)

static void field_u32_raw (wbuf *f, int code, char type, uint32_t v)
{
  uint8_t hd[4] = { (uint8_t) code, 1, (uint8_t) type, 0 };
  wbuf_pad (f, 8); wbuf_put (f, hd, 4); wbuf_pad (f, 4); wbuf_put (f, &v, 4);
}

MAIN_BEGIN ("t_Validation")
  probe = getenv ("TV_PROBE") != NULL;
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  B = th_client (D);

  /* --- control: the base message is fine */
  CASE ("valid GetId", "RR", );
  CASE ("valid big-endian GetId", "RR", m.endian = 'B');
  CASE ("flags: every bit set (unknown bits are ignored)", "RR", m.flags = 0xf8 | W_F_NOAUTOSTART | W_F_ALLOWINTERACT);
  CASE ("unknown header field code 77 (type u) is ignored", "RR", field_u32_raw (&m.extra, 77, 'u', 5));
  CASE ("unknown header field code 255 (type u) is ignored", "RR", field_u32_raw (&m.extra, 255, 'u', 5));
  CASE ("message type 6 (unknown) is ignored", "R|ER", m.type = 6);
  CASE ("message type 200 (unknown) is ignored", "R|ER", m.type = 200);

  /* --- fixed header */
  { M m; wbuf b = { 0 }; m_init (&m); m_build (&m, &b); b.d[0] = 'x'; expect_raw ("endianness byte 'x'", b.d, b.len, "D"); wbuf_free (&b); }
  CASE ("protocol version 0", "D", m.version = 0);
  CASE ("protocol version 2", "D", m.version = 2);
  CASE ("protocol version 255", "D", m.version = 255);
  CASE ("message type 0 (invalid)", "D", m.type = 0);
  CASE ("serial 0", "D", m.serial = 0);
  CASE ("serial 0xffffffff", "RR", m.serial = 0xffffffffu);
  CASE ("body length declared 200 MiB", "D", m.body_len = 200u << 20);
  CASE ("body length declared 0xffffffff", "D", m.body_len = 0xffffffffL);
  CASE ("body length declared 128 MiB + 1", "D", m.body_len = (128L << 20) + 1);
  CASE ("fields length declared 0xffffffff", "D", m.fields_len = 0xffffffffL);
  CASE ("fields length declared 64 MiB + 1", "D", m.fields_len = (64L << 20) + 1);

  /* --- required header fields */
  CASE ("method call without PATH", "D", m.path = NULL);
  CASE ("method call without MEMBER", "D", m.member = NULL);
  CASE ("method call with neither PATH nor MEMBER", "D", m.path = NULL; m.member = NULL);
  CASE ("signal without PATH", "D", m.type = W_SIGNAL; m.path = NULL; m.dest = NULL);
  CASE ("signal without INTERFACE", "D", m.type = W_SIGNAL; m.iface = NULL; m.dest = NULL);
  CASE ("signal without MEMBER", "D", m.type = W_SIGNAL; m.member = NULL; m.dest = NULL);
  CASE ("method return without REPLY_SERIAL", "D", m.type = W_RETURN; m.path = m.iface = m.member = NULL);
  CASE ("error without REPLY_SERIAL", "D", m.type = W_ERROR; m.err = "a.b.C"; m.path = m.iface = m.member = NULL);
  CASE ("error without ERROR_NAME", "D", m.type = W_ERROR; m.has_rs = 1; m.rs = 1; m.path = m.iface = m.member = NULL);
  CASE ("empty header field array", "D", m.path = m.iface = m.member = m.dest = NULL);
  CASE ("method return to a peer that does not exist", "ER|R", m.type = W_RETURN; m.has_rs = 1; m.rs = 3; m.path = m.iface = m.member = NULL; m.dest = ":1.9999");

  /* --- invalid header field contents */
  CASE ("PATH 'foo' (not absolute)", "D", m.path = "foo");
  CASE ("PATH '/foo/' (trailing slash)", "D", m.path = "/foo/");
  CASE ("PATH '//' ", "D", m.path = "//");
  CASE ("PATH '/foo//bar'", "D", m.path = "/foo//bar");
  CASE ("PATH '/foo-bar'", "D", m.path = "/foo-bar");
  CASE ("PATH '' (empty)", "D", m.path = "");
  CASE ("PATH '/' is valid", "RR", m.path = "/");
  CASE ("PATH '/a_b/C1' is valid", "RR", m.path = "/a_b/C1");
  CASE ("INTERFACE 'nodots'", "D", m.iface = "nodots");
  CASE ("INTERFACE '.a.b'", "D", m.iface = ".a.b");
  CASE ("INTERFACE 'a..b'", "D", m.iface = "a..b");
  CASE ("INTERFACE 'a.1b'", "D", m.iface = "a.1b");
  CASE ("INTERFACE 'a.b-c'", "D", m.iface = "a.b-c");
  CASE ("INTERFACE ''", "D", m.iface = "");
  CASE ("MEMBER ''", "D", m.member = "");
  CASE ("MEMBER '1abc'", "D", m.member = "1abc");
  CASE ("MEMBER 'a.b'", "D", m.member = "a.b");
  CASE ("MEMBER 'a-b'", "D", m.member = "a-b");
  CASE ("MEMBER of 256 characters", "D", char big[260]; memset (big, 'a', 256); big[256] = 0; m.member = strdup (big));
  CASE ("MEMBER of 255 characters is valid", "ER", char big[260]; memset (big, 'a', 255); big[255] = 0; m.member = strdup (big));
  CASE ("INTERFACE of 256 characters", "D", char big[300]; memset (big, 'a', 256); big[0] = 'a'; big[1] = '.'; big[256] = 0; m.iface = strdup (big));
  CASE ("DESTINATION 'nodots'", "D", m.dest = "nodots");
  CASE ("DESTINATION ''", "D", m.dest = "");
  CASE ("DESTINATION 'a..b'", "D", m.dest = "a..b");
  CASE ("DESTINATION ':'", "ER|D", m.dest = ":");
  CASE ("DESTINATION of 256 characters", "D", char big[300]; memset (big, 'a', 256); big[1] = '.'; big[256] = 0; m.dest = strdup (big));
  CASE ("ERROR_NAME 'nodots'", "D", m.type = W_ERROR; m.err = "nodots"; m.has_rs = 1; m.rs = 1; m.path = m.iface = m.member = NULL; m.dest = ":1.1");
  CASE ("duplicate PATH field", "D", wf_str (&m.extra, 'l', WF_PATH, 'o', "/other"));
  CASE ("duplicate MEMBER field", "D", wf_str (&m.extra, 'l', WF_MEMBER, 's', "Other"));
  CASE ("header field code 0", "D", field_u32_raw (&m.extra, 0, 'u', 1));
  CASE ("PATH sent with type 's' instead of 'o'", "D", m.path = NULL; wf_str (&m.extra, 'l', WF_PATH, 's', "/org/freedesktop/DBus"));
  CASE ("MEMBER sent with type 'u'", "D", m.member = NULL; field_u32_raw (&m.extra, WF_MEMBER, 'u', 1));
  CASE ("REPLY_SERIAL 0 in a method return", "D", m.type = W_RETURN; m.has_rs = 1; m.rs = 0; m.path = m.iface = m.member = NULL; m.dest = ":1.1");
  CASE ("SIGNATURE header field of a wrong type 'u'", "D", field_u32_raw (&m.extra, WF_SIG, 'u', 1));
  CASE ("UNIX_FDS field with a string type", "D", wf_str (&m.extra, 'l', WF_UNIXFDS, 's', "1"));

  /* --- padding */
  CASE ("non-zero padding between header fields and body", "D", m.pad_garbage = 1; m.body_len = -1; m.sig = "u"; { uint32_t v = 1; wbuf_put (&m.body, &v, 4); m.member = "ListQueuedOwners"; });
  CASE ("body smaller than the signature demands", "D", m.sig = "s"; m.member = "NameHasOwner");
  CASE ("body present but no signature", "D", { uint32_t v = 0; wbuf_put (&m.body, &v, 4); });
  CASE ("signature without body bytes (u)", "D", m.sig = "u"; m.member = "ReleaseName");
  CASE ("extra trailing body bytes after a valid body", "D", body_str (&m, "no.such.name", 12, 1); wbuf_put (&m.body, "\0\0\0\0", 4));

  /* --- signatures */
  CASE ("SIGNATURE 'z' (unknown type)", "D", m.sig = "z");
  CASE ("SIGNATURE '(' unclosed", "D", m.sig = "(");
  CASE ("SIGNATURE '(s' unclosed", "D", m.sig = "(s");
  CASE ("SIGNATURE 'a' without element", "D", m.sig = "a");
  CASE ("SIGNATURE 'a{ss' unclosed", "D", m.sig = "a{ss");
  CASE ("SIGNATURE '{ss}' outside an array", "D", m.sig = "{ss}");
  CASE ("SIGNATURE 'a{s}' (one member)", "D", m.sig = "a{s}");
  CASE ("SIGNATURE 'a{vs}' (variant key)", "D", m.sig = "a{vs}");
  CASE ("SIGNATURE '()' (empty struct)", "D", m.sig = "()");
  CASE ("SIGNATURE ')' alone", "D", m.sig = ")");
  CASE ("SIGNATURE 'a{sss}'", "D", m.sig = "a{sss}");
  CASE ("SIGNATURE 'r' and 'e' (reserved)", "D", m.sig = "r");
  CASE ("SIGNATURE of 33 nested arrays", "D", char s[80]; memset (s, 'a', 33); s[33] = 'y'; s[34] = 0; m.sig = strdup (s));
  CASE ("SIGNATURE of 33 nested structs", "D", char s[80]; for (int i = 0; i < 33; i++) s[i] = '('; s[33] = 'y'; for (int i = 0; i < 33; i++) s[34 + i] = ')'; s[67] = 0; m.sig = strdup (s));
  CASE ("SIGNATURE of 32 nested arrays is the maximum", "ER|D", char s[80]; memset (s, 'a', 32); s[32] = 'y'; s[33] = 0; m.sig = strdup (s); { uint32_t z = 0; wbuf_put (&m.body, &z, 4); m.member = "ListNames"; });
  CASE ("SIGNATURE longer than 255 bytes", "D", { char *s = malloc (300); memset (s, 'y', 299); s[299] = 0; wbuf f = { 0 }; (void) f; m.sig = s; });

  /* --- string bodies */
  CASE ("string argument valid", "RR", body_str (&m, "no.such.name", 12, 1));
  CASE ("string argument not NUL terminated", "D", body_str (&m, "no.such.name", 12, 0); wbuf_put (&m.body, "X", 1));
  CASE ("string argument NUL replaced by 'X'", "D", body_str (&m, "no.such.name", 12, 0); wbuf_put (&m.body, "X", 1));
  CASE ("string argument with an embedded NUL", "D", body_str (&m, "no.such\0name", 12, 1));
  CASE ("string argument length beyond the body", "D", body_str (&m, "no.such.name", 12, 1); m.body.d[0] = 200);
  CASE ("string argument length 0xffffffff", "D", body_str (&m, "no.such.name", 12, 1); memset (m.body.d, 0xff, 4));
  CASE ("string with invalid UTF-8 (lone continuation 0x80)", "D", body_str (&m, "no.\x80.name", 9, 1));
  CASE ("string with invalid UTF-8 (0xff)", "D", body_str (&m, "no.\xff.name", 9, 1));
  CASE ("string with truncated 2-byte sequence", "D", body_str (&m, "no.such\xc3", 8, 1));
  CASE ("string with overlong encoding of '/' (c0 af)", "D", body_str (&m, "a\xc0\xaf" "b", 4, 1));
  CASE ("string with overlong encoding of NUL (c0 80)", "D", body_str (&m, "a\xc0\x80" "b", 4, 1));
  CASE ("string with UTF-16 surrogate (ed a0 80)", "D", body_str (&m, "a\xed\xa0\x80" "b", 5, 1));
  CASE ("string with code point above U+10FFFF (f4 90 80 80)", "D", body_str (&m, "a\xf4\x90\x80\x80" "b", 6, 1));
  CASE ("string with 5-byte sequence (f8 88 80 80 80)", "D", body_str (&m, "a\xf8\x88\x80\x80\x80" "b", 7, 1));
  CASE ("string with valid multi-byte UTF-8 (ae, euro, emoji)", "RR", body_str (&m, "x\xc3\xa4\xe2\x82\xac\xf0\x9f\x98\x80", 10, 1));
  CASE ("string with U+FFFF noncharacter", "RR|D", body_str (&m, "x\xef\xbf\xbf", 4, 1));
  CASE ("string with U+10FFFF", "RR|D", body_str (&m, "x\xf4\x8f\xbf\xbf", 5, 1));

  /* --- other body types */
  CASE ("object path argument valid", "ER", m.sig = "o"; m.member = "GetNameOwner"; { uint32_t l = 4; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "/a/b\0", 5); });
  CASE ("object path argument invalid ('a/b')", "D", m.sig = "o"; m.member = "GetNameOwner"; { uint32_t l = 3; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "a/b\0", 4); });
  CASE ("object path argument invalid ('/a/')", "D", m.sig = "o"; m.member = "GetNameOwner"; { uint32_t l = 3; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "/a/\0", 4); });
  CASE ("signature argument valid", "ER", m.sig = "g"; m.member = "GetNameOwner"; { uint8_t l = 2; wbuf_put (&m.body, &l, 1); wbuf_put (&m.body, "su\0", 3); });
  CASE ("signature argument invalid ('z')", "D", m.sig = "g"; m.member = "GetNameOwner"; { uint8_t l = 1; wbuf_put (&m.body, &l, 1); wbuf_put (&m.body, "z\0", 2); });
  CASE ("signature argument not NUL terminated", "D", m.sig = "g"; m.member = "GetNameOwner"; { uint8_t l = 1; wbuf_put (&m.body, &l, 1); wbuf_put (&m.body, "sX", 2); });
  CASE ("boolean 2", "D", m.sig = "b"; m.member = "GetNameOwner"; { uint32_t v = 2; wbuf_put (&m.body, &v, 4); });
  CASE ("boolean 1 is valid", "ER", m.sig = "b"; m.member = "GetNameOwner"; { uint32_t v = 1; wbuf_put (&m.body, &v, 4); });
  CASE ("boolean 0xffffffff", "D", m.sig = "b"; m.member = "GetNameOwner"; { uint32_t v = 0xffffffffu; wbuf_put (&m.body, &v, 4); });
  CASE ("padding byte before a u32 not zero (yu)", "D", m.sig = "yu"; m.member = "GetNameOwner"; { uint8_t y = 1; wbuf_put (&m.body, &y, 1); wbuf_put (&m.body, "\1\1\1", 3); uint32_t v = 7; wbuf_put (&m.body, &v, 4); });
  CASE ("yu with zero padding", "ER", m.sig = "yu"; m.member = "GetNameOwner"; { uint8_t y = 1; wbuf_put (&m.body, &y, 1); wbuf_put (&m.body, "\0\0\0", 3); uint32_t v = 7; wbuf_put (&m.body, &v, 4); });
  CASE ("array of u32 with length not a multiple of 4", "D", m.sig = "au"; m.member = "GetNameOwner"; { uint32_t l = 3; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0", 3); });
  CASE ("array length beyond the body", "D", m.sig = "au"; m.member = "GetNameOwner"; { uint32_t l = 400; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0\0", 4); });
  CASE ("array length 64 MiB + 4 (above the maximum)", "D", m.sig = "au"; m.member = "GetNameOwner"; { uint32_t l = (64u << 20) + 4; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0\0", 4); });
  CASE ("array length 0xffffffff", "D", m.sig = "au"; m.member = "GetNameOwner"; { uint32_t l = 0xffffffffu; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0\0", 4); });
  CASE ("array of 8-byte elements without the padding after the length", "D", m.sig = "ax"; m.member = "GetNameOwner"; { uint32_t l = 8; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\1\0\0\0\0\0\0\0", 8); });
  CASE ("array of 8-byte elements with garbage in the padding", "D", m.sig = "ax"; m.member = "GetNameOwner"; { uint32_t l = 8; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\7\7\7\7", 4); wbuf_put (&m.body, "\1\0\0\0\0\0\0\0", 8); });
  CASE ("empty array of 8-byte elements, padding present", "ER", m.sig = "ax"; m.member = "GetNameOwner"; { uint32_t l = 0; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0\0", 4); });
  CASE ("empty array of 8-byte elements, padding missing", "D", m.sig = "ax"; m.member = "GetNameOwner"; { uint32_t l = 0; wbuf_put (&m.body, &l, 4); });
  CASE ("variant with an empty signature", "D", m.sig = "v"; m.member = "GetNameOwner"; { wbuf_put (&m.body, "\0\0", 2); });
  CASE ("variant with two complete types ('ss')", "D", m.sig = "v"; m.member = "GetNameOwner"; { wbuf_put (&m.body, "\2ss\0", 4); wbuf_put (&m.body, "\1\0\0\0a\0\0\0\1\0\0\0b\0", 15); });
  CASE ("variant with an invalid signature ('z')", "D", m.sig = "v"; m.member = "GetNameOwner"; { wbuf_put (&m.body, "\1z\0\0", 4); });
  CASE ("variant with a valid payload", "ER", m.sig = "v"; m.member = "GetNameOwner"; { wbuf_put (&m.body, "\1y\0\5", 4); });
  CASE ("variant nested 65 deep", "D", m.sig = "v"; m.member = "GetNameOwner"; { for (int i = 0; i < 65; i++) wbuf_put (&m.body, "\1v\0", 3); wbuf_put (&m.body, "\1y\0\5", 4); });
  CASE ("struct padding not zero", "D", m.sig = "(yy)"; m.member = "GetNameOwner"; { wbuf_put (&m.body, "\1\1\1\1\1\1\1\1", 8); wbuf_put (&m.body, "\1\1", 2); });
  CASE ("dict entry with a bad string inside", "D", m.sig = "a{ss}"; m.member = "GetNameOwner"; { uint32_t l = 16; wbuf_put (&m.body, &l, 4); wbuf_put (&m.body, "\0\0\0\0", 4); uint32_t sl = 1; wbuf_put (&m.body, &sl, 4); wbuf_put (&m.body, "\x80\0", 2); wbuf_put (&m.body, "\0\0", 2); sl = 1; wbuf_put (&m.body, &sl, 4); wbuf_put (&m.body, "v\0", 2); });

  /* --- truncated and partial input */
  { M m; wbuf b = { 0 }; m_init (&m); m_build (&m, &b);
    { wconn *a = th_client (D); wc_send_raw (a, b.d, 10);
      T (wc_silent (a, 400), "half a header: the daemon waits");
      wc_send_raw (a, b.d + 10, b.len - 10);
      { wmsg *r = NULL; T (wc_recv (a, &r, 2000) == 1 && r->type == W_RETURN, "rest of the message arrives later: answered"); wm_free (r); }
      wc_close (a); }
    { wconn *a = th_client (D); wc_send_raw (a, b.d, b.len - 1); wc_close (a); }
    T (wc_sync (B) == 0, "bystander fine after a message cut off by a close");
    { wconn *a = th_client (D); wc_send_raw (a, b.d, 3); wc_close (a); }
    T (wc_sync (B) == 0, "bystander fine after a header cut off by a close");
    wbuf_free (&b); }
  { /* a valid message followed by garbage: first is answered, then dropped */
    M m; wbuf b = { 0 }; wconn *a = th_client (D); wmsg *r = NULL; m_init (&m); m_build (&m, &b);
    wbuf_put (&b, "garbage garbage garbage garbage", 31);
    wc_send_raw (a, b.d, b.len);
    int got = wc_recv (a, &r, 2000); int ret = got == 1 && r->type == W_RETURN; wm_free (r);
    T (ret || wc_wait_eof (a, 1000), "valid message then garbage: answered or dropped");
    T (wc_wait_eof (a, 2000), "valid message then garbage: the connection is dropped");
    wc_close (a); wbuf_free (&b); }
  { char junk[4096]; for (int i = 0; i < 4096; i++) junk[i] = (char) (i * 131 + 7);
    expect_raw ("4 KiB of pseudo-random bytes", junk, sizeof junk, "D"); }
  { char z[64] = { 0 }; expect_raw ("64 zero bytes", z, sizeof z, "D"); }
  { char t[16] = "l\1\0\1\0\0\0\0\1\0\0\0"; expect_raw ("12 byte start of a header, then silence", t, 12, "-"); }

  /* --- sender header handling (client supplied SENDER is overwritten) */
  { wconn *a = th_client (D), *b = th_client (D); wmsg *m, *got;
    wc_add_match (b, "type='signal',interface='t.Validation'"); wc_sync (b);
    m = wm_signal ("/x", "t.Validation", "S"); wm_setstr (&m->sender, ":1.31337"); wc_send (a, m); wm_free (m);
    got = wc_wait_sig (b, "S", 2000);
    T (got && STREQ (got->sender, a->unique), "bogus SENDER from a client is replaced by the bus (%s)", got ? got->sender : "-");
    wm_free (got);
    m = wm_signal ("/x", "t.Validation", "S"); wm_setstr (&m->sender, "not a name!"); wc_send (a, m); wm_free (m);
    got = wc_wait_sig (b, "S", 1000);
    T (got ? STREQ (got->sender, a->unique) : 1, "SENDER that is not even a valid name: replaced, or the connection dropped");
    wm_free (got);
    wc_close (a); wc_close (b); }

  T (th_healthy (D), "daemon healthy after the whole zoo");
  T (th_alive (D), "daemon still running");
  wc_close (B);
  th_stop (D);
MAIN_END

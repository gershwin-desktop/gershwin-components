/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* SASL authentication phase: every command, malformed input, ordering. */

#include "t.h"

static tdaemon *D;

/* Next line from the server, "" on timeout, "<EOF>" when closed. */
static const char *L (wconn *c, int ms)
{
  static char buf[8][1100]; static int i;
  char *b = buf[i++ & 7];
  int n = wc_read_line (c, b, 1100, ms);
  if (n == -1) strcpy (b, "<TIMEOUT>");
  else if (n == -2) strcpy (b, "<EOF>");
  return b;
}
static int starts (const char *s, const char *p) { return strncmp (s, p, strlen (p)) == 0; }
static int is_ok_line (const char *s)
{
  if (!starts (s, "OK ") || strlen (s) != 35) return 0;
  for (int i = 3; i < 35; i++)
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  return 1;
}
static wconn *R (void) { return th_raw (D); }
/* raw connection that already sent the NUL byte */
static wconn *N (void) { wconn *c = th_raw (D); wc_send_nul (c); return c; }
static char *ext (void)
{
  static char b[128]; char *h = wc_uidhex ();
  snprintf (b, sizeof b, "AUTH EXTERNAL %s", h); free (h);
  return b;
}
/* After a mishap on c, is the line still usable for a complete login? */
static int can_login (wconn *c)
{
  wc_send_line (c, ext ());
  if (!is_ok_line (L (c, 3000))) return 0;
  wc_send_line (c, "BEGIN");
  return wc_hello (c) == 0;
}
static int closed (wconn *c) { return wc_wait_eof (c, 2000); }

MAIN_BEGIN ("t_Sasl")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *c; const char *l; char guid1[64], guid2[64];

  /* --- the happy paths */
  c = N (); wc_send_line (c, ext ()); l = L (c, 3000);
  T (is_ok_line (l), "AUTH EXTERNAL with initial response answers OK <32 hex guid>");
  snprintf (guid1, sizeof guid1, "%s", l);
  wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "Hello works after BEGIN"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); l = L (c, 3000); snprintf (guid2, sizeof guid2, "%s", l);
  T (strcmp (guid1, guid2) == 0, "server GUID is stable across connections"); wc_close (c);

  c = N (); wc_send_line (c, "AUTH EXTERNAL"); T (strcmp (L (c, 3000), "DATA") == 0, "AUTH EXTERNAL without response asks DATA");
  { char b[100], *h = wc_uidhex (); snprintf (b, sizeof b, "DATA %s", h); free (h); wc_send_line (c, b); }
  T (is_ok_line (L (c, 3000)), "DATA <uid hex> then OK"); wc_send_line (c, "BEGIN");
  T (wc_hello (c) == 0, "Hello after two-step EXTERNAL"); wc_close (c);

  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "DATA");
  T (is_ok_line (L (c, 3000)), "empty DATA after AUTH EXTERNAL means 'the credentials of the socket'");
  wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "Hello works"); wc_close (c);

  c = R (); T (wc_auth (c, WA_EXTERNAL) == 0 && wc_hello (c) == 0, "wc_auth EXTERNAL works"); wc_close (c);
  c = R (); T (wc_auth (c, WA_EXTERNAL_NOINIT) == 0 && wc_hello (c) == 0, "wc_auth EXTERNAL_NOINIT works"); wc_close (c);

  /* --- ANONYMOUS: the test config of the real daemon allows it, minibus never does */
  if (th_is_real ()) {
    c = N (); wc_send_line (c, "AUTH ANONYMOUS"); T (is_ok_line (L (c, 3000)), "AUTH ANONYMOUS without trace is accepted");
    wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "Hello works for an anonymous client");
    { wconn *e = th_client (D);
      wmsg *r = NULL; int t = tcall (e, wm_bus ("GetConnectionUnixUser", "s", c->unique), &r);
      T (t == W_ERROR || t == W_RETURN, "GetConnectionUnixUser of an anonymous peer is answered");
      wm_free (r);
      T (wc_sync (e) == 0 && wc_ping (c, "org.freedesktop.DBus") == 0, "anonymous client can talk");
      wc_close (e); }
    wc_close (c);
    c = N (); wc_send_line (c, "AUTH ANONYMOUS 74657374"); T (is_ok_line (L (c, 3000)), "AUTH ANONYMOUS with trace is accepted");
    wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "Hello works"); wc_close (c);
    c = R (); T (wc_auth (c, WA_ANONYMOUS | WA_FD) == 0 && wc_hello (c) == 0, "ANONYMOUS plus NEGOTIATE_UNIX_FD"); wc_close (c);

  } else {
    c = N (); wc_send_line (c, "AUTH ANONYMOUS"); l = L (c, 3000);
    T (starts (l, "REJECTED"), "minibus: AUTH ANONYMOUS is rejected (%s)", l);
    T (can_login (c), "minibus: EXTERNAL still possible after that"); wc_close (c);
  }

  /* --- rejected mechanisms and credentials */
  c = N (); wc_send_line (c, "AUTH FOO"); l = L (c, 3000);
  T (starts (l, "REJECTED ") && strstr (l, "EXTERNAL"), "unknown mechanism: REJECTED listing EXTERNAL (%s)", l);
  if (th_is_real ()) { T (strstr (l, "ANONYMOUS") != NULL, "real: REJECTED also lists ANONYMOUS (%s)", l); }
  else { T (strstr (l, "ANONYMOUS") == NULL, "minibus: REJECTED lists EXTERNAL only (%s)", l); }
  T (can_login (c), "login still possible after REJECTED"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "AUTH without mechanism: REJECTED (%s)", l); T (can_login (c), "login after bare AUTH"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH DBUS_COOKIE_SHA1 61646d696e"); l = L (c, 3000);
  T (starts (l, "REJECTED") && !strstr (l, "COOKIE"), "DBUS_COOKIE_SHA1 is not offered (%s)", l); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL 31323334"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "EXTERNAL with another uid: REJECTED (%s)", l); T (can_login (c), "login after wrong uid"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "DATA 31323334"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "DATA with another uid: REJECTED (%s)", l); T (can_login (c), "login after wrong DATA"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL zz"); l = L (c, 3000);
  T (starts (l, "ERROR") || starts (l, "REJECTED"), "non-hex argument is refused (%s)", l); T (can_login (c), "login after bad hex"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL 123"); l = L (c, 3000);
  T (starts (l, "ERROR") || starts (l, "REJECTED"), "odd-length hex is refused (%s)", l); T (can_login (c), "login after odd hex"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL 30"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "uid 0 given when we are not 0: REJECTED (%s)", l); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "ERROR"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "client ERROR in the DATA phase: REJECTED (%s)", l); T (can_login (c), "login after client ERROR"); wc_close (c);

  /* --- unknown / malformed command lines */
  const char *junk[] = { "auth EXTERNAL", "FOO BAR", "", "REJECTED", "OK abc", "AGREE_UNIX_FD", "data 00", NULL };
  for (int i = 0; junk[i]; i++)
    {
      c = N (); wc_send_line (c, junk[i]); l = L (c, 3000);
      T (starts (l, "ERROR"), "line '%s' answered with ERROR (%s)", junk[i], l);
      T (can_login (c), "login still possible after '%s'", junk[i]); wc_close (c);
    }
  c = N (); wc_send_line (c, "CANCEL"); T (starts (L (c, 3000), "ERROR"), "CANCEL outside a conversation: ERROR");
  T (can_login (c), "login after stray CANCEL"); wc_close (c);
  c = N (); wc_send_line (c, "DATA 00"); T (starts (L (c, 3000), "ERROR"), "DATA outside a conversation: ERROR"); wc_close (c);
  c = N (); wc_send_line (c, "NEGOTIATE_UNIX_FD"); T (starts (L (c, 3000), "ERROR"), "NEGOTIATE_UNIX_FD before authentication: ERROR");
  T (can_login (c), "login after early NEGOTIATE_UNIX_FD"); wc_close (c);
  c = N (); wc_send_raw (c, "AUTH EXTERNAL\n", 14); l = L (c, 400);
  T (strcmp (l, "<TIMEOUT>") == 0, "a bare LF does not terminate a command (spec requires CRLF)"); wc_close (c);
  c = N (); wc_send_raw (c, "AUTH EXTERNAL\r", 14); T (strcmp (L (c, 400), "<TIMEOUT>") == 0, "CR without LF: nothing happens yet");
  wc_send_raw (c, "\n", 1); T (strcmp (L (c, 3000), "DATA") == 0, "the LF completes the line"); wc_close (c);
  c = N (); wc_send_raw (c, "AUTH EXT\0ERNAL\r\n", 16); T (starts (L (c, 3000), "ERROR"), "NUL inside a line: ERROR"); wc_close (c);
  c = N (); wc_send_raw (c, "\0AUTH EXTERNAL\r\n", 16); T (starts (L (c, 3000), "ERROR"), "second NUL byte in front of a command: ERROR"); wc_close (c);
  c = N (); wc_send_raw (c, "AUTH \xc3\xa4XTERNAL\r\n", 16); l = L (c, 3000);
  T (starts (l, "ERROR") || starts (l, "REJECTED"), "non-ASCII byte in a command is refused (%s)", l); wc_close (c);

  /* --- ordering and state machine */
  c = R (); wc_send_line (c, "AUTH EXTERNAL"); T (strcmp (L (c, 800), "<EOF>") == 0, "first byte not NUL: connection closed"); wc_close (c);
  c = R (); wc_send_raw (c, "A", 1); T (closed (c), "first byte 'A': connection closed"); wc_close (c);
  c = N (); wc_send_line (c, "BEGIN"); T (strcmp (L (c, 2000), "<EOF>") == 0, "BEGIN without OK: connection closed"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "BEGIN");
  T (strcmp (L (c, 2000), "<EOF>") == 0, "BEGIN while still in the DATA exchange: connection closed"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "CANCEL"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "CANCEL during DATA exchange: REJECTED (%s)", l); T (can_login (c), "login after CANCEL"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "CANCEL"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "CANCEL after OK: REJECTED (%s)", l); T (can_login (c), "login after CANCEL following OK"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, ext ()); T (starts (L (c, 3000), "ERROR"), "second AUTH while expecting BEGIN: ERROR");
  wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "connection still completes"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "DATA 00"); T (starts (L (c, 3000), "ERROR"), "DATA while expecting BEGIN: ERROR"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "ERROR"); l = L (c, 3000);
  T (starts (l, "REJECTED"), "client ERROR while expecting BEGIN: REJECTED (%s)", l); T (can_login (c), "login after that"); wc_close (c);
  c = N (); wc_send_line (c, "AUTH EXTERNAL"); L (c, 3000); wc_send_line (c, "AUTH ANONYMOUS"); T (starts (L (c, 3000), "ERROR"), "AUTH during the DATA exchange: ERROR"); wc_close (c);

  /* --- NEGOTIATE_UNIX_FD */
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "NEGOTIATE_UNIX_FD");
  T (strcmp (L (c, 3000), "AGREE_UNIX_FD") == 0, "NEGOTIATE_UNIX_FD after OK: AGREE_UNIX_FD");
  wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "Hello after negotiation"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "NEGOTIATE_UNIX_FD"); L (c, 3000); wc_send_line (c, "NEGOTIATE_UNIX_FD");
  l = L (c, 3000); T (strcmp (l, "AGREE_UNIX_FD") == 0 || starts (l, "ERROR"), "second NEGOTIATE_UNIX_FD answered (%s)", l);
  wc_send_line (c, "BEGIN"); T (wc_hello (c) == 0, "connection still completes"); wc_close (c);
  c = N (); wc_send_line (c, ext ()); L (c, 3000); wc_send_line (c, "BEGIN"); wc_send_line (c, "NEGOTIATE_UNIX_FD");
  T (closed (c), "NEGOTIATE_UNIX_FD after BEGIN is garbage in the message stream: closed"); wc_close (c);

  /* --- splitting and pipelining */
  c = N ();
  { const char *s = "AUTH EXTERNAL\r\n"; for (const char *p = s; *p; p++) { wc_send_raw (c, p, 1); usleep (3000); } }
  T (strcmp (L (c, 3000), "DATA") == 0, "a command split into single bytes works"); wc_close (c);
  c = N (); wc_send_raw (c, "AUTH FOO\r\nAUTH EXTERNAL\r\n", 25);
  l = L (c, 3000); T (starts (l, "REJECTED"), "two commands in one write: first answer (%s)", l);
  T (strcmp (L (c, 3000), "DATA") == 0, "two commands in one write: second answer"); wc_close (c);
  { /* AUTH, BEGIN and Hello all in one write, replies are read later */
    wbuf all = { 0 }, hello = { 0 }; wmsg *m = wm_bus ("Hello", ""); char *h = wc_uidhex (), t[200]; wmsg *r = NULL;
    m->serial = 1; wm_encode (m, &hello); wm_free (m);
    snprintf (t, sizeof t, "AUTH EXTERNAL %s\r\nBEGIN\r\n", h); free (h);
    wbuf_put (&all, "", 1); wbuf_put (&all, t, strlen (t)); wbuf_put (&all, hello.d, hello.len);
    c = R (); wc_send_raw (c, all.d, all.len);
    T (is_ok_line (L (c, 3000)), "pipelined login: OK comes back");
    T (wc_recv (c, &r, 3000) == 1 && r->type == W_RETURN && r->has_reply_serial && r->reply_serial == 1, "pipelined login: Hello reply follows");
    wm_free (r); wbuf_free (&all); wbuf_free (&hello); wc_close (c); }
  c = N (); { char big[100]; memset (big, 'A', sizeof big); wc_send_raw (c, big, sizeof big); }
  T (strcmp (L (c, 400), "<TIMEOUT>") == 0, "100 bytes without a line end: patiently waits"); wc_close (c);

  /* --- limits */
  c = N (); { char *big = malloc (20000); memset (big, 'A', 20000); memcpy (big, "AUTH ", 5); big[19998] = '\r'; big[19999] = '\n';
    wc_send_raw (c, big, 20000); free (big); }
  l = L (c, 3000); T (strcmp (l, "<EOF>") == 0 || starts (l, "ERROR") || starts (l, "REJECTED"), "20000 byte line is refused or closes (%s)", l);
  wc_close (c);
  c = N (); { char *big = malloc (200000); memset (big, 'A', 200000); wc_send_raw (c, big, 200000); free (big); }
  T (closed (c), "200000 bytes without a line end: connection closed"); wc_close (c);
  c = N (); { int dropped = 0;
    for (int i = 0; i < 60 && !dropped; i++)
      {
        if (wc_send_line (c, "AUTH FOO") < 0) { dropped = 1; break; }
        if (strcmp (L (c, 2000), "<EOF>") == 0) dropped = 1;
      }
    T (dropped, "endless failed authentication attempts end with a closed connection (real: after 6)"); }
  wc_close (c);

  /* --- abandoned connections */
  for (int i = 0; i < 20; i++) { c = R (); wc_close (c); }
  for (int i = 0; i < 20; i++) { c = N (); wc_close (c); }
  for (int i = 0; i < 20; i++) { c = N (); wc_send_raw (c, "AUTH EXTER", 10); wc_close (c); }
  for (int i = 0; i < 20; i++) { c = N (); wc_send_line (c, ext ()); wc_close (c); }
  for (int i = 0; i < 20; i++) { c = N (); wc_send_line (c, ext ()); wc_send_line (c, "BEGIN"); wc_close (c); }
  T (th_healthy (D), "daemon healthy after 100 abandoned or half-open connections");
  T (th_alive (D), "daemon still running");

  th_stop (D);
MAIN_END

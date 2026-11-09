/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Hello, unique names, behaviour before registration. */

#include "t.h"

static tdaemon *D;

static int unique_num (const char *u)
{
  if (!is_unique_name (u)) return -1;
  const char *dot = strrchr (u, '.');
  return atoi (dot + 1);
}

MAIN_BEGIN ("t_Hello")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *c, *e; wmsg *r;

  /* --- the Hello exchange itself */
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_bus ("Hello", ""); uint32_t ser;
    ser = wc_send (c, m); wm_free (m);
    T (wc_recv (c, &r, 3000) == 1, "Hello is answered");
    T (r && r->type == W_RETURN, "Hello reply is a method return");
    T (r && r->has_reply_serial && r->reply_serial == ser, "reply_serial matches the call");
    T (r && STREQ (r->sender, "org.freedesktop.DBus"), "reply sender is org.freedesktop.DBus");
    T (r && r->sig && STREQ (r->sig, "s"), "reply signature is s");
    { char *u = r ? wm_arg_str (r, 0) : NULL;
      T (u && is_unique_name (u), "reply body is a unique name (%s)", u ? u : "-");
      T (r && r->dest && u && STREQ (r->dest, u), "reply destination is the new unique name");
      T (u && u[1] >= '0' && u[1] <= '9', "unique name starts with a digit element (%s)", u ? u : "-");
      snprintf (c->unique, sizeof c->unique, "%s", u ? u : "");
      free (u); }
    wm_free (r);
    T (wc_recv (c, &r, 3000) == 1 && r->type == W_SIGNAL, "a signal follows the Hello reply");
    T (r && STREQ (r->member, "NameAcquired") && STREQ (r->iface, "org.freedesktop.DBus"), "it is org.freedesktop.DBus.NameAcquired");
    T (r && STREQ (r->path, "/org/freedesktop/DBus"), "NameAcquired path is /org/freedesktop/DBus");
    T (r && STREQ (r->sender, "org.freedesktop.DBus"), "NameAcquired sender is the bus");
    T (r && STREQ (r->dest, c->unique), "NameAcquired is addressed to the new client");
    { char *a = r ? wm_arg_str (r, 0) : NULL; T (a && STREQ (a, c->unique), "NameAcquired carries the unique name"); free (a); }
    T (r && r->sig && STREQ (r->sig, "s"), "NameAcquired signature is s");
    wm_free (r);
    T (wc_silent (c, 200), "exactly one NameAcquired is sent for the unique name"); }
  wc_close (c);

  /* --- unique names: distinct, increasing, not reused */
  { wconn *cs[40]; int last = -1, ok = 1, inc = 1;
    for (int i = 0; i < 40; i++)
      {
        cs[i] = th_client (D); ok = ok && cs[i];
        if (!cs[i]) continue;
        int n = unique_num (cs[i]->unique);
        if (n <= last) inc = 0;
        last = n;
      }
    T (ok, "40 clients connect"); T (inc, "unique names are strictly increasing");
    { int distinct = 1; for (int i = 0; i < 40; i++) for (int j = i + 1; j < 40; j++) if (cs[i] && cs[j] && STREQ (cs[i]->unique, cs[j]->unique)) distinct = 0;
      T (distinct, "all unique names differ"); }
    T (cs[0] && strncmp (cs[0]->unique, ":1.", 3) == 0, "names look like :1.N (%s)", cs[0] ? cs[0]->unique : "-");
    for (int i = 0; i < 40; i++) wc_close (cs[i]);
    c = th_client (D);
    T (c && unique_num (c->unique) > last, "a name is never reused after disconnects (%s after :1.%d)", c ? c->unique : "-", last);
    wc_close (c); }

  /* --- unique name is a real owner */
  c = th_client (D); e = th_client (D);
  T (wc_name_has_owner (e, c->unique) == 1, "NameHasOwner(unique) is true while connected");
  { char *o = wc_get_name_owner (e, c->unique); T (o && STREQ (o, c->unique), "GetNameOwner(unique) returns itself"); free (o); }
  { wmsg *l = tok (e, wm_bus ("ListNames", "")); char *d = l ? wm_dump (l) : NULL;
    T (d && strstr (d, c->unique) && strstr (d, e->unique) && strstr (d, "\"org.freedesktop.DBus\""), "ListNames has both clients and the bus (%s)", d ? d : "-");
    free (d); wm_free (l); }
  { char gone[128]; snprintf (gone, sizeof gone, "%s", c->unique); wc_close (c);
    for (int i = 0; i < 50 && wc_name_has_owner (e, gone) == 1; i++) usleep (20000);
    T (wc_name_has_owner (e, gone) == 0, "NameHasOwner(unique) false after disconnect");
    T (wc_get_name_owner (e, gone) == NULL && STREQ (e->err, E_NAME_HAS_NO_OWNER), "GetNameOwner of a gone unique name: NameHasNoOwner"); }
  wc_close (e);

  /* --- Hello twice, Hello with garbage */
  c = th_client (D);
  { wmsg *m = wm_bus ("Hello", ""); T (terr (c, m, "org.freedesktop.DBus.Error.Failed"), "second Hello: Failed"); }
  T (wc_sync (c) == 0, "connection survives a second Hello");
  wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  T (terr (c, wm_bus ("Hello", "s", "foo"), E_INVALID_ARGS), "Hello with an argument: InvalidArgs");
  T (wc_hello (c) == 0, "a proper Hello still works afterwards");
  wc_close (c);

  /* --- Hello variants that are accepted */
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", NULL, "Hello");
    T (tcall (c, m, &r) == W_RETURN, "Hello without an interface header is accepted"); wm_free (r); }
  wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_bus ("Hello", ""); m->flags = W_F_NOREPLY; wc_send (c, m); wm_free (m);
    wmsg *n = wc_wait_sig (c, "NameAcquired", 3000);
    T (n != NULL, "Hello with NO_REPLY_EXPECTED still registers (NameAcquired arrives)");
    char *u = n ? wm_arg_str (n, 0) : NULL; T (u && is_unique_name (u), "and carries a unique name");
    /* the real daemon answers Hello anyway: the flag is honoured only for empty replies, so no assertion here */
    free (u); wm_free (n);
    T (wc_sync (c) == 0, "connection works after it"); }
  wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL); wire_endian = 'B';
  { wmsg *m = wm_bus ("Hello", "");
    T (tcall (c, m, &r) == W_RETURN, "Hello from a big-endian client works");
    { char *u = r ? wm_arg_str (r, 0) : NULL; T (u && is_unique_name (u), "big-endian Hello reply is decodable"); free (u); }
    wm_free (r); }
  { wmsg *n = wc_wait_sig (c, "NameAcquired", 3000); T (n != NULL, "NameAcquired reaches a big-endian client"); wm_free (n); }
  wire_endian = 'l'; wc_close (c);

  /* --- before Hello */
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  T (terr (c, wm_bus ("RequestName", "su", "org.t.Early", 0), E_ACCESS_DENIED), "RequestName before Hello: AccessDenied");
  T (terr (c, wm_bus ("ListNames", ""), E_ACCESS_DENIED), "ListNames before Hello: AccessDenied");
  T (terr (c, wm_bus ("GetId", ""), E_ACCESS_DENIED), "GetId before Hello: AccessDenied");
  T (!wc_wait_eof (c, 300), "the connection stays open after those");
  T (wc_hello (c) == 0, "Hello works after the refused calls");
  T (wc_request_name (c, "org.t.Early", 0) == 1, "and the connection is then fully usable");
  wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_call ("org.some.Other", "/", "x.I", "M"); wc_send (c, m); wm_free (m); }
  T (wc_wait_eof (c, 3000), "method call to another peer before Hello: connection dropped"); wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_signal ("/", "x.I", "S"); wc_send (c, m); wm_free (m); }
  T (wc_wait_eof (c, 3000), "signal before Hello: connection dropped"); wc_close (c);
  c = th_raw (D); wc_auth (c, WA_EXTERNAL);
  { wmsg *m = wm_new (W_RETURN, 0); m->has_reply_serial = 1; m->reply_serial = 5; wm_setstr (&m->dest, "org.freedesktop.DBus"); wc_send (c, m); wm_free (m); }
  { int gone = wc_wait_eof (c, 1000); T (gone || wc_hello (c) == 0, "method return before Hello: dropped or ignored"); }
  wc_close (c);
  T (th_healthy (D), "daemon healthy after all this");

  th_stop (D);
MAIN_END

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Message routing: unicast, broadcast, errors, ordering, sizes, framing. */

#include "t.h"

static tdaemon *D;

static void all_types (wmsg *m)
{
  size_t tk;
  wm_setstr (&m->sig, "ybnqiuxtdsogas(ui)va{sv}aya(ys)ax");
  wm_byte (m, 0xAB); wm_bool (m, 1); wm_i16 (m, -1234); wm_u16 (m, 54321); wm_i32 (m, -123456789); wm_u32 (m, 4000000000u);
  wm_i64 (m, -1234567890123LL); wm_u64 (m, 12345678901234567890ULL); wm_dbl (m, 3.5); wm_str (m, "str\xc3\xa4"); wm_str (m, "/o/b/j"); wm_sigstr (m, "a{sv}");
  tk = wm_array_begin (m, 4); wm_str (m, "x"); wm_str (m, "yy"); wm_array_end (m, tk, 4);
  wm_struct_begin (m); wm_u32 (m, 9); wm_i32 (m, -9);
  wm_variant_begin (m, "s"); wm_str (m, "in variant");
  tk = wm_array_begin (m, 8);
  wm_struct_begin (m); wm_str (m, "k1"); wm_variant_begin (m, "u"); wm_u32 (m, 7);
  wm_struct_begin (m); wm_str (m, "k2"); wm_variant_begin (m, "s"); wm_str (m, "x");
  wm_array_end (m, tk, 8);
  tk = wm_array_begin (m, 1); for (int i = 0; i < 37; i++) wm_byte (m, (uint8_t) (i * 7)); wm_array_end (m, tk, 1);
  tk = wm_array_begin (m, 8); wm_struct_begin (m); wm_byte (m, 1); wm_str (m, "one"); wm_struct_begin (m); wm_byte (m, 2); wm_str (m, "two"); wm_array_end (m, tk, 8);
  tk = wm_array_begin (m, 8); wm_i64 (m, 1); wm_i64 (m, -2); wm_array_end (m, tk, 8);
}

static uint32_t sum (const wmsg *m) { uint32_t h = 2166136261u; for (size_t i = 0; i < m->body.len; i++) h = (h ^ m->body.d[i]) * 16777619u; return h; }

static wmsg *big_signal (size_t n, const char *member)
{
  wmsg *m = wm_signal ("/big", "t.Big", member); size_t tk;
  wm_setstr (&m->sig, "ay"); tk = wm_array_begin (m, 1);
  { uint8_t *b = malloc (n); for (size_t i = 0; i < n; i++) b[i] = (uint8_t) (i * 31 + (i >> 8)); wm_raw (m, b, n); free (b); }
  wm_array_end (m, tk, 1);
  return m;
}

/* next message that is not one of the bus bookkeeping signals */
static int rcv (wconn *c, wmsg **out, int ms)
{
  for (;;)
    {
      int rc = wc_recv (c, out, ms);
      if (rc != 1) return rc;
      if ((*out)->type == W_SIGNAL && (*out)->sender && STREQ ((*out)->sender, "org.freedesktop.DBus")
          && (STREQ ((*out)->member, "NameAcquired") || STREQ ((*out)->member, "NameLost"))) { wm_free (*out); continue; }
      return 1;
    }
}

/* B answers every call it gets with an empty reply, until stop */
static int answer_one (wconn *b, const char *member, int ms)
{
  wmsg *g = wc_wait_call (b, member, ms); int ok = g != NULL;
  if (g) { wc_reply_empty (b, g); wm_free (g); }
  return ok;
}

MAIN_BEGIN ("t_Routing")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *a = th_client (D), *b = th_client (D), *c = th_client (D);
  wmsg *g, *r;

  /* --- unicast by unique name */
  { wmsg *m = wm_call_args (b->unique, "/p/q", "x.Iface", "Meth", "su", "arg", 5u); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Meth", 2000);
    T (g != NULL, "unicast call by unique name is delivered");
    T (g && g->serial == s, "the serial is preserved (%u/%u)", g ? g->serial : 0, s);
    T (g && STREQ (g->sender, a->unique), "the bus sets the sender header to the caller's unique name");
    T (g && STREQ (g->dest, b->unique), "the destination header is kept");
    T (g && STREQ (g->path, "/p/q") && STREQ (g->iface, "x.Iface") && STREQ (g->member, "Meth"), "path, interface, member are kept");
    T (g && g->sig && STREQ (g->sig, "su"), "signature is kept");
    { char *d = g ? wm_dump (g) : NULL; T (d && STREQ (d, "\"arg\",5"), "body is kept (%s)", d ? d : "-"); free (d); }
    wmsg *rep = wm_return (g); wm_args (rep, "s", "back"); wc_send (b, rep); wm_free (rep);
    T (rcv (a, &r, 2000) == 1 && r->type == W_RETURN && r->reply_serial == s, "the reply finds its way back, reply_serial intact");
    T (r && STREQ (r->sender, b->unique) && STREQ (r->dest, a->unique), "reply sender is the callee, destination the caller");
    wm_free (r); wm_free (g); }
  /* error reply with and without message */
  { wmsg *m = wm_call (b->unique, "/", "x.I", "Err"); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Err", 2000); wmsg *e = wm_error (g, "x.Custom.Error", "it broke"); wc_send (b, e); wm_free (e); wm_free (g);
    T (rcv (a, &r, 2000) == 1 && r->type == W_ERROR && STREQ (r->errname, "x.Custom.Error") && r->reply_serial == s, "error reply routed with its name");
    { char *t = r ? wm_arg_str (r, 0) : NULL; T (t && STREQ (t, "it broke"), "error text intact"); free (t); }
    wm_free (r);
    m = wm_call (b->unique, "/", "x.I", "Err2"); s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Err2", 2000); e = wm_error (g, "x.Custom.Error", NULL); wc_send (b, e); wm_free (e); wm_free (g);
    T (rcv (a, &r, 2000) == 1 && r->type == W_ERROR && r->sig == NULL, "error reply without a message is routed too"); wm_free (r); }
  /* message flags travel */
  { wmsg *m = wm_call (b->unique, "/", "x.I", "Flags"); m->flags = W_F_NOREPLY | W_F_NOAUTOSTART | W_F_ALLOWINTERACT; wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Flags", 2000); T (g && g->flags == (W_F_NOREPLY | W_F_NOAUTOSTART | W_F_ALLOWINTERACT), "flags are delivered as sent (%d)", g ? g->flags : -1); wm_free (g); }
  /* to oneself */
  { wmsg *m = wm_call (a->unique, "/", "x.I", "Self"); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (a, "Self", 2000); T (g && g->serial == s && STREQ (g->sender, a->unique), "a call to oneself is delivered"); wm_free (g); }

  /* --- unicast by well-known name */
  wc_request_name (b, "org.t.Svc", 0); wc_request_name (c, "org.t.Svc", 0); wc_clear (b); wc_clear (c);
  { wmsg *m = wm_call (  "org.t.Svc", "/", "x.I", "ByName"); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "ByName", 2000); T (g != NULL, "call to a well-known name goes to the primary owner");
    T (g && STREQ (g->dest, "org.t.Svc"), "the destination header keeps the well-known name (%s)", g ? g->dest : "-");
    T (wc_silent (c, 200), "the queued owner gets nothing"); wm_free (g); }
  wc_release_name (b, "org.t.Svc"); wc_clear (c);
  { wmsg *m = wm_call ("org.t.Svc", "/", "x.I", "ByName2"); wc_send (a, m); wm_free (m);
    g = wc_wait_call (c, "ByName2", 2000); T (g != NULL, "after the primary owner released, the next owner gets the calls"); wm_free (g); }
  wc_release_name (c, "org.t.Svc");
  T (terr (a, wm_call ("org.t.Svc", "/", "x.I", "Gone"), E_SERVICE_UNKNOWN), "call to a name nobody owns any more: ServiceUnknown");

  /* --- missing destinations */
  { wmsg *e = NULL; T (tcall (a, wm_call ("org.t.Missing", "/", "x.I", "M"), &e) == W_ERROR && STREQ (e->errname, E_SERVICE_UNKNOWN), "well-known destination missing: ServiceUnknown");
    T (e && STREQ (e->sender, "org.freedesktop.DBus") && STREQ (e->dest, a->unique), "the error comes from the bus, to the caller"); wm_free (e); }
  T (terr (a, wm_call (":1.99999", "/", "x.I", "M"), E_SERVICE_UNKNOWN), "unique destination missing: ServiceUnknown");
  { char dead[64]; wconn *x = th_client (D); snprintf (dead, sizeof dead, "%s", x->unique); wc_close (x);
    for (int i = 0; i < 50 && wc_name_has_owner (a, dead) == 1; i++) usleep (20000);
    T (terr (a, wm_call (dead, "/", "x.I", "M"), E_SERVICE_UNKNOWN), "a unique name that just disconnected: ServiceUnknown"); }
  { wmsg *m = wm_call ("org.t.Missing", "/", "x.I", "M"); m->flags = W_F_NOREPLY; wc_send (a, m); wm_free (m);
    T (wc_sync (a) == 0, "NO_REPLY_EXPECTED call to a missing name: connection survives (an error may or may not follow)"); wc_clear (a); }
  { wmsg *m = wm_signal ("/", "x.I", "ToNobody"); wm_setstr (&m->dest, "org.t.Missing"); wc_send (a, m); wm_free (m);
    T (wc_sync (a) == 0, "unicast signal to a missing name: connection survives"); wc_clear (a); }

  /* --- NoReply when the callee goes away */
  { wconn *x = th_client (D); wmsg *m; uint32_t s1, s2;
    wc_request_name (x, "org.t.Dies", 0);
    m = wm_call ("org.t.Dies", "/", "x.I", "A"); s1 = wc_send (a, m); wm_free (m);
    m = wm_call (x->unique, "/", "x.I", "B"); s2 = wc_send (b, m); wm_free (m);
    wm_free (wc_wait_call (x, "A", 2000)); wm_free (wc_wait_call (x, "B", 2000));
    wc_close (x);
    r = NULL; { wmsg *rr = NULL; int rc = rcv (a, &rr, 3000); r = rr; T (rc == 1 && r->type == W_ERROR && STREQ (r->errname, E_NO_REPLY) && r->reply_serial == s1, "callee disconnects without replying: caller A gets NoReply"); }
    T (r && STREQ (r->sender, "org.freedesktop.DBus"), "NoReply comes from the bus"); wm_free (r);
    r = NULL; { wmsg *rr = NULL; int rc = rcv (b, &rr, 3000); r = rr; T (rc == 1 && r->type == W_ERROR && STREQ (r->errname, E_NO_REPLY) && r->reply_serial == s2, "... and so does B for its own call"); } wm_free (r); }
  { /* already answered: no NoReply later */
    wconn *x = th_client (D); wmsg *m = wm_call (x->unique, "/", "x.I", "Answered"); wc_send (a, m); wm_free (m);
    answer_one (x, "Answered", 2000); wm_free (rcv (a, &r, 2000) == 1 ? r : NULL); wc_close (x);
    T (wc_silent (a, 300), "a call that was answered does not produce NoReply when the callee later leaves"); }
  { /* NO_REPLY_EXPECTED calls need no NoReply */
    wconn *x = th_client (D); wmsg *m = wm_call (x->unique, "/", "x.I", "Quiet"); m->flags = W_F_NOREPLY; wc_send (a, m); wm_free (m);
    wm_free (wc_wait_call (x, "Quiet", 2000)); wc_close (x);
    T (wc_silent (a, 400), "a NO_REPLY_EXPECTED call produces no NoReply when the callee leaves"); }
  { /* the caller leaves: the callee's late reply must go nowhere and harm nobody */
    wconn *x = th_client (D), *y = th_client (D); wmsg *m = wm_call (y->unique, "/", "x.I", "Orphan"); wc_send (x, m); wm_free (m);
    g = wc_wait_call (y, "Orphan", 2000); wc_close (x);
    for (int i = 0; i < 50; i++) { usleep (20000); if (wc_sync (a) == 0 && wc_name_has_owner (a, g ? g->sender : "") == 0) break; }
    { wmsg *rep = wm_return (g); wc_send (y, rep); wm_free (rep); }
    T (wc_sync (y) == 0, "replying to a caller that is gone is harmless (connection stays up)"); wm_free (g); wc_close (y); }

  /* --- replies and errors that nobody asked for: the permissive test config of the
   * real daemon forwards them, minibus drops them (only the asked callee may answer) */
  { wmsg *m = wm_new (W_RETURN, 0); m->has_reply_serial = 1; m->reply_serial = 424242; wm_setstr (&m->dest, b->unique); wc_send (a, m); wm_free (m);
    g = NULL; rcv (b, &g, 1500);
    if (th_is_real ()) { T (g && g->type == W_RETURN && g->reply_serial == 424242 && STREQ (g->sender, a->unique), "real: an unsolicited method return is forwarded"); }
    else { T (g == NULL, "minibus: an unsolicited method return is dropped"); }
    wm_free (g); }
  { wmsg *m = wm_new (W_ERROR, 0); m->has_reply_serial = 1; m->reply_serial = 424243; wm_setstr (&m->dest, b->unique); wm_setstr (&m->errname, "x.Unsolicited"); wc_send (a, m); wm_free (m);
    g = NULL; rcv (b, &g, 1500);
    if (th_is_real ()) { T (g && g->type == W_ERROR && STREQ (g->errname, "x.Unsolicited"), "real: an unsolicited error is forwarded"); }
    else { T (g == NULL, "minibus: an unsolicited error is dropped"); }
    wm_free (g); }
  { wmsg *m = wm_new (W_RETURN, 0); m->has_reply_serial = 1; m->reply_serial = 1; wm_setstr (&m->dest, ":1.88888"); wc_send (a, m); wm_free (m);
    T (wc_sync (a) == 0, "a method return to a missing peer: connection survives"); wc_clear (a); }
  { /* a reply to a call can come from a party that was not asked; serial matching is up to the receiver */
    wmsg *m = wm_call (b->unique, "/", "x.I", "Who"); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Who", 2000);
    { wmsg *rep = wm_return (g); wm_setstr (&rep->dest, a->unique); wc_send (c, rep); wm_free (rep); }
    r = NULL; rcv (a, &r, 1500);
    if (th_is_real ()) { T (r && r->type == W_RETURN && r->reply_serial == s && STREQ (r->sender, c->unique), "real: a reply from a third client reaches the original caller"); }
    else { T (r == NULL, "minibus: a reply from a third client is dropped"); }
    wm_free (r); wm_free (g); wc_clear (a); wc_clear (b); }

  /* --- two calls outstanding, answered in reverse order */
  { wmsg *m = wm_call (b->unique, "/", "x.I", "First"); uint32_t s1 = wc_send (a, m); wm_free (m);
    m = wm_call (b->unique, "/", "x.I", "Second"); uint32_t s2 = wc_send (a, m); wm_free (m);
    wmsg *g1 = wc_wait_call (b, "First", 2000), *g2 = wc_wait_call (b, "Second", 2000);
    wc_reply_empty (b, g2); wc_reply_empty (b, g1);
    wmsg *r1 = NULL, *r2 = NULL; rcv (a, &r1, 2000); rcv (a, &r2, 2000);
    T (r1 && r2 && r1->reply_serial == s2 && r2->reply_serial == s1, "replies are delivered in the order the callee sent them, matched by reply_serial");
    wm_free (r1); wm_free (r2); wm_free (g1); wm_free (g2); }

  /* --- peer interfaces are forwarded to the peer, not answered by the bus */
  { wmsg *m = wm_call (b->unique, "/any", "org.freedesktop.DBus.Peer", "Ping"); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Ping", 2000); T (g != NULL, "Peer.Ping to a client is delivered to that client");
    if (g) { wc_reply_empty (b, g); wm_free (g); }
    T (rcv (a, &r, 2000) == 1 && r->type == W_RETURN && STREQ (r->sender, b->unique), "and its answer comes back from the client"); wm_free (r); }
  { wmsg *m = wm_call (b->unique, "/", "org.freedesktop.DBus.Introspectable", "Introspect"); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Introspect", 2000); T (g != NULL, "Introspect to a client is delivered to that client"); wm_free (g); }

  /* --- broadcast */
  wc_add_match (b, "type='signal',interface='t.Bc'"); wc_add_match (a, "type='signal',interface='t.Bc'"); wc_sync (a); wc_sync (b); wc_clear (a); wc_clear (b); wc_clear (c);
  { wmsg *m = wm_signal ("/bc", "t.Bc", "Hit"); wm_args (m, "s", "payload"); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_sig (b, "Hit", 2000);
    T (g != NULL, "a broadcast reaches the subscriber");
    T (g && STREQ (g->sender, a->unique), "broadcast sender header is set");
    T (g && g->dest == NULL, "broadcast has no destination");
    T (g && g->serial == s && STREQ (g->path, "/bc") && STREQ (g->iface, "t.Bc"), "serial, path and interface kept");
    wm_free (g);
    g = wc_wait_sig (a, "Hit", 2000); T (g != NULL, "the sender gets its own broadcast when its own rule matches"); wm_free (g);
    T (wc_silent (c, 200), "an unsubscribed client gets nothing"); }
  { wmsg *m = wm_signal ("/bc", "t.Bc", "Hit2"); wc_send (a, m); wm_free (m); wm_free (wc_wait_sig (b, "Hit2", 2000)); wm_free (wc_wait_sig (a, "Hit2", 2000)); }
  wc_remove_match (a, "type='signal',interface='t.Bc'"); wc_clear (a);
  { wmsg *m = wm_signal ("/bc", "t.Bc", "Hit3"); wc_send (a, m); wm_free (m); wm_free (wc_wait_sig (b, "Hit3", 2000));
    T (wc_silent (a, 200), "after RemoveMatch the sender no longer sees its own broadcasts"); }
  wc_remove_match (b, "type='signal',interface='t.Bc'"); wc_clear (b);

  /* --- ordering and flooding */
  wc_add_match (b, "type='signal',interface='t.Seq'"); wc_sync (b); wc_clear (b);
  { int ok = 1; int N = 2000;
    for (int i = 0; i < N; i++) { wmsg *m = wm_signal ("/s", "t.Seq", "N"); wm_args (m, "u", (uint32_t) i); wc_send (a, m); wm_free (m); }
    for (int i = 0; i < N && ok; i++) { wmsg *s = NULL; uint32_t v = 0; if (rcv (b, &s, 5000) != 1) { ok = 0; break; } if (!wm_arg_u32 (s, 0, &v) || (int) v != i) ok = 0; wm_free (s); }
    T (ok, "2000 broadcasts from one sender arrive complete and in order"); }
  { /* two senders to one receiver: per-sender order is preserved */
    int N = 500, ok = 1, na = 0, nc = 0;
    for (int i = 0; i < N; i++) { wmsg *m = wm_signal ("/s", "t.Seq", "N"); wm_args (m, "u", (uint32_t) i); wc_send (a, m); wm_free (m); m = wm_signal ("/s", "t.Seq", "N"); wm_args (m, "u", (uint32_t) i); wc_send (c, m); wm_free (m); }
    for (int i = 0; i < 2 * N && ok; i++)
      { wmsg *s = NULL; uint32_t v = 0; if (rcv (b, &s, 5000) != 1) { ok = 0; break; } wm_arg_u32 (s, 0, &v);
        if (STREQ (s->sender, a->unique)) { if ((int) v != na++) ok = 0; } else if (STREQ (s->sender, c->unique)) { if ((int) v != nc++) ok = 0; } else ok = 0; wm_free (s); }
    T (ok && na == N && nc == N, "two interleaved senders: each sender's order is preserved"); }
  { /* the same flood to ten receivers */
    wconn *rs[10]; int ok = 1;
    for (int i = 0; i < 10; i++) { rs[i] = th_client (D); wc_add_match (rs[i], "type='signal',interface='t.Flood'"); wc_sync (rs[i]); }
    for (int i = 0; i < 1000; i++) { wmsg *m = wm_signal ("/s", "t.Flood", "N"); wm_args (m, "u", (uint32_t) i); wc_send (a, m); wm_free (m); }
    for (int k = 0; k < 10; k++)
      for (int i = 0; i < 1000 && ok; i++) { wmsg *s = NULL; uint32_t v = 0; if (rcv (rs[k], &s, 5000) != 1) { ok = 0; break; } if (!wm_arg_u32 (s, 0, &v) || (int) v != i) ok = 0; wm_free (s); }
    T (ok, "1000 broadcasts to 10 receivers all arrive in order");
    for (int i = 0; i < 10; i++) wc_close (rs[i]); }
  wc_remove_match (b, "type='signal',interface='t.Seq'");

  /* --- pipelining: many requests in one write, answers in order */
  { wbuf all = { 0 }; int N = 300; uint32_t first = a->next_serial; int ok = 1;
    for (int i = 0; i < N; i++) { wmsg *m = wm_bus ("GetId", ""); m->serial = a->next_serial++; wm_encode (m, &all); wm_free (m); }
    wc_send_raw (a, all.d, all.len); wbuf_free (&all);
    for (int i = 0; i < N && ok; i++) { wmsg *s = NULL; if (rcv (a, &s, 5000) != 1 || s->type != W_RETURN || s->reply_serial != first + i) ok = 0; wm_free (s); }
    T (ok, "300 pipelined calls in a single write are answered in order"); }
  { wbuf all = { 0 }; int N = 1000; int ok = 1;
    wc_add_match (b, "type='signal',interface='t.Small'"); wc_sync (b); wc_clear (b);
    for (int i = 0; i < N; i++) { wmsg *m = wm_signal ("/s", "t.Small", "N"); wm_args (m, "u", (uint32_t) i); m->serial = a->next_serial++; wm_encode (m, &all); wm_free (m); }
    wc_send_raw (a, all.d, all.len); wbuf_free (&all);
    for (int i = 0; i < N && ok; i++) { wmsg *s = NULL; uint32_t v = 0; if (rcv (b, &s, 5000) != 1 || !wm_arg_u32 (s, 0, &v) || (int) v != i) ok = 0; wm_free (s); }
    T (ok, "1000 small signals in a single write are all delivered in order");
    wc_remove_match (b, "type='signal',interface='t.Small'"); }

  /* --- framing: byte by byte and random chunks */
  { wmsg *m = wm_call_args (b->unique, "/p", "x.I", "Slow", "ssu", "one", "two", 3u); wbuf w = { 0 }; m->serial = a->next_serial++; wm_encode (m, &w);
    for (size_t i = 0; i < w.len; i++) { wc_send_raw (a, w.d + i, 1); usleep (300); }
    g = wc_wait_call (b, "Slow", 3000); T (g != NULL, "a message sent one byte at a time (%zu bytes) is delivered", w.len);
    { char *d = g ? wm_dump (g) : NULL; T (d && STREQ (d, "\"one\",\"two\",3"), "intact (%s)", d ? d : "-"); free (d); }
    wm_free (g); wm_free (m); wbuf_free (&w); }
  { wbuf all = { 0 }; int N = 60; int ok = 1; unsigned seed = 12345;
    wc_add_match (b, "type='signal',interface='t.Chunk'"); wc_sync (b); wc_clear (b);
    for (int i = 0; i < N; i++) { wmsg *m = wm_signal ("/s", "t.Chunk", "N"); wm_args (m, "us", (uint32_t) i, "some text to make it longer than a few bytes"); m->serial = a->next_serial++; wm_encode (m, &all); wm_free (m); }
    for (size_t off = 0; off < all.len;) { size_t n = 1 + rand_r (&seed) % 23; if (off + n > all.len) n = all.len - off; wc_send_raw (a, all.d + off, n); off += n; if (rand_r (&seed) % 5 == 0) usleep (200); }
    for (int i = 0; i < N && ok; i++) { wmsg *s = NULL; uint32_t v = 0; if (rcv (b, &s, 5000) != 1 || !wm_arg_u32 (s, 0, &v) || (int) v != i) ok = 0; wm_free (s); }
    T (ok, "60 messages cut into random 1..23 byte pieces arrive intact and in order"); wbuf_free (&all);
    wc_remove_match (b, "type='signal',interface='t.Chunk'"); }

  /* --- body round trips through the bus, both byte orders */
  for (int e = 0; e < 2; e++)
    {
      wconn *s = e ? th_client (D) : a; wmsg *m; char *d1, *d2; wmsg *loc = NULL; wbuf w = { 0 }; size_t used;
      wire_endian = e ? 'B' : 'l';
      m = wm_call (b->unique, "/types", "t.Types", "All"); all_types (m);
      wm_encode (m, &w); loc = calloc (1, sizeof *loc); wm_decode (w.d, w.len, loc, &used); d1 = wm_dump (loc);
      wc_send (s, m); g = wc_wait_call (b, "All", 3000); d2 = g ? wm_dump (g) : NULL;
      T (g != NULL, "%s-endian message with every basic and container type is delivered", e ? "big" : "little");
      T (d1 && d2 && STREQ (d1, d2) && !strstr (d2, "!ERR"), "and decodes to the same values (%s)", d2 ? d2 : "-");
      T (g && g->body.len == m->body.len, "body length unchanged (%zu)", g ? g->body.len : (size_t) 0);
      if (g && g->endian == m->endian) { T (memcmp (g->body.d, m->body.d, m->body.len) == 0, "body bytes unchanged when the byte order is kept"); }
      free (d1); free (d2); wm_free (g); wm_free (m); wm_free (loc); wbuf_free (&w);
      if (e) wc_close (s);
      wire_endian = 'l';
    }
  { /* big-endian receiver of a little-endian message and vice versa */
    wconn *be = th_client_be (D); wire_endian = 'B'; wc_hello (be);
    wmsg *m = wm_call_args (be->unique, "/", "t.I", "Mix", "uxs", 0x01020304u, (int64_t) 0x0102030405060708LL, "mixed"); wire_endian = 'l';
    wc_send (a, m); wm_free (m);
    g = wc_wait_call (be, "Mix", 3000); { char *d = g ? wm_dump (g) : NULL; T (d && STREQ (d, "16909060,72623859790382856,\"mixed\""), "little-endian call arrives at a big-endian client decodable (%s)", d ? d : "-"); free (d); }
    wm_free (g);
    wire_endian = 'B'; m = wm_call_args (a->unique, "/", "t.I", "Mix2", "uxs", 0x01020304u, (int64_t) 0x0102030405060708LL, "mixed"); wire_endian = 'l';
    wc_send (be, m); wm_free (m);
    g = wc_wait_call (a, "Mix2", 3000); { char *d = g ? wm_dump (g) : NULL; T (d && STREQ (d, "16909060,72623859790382856,\"mixed\""), "big-endian call arrives at a little-endian client decodable (%s)", d ? d : "-"); free (d); }
    wm_free (g); wc_close (be); }

  /* --- sizes */
  { size_t sizes[] = { 0, 1, 7, 8, 255, 4096, 65535, 65536, 65537, 262144, 1048576, 4000000 }; wc_add_match (b, "type='signal',interface='t.Big'"); wc_sync (b); wc_clear (b);
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++)
      {
        wmsg *m = big_signal (sizes[i], "B"), *s = NULL; uint32_t h = sum (m);
        wc_send (a, m); wm_free (m);
        int rc = rcv (b, &s, 15000);
        T (rc == 1 && s->body.len == 4 + sizes[i] && sum (s) == h, "broadcast with a %zu byte array arrives intact", sizes[i]);
        wm_free (s);
      }
    wc_remove_match (b, "type='signal',interface='t.Big'"); }
  { wmsg *m = big_signal (3000000, "U"), *s; wm_setstr (&m->dest, b->unique); m->type = W_CALL; wm_setstr (&m->member, "Huge"); wm_setstr (&m->path, "/h"); uint32_t h = sum (m);
    wc_send (a, m); wm_free (m); s = wc_wait_call (b, "Huge", 15000); T (s && sum (s) == h, "3 MB method call to a client arrives intact"); wm_free (s); }
  { /* many large messages back to back */
    int ok = 1; wc_add_match (b, "type='signal',interface='t.Big'"); wc_sync (b); wc_clear (b);
    for (int i = 0; i < 30; i++) { wmsg *m = big_signal (200000 + i, "Many"); wc_send (a, m); wm_free (m); }
    for (int i = 0; i < 30 && ok; i++) { wmsg *s = NULL; if (rcv (b, &s, 15000) != 1 || s->body.len != 4 + 200000 + (size_t) i) ok = 0; wm_free (s); }
    T (ok, "30 back to back 200 KB messages arrive complete and in order");
    wc_remove_match (b, "type='signal',interface='t.Big'"); }

  /* --- connection churn and cleanup */
  { int ok = 1; char last[64] = "";
    for (int i = 0; i < 200; i++) { wconn *x = th_client (D); if (!x) { ok = 0; break; } wc_request_name (x, "org.t.Churn", 0); snprintf (last, sizeof last, "%s", x->unique); wc_close (x); }
    T (ok, "200 connect/own/disconnect cycles");
    for (int i = 0; i < 100 && wc_name_has_owner (a, "org.t.Churn") == 1; i++) usleep (20000);
    T (wc_name_has_owner (a, "org.t.Churn") == 0, "the name is free after the last owner left");
    T (wc_name_has_owner (a, last) == 0, "and so is its unique name"); }
  { /* a client that dies in the middle of a message */
    wconn *x = th_client (D); wmsg *m = wm_call (b->unique, "/", "x.I", "Half"); wbuf w = { 0 }; m->serial = 1; wm_encode (m, &w);
    wc_send_raw (x, w.d, w.len / 2); wc_close (x); wm_free (m); wbuf_free (&w);
    T (wc_silent (b, 300), "half a message from a vanished client is never delivered"); }
  { /* a dying client that has just sent a full message: it is still delivered */
    wconn *x = th_client (D); wmsg *m = wm_signal ("/", "t.Last", "Words"); wc_add_match (b, "type='signal',interface='t.Last'"); wc_sync (b); wc_clear (b);
    wc_send (x, m); wm_free (m); wc_close (x);
    g = wc_wait_sig (b, "Words", 3000); T (g != NULL, "a signal sent right before the sender closed is still delivered"); wm_free (g);
    wc_remove_match (b, "type='signal',interface='t.Last'"); }

  T (th_healthy (D), "daemon healthy");
  wc_close (a); wc_close (b); wc_close (c);
  th_stop (D);
MAIN_END

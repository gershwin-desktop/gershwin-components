/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* org.freedesktop.DBus.Monitoring.BecomeMonitor */

#include "t.h"

static tdaemon *D;

#define MON(r, n, f) wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu", r, n, (uint32_t) (f))

static wconn *monitor (const char **rules, int n)
{
  wconn *m = th_client (D); wmsg *r = NULL;
  if (!m) return NULL;
  if (tcall (m, MON (rules, n, 0), &r) != W_RETURN) { wm_free (r); wc_close (m); return NULL; }
  wm_free (r);
  /* the bus tells the new monitor that it lost its unique name (real behaviour) */
  wm_free (wc_wait_sig_arg0 (m, "NameLost", m->unique, 300));
  return m;
}
static void quiesce (wconn *c) { wc_drain (c, 150); wc_clear (c); }

/* send a marker from s and wait for it on every monitor so all earlier
 * traffic has been delivered to them */
static void flush (wconn *s, wconn **mons, int n)
{
  wmsg *m = wm_signal ("/t", "t.Marker", "Mark");
  wc_send (s, m); wm_free (m);
  for (int i = 0; i < n; i++) wm_free (wc_wait_sig (mons[i], "Mark", 3000));
}

static int seen (wconn *m, int type, const char *member, const char *arg0)
{
  return wc_inbox_find (m, type, member, arg0) >= 0;
}

MAIN_BEGIN ("t_Monitor")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *a = th_client (D), *b = th_client (D), *w = th_client (D);
  wc_add_match (w, "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'");
  wc_sync (w); quiesce (w);
  const char *none[] = { NULL };

  /* --- becoming a monitor */
  wconn *mon = th_client (D); char monu[64]; snprintf (monu, sizeof monu, "%s", mon->unique);
  { wmsg *r = NULL; int t = tcall (mon, MON (none, 0, 0), &r);
    T (t == W_RETURN, "BecomeMonitor with an empty rule list: method return");
    T (r && r->sig == NULL && STREQ (r->sender, "org.freedesktop.DBus"), "the reply is empty and comes from the bus"); wm_free (r); }
  { wmsg *l = tok (a, wm_bus ("ListNames", "")); char *d = l ? wm_dump (l) : NULL;
    T (d && !strstr (d, monu), "a monitor is not listed by ListNames any more (%s)", d ? d : "-"); free (d); wm_free (l); }
  T (wc_name_has_owner (a, monu) == 0, "NameHasOwner(monitor's unique name) is false");
  T (wc_wait_sig_arg0 (w, "NameOwnerChanged", monu, 2000) != NULL, "watchers learn that the monitor's unique name went away");
  wc_clear (w);
  quiesce (mon);

  /* --- what a monitor sees */
  wc_request_name (b, "org.t.B", 0);
  { wmsg *m = wm_call_args (b->unique, "/p", "x.I", "M", "s", "hi"); wc_send (a, m); wm_free (m);
    wmsg *g = wc_wait_call (b, "M", 2000); wmsg *r = wm_return (g); wm_args (r, "u", 7); wc_send (b, r); wm_free (r); wm_free (g); }
  { wmsg *m = wm_signal ("/s", "x.I", "Sg"); wm_args (m, "s", "bcast"); wc_send (a, m); wm_free (m); }
  { wmsg *m = wm_signal ("/s", "x.I", "Uni"); wm_setstr (&m->dest, b->unique); wc_send (a, m); wm_free (m); }
  { wmsg *e = NULL; wmsg *m = wm_call (b->unique, "/p", "x.I", "Fail"); uint32_t s = wc_send (a, m); wm_free (m);
    wmsg *g = wc_wait_call (b, "Fail", 2000); e = wm_error (g, "x.Err", "no"); wc_send (b, e); wm_free (e); wm_free (g); (void) s; }
  T (wc_ping (a, "org.freedesktop.DBus") == 0, "call to the bus");
  T (terr (a, wm_call ("org.no.Such", "/", "x.I", "M"), E_SERVICE_UNKNOWN), "call to a missing name");
  flush (a, &mon, 1);
  T (seen (mon, W_CALL, "RequestName", NULL), "monitor sees a method call to the bus (RequestName)");
  T (seen (mon, W_CALL, "M", NULL), "monitor sees a method call between two clients");
  { int i = wc_inbox_find (mon, W_CALL, "M", NULL);
    wmsg *m = i >= 0 ? mon->inbox[i] : NULL;
    T (m && STREQ (m->dest, b->unique) && STREQ (m->sender, a->unique), "the call is shown unchanged: sender %s dest %s", m ? m->sender : "-", m ? m->dest : "-");
    char *s = m ? wm_arg_str (m, 0) : NULL; T (s && STREQ (s, "hi"), "with its body"); free (s); }
  { int ok = 0; for (int i = 0; i < mon->ninbox; i++) if (mon->inbox[i]->type == W_RETURN && STREQ (mon->inbox[i]->sender, b->unique)) ok = 1; T (ok, "monitor sees the method return of a client"); }
  { int ok = 0; for (int i = 0; i < mon->ninbox; i++) if (mon->inbox[i]->type == W_ERROR && mon->inbox[i]->errname && STREQ (mon->inbox[i]->errname, "x.Err")) ok = 1; T (ok, "monitor sees an error reply of a client"); }
  T (seen (mon, W_SIGNAL, "Sg", NULL), "monitor sees a broadcast signal nobody subscribed to");
  T (seen (mon, W_SIGNAL, "Uni", NULL), "monitor sees a unicast signal addressed to somebody else");
  T (seen (mon, W_CALL, "GetId", NULL) || seen (mon, W_CALL, "Ping", NULL), "monitor sees calls to the bus");
  { int ok = 0; for (int i = 0; i < mon->ninbox; i++) if (mon->inbox[i]->type == W_RETURN && STREQ (mon->inbox[i]->sender, "org.freedesktop.DBus")) ok = 1; T (ok, "monitor sees replies sent by the bus"); }
  T (seen (mon, W_SIGNAL, "NameOwnerChanged", "org.t.B"), "monitor sees NameOwnerChanged although it never subscribed");
  T (seen (mon, W_SIGNAL, "NameAcquired", "org.t.B"), "monitor sees a NameAcquired addressed to somebody else");
  { int ok = 0; for (int i = 0; i < mon->ninbox; i++) if (mon->inbox[i]->type == W_ERROR && mon->inbox[i]->errname && STREQ (mon->inbox[i]->errname, E_SERVICE_UNKNOWN)) ok = 1;
    T (ok, "monitor sees the bus error for an undeliverable call"); }
  { int n = 0; for (int i = 0; i < mon->ninbox; i++) if (mon->inbox[i]->type == W_CALL && mon->inbox[i]->member && STREQ (mon->inbox[i]->member, "M") && STREQ (mon->inbox[i]->dest, b->unique)) n++;
    T (n == 1, "every message appears once (%d)", n); }
  quiesce (mon);

  /* --- monitors do not disturb normal delivery */
  { wmsg *m = wm_call_args (b->unique, "/p", "x.I", "M", ""); uint32_t s = wc_send (a, m); wm_free (m);
    wmsg *g = wc_wait_call (b, "M", 2000); T (g && g->serial == s, "the callee still gets its call"); wm_free (g); }
  T (wc_silent (a, 150), "the sender is not told about the monitor");
  quiesce (mon);

  /* --- a monitor may not send */
  { wconn *m2 = monitor (none, 0);
    T (m2 != NULL, "second monitor");
    wmsg *s = wm_signal ("/t", "x.I", "FromMon"); wc_send (m2, s); wm_free (s);
    T (wc_wait_eof (m2, 3000), "a monitor that sends a signal is disconnected");
    wc_close (m2); }
  { wconn *m2 = monitor (none, 0);
    wmsg *s = wm_bus ("ListNames", ""); wc_send (m2, s); wm_free (s);
    T (wc_wait_eof (m2, 3000), "a monitor that calls the bus is disconnected");
    wc_close (m2); }
  { wconn *m2 = monitor (none, 0);
    wmsg *s = wm_call (b->unique, "/", "x.I", "M"); wc_send (m2, s); wm_free (s);
    T (wc_wait_eof (m2, 3000), "a monitor that calls a client is disconnected");
    wc_close (m2); }
  { wconn *m2 = monitor (none, 0); wmsg *r = NULL;
    T (tcall (m2, MON (none, 0, 0), &r) != W_RETURN, "BecomeMonitor twice is not accepted"); wm_free (r);
    T (wc_wait_eof (m2, 3000), "and costs the connection"); wc_close (m2); }
  T (wc_sync (a) == 0 && wc_sync (b) == 0, "other clients unaffected");
  quiesce (mon);

  /* --- errors in the request */
  { wconn *c = th_client (D);
    T (terr (c, MON (none, 0, 1), E_INVALID_ARGS), "BecomeMonitor with flags != 0: InvalidArgs");
    T (terr (c, MON (none, 0, 0xffffffffu), E_INVALID_ARGS), "BecomeMonitor with all flags set: InvalidArgs");
    { const char *bad[] = { "foo='bar'" }; T (terr (c, MON (bad, 1, 0), E_MATCH_INVALID), "BecomeMonitor with a bad rule: MatchRuleInvalid"); }
    { const char *bad[] = { "type='signal'", "arg64='x'" }; T (terr (c, MON (bad, 2, 0), E_MATCH_INVALID), "one bad rule among good ones spoils the request"); }
    T (terr (c, wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "s", "x"), E_INVALID_ARGS), "BecomeMonitor with the wrong signature: InvalidArgs");
    T (terr (c, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor"), E_INVALID_ARGS), "BecomeMonitor without arguments: InvalidArgs");
    T (terr (c, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "Nope"), E_UNKNOWN_METHOD), "unknown method on the Monitoring interface: UnknownMethod");
    T (wc_sync (c) == 0, "after those errors the connection is still a normal client");
    T (wc_request_name (c, "org.t.StillNormal", 0) == 1, "and can own names");
    { wmsg *r = NULL; T (tcall (c, MON (none, 0, 0), &r) == W_RETURN, "and can still become a monitor"); wm_free (r); }
    wc_close (c); }
  { wconn *c = th_client (D); wmsg *r = NULL;
    T (tcall (c, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "BecomeMonitor"), &r) == W_ERROR, "BecomeMonitor is not on org.freedesktop.DBus itself"); wm_free (r); wc_close (c); }

  /* --- filtering */
  { const char *rules[] = { "type='signal',interface='x.I'", "sender='org.freedesktop.DBus',member='NameOwnerChanged'" };
    wconn *f = monitor (rules, 2); wconn *ms[1] = { f };
    T (f != NULL, "monitor with two rules");
    { wmsg *m = wm_signal ("/s", "x.I", "Sg"); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/s", "y.I", "Other"); wc_send (a, m); wm_free (m); }
    T (wc_ping (a, "org.freedesktop.DBus") == 0, "a call to the bus");
    T (wc_request_name (a, "org.t.Filtered", 0) == 1, "a name request");
    flush (a, ms, 1); (void) 0;
    T (seen (f, W_SIGNAL, "Sg", NULL), "signal matching the first rule is delivered");
    T (!seen (f, W_SIGNAL, "Other", NULL), "signal of another interface is not");
    T (seen (f, W_SIGNAL, "NameOwnerChanged", "org.t.Filtered"), "NameOwnerChanged matching the second rule is delivered");
    T (!seen (f, W_CALL, NULL, NULL), "no method calls (no rule asks for them)");
    T (!seen (f, W_RETURN, NULL, NULL), "no replies");
    wc_close (f); }
  { const char *rules[] = { "type='method_call'" }; wconn *f = monitor (rules, 1); wconn *ms[1] = { f };
    { wmsg *m = wm_signal ("/s", "x.I", "Sg"); wc_send (a, m); wm_free (m); }
    T (wc_ping (a, "org.freedesktop.DBus") == 0, "ping the bus");
    flush (a, ms, 0); wc_ping (a, "org.freedesktop.DBus"); wc_drain (f, 300);
    T (seen (f, W_CALL, "Ping", NULL), "type='method_call' delivers method calls");
    T (!seen (f, W_SIGNAL, NULL, NULL) && !seen (f, W_RETURN, NULL, NULL), "and nothing else");
    wc_close (f); }
  { const char *rules[] = { "type='method_return'" }; wconn *f = monitor (rules, 1);
    wc_ping (a, "org.freedesktop.DBus"); wc_drain (f, 300);
    T (seen (f, W_RETURN, NULL, NULL), "type='method_return' delivers returns");
    T (!seen (f, W_CALL, NULL, NULL), "and no calls"); wc_close (f); }
  { const char *rules[] = { "type='error'" }; wconn *f = monitor (rules, 1);
    terr (a, wm_call ("org.no.Such", "/", "x.I", "M"), E_SERVICE_UNKNOWN); wc_ping (a, "org.freedesktop.DBus"); wc_drain (f, 300);
    T (seen (f, W_ERROR, NULL, NULL), "type='error' delivers errors");
    T (!seen (f, W_RETURN, NULL, NULL), "and no returns"); wc_close (f); }
  { char r1[100]; snprintf (r1, sizeof r1, "sender='%s'", b->unique); const char *rules[] = { r1 }; wconn *f = monitor (rules, 1);
    { wmsg *m = wm_signal ("/s", "x.I", "FromA"); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/s", "x.I", "FromB"); wc_send (b, m); wm_free (m); }
    wc_sync (a); wc_sync (b); wc_drain (f, 300);
    T (seen (f, W_SIGNAL, "FromB", NULL) && !seen (f, W_SIGNAL, "FromA", NULL), "sender rule limits the monitor to one client"); wc_close (f); }
  { char r1[100]; snprintf (r1, sizeof r1, "destination='%s'", b->unique); const char *rules[] = { r1 }; wconn *f = monitor (rules, 1);
    { wmsg *m = wm_signal ("/s", "x.I", "ToB"); wm_setstr (&m->dest, b->unique); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/s", "x.I", "ToA"); wm_setstr (&m->dest, a->unique); wc_send (b, m); wm_free (m); }
    wc_sync (a); wc_sync (b); wc_drain (f, 300);
    T (seen (f, W_SIGNAL, "ToB", NULL) && !seen (f, W_SIGNAL, "ToA", NULL), "destination rule limits the monitor to messages for one client"); wc_close (f); }
  { const char *rules[] = { "arg0='hit'" }; wconn *f = monitor (rules, 1);
    { wmsg *m = wm_signal ("/s", "x.I", "Hit"); wm_args (m, "s", "hit"); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/s", "x.I", "Miss"); wm_args (m, "s", "miss"); wc_send (a, m); wm_free (m); }
    wc_sync (a); wc_drain (f, 300);
    T (seen (f, W_SIGNAL, "Hit", NULL) && !seen (f, W_SIGNAL, "Miss", NULL), "argument rule works for monitors"); wc_close (f); }
  { const char *rules[] = { "path_namespace='/ns'" }; wconn *f = monitor (rules, 1);
    { wmsg *m = wm_signal ("/ns/a", "x.I", "In"); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/nsx", "x.I", "Out"); wc_send (a, m); wm_free (m); }
    wc_sync (a); wc_drain (f, 300);
    T (seen (f, W_SIGNAL, "In", NULL) && !seen (f, W_SIGNAL, "Out", NULL), "path_namespace rule works for monitors"); wc_close (f); }
  { const char *rules[] = { "type='signal',member='Dup'", "interface='x.I'", "" }; wconn *f = monitor (rules, 3);
    { wmsg *m = wm_signal ("/s", "x.I", "Dup"); wc_send (a, m); wm_free (m); }
    wc_sync (a); wc_drain (f, 300);
    int n = 0; for (int i = 0; i < f->ninbox; i++) if (f->inbox[i]->member && STREQ (f->inbox[i]->member, "Dup")) n++;
    T (n == 1, "a message matching several of the monitor's rules arrives once (%d)", n); wc_close (f); }
  { const char *rules[] = { "" }; wconn *f = monitor (rules, 1);
    { wmsg *m = wm_signal ("/s", "x.I", "AnyThing"); wc_send (a, m); wm_free (m); }
    wc_ping (a, "org.freedesktop.DBus"); wc_drain (f, 300);
    T (seen (f, W_SIGNAL, "AnyThing", NULL) && seen (f, W_CALL, "Ping", NULL), "an empty rule string means everything"); wc_close (f); }

  /* --- several monitors, big messages, ordering */
  { wconn *ms[3]; for (int i = 0; i < 3; i++) ms[i] = monitor (none, 0);
    for (int i = 0; i < 20; i++) { wmsg *m = wm_signal ("/s", "x.I", "Seq"); wm_args (m, "u", (uint32_t) i); wc_send (a, m); wm_free (m); }
    { wmsg *m = wm_signal ("/s", "x.I", "Big"); size_t tk; wm_setstr (&m->sig, "ay"); tk = wm_array_begin (m, 1); for (int i = 0; i < 200000; i++) wm_byte (m, (uint8_t) i); wm_array_end (m, tk, 1); wc_send (a, m); wm_free (m); }
    flush (a, ms, 3);
    for (int k = 0; k < 3; k++)
      {
        int ok = 1, expect = 0, big = 0;
        for (int i = 0; i < ms[k]->ninbox; i++)
          {
            wmsg *m = ms[k]->inbox[i]; uint32_t v;
            if (m->member && STREQ (m->member, "Seq") && wm_arg_u32 (m, 0, &v)) { if ((int) v != expect++) ok = 0; }
            if (m->member && STREQ (m->member, "Big")) big = m->body.len == 4 + 200000;
          }
        T (ok && expect == 20, "monitor %d sees 20 messages in order", k);
        T (big, "monitor %d gets the 200000 byte array intact", k);
      }
    for (int i = 0; i < 3; i++) wc_close (ms[i]); }

  /* --- eavesdrop as match rule key (not required of minibus) */
  if (th_is_real ())
    {
      wconn *e = th_client (D);
      T (wc_add_match (e, "eavesdrop='true',type='method_call'") == 0, "real: eavesdrop rule accepted");
      { wmsg *m = wm_call_args (b->unique, "/p", "x.I", "Eaves", ""); wc_send (a, m); wm_free (m); wm_free (wc_wait_call (b, "Eaves", 2000)); }
      wc_drain (e, 300);
      T (seen (e, W_CALL, "Eaves", NULL), "real: eavesdrop=true sees calls addressed to others");
      wc_close (e);
    }

  /* --- monitor going away */
  { wconn *m2 = monitor (none, 0); wc_close (m2); }
  T (wc_sync (a) == 0 && wc_sync (b) == 0, "traffic fine after monitors disconnect");
  T (th_healthy (D), "daemon healthy");
  wc_close (mon); wc_close (a); wc_close (b); wc_close (w);
  th_stop (D);
MAIN_END

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Name ownership: RequestName, ReleaseName, queues, replacement and the
 * NameOwnerChanged / NameAcquired / NameLost signals. */

#include "t.h"

static tdaemon *D;

#define PRIMARY 1
#define IN_QUEUE 2
#define EXISTS 3
#define ALREADY 4
#define F_ALLOW 1
#define F_REPLACE 2
#define F_NOQUEUE 4

static char *queue_of (wconn *c, const char *name)
{
  wmsg *r = tok (c, wm_bus ("ListQueuedOwners", "s", name)); char *d;
  if (!r) return strdup ("(error)");
  d = wm_dump (r); wm_free (r); return d;
}
static int queue_is (wconn *c, const char *name, const char *a, const char *b, const char *cc)
{
  char *q = queue_of (c, name), want[300]; int ok;
  snprintf (want, sizeof want, "[\"%s\"%s%s%s%s%s%s]", a ? a : "", b ? ",\"" : "", b ? b : "", b ? "\"" : "", cc ? ",\"" : "", cc ? cc : "", cc ? "\"" : "");
  if (!a) strcpy (want, "[]");
  ok = strcmp (q, want) == 0;
  if (!ok) fprintf (stderr, "  queue of %s is %s, wanted %s\n", name, q, want);
  free (q); return ok;
}
static int release (wconn *c, const char *name)
{
  wmsg *r = tok (c, wm_bus ("ReleaseName", "s", name)); uint32_t v = 99;
  if (r) wm_arg_u32 (r, 0, &v);
  wm_free (r); return (int) v;
}
/* does c have a signal member with arg0 within ms */
static int got (wconn *c, const char *member, const char *arg0, int ms)
{
  wmsg *m = wc_wait_sig_arg0 (c, member, arg0, ms); int ok = m != NULL; wm_free (m); return ok;
}
/* NameOwnerChanged (name, old, new) seen? */
typedef struct { const char *n, *o, *w; } noc_t;
static int noc_pred (const wmsg *m, void *x)
{
  noc_t *t = x; char *a = NULL, *b = NULL, *c = NULL; int ok = 0;
  if (m->type != W_SIGNAL || !m->member || strcmp (m->member, "NameOwnerChanged")) return 0;
  a = wm_arg_str (m, 0);
  if (a && !strcmp (a, t->n))
    {
      wr r; const char *s0, *s1, *s2; wr_init (&r, m); s0 = wr_str (&r); s1 = wr_str (&r); s2 = wr_str (&r);
      (void) s0; (void) b; (void) c;
      ok = s1 && s2 && !strcmp (s1, t->o) && !strcmp (s2, t->w);
    }
  free (a);
  return ok;
}
static int noc (wconn *c, const char *n, const char *o, const char *w, int ms)
{
  noc_t t = { n, o, w }; wmsg *m = wc_wait (c, noc_pred, &t, ms); int ok = m != NULL; wm_free (m); return ok;
}
static void settle (wconn *c) { wc_drain (c, 120); wc_clear (c); }
static wconn *watcher (void)
{
  wconn *w = th_client (D);
  wc_add_match (w, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'");
  wc_sync (w);
  return w;
}

MAIN_BEGIN ("t_Names")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *a = th_client (D), *b = th_client (D), *c = th_client (D), *w = watcher ();

  /* --- plain acquisition */
  T (wc_request_name (a, "org.t.One", 0) == PRIMARY, "first RequestName: PRIMARY_OWNER (1)");
  T (a->ninbox > 0 && wc_inbox_find (a, W_SIGNAL, "NameAcquired", "org.t.One") >= 0,
     "NameAcquired(name) is delivered BEFORE the RequestName reply");
  wc_clear (a);
  T (noc (w, "org.t.One", "", a->unique, 2000), "NameOwnerChanged(name, '', owner) reaches a watcher");
  { wmsg *n = NULL; (void) n; }
  T (wc_request_name (a, "org.t.One", 0) == ALREADY, "same owner again: ALREADY_OWNER (4)");
  T (wc_silent (a, 150), "no signal for a repeated request");
  { char *o = wc_get_name_owner (b, "org.t.One"); T (o && STREQ (o, a->unique), "GetNameOwner returns the owner"); free (o); }
  T (wc_name_has_owner (b, "org.t.One") == 1, "NameHasOwner true");
  T (queue_is (b, "org.t.One", a->unique, NULL, NULL), "ListQueuedOwners: [owner]");

  /* --- queueing */
  T (wc_request_name (b, "org.t.One", 0) == IN_QUEUE, "second client: IN_QUEUE (2)");
  T (wc_request_name (c, "org.t.One", 0) == IN_QUEUE, "third client: IN_QUEUE (2)");
  T (queue_is (a, "org.t.One", a->unique, b->unique, c->unique), "queue is FIFO: owner, b, c");
  T (wc_silent (a, 100), "owner is not told about waiters");
  T (wc_inbox_find (b, W_SIGNAL, "NameAcquired", "org.t.One") < 0, "waiters get no NameAcquired");
  T (wc_request_name (b, "org.t.One", 0) == IN_QUEUE, "asking again while queued keeps the place: IN_QUEUE");
  T (queue_is (a, "org.t.One", a->unique, b->unique, c->unique), "queue unchanged by the repeated request");
  T (wc_request_name (b, "org.t.One", F_NOQUEUE) == EXISTS, "DO_NOT_QUEUE while queued: EXISTS (3)");
  T (queue_is (a, "org.t.One", a->unique, c->unique, NULL), "DO_NOT_QUEUE removed b from the queue");
  T (wc_request_name (b, "org.t.One", 0) == IN_QUEUE, "b queues again at the end");
  T (queue_is (a, "org.t.One", a->unique, c->unique, b->unique), "queue: owner, c, b");

  /* --- release hands over to the head of the queue */
  wc_clear (a); wc_clear (b); wc_clear (c); settle (w);
  T (release (a, "org.t.One") == 1, "ReleaseName by the owner: RELEASED (1)");
  T (a->ninbox > 0 && wc_inbox_find (a, W_SIGNAL, "NameLost", "org.t.One") >= 0, "releaser gets NameLost before the reply");
  T (got (c, "NameAcquired", "org.t.One", 2000), "head of the queue (c) gets NameAcquired");
  T (noc (w, "org.t.One", a->unique, c->unique, 2000), "NameOwnerChanged(name, old owner, next owner)");
  T (queue_is (a, "org.t.One", c->unique, b->unique, NULL), "queue: c owns, b waits");
  T (wc_silent (b, 150), "b is not told anything yet");
  T (release (a, "org.t.One") == 3, "ReleaseName by a client that is not the owner nor waiting: NOT_OWNER (3)");
  T (release (b, "org.t.One") == 1, "ReleaseName by a waiting client: RELEASED (1) and it leaves the queue");
  T (queue_is (a, "org.t.One", c->unique, NULL, NULL), "queue: only c");
  T (wc_silent (b, 150) && wc_silent (w, 150), "leaving the queue is silent (no NameLost, no NameOwnerChanged)");
  T (release (c, "org.t.One") == 1, "owner releases: no waiters left");
  T (noc (w, "org.t.One", c->unique, "", 2000), "NameOwnerChanged(name, owner, '')");
  T (wc_name_has_owner (a, "org.t.One") == 0, "name has no owner now");
  T (wc_get_name_owner (a, "org.t.One") == NULL && STREQ (a->err, E_NAME_HAS_NO_OWNER), "GetNameOwner: NameHasNoOwner");
  T (terr (a, wm_bus ("ListQueuedOwners", "s", "org.t.One"), E_NAME_HAS_NO_OWNER), "ListQueuedOwners of a free name: NameHasNoOwner");
  T (release (a, "org.t.One") == 2, "ReleaseName of a name nobody owns: NON_EXISTENT (2)");
  wc_clear (a); wc_clear (b); wc_clear (c); settle (w);

  /* --- replacement */
  T (wc_request_name (a, "org.t.Two", F_ALLOW) == PRIMARY, "a owns Two, allowing replacement");
  T (wc_request_name (b, "org.t.Two", F_REPLACE) == PRIMARY, "b replaces a: PRIMARY_OWNER");
  T (got (a, "NameLost", "org.t.Two", 2000), "the replaced owner gets NameLost");
  T (got (b, "NameAcquired", "org.t.Two", 2000), "the replacer gets NameAcquired");
  T (noc (w, "org.t.Two", a->unique, b->unique, 2000), "a single NameOwnerChanged(old, new)");
  T (queue_is (c, "org.t.Two", b->unique, a->unique, NULL), "the replaced owner waits in the queue");
  T (wc_request_name (a, "org.t.Two", F_REPLACE) == IN_QUEUE, "REPLACE_EXISTING against an owner that did not allow it: IN_QUEUE");
  T (wc_request_name (a, "org.t.Two", F_REPLACE | F_NOQUEUE) == EXISTS, "... and with DO_NOT_QUEUE: EXISTS");
  T (queue_is (c, "org.t.Two", b->unique, NULL, NULL), "a left the queue through DO_NOT_QUEUE");
  T (wc_request_name (c, "org.t.Two", F_REPLACE | F_NOQUEUE) == EXISTS, "an outsider asking with REPLACE_EXISTING|DO_NOT_QUEUE: EXISTS");
  /* the owner changes its mind: flags can be updated by asking again */
  T (wc_request_name (b, "org.t.Two", F_ALLOW) == ALREADY, "owner asks again with ALLOW_REPLACEMENT: ALREADY_OWNER");
  wc_clear (a); wc_clear (b); settle (w);
  T (wc_request_name (a, "org.t.Two", F_REPLACE) == PRIMARY, "a can now replace b (flags were updated)");
  T (queue_is (c, "org.t.Two", a->unique, b->unique, NULL), "queue: a owns, b waits");
  wc_clear (a); wc_clear (b); wc_clear (c); settle (w);
  release (a, "org.t.Two"); release (b, "org.t.Two");

  /* replaced owner that asked DO_NOT_QUEUE is not queued */
  T (wc_request_name (a, "org.t.Three", F_ALLOW | F_NOQUEUE) == PRIMARY, "a owns Three (ALLOW|DO_NOT_QUEUE)");
  T (wc_request_name (b, "org.t.Three", F_REPLACE) == PRIMARY, "b replaces a");
  T (queue_is (c, "org.t.Three", b->unique, NULL, NULL), "a requested DO_NOT_QUEUE so it is not in the queue after being replaced");
  T (got (a, "NameLost", "org.t.Three", 2000), "a got NameLost");
  release (b, "org.t.Three");
  wc_clear (a); wc_clear (b); wc_clear (c); settle (w);

  /* DO_NOT_QUEUE on a free and on a taken name */
  T (wc_request_name (a, "org.t.Four", F_NOQUEUE) == PRIMARY, "DO_NOT_QUEUE on a free name: PRIMARY_OWNER");
  T (wc_request_name (b, "org.t.Four", F_NOQUEUE) == EXISTS, "DO_NOT_QUEUE on a taken name: EXISTS");
  T (queue_is (c, "org.t.Four", a->unique, NULL, NULL), "EXISTS does not queue");
  T (wc_request_name (b, "org.t.Four", 8) == IN_QUEUE, "unknown flag bit 8 is ignored: queued");
  T (wc_request_name (c, "org.t.Four", 0xfff0) == IN_QUEUE, "unknown flag bits are ignored: queued");
  release (a, "org.t.Four"); release (b, "org.t.Four"); release (c, "org.t.Four");
  wc_clear (a); wc_clear (b); wc_clear (c); settle (w);

  /* --- disconnects */
  { wconn *x = th_client (D), *y = th_client (D); char xu[64];
    wc_request_name (x, "org.t.D1", 0); wc_request_name (x, "org.t.D2", 0); wc_request_name (x, "org.t.D3", 0);
    wc_request_name (y, "org.t.D1", 0); wc_request_name (y, "org.t.D2", 0);
    settle (w); wc_clear (y);
    snprintf (xu, sizeof xu, "%s", x->unique);
    wc_close (x);
    T (noc (w, "org.t.D1", xu, y->unique, 3000), "owner disconnects: the queued client inherits D1 (NameOwnerChanged old->new)");
    T (noc (w, "org.t.D2", xu, y->unique, 3000), "... and D2");
    T (noc (w, "org.t.D3", xu, "", 3000), "D3 had no waiter: NameOwnerChanged(old, '')");
    T (noc (w, xu, xu, "", 3000), "the unique name disappears (NameOwnerChanged(:1.x, :1.x, ''))");
    T (got (y, "NameAcquired", "org.t.D1", 3000) && got (y, "NameAcquired", "org.t.D2", 3000), "the inheriting client got NameAcquired for D1 and D2");
    T (wc_name_has_owner (a, "org.t.D3") == 0, "D3 is free");
    T (queue_is (a, "org.t.D1", y->unique, NULL, NULL), "queue of D1 is just y");
    wc_close (y); }
  settle (w);
  { /* queue member disconnects: no NameOwnerChanged for the name, but for its unique name */
    wconn *x = th_client (D), *y = th_client (D); char yu[64];
    wc_request_name (x, "org.t.D4", 0); wc_request_name (y, "org.t.D4", 0);
    settle (w); snprintf (yu, sizeof yu, "%s", y->unique);
    wc_close (y);
    T (noc (w, yu, yu, "", 3000), "waiting client disconnects: its unique name goes away");
    T (queue_is (a, "org.t.D4", x->unique, NULL, NULL), "it left the queue of D4");
    T (wc_inbox_find (w, W_SIGNAL, "NameOwnerChanged", "org.t.D4") < 0, "no NameOwnerChanged for D4 itself");
    wc_close (x); }
  { /* ordering: well-known names before the unique name on disconnect */
    wconn *x = th_client (D); char xu[64]; wmsg *m; int i_unique = -1, i_name = -1;
    wc_request_name (x, "org.t.O1", 0); wc_request_name (x, "org.t.O2", 0);
    settle (w); snprintf (xu, sizeof xu, "%s", x->unique);
    wc_close (x);
    wc_drain (w, 800);
    for (int i = 0; i < w->ninbox; i++)
      {
        m = w->inbox[i]; char *n = wm_arg_str (m, 0);
        if (n && !strcmp (n, xu)) i_unique = i;
        if (n && n[0] == 'o' && i_name < i) i_name = i;
        free (n);
      }
    T (i_unique > i_name && i_name >= 0, "NameOwnerChanged for the unique name comes after those of its well-known names"); }
  settle (w);

  /* --- the signals of connecting */
  { wconn *x; char *u;
    settle (w);
    x = th_client (D);
    T (noc (w, x->unique, "", x->unique, 3000), "a new connection triggers NameOwnerChanged(:1.x, '', :1.x)");
    u = strdup (x->unique); wc_close (x); free (u); settle (w); }

  /* --- name syntax */
  { const char *ok[] = { "a.b", "org.example.Name", "a.b.c.d.e.f", "A.B", "a_b.c_d", "a-b.c-d", "_a._b", "a.b1", "com.example-1.Foo", NULL };
    const char *bad[] = { "x", "", ".a.b", "a..b", "a.b.", "1a.b", "a.1b", "a.b$", "a b.c", ":1.5", ":x", "a.\xc3\xa4", "org.freedesktop.DBus", NULL };
    for (int i = 0; ok[i]; i++)
      {
        T (wc_request_name (a, ok[i], 0) == PRIMARY, "valid name '%s' is accepted", ok[i]);
        release (a, ok[i]);
      }
    for (int i = 0; bad[i]; i++)
      {
        int r = wc_request_name (a, bad[i], 0);
        T (r == -1 && (STREQ (a->err, E_INVALID_ARGS) || STREQ (a->err, E_ACCESS_DENIED)), "invalid name '%s' is refused (%s)", bad[i], a->err);
      }
    { char n[400]; memset (n, 'a', 255); n[1] = '.'; n[255] = 0;
      T (wc_request_name (a, n, 0) == PRIMARY, "a name of 255 characters is accepted"); release (a, n);
      n[255] = 'a'; n[256] = 0;
      T (wc_request_name (a, n, 0) == -1, "a name of 256 characters is refused");
      memset (n, 'a', 399); n[1] = '.'; n[399] = 0;
      T (wc_request_name (a, n, 0) == -1, "a name of 399 characters is refused"); }
    T (wc_request_name (a, "a.b.c", 0) == PRIMARY && release (a, "a.b.c") == 1, "request/release cycle"); }
  T (terr (a, wm_bus ("RequestName", "s", "a.b"), E_INVALID_ARGS), "RequestName with wrong signature (s): InvalidArgs");
  T (terr (a, wm_bus ("RequestName", "", NULL), E_INVALID_ARGS), "RequestName without arguments: InvalidArgs");
  T (terr (a, wm_bus ("RequestName", "us", 1, "a.b"), E_INVALID_ARGS), "RequestName with swapped arguments: InvalidArgs");
  T (terr (a, wm_bus ("ReleaseName", "u", 3), E_INVALID_ARGS), "ReleaseName with wrong signature: InvalidArgs");
  T (terr (a, wm_bus ("ReleaseName", "s", "x"), E_INVALID_ARGS), "ReleaseName of an invalid name: InvalidArgs");
  T (terr (a, wm_bus ("ReleaseName", "s", a->unique), E_INVALID_ARGS), "ReleaseName of the unique name: InvalidArgs");
  T (terr (a, wm_bus ("ReleaseName", "s", "org.freedesktop.DBus"), E_INVALID_ARGS), "ReleaseName of org.freedesktop.DBus: InvalidArgs");
  T (wc_name_has_owner (a, "org.freedesktop.DBus") == 1, "NameHasOwner(org.freedesktop.DBus) is true");
  { char *o = wc_get_name_owner (a, "org.freedesktop.DBus"); T (o && STREQ (o, "org.freedesktop.DBus"), "GetNameOwner(org.freedesktop.DBus) is itself"); free (o); }
  { wmsg *r = tok (a, wm_bus ("ListQueuedOwners", "s", "org.freedesktop.DBus")); char *d = r ? wm_dump (r) : NULL;
    T (d && STREQ (d, "[\"org.freedesktop.DBus\"]"), "ListQueuedOwners(org.freedesktop.DBus)"); free (d); wm_free (r); }
  T (wc_name_has_owner (a, "") == 0 && wc_name_has_owner (a, "x") == 0 && wc_name_has_owner (a, ":9.9") == 0, "NameHasOwner of invalid or unknown names: false");

  /* --- ListNames shows well-known names and unique names, owners listed once */
  wc_request_name (a, "org.t.Listed", 0); wc_request_name (b, "org.t.Listed", 0);
  { wmsg *r = tok (c, wm_bus ("ListNames", "")); char *d = r ? wm_dump (r) : NULL; const char *p; int n = 0;
    T (d && strstr (d, "\"org.t.Listed\""), "ListNames contains a well-known name");
    for (p = d; p && (p = strstr (p, "org.t.Listed")); p++) n++;
    T (n == 1, "a queued name is listed once (%d)", n);
    T (d && strstr (d, a->unique) && strstr (d, b->unique) && strstr (d, c->unique), "ListNames contains all unique names");
    free (d); wm_free (r); }
  { wmsg *r = tok (c, wm_bus ("ListNames", "")); T (r && r->sig && STREQ (r->sig, "as"), "ListNames signature is as"); wm_free (r); }
  { wmsg *r = tok (c, wm_bus ("ListNames", "s", "x")); T (r == NULL, "ListNames with an argument is an error"); }

  /* --- the crowd: 30 clients on one name, handing it down in order */
  { wconn *cs[30]; char prev[64] = ""; int ok = 1;
    for (int i = 0; i < 30; i++) cs[i] = th_client (D);
    for (int i = 0; i < 30; i++) ok = ok && wc_request_name (cs[i], "org.t.Crowd", 0) == (i ? IN_QUEUE : PRIMARY);
    T (ok, "30 clients ask for the same name: one primary, 29 queued");
    { wmsg *r = tok (a, wm_bus ("ListQueuedOwners", "s", "org.t.Crowd")); char *d = r ? wm_dump (r) : NULL; int n = 0;
      for (const char *p = d; p && *p; p++) if (*p == ',') n++;
      T (r && n == 29, "ListQueuedOwners has 30 entries"); free (d); wm_free (r); }
    ok = 1;
    for (int i = 0; i < 29; i++)
      {
        char *o;
        snprintf (prev, sizeof prev, "%s", cs[i]->unique);
        wc_close (cs[i]);
        got (cs[i + 1], "NameAcquired", "org.t.Crowd", 3000);
        o = wc_get_name_owner (a, "org.t.Crowd");
        ok = ok && o && STREQ (o, cs[i + 1]->unique);
        free (o);
      }
    T (ok, "owner after each disconnect is the next one in line, in order");
    for (int i = 29; i < 30; i++) wc_close (cs[i]); }

  T (th_healthy (D), "daemon healthy");
  wc_close (a); wc_close (b); wc_close (c); wc_close (w);
  th_stop (D);
MAIN_END

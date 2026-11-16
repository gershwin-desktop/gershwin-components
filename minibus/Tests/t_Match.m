/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* AddMatch / RemoveMatch: every key, quoting, invalid rules, duplicates.
 *
 * Method: R holds the rule under test plus a permanent marker rule. S sends
 * the test signal and then a marker signal. Messages from one sender reach
 * one receiver in order, so once the marker is in, the test signal was either
 * delivered already or never will be. */

#include "t.h"

static tdaemon *D;
static wconn *S, *S2, *R, *X;

static void add_marker (void) { wc_add_match (R, "type='signal',interface='t.Marker'"); }

typedef struct {
  const char *rule;
  const char *path, *iface, *member;
  const char *sig;            /* signature of the args below */
  const char *a0, *a1, *a2;   /* string args (or a number for 'u') */
  int from2;                  /* send from S2 (owns org.t.S2) instead of S */
  const char *dest;           /* unicast destination, NULL broadcast; "R" = R */
  int expect;
  const char *why;
} row_t;

static wmsg *sigmsg (const row_t *r)
{
  wmsg *m = wm_signal (r->path ? r->path : "/t", r->iface ? r->iface : "t.I", r->member ? r->member : "Sig");
  const char *args[3] = { r->a0, r->a1, r->a2 };
  if (r->sig && r->sig[0])
    {
      wm_setstr (&m->sig, r->sig);
      for (int i = 0; r->sig[i]; i++)
        {
          switch (r->sig[i])
            {
            case 's': wm_str (m, args[i]); break;
            case 'o': wm_str (m, args[i]); break;
            case 'u': wm_u32 (m, (uint32_t) atoi (args[i])); break;
            case 'i': wm_i32 (m, atoi (args[i])); break;
            case 'b': wm_bool (m, atoi (args[i])); break;
            case 'y': wm_byte (m, (uint8_t) atoi (args[i])); break;
            }
        }
    }
  if (r->dest) wm_setstr (&m->dest, STREQ (r->dest, "R") ? R->unique : r->dest);
  return m;
}

/* 1 = delivered, 0 = not, -1 = rule refused */
static int delivered_row (const row_t *r)
{
  wmsg *m = sigmsg (r), *mk; uint32_t ser; int found, rc;
  wconn *snd = r->from2 ? S2 : S;
  rc = wc_add_match (R, r->rule);
  if (rc) return -1;
  ser = wc_send (snd, m); wm_free (m);
  mk = wm_signal ("/t", "t.Marker", "Mark"); wc_send (snd, mk); wm_free (mk);
  { wmsg *got = wc_wait_sig (R, "Mark", 3000); T (got != NULL, "marker arrives (%s)", r->rule); wm_free (got); }
  found = 0;
  for (int i = 0; i < R->ninbox; i++)
    if (R->inbox[i]->serial == ser && R->inbox[i]->type == W_SIGNAL && R->inbox[i]->member && STREQ (R->inbox[i]->member, r->member ? r->member : "Sig")) found++;
  wc_clear (R);
  wc_remove_match (R, r->rule);
  return found;
}

static void run_rows (const row_t *rows, int n)
{
  for (int i = 0; i < n; i++)
    {
      int d = delivered_row (&rows[i]);
      T (d == rows[i].expect, "rule [%s] %s %s %s '%s'%s%s: expect %s got %s%s%s", rows[i].rule,
         rows[i].path ? rows[i].path : "/t", rows[i].iface ? rows[i].iface : "t.I", rows[i].member ? rows[i].member : "Sig",
         rows[i].a0 ? rows[i].a0 : "", rows[i].from2 ? " from S2" : "", rows[i].dest ? " unicast" : "",
         rows[i].expect == 1 ? "delivered" : rows[i].expect == 0 ? "dropped" : "refused",
         d == 1 ? "delivered" : d == 0 ? "dropped" : "refused", rows[i].why ? " - " : "", rows[i].why ? rows[i].why : "");
    }
}

#define ROWS(...) { row_t rows[] = { __VA_ARGS__ }; run_rows (rows, (int) (sizeof rows / sizeof rows[0])); }

static int rule_err (const char *rule, const char *name)
{
  wmsg *rr = NULL; int t = tcall (R, wm_bus ("AddMatch", "s", rule), &rr);
  int ok = t == W_ERROR && rr->errname && STREQ (rr->errname, name);
  if (!ok) fprintf (stderr, "  rule [%s] gave type %d %s\n", rule, t, rr && rr->errname ? rr->errname : "");
  wm_free (rr);
  if (t == W_RETURN) wc_remove_match (R, rule);
  return ok;
}

MAIN_BEGIN ("t_Match")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  S = th_client (D); S2 = th_client (D); R = th_client (D); X = th_client (D);
  wc_request_name (S2, "org.t.S2", 0);
  add_marker ();
  wc_sync (R); wc_clear (R);

  /* --- no rule, no broadcast */
  { wmsg *m = wm_signal ("/t", "t.I", "Quiet"); wc_send (S, m); wm_free (m); m = wm_signal ("/t", "t.Marker", "Mark"); wc_send (S, m); wm_free (m);
    wmsg *g = wc_wait_sig (R, "Mark", 3000); T (g != NULL, "marker arrives");
    T (wc_inbox_find (R, W_SIGNAL, "Quiet", NULL) < 0, "a broadcast without any matching rule is not delivered"); wm_free (g); wc_clear (R); }
  { wmsg *m = wm_signal ("/t", "t.I", "Quiet"); wc_send (S, m); wm_free (m);
    T (wc_silent (X, 200), "a client with no rules receives no broadcast at all"); }

  /* --- type */
  ROWS ({ "type='signal'", .expect = 1 },
        { "type='method_call'", .expect = 0, .why = "a signal is not a method call" },
        { "type='method_return'", .expect = 0 },
        { "type='error'", .expect = 0 },
        { "type=signal", .expect = 1, .why = "unquoted value" },
        { "", .expect = 1, .why = "the empty rule matches every broadcast" })

  /* --- sender */
  { char r1[100], r2[100], r3[100];
    snprintf (r1, sizeof r1, "sender='%s'", S->unique); snprintf (r2, sizeof r2, "sender='%s'", S2->unique); snprintf (r3, sizeof r3, "type='signal',sender='%s'", S2->unique);
    ROWS ({ r1, .expect = 1 }, { r2, .expect = 0 }, { r2, .from2 = 1, .expect = 1 }, { r3, .from2 = 1, .expect = 1 },
          { "sender='org.t.S2'", .from2 = 1, .expect = 1, .why = "well-known name resolves to its owner" },
          { "sender='org.t.S2'", .from2 = 0, .expect = 0 },
          { "sender='org.t.Nobody'", .expect = 0 },
          { "sender='org.freedesktop.DBus'", .expect = 0, .why = "S is not the bus" }) }

  /* --- interface, member, path */
  ROWS ({ "interface='t.I'", .expect = 1 }, { "interface='t.Other'", .expect = 0 },
        { "interface='t'", .expect = -1, .why = "a one-element interface name is invalid" },
        { "member='Sig'", .expect = 1 }, { "member='Sag'", .expect = 0 }, { "member='sig'", .expect = 0, .why = "case sensitive" },
        { "path='/t'", .expect = 1 }, { "path='/'", .expect = 0 }, { "path='/t/x'", .expect = 0 }, { "path='/t', interface='t.I', member='Sig'", .expect = 1 },
        { "type='signal',interface='t.I',member='Sig',path='/t'", .expect = 1 },
        { "type='signal',interface='t.I',member='Sag',path='/t'", .expect = 0, .why = "every key must match" },
        { "type='signal',interface='t.Other',member='Sig',path='/t'", .expect = 0 },
        { "type='signal',interface='t.I',member='Sig',path='/other'", .expect = 0 },
        { "type='method_call',interface='t.I',member='Sig',path='/t'", .expect = 0 })

  /* --- path_namespace */
  ROWS ({ "path_namespace='/t'", .expect = 1 },
        { "path_namespace='/'", .path = "/anything/deep", .expect = 1 },
        { "path_namespace='/a/b'", .path = "/a/b", .expect = 1 },
        { "path_namespace='/a/b'", .path = "/a/b/c", .expect = 1 },
        { "path_namespace='/a/b'", .path = "/a/b/c/d", .expect = 1 },
        { "path_namespace='/a/b'", .path = "/a/bc", .expect = 0, .why = "not a path prefix" },
        { "path_namespace='/a/b'", .path = "/a", .expect = 0 },
        { "path_namespace='/a/b'", .path = "/", .expect = 0 },
        { "path_namespace='/a/b/'", .expect = -1, .why = "trailing slash is not a path" },
        { "path_namespace='a'", .expect = -1 },
        { "path='/a',path_namespace='/a'", .expect = -1, .why = "path and path_namespace exclude each other" })

  /* --- args */
  ROWS ({ "arg0='hello'", .sig = "s", .a0 = "hello", .expect = 1 },
        { "arg0='hello'", .sig = "s", .a0 = "Hello", .expect = 0 },
        { "arg0='hello'", .sig = "s", .a0 = "hello!", .expect = 0 },
        { "arg0='hello'", .sig = "s", .a0 = "hell", .expect = 0 },
        { "arg0='hello'", .expect = 0, .why = "no arguments" },
        { "arg0=''", .sig = "s", .a0 = "", .expect = 1, .why = "empty string argument" },
        { "arg0=''", .sig = "s", .a0 = "x", .expect = 0 },
        { "arg1='b'", .sig = "ss", .a0 = "a", .a1 = "b", .expect = 1 },
        { "arg1='b'", .sig = "ss", .a0 = "b", .a1 = "a", .expect = 0 },
        { "arg1='b'", .sig = "s", .a0 = "b", .expect = 0, .why = "message has only one argument" },
        { "arg0='a',arg1='b'", .sig = "ss", .a0 = "a", .a1 = "b", .expect = 1 },
        { "arg0='a',arg1='c'", .sig = "ss", .a0 = "a", .a1 = "b", .expect = 0 },
        { "arg2='c'", .sig = "sss", .a0 = "a", .a1 = "b", .a2 = "c", .expect = 1 },
        { "arg0='5'", .sig = "u", .a0 = "5", .expect = 0, .why = "only string arguments are matched" },
        { "arg0='/5'", .sig = "o", .a0 = "/5", .expect = 0, .why = "object paths are not strings for argN" },
        { "arg0path='/5'", .sig = "o", .a0 = "/5", .expect = 1, .why = "but argNpath matches object paths" },
        { "arg1='b'", .sig = "uss", .a0 = "1", .a1 = "x", .a2 = "b", .expect = 0, .why = "argN counts every argument" },
        { "arg1='x'", .sig = "uss", .a0 = "1", .a1 = "x", .a2 = "b", .expect = 1 },
        { "arg63='z'", .sig = "s", .a0 = "z", .expect = 0, .why = "arg63 is legal, just not present" },
        { "arg64='z'", .expect = -1, .why = "arg64 is out of range" },
        { "arg0='it'\\''s'", .sig = "s", .a0 = "it's", .expect = 1, .why = "quote escaped as '\\''" },
        { "arg0='a,b'", .sig = "s", .a0 = "a,b", .expect = 1, .why = "comma inside quotes" },
        { "arg0='a b'", .sig = "s", .a0 = "a b", .expect = 1, .why = "space inside quotes" },
        { "arg0='a\\b'", .sig = "s", .a0 = "a\\b", .expect = 1, .why = "backslash is literal inside quotes" },
        { "arg0=x", .sig = "s", .a0 = "x", .expect = 1, .why = "unquoted value" },
        { "arg0='\xc3\xa4'", .sig = "s", .a0 = "\xc3\xa4", .expect = 1, .why = "UTF-8 value" })

  /* --- argNpath */
  ROWS ({ "arg0path='/aa/bb/'", .sig = "s", .a0 = "/", .expect = 1 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/", .expect = 1 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/bb/", .expect = 1 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/bb/cc", .expect = 1 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/bb/cc/", .expect = 1 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/b", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/bb", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/aa/bbb/", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "s", .a0 = "/ab/", .expect = 0 },
        { "arg0path='/aa/bb'", .sig = "s", .a0 = "/aa/bb", .expect = 1 },
        { "arg0path='/aa/bb'", .sig = "s", .a0 = "/aa/", .expect = 1 },
        { "arg0path='/aa/bb'", .sig = "s", .a0 = "/", .expect = 1 },
        { "arg0path='/aa/bb'", .sig = "s", .a0 = "/aa/bb/cc", .expect = 0, .why = "a rule without a trailing slash is a leaf" },
        { "arg0path='/aa/bb'", .sig = "s", .a0 = "/aa/bc", .expect = 0 },
        { "arg0path='/aa/bb/'", .sig = "u", .a0 = "5", .expect = 0 },
        { "arg1path='/x/'", .sig = "ss", .a0 = "/y", .a1 = "/x/z", .expect = 1 })

  /* --- argNnamespace */
  ROWS ({ "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.mycompany.Foo", .expect = 1 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.mycompany.Foo.Bar", .expect = 1 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.mycompany.Foo.Bar.Baz", .expect = 1 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.mycompany.FooBar", .expect = 0 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.mycompany", .expect = 0 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "com.other.Foo", .expect = 0 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "s", .a0 = "", .expect = 0 },
        { "arg0namespace='com.mycompany.Foo'", .sig = "u", .a0 = "5", .expect = 0 },
        { "arg0namespace='com'", .sig = "s", .a0 = "com.x.y", .expect = 1 },
        { "arg0namespace=':1.'", .expect = -1, .why = "namespace must be a valid name" },
        { "arg0namespace='a b'", .expect = -1 })

  /* --- combinations, eavesdrop key, mixed order */
  ROWS ({ "member='Sig',interface='t.I',type='signal'", .expect = 1, .why = "key order does not matter" },
        { "type='signal',sender='org.t.S2',interface='t.I',member='Sig',path='/t',arg0='q',arg1path='/x/'", .sig = "ss", .a0 = "q", .a1 = "/x/y", .from2 = 1, .expect = 1 },
        { "type='signal',sender='org.t.S2',interface='t.I',member='Sig',path='/t',arg0='q',arg1path='/x/'", .sig = "ss", .a0 = "q", .a1 = "/y", .from2 = 1, .expect = 0 },
        { "eavesdrop='false'", .expect = 1 },
        { "eavesdrop='true',type='signal'", .expect = 1 },
        { "type='signal',eavesdrop='maybe'", .expect = -1 })

  /* --- unicast: destination key and who gets what */
  { char ra[100], rb[100];
    snprintf (ra, sizeof ra, "destination='%s'", R->unique); snprintf (rb, sizeof rb, "destination='%s'", X->unique);
    ROWS ({ ra, .expect = 0, .why = "a broadcast has no destination" },
          { rb, .expect = 0 },
          { ra, .dest = "R", .expect = 1 },
          { rb, .dest = "R", .expect = 1, .why = "addressed messages are delivered whatever the rules say" },
          { "interface='t.Other'", .dest = "R", .expect = 1, .why = "addressed messages ignore non-matching rules" },
          { "member='Nope'", .dest = "R", .expect = 1 },
          { "type='signal'", .dest = "R", .expect = 1 }) }
  { /* unicast signal does not reach a third party with a matching rule */
    wmsg *m; wc_add_match (X, "type='signal'"); wc_sync (X); wc_clear (X);
    m = wm_signal ("/t", "t.I", "Uni"); wm_setstr (&m->dest, R->unique); wc_send (S, m); wm_free (m);
    m = wm_signal ("/t", "t.Marker", "Mark"); wm_setstr (&m->dest, X->unique); wc_send (S, m); wm_free (m);
    { wmsg *g = wc_wait_sig (X, "Mark", 3000); T (g != NULL, "marker arrives at X"); wm_free (g); }
    T (wc_inbox_find (X, W_SIGNAL, "Uni", NULL) < 0, "a unicast signal is not copied to other clients with matching rules");
    wc_remove_match (X, "type='signal'"); wc_clear (X); wc_clear (R); }

  /* --- invalid rules */
  { const char *bad[] = { "foo='bar'", "type='bogus'", "type='signal", ",type='signal'", "type='signal',,member='x'", "type", "type=", "'signal'",
                          "member='a',member='b'", "type='signal',type='signal'", "arg0='a',arg0='b'", "path='x'", "path='/x/'", "path='//'", "interface='nodot'", "interface='.a.b'", "interface='a..b'",
                          "member='a.b'", "member='1a'", "member=''", "sender='x'", "sender=''", "sender='a..b'", "destination='x'", "arg='x'", "argx='x'", "arg-1='x'", "arg0x='x'", "arg0Path='/a'",
                          "arg999='x'", "arg0namespace=''", "type='signal' member='x'", "type='signal';member='x'", "eavesdrop='1'", NULL };
    for (int i = 0; bad[i]; i++)
      T (rule_err (bad[i], E_MATCH_INVALID), "invalid rule [%s]: MatchRuleInvalid", bad[i]); }
  T (terr (R, wm_bus ("AddMatch", "u", 1), E_INVALID_ARGS), "AddMatch with wrong signature: InvalidArgs");
  T (terr (R, wm_bus ("AddMatch", "", NULL), E_INVALID_ARGS), "AddMatch without arguments: InvalidArgs");
  T (terr (R, wm_bus ("RemoveMatch", "u", 1), E_INVALID_ARGS), "RemoveMatch with wrong signature: InvalidArgs");
  T (wc_sync (R) == 0, "connection still there after all the invalid rules");

  /* --- RemoveMatch */
  T (wc_remove_match (R, "type='signal',member='NeverAdded'") == -1 && STREQ (R->err, E_MATCH_NOT_FOUND), "RemoveMatch of an unknown rule: MatchRuleNotFound");
  T (wc_remove_match (R, "") == -1 && STREQ (R->err, E_MATCH_NOT_FOUND), "RemoveMatch of an unregistered empty rule: MatchRuleNotFound");
  T (terr (R, wm_bus ("RemoveMatch", "s", "garbage ="), E_MATCH_INVALID), "RemoveMatch of a malformed rule: MatchRuleInvalid");
  T (wc_add_match (R, "type='signal',member='Rm1',interface='t.I'") == 0, "add");
  T (wc_remove_match (R, "interface='t.I',type='signal',member='Rm1'") == 0, "RemoveMatch with the keys in another order finds the same rule");
  T (wc_remove_match (R, "type='signal',member='Rm1',interface='t.I'") == -1, "removing it again: MatchRuleNotFound");
  T (wc_add_match (R, "member='Rm2'") == 0 && wc_remove_match (R, "member = 'Rm2'") == -1, "a differently spelled rule with spaces around = is not the same (or invalid)");
  T (wc_remove_match (R, "member='Rm2'") == 0, "remove the proper one");
  { /* duplicates: delivered once, removed one at a time */
    uint32_t s1; wmsg *m;
    T (wc_add_match (R, "member='Dup'") == 0 && wc_add_match (R, "member='Dup'") == 0, "the same rule can be added twice");
    for (int round = 0; round < 3; round++)
      {
        int want = round < 2;
        wc_clear (R);
        m = wm_signal ("/t", "t.I", "Dup"); s1 = wc_send (S, m); wm_free (m);
        m = wm_signal ("/t", "t.Marker", "Mark"); wc_send (S, m); wm_free (m);
        { wmsg *g = wc_wait_sig (R, "Mark", 3000); wm_free (g); }
        { int n = 0; for (int i = 0; i < R->ninbox; i++) if (R->inbox[i]->serial == s1) n++;
          T (n == (want ? 1 : 0), "round %d: duplicate rule delivers %d copy (got %d)", round, want, n); }
        if (round < 2) T (wc_remove_match (R, "member='Dup'") == 0, "remove one instance (round %d)", round);
      }
    T (wc_remove_match (R, "member='Dup'") == -1, "a third removal fails: MatchRuleNotFound"); wc_clear (R); }
  { /* rules of overlapping nature deliver one copy only */
    uint32_t s1; wmsg *m; int n = 0;
    wc_add_match (R, "member='Ov'"); wc_add_match (R, "interface='t.I'"); wc_add_match (R, "type='signal'"); wc_clear (R);
    m = wm_signal ("/t", "t.I", "Ov"); s1 = wc_send (S, m); wm_free (m);
    m = wm_signal ("/t", "t.Marker", "Mark"); wc_send (S, m); wm_free (m);
    { wmsg *g = wc_wait_sig (R, "Mark", 3000); wm_free (g); }
    for (int i = 0; i < R->ninbox; i++) if (R->inbox[i]->serial == s1) n++;
    T (n == 1, "a message matching three different rules is delivered once (%d)", n);
    wc_remove_match (R, "member='Ov'"); wc_remove_match (R, "interface='t.I'"); wc_remove_match (R, "type='signal'"); wc_clear (R); }

  /* --- many rules, rules die with the connection */
  { wconn *y = th_client (D); char rule[100]; int ok = 1;
    for (int i = 0; i < 300; i++) { snprintf (rule, sizeof rule, "type='signal',member='Many%d'", i); ok = ok && wc_add_match (y, rule) == 0; }
    T (ok, "300 rules on one connection");
    { wmsg *m = wm_signal ("/t", "t.I", "Many299"); uint32_t s = wc_send (S, m); wm_free (m);
      m = wm_signal ("/t", "t.Marker", "Mark"); wc_send (S, m); wm_free (m);
      wc_add_match (y, "type='signal',interface='t.Marker'");
      m = wm_signal ("/t", "t.Marker", "Mark"); wc_send (S, m); wm_free (m);
      { wmsg *g = wc_wait_sig (y, "Mark", 3000); wm_free (g); }
      { int hit = 0; for (int i = 0; i < y->ninbox; i++) if (y->inbox[i]->serial == s) hit = 1; T (hit, "the last of 300 rules still matches"); } }
    for (int i = 0; i < 300; i++) { snprintf (rule, sizeof rule, "type='signal',member='Many%d'", i); ok = ok && wc_remove_match (y, rule) == 0; }
    T (ok, "all 300 rules can be removed again");
    wc_close (y); }
  { /* a reused unique name never inherits rules: new connections start with none */
    wconn *y = th_client (D); T (wc_silent (y, 100), "fresh connection has no rules and gets nothing");
    wc_close (y); }

  /* --- sender rule follows name ownership */
  { wconn *o1 = th_client (D), *o2 = th_client (D); wmsg *m, *g; uint32_t s;
    wc_request_name (o1, "org.t.Mover", 0);
    wc_add_match (R, "type='signal',sender='org.t.Mover',member='Mv'"); wc_sync (R); wc_clear (R);
    m = wm_signal ("/t", "t.I", "Mv"); s = wc_send (o1, m); wm_free (m);
    g = wc_wait_sig (R, "Mv", 2000); T (g && g->serial == s, "first owner of the name matches the sender rule"); wm_free (g);
    wc_release_name (o1, "org.t.Mover"); wc_request_name (o2, "org.t.Mover", 0);
    wc_clear (R);
    m = wm_signal ("/t", "t.I", "Mv"); wc_send (o1, m); wm_free (m);
    m = wm_signal ("/t", "t.I", "Mv"); s = wc_send (o2, m); wm_free (m);
    g = wc_wait_sig (R, "Mv", 2000); T (g && g->serial == s && STREQ (g->sender, o2->unique), "after the name moved, the new owner matches, the old one does not"); wm_free (g);
    wc_remove_match (R, "type='signal',sender='org.t.Mover',member='Mv'"); wc_clear (R);
    wc_close (o1); wc_close (o2); }

  /* --- NameOwnerChanged filtering by arg0 and arg0namespace, as used by real programs */
  { wmsg *g; wconn *o = th_client (D);
    wc_add_match (R, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.t.Watch'"); wc_sync (R); wc_clear (R);
    wc_request_name (o, "org.t.Other", 0); wc_request_name (o, "org.t.Watch", 0);
    g = wc_wait_sig (R, "NameOwnerChanged", 2000);
    { char *a = g ? wm_arg_str (g, 0) : NULL; T (a && STREQ (a, "org.t.Watch"), "NameOwnerChanged filtered by arg0 delivers only the watched name (%s)", a ? a : "-"); free (a); }
    wm_free (g); wc_sync (R); T (wc_inbox_find (R, W_SIGNAL, "NameOwnerChanged", "org.t.Other") < 0, "the other name did not leak through");
    wc_remove_match (R, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.t.Watch'"); wc_clear (R);
    wc_add_match (R, "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.t.ns'"); wc_sync (R); wc_clear (R);
    wc_request_name (o, "org.t.ns.A", 0); wc_request_name (o, "org.t.nsx.B", 0); wc_request_name (o, "org.t.ns", 0);
    wc_sync (o); wc_drain (R, 300);
    T (wc_inbox_find (R, W_SIGNAL, "NameOwnerChanged", "org.t.ns.A") >= 0 && wc_inbox_find (R, W_SIGNAL, "NameOwnerChanged", "org.t.ns") >= 0, "arg0namespace on NameOwnerChanged matches the namespace and its root");
    T (wc_inbox_find (R, W_SIGNAL, "NameOwnerChanged", "org.t.nsx.B") < 0, "... but not a sibling that merely shares the prefix");
    wc_remove_match (R, "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.t.ns'"); wc_clear (R);
    wc_close (o); }

  T (th_healthy (D), "daemon healthy");
  wc_close (S); wc_close (S2); wc_close (R); wc_close (X);
  th_stop (D);
MAIN_END

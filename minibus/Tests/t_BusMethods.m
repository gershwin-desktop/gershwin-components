/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The methods of org.freedesktop.DBus and the standard interfaces the bus
 * implements on itself, including their error paths. Match rules and names
 * have their own tools. */

#include "t.h"

static tdaemon *D;
static wconn *A, *B;

static int is_hex32 (const char *s)
{
  if (!s || strlen (s) != 32) return 0;
  for (int i = 0; i < 32; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  return 1;
}

static char *str_result (wconn *c, wmsg *m) { wmsg *r = tok (c, m); char *s = r ? wm_arg_str (r, 0) : NULL; wm_free (r); return s; }

static int no_reply_to (wconn *c, wmsg *m)
{
  /* send with NO_REPLY_EXPECTED then sync: no reply may show up */
  uint32_t s; int n = 0;
  m->flags |= W_F_NOREPLY;
  s = wc_send (c, m); wm_free (m);
  wc_sync (c);
  for (int i = 0; i < c->ninbox; i++) if (c->inbox[i]->has_reply_serial && c->inbox[i]->reply_serial == s) n++;
  wc_clear (c);
  return n == 0;
}

MAIN_BEGIN ("t_BusMethods")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  A = th_client (D); B = th_client (D);
  wmsg *r;

  /* --- shape of replies from the bus */
  { wmsg *m = wm_bus ("GetId", ""); uint32_t s = wc_send (A, m); wm_free (m);
    T (wc_recv (A, &r, 3000) == 1, "reply arrives");
    T (r && r->type == W_RETURN && r->has_reply_serial && r->reply_serial == s, "METHOD_RETURN with the right reply_serial");
    T (r && STREQ (r->sender, "org.freedesktop.DBus"), "sender is org.freedesktop.DBus");
    T (r && STREQ (r->dest, A->unique), "destination is the caller");
    T (r && r->sig && STREQ (r->sig, "s"), "signature s");
    wm_free (r); }

  /* --- GetId */
  { char *gid = str_result (A, wm_bus ("GetId", "")), *gid2 = str_result (B, wm_bus ("GetId", ""));
    T (is_hex32 (gid), "GetId is 32 lower-case hex digits (%s)", gid ? gid : "-");
    T (gid && gid2 && STREQ (gid, gid2), "GetId is the same for every client");
    free (gid); free (gid2); }
  T (terr (A, wm_bus ("GetId", "s", "x"), E_INVALID_ARGS), "GetId with an argument: InvalidArgs");

  /* --- ListNames / ListActivatableNames */
  { wmsg *l = tok (A, wm_bus ("ListNames", "")); char *d = l ? wm_dump (l) : NULL;
    T (d && strstr (d, "\"org.freedesktop.DBus\"") && strstr (d, A->unique) && strstr (d, B->unique), "ListNames: bus, A and B");
    free (d); wm_free (l); }
  { wmsg *l = tok (A, wm_bus ("ListActivatableNames", "")); char *d = l ? wm_dump (l) : NULL;
    T (l && l->sig && STREQ (l->sig, "as"), "ListActivatableNames returns as");
    T (d && STREQ (d, "[\"org.freedesktop.DBus\"]"), "the bus itself is the only activatable name (%s)", d ? d : "-");
    free (d); wm_free (l); }

  /* --- StartServiceByName */
  T (terr (A, wm_bus ("StartServiceByName", "su", "org.t.Absent", 0), E_SERVICE_UNKNOWN), "StartServiceByName of an unknown service: ServiceUnknown");
  T (terr (A, wm_bus ("StartServiceByName", "su", "org.t.Absent", 5), E_SERVICE_UNKNOWN), "... with flags set too");
  T (terr (A, wm_bus ("StartServiceByName", "s", "org.t.Absent"), E_INVALID_ARGS), "StartServiceByName with one argument: InvalidArgs");
  wc_request_name (B, "org.t.Running", 0);
  T (terr (A, wm_bus ("StartServiceByName", "su", "org.t.Running", 0), E_SERVICE_UNKNOWN), "StartServiceByName of a name that is currently owned: still ServiceUnknown (activation looks at service files only)");

  /* --- UpdateActivationEnvironment, ReloadConfig */
  { wmsg *m = wm_bus ("UpdateActivationEnvironment", ""); size_t tk; wm_setstr (&m->sig, "a{ss}"); tk = wm_array_begin (m, 8); wm_struct_begin (m); wm_str (m, "FOO"); wm_str (m, "bar"); wm_array_end (m, tk, 8);
    r = NULL; T (tcall (A, m, &r) == W_RETURN && r->sig == NULL, "UpdateActivationEnvironment with a dict: empty reply"); wm_free (r); }
  { wmsg *m = wm_bus ("UpdateActivationEnvironment", ""); size_t tk; wm_setstr (&m->sig, "a{ss}"); tk = wm_array_begin (m, 8); wm_array_end (m, tk, 8);
    T (tcall (A, m, NULL) == W_RETURN, "UpdateActivationEnvironment with an empty dict"); }
  T (terr (A, wm_bus ("UpdateActivationEnvironment", ""), E_INVALID_ARGS), "UpdateActivationEnvironment without argument: InvalidArgs");
  T (terr (A, wm_bus ("UpdateActivationEnvironment", "s", "x"), E_INVALID_ARGS), "UpdateActivationEnvironment with a string: InvalidArgs");
  r = NULL; T (tcall (A, wm_bus ("ReloadConfig", ""), &r) == W_RETURN && r->sig == NULL, "ReloadConfig: empty reply"); wm_free (r);
  T (terr (A, wm_bus ("ReloadConfig", "s", "x"), E_INVALID_ARGS), "ReloadConfig with an argument: InvalidArgs");

  /* --- credentials */
  { wmsg *u = tok (A, wm_bus ("GetConnectionUnixUser", "s", B->unique)); uint32_t v = 99999;
    T (u && u->sig && STREQ (u->sig, "u") && wm_arg_u32 (u, 0, &v) && v == (uint32_t) getuid (), "GetConnectionUnixUser(peer) is our uid");
    wm_free (u);
    u = tok (A, wm_bus ("GetConnectionUnixUser", "s", "org.freedesktop.DBus")); v = 99999;
    T (u && wm_arg_u32 (u, 0, &v) && v == (uint32_t) getuid (), "GetConnectionUnixUser(bus) is the daemon's uid"); wm_free (u);
    u = tok (A, wm_bus ("GetConnectionUnixProcessID", "s", B->unique)); v = 0;
    T (u && u->sig && STREQ (u->sig, "u") && wm_arg_u32 (u, 0, &v) && v == (uint32_t) getpid (), "GetConnectionUnixProcessID(peer) is our pid (%u)", v);
    wm_free (u);
    u = tok (A, wm_bus ("GetConnectionUnixProcessID", "s", "org.freedesktop.DBus")); v = 0;
    T (u && wm_arg_u32 (u, 0, &v) && v == (uint32_t) D->pid, "GetConnectionUnixProcessID(bus) is the daemon pid (%u vs %d)", v, (int) D->pid);
    wm_free (u); }
  { wconn *w = th_client (D); wc_request_name (w, "org.t.Cred", 0);
    wmsg *u = tok (A, wm_bus ("GetConnectionUnixUser", "s", "org.t.Cred")); uint32_t v = 99999;
    T (u && wm_arg_u32 (u, 0, &v) && v == (uint32_t) getuid (), "credentials can be asked by well-known name");
    wm_free (u); wc_close (w); }
  { wmsg *c = tok (A, wm_bus ("GetConnectionCredentials", "s", B->unique)); char *d = c ? wm_dump (c) : NULL; char want1[64], want2[64];
    snprintf (want1, sizeof want1, "{\"UnixUserID\":<%u>}", (unsigned) getuid ()); snprintf (want2, sizeof want2, "{\"ProcessID\":<%u>}", (unsigned) getpid ());
    T (c && c->sig && STREQ (c->sig, "a{sv}"), "GetConnectionCredentials returns a{sv}");
    T (d && strstr (d, want1), "credentials carry UnixUserID (%s)", d ? d : "-");
    T (d && strstr (d, want2), "credentials carry ProcessID");
    free (d); wm_free (c); }
  { wmsg *c = tok (A, wm_bus ("GetConnectionCredentials", "s", "org.freedesktop.DBus")); T (c != NULL, "GetConnectionCredentials(bus) works"); wm_free (c); }
  T (terr (A, wm_bus ("GetConnectionUnixUser", "s", "org.t.Absent"), E_NAME_HAS_NO_OWNER), "GetConnectionUnixUser of a missing name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetConnectionUnixUser", "s", ":9.9"), E_NAME_HAS_NO_OWNER), "GetConnectionUnixUser of a missing unique name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetConnectionUnixUser", "s", "x"), E_NAME_HAS_NO_OWNER) || terr (A, wm_bus ("GetConnectionUnixUser", "s", "x"), E_INVALID_ARGS), "GetConnectionUnixUser of an invalid name: refused");
  T (terr (A, wm_bus ("GetConnectionUnixProcessID", "s", "org.t.Absent"), E_NAME_HAS_NO_OWNER), "GetConnectionUnixProcessID of a missing name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetConnectionCredentials", "s", "org.t.Absent"), E_NAME_HAS_NO_OWNER), "GetConnectionCredentials of a missing name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetConnectionUnixUser", "u", 1), E_INVALID_ARGS), "GetConnectionUnixUser with the wrong signature: InvalidArgs");
  T (terr (A, wm_bus ("GetConnectionUnixUser", "", NULL), E_INVALID_ARGS), "GetConnectionUnixUser without arguments: InvalidArgs");
  T (terr (A, wm_bus ("GetConnectionUnixProcessID", "", NULL), E_INVALID_ARGS), "GetConnectionUnixProcessID without arguments: InvalidArgs");
  T (terr (A, wm_bus ("GetConnectionCredentials", "", NULL), E_INVALID_ARGS), "GetConnectionCredentials without arguments: InvalidArgs");
  T (terr (A, wm_bus ("GetAdtAuditSessionData", "s", B->unique), "org.freedesktop.DBus.Error.AdtAuditDataUnknown"), "GetAdtAuditSessionData: AdtAuditDataUnknown");
  T (terr (A, wm_bus ("GetConnectionSELinuxSecurityContext", "s", B->unique), "org.freedesktop.DBus.Error.SELinuxSecurityContextUnknown"), "GetConnectionSELinuxSecurityContext: SELinuxSecurityContextUnknown");
  T (terr (A, wm_bus ("GetAdtAuditSessionData", "s", "org.t.Absent"), E_NAME_HAS_NO_OWNER), "GetAdtAuditSessionData of a missing name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetConnectionSELinuxSecurityContext", "s", "org.t.Absent"), E_NAME_HAS_NO_OWNER), "GetConnectionSELinuxSecurityContext of a missing name: NameHasNoOwner");
  T (terr (A, wm_bus ("GetAdtAuditSessionData", "", NULL), E_INVALID_ARGS), "GetAdtAuditSessionData without arguments: InvalidArgs");
  T (terr (A, wm_bus ("GetConnectionSELinuxSecurityContext", "", NULL), E_INVALID_ARGS), "GetConnectionSELinuxSecurityContext without arguments: InvalidArgs");

  /* --- argument checking for every method */
  { struct { const char *m, *sig; } bad[] = {
      { "Hello", "s" }, { "RequestName", "" }, { "RequestName", "s" }, { "RequestName", "su" /* valid */ }, { "ReleaseName", "" }, { "ReleaseName", "u" },
      { "StartServiceByName", "" }, { "NameHasOwner", "" }, { "NameHasOwner", "u" }, { "ListNames", "s" }, { "ListActivatableNames", "s" },
      { "AddMatch", "" }, { "RemoveMatch", "" }, { "GetNameOwner", "" }, { "GetNameOwner", "u" }, { "ListQueuedOwners", "" }, { "ListQueuedOwners", "u" },
      { "GetId", "u" }, { NULL, NULL } };
    for (int i = 0; bad[i].m; i++)
      {
        wmsg *m = wm_bus (bad[i].m, "", NULL);
        if (bad[i].sig[0]) { wm_setstr (&m->sig, bad[i].sig); for (const char *p = bad[i].sig; *p; p++) if (*p == 's') wm_str (m, "org.t.Arg"); else wm_u32 (m, 1); }
        if (STREQ (bad[i].m, "RequestName") && STREQ (bad[i].sig, "su")) { wm_free (m); continue; }
        T (terr (A, m, E_INVALID_ARGS), "%s with signature '%s': InvalidArgs", bad[i].m, bad[i].sig);
      } }

  /* --- unknown things */
  T (terr (A, wm_bus ("Frobnicate", ""), E_UNKNOWN_METHOD), "unknown method on org.freedesktop.DBus: UnknownMethod");
  T (terr (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.t.Other", "ListNames"), E_UNKNOWN_INTERFACE), "known method name on an unknown interface: UnknownInterface");
  T (terr (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.t.Other", "Whatever"), E_UNKNOWN_INTERFACE) || terr (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.t.Other", "Whatever"), E_UNKNOWN_METHOD),
     "unknown method on an unknown interface: UnknownInterface or UnknownMethod");
  { wmsg *l = tok (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", NULL, "ListNames")); T (l != NULL, "a call without interface header is resolved by member"); wm_free (l); }
  { wmsg *l = tok (A, wm_call ("org.freedesktop.DBus", "/some/other/path", "org.freedesktop.DBus", "ListNames")); T (l != NULL, "the object path of calls to the bus is not checked"); wm_free (l); }
  { wmsg *l = tok (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus", "ListNames")); T (l != NULL, "ListNames on path /"); wm_free (l); }
  T (terr (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Peer", "Foo"), E_UNKNOWN_METHOD), "Peer.Foo: UnknownMethod");
  T (terr (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Introspectable", "Foo"), E_UNKNOWN_METHOD), "Introspectable.Foo: UnknownMethod");
  T (terr (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Properties", "Foo"), E_UNKNOWN_METHOD), "Properties.Foo: UnknownMethod");

  /* --- NO_REPLY_EXPECTED: executed, not answered */
  (void) no_reply_to (A, wm_bus ("ListNames", ""));   /* real: still answered, the flag is only honoured for empty replies */
  T (no_reply_to (A, wm_bus ("AddMatch", "s", "type='signal',member='NoRep'")), "NO_REPLY_EXPECTED AddMatch (empty reply): no reply");
  T (wc_remove_match (A, "type='signal',member='NoRep'") == 0, "... but the rule was installed");
  (void) no_reply_to (A, wm_bus ("RequestName", "su", "org.t.NoRep", 0));
  { char *o = wc_get_name_owner (B, "org.t.NoRep"); T (o && STREQ (o, A->unique), "... but the name was acquired"); free (o); }

  /* --- Peer */
  r = NULL; T (tcall (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Peer", "Ping"), &r) == W_RETURN && r->sig == NULL, "Peer.Ping on /: empty reply"); wm_free (r);
  r = NULL; T (tcall (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Peer", "Ping"), &r) == W_RETURN, "Peer.Ping on the bus path"); wm_free (r);
  r = NULL; T (tcall (A, wm_call ("org.freedesktop.DBus", "/anywhere", "org.freedesktop.DBus.Peer", "Ping"), &r) == W_RETURN, "Peer.Ping on any path"); wm_free (r);
  r = NULL; T (tcall (A, wm_call ("org.freedesktop.DBus", "/", NULL, "Ping"), &r) == W_RETURN, "Ping without interface"); wm_free (r);
  T (terr (A, wm_call_args ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Peer", "Ping", "s", "x"), E_INVALID_ARGS), "Peer.Ping with an argument: InvalidArgs");
  { char *m1 = str_result (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Peer", "GetMachineId")), *m2 = str_result (B, wm_call ("org.freedesktop.DBus", "/x", NULL, "GetMachineId"));
    T (is_hex32 (m1), "GetMachineId is 32 hex digits (%s)", m1 ? m1 : "-"); T (m1 && m2 && STREQ (m1, m2), "GetMachineId is stable");
    free (m1); free (m2); }
  T (terr (A, wm_call_args ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Peer", "GetMachineId", "s", "x"), E_INVALID_ARGS), "GetMachineId with an argument: InvalidArgs");

  /* --- Introspectable */
  { char *x = str_result (A, wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Introspectable", "Introspect"));
    T (x && strstr (x, "<node") && strstr (x, "</node>"), "Introspect returns a <node> document");
    T (x && strncmp (x, "<!DOCTYPE node", 14) == 0, "Introspect starts with the DOCTYPE");
    T (x && strstr (x, "<interface name=\"org.freedesktop.DBus\">"), "it describes org.freedesktop.DBus");
    const char *ifs[] = { "org.freedesktop.DBus.Properties", "org.freedesktop.DBus.Introspectable", "org.freedesktop.DBus.Peer", "org.freedesktop.DBus.Monitoring", NULL };
    for (int i = 0; ifs[i]; i++) { char t[120]; snprintf (t, sizeof t, "<interface name=\"%s\">", ifs[i]); T (x && strstr (x, t), "it describes %s", ifs[i]); }
    const char *meth[] = { "Hello", "RequestName", "ReleaseName", "StartServiceByName", "UpdateActivationEnvironment", "NameHasOwner", "ListNames", "ListActivatableNames",
      "AddMatch", "RemoveMatch", "GetNameOwner", "ListQueuedOwners", "GetConnectionUnixUser", "GetConnectionUnixProcessID", "GetAdtAuditSessionData",
      "GetConnectionSELinuxSecurityContext", "ReloadConfig", "GetId", "GetConnectionCredentials", "BecomeMonitor", "Ping", "GetMachineId", "Introspect", "Get", "GetAll", "Set", NULL };
    for (int i = 0; meth[i]; i++) { char t[120]; snprintf (t, sizeof t, "<method name=\"%s\">", meth[i]); T (x && strstr (x, t), "it lists method %s", meth[i]); }
    const char *sigs[] = { "NameOwnerChanged", "NameLost", "NameAcquired", NULL };
    for (int i = 0; sigs[i]; i++) { char t[120]; snprintf (t, sizeof t, "<signal name=\"%s\">", sigs[i]); T (x && strstr (x, t), "it lists signal %s", sigs[i]); }
    T (x && strstr (x, "<property name=\"Features\"") && strstr (x, "<property name=\"Interfaces\""), "it lists the Features and Interfaces properties");
    free (x); }
  { char *a = str_result (A, wm_call ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Introspectable", "Introspect"));
    T (a && strstr (a, "<node"), "Introspect works on /"); free (a); }
  T (terr (A, wm_call_args ("org.freedesktop.DBus", "/", "org.freedesktop.DBus.Introspectable", "Introspect", "s", "x"), E_INVALID_ARGS), "Introspect with an argument: InvalidArgs");

  /* --- Properties */
#define PR(...) wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Properties", __VA_ARGS__)
  { wmsg *g = tok (A, PR ("Get", "ss", "org.freedesktop.DBus", "Features")); char *d = g ? wm_dump (g) : NULL;
    T (g && g->sig && STREQ (g->sig, "v") && d && d[0] == '<' && d[1] == '[', "Get Features: a variant holding an array of strings (%s)", d ? d : "-");
    free (d); wm_free (g); }
  { wmsg *g = tok (A, PR ("Get", "ss", "org.freedesktop.DBus", "Interfaces")); char *d = g ? wm_dump (g) : NULL;
    T (d && strstr (d, "\"org.freedesktop.DBus.Monitoring\""), "Get Interfaces lists org.freedesktop.DBus.Monitoring (%s)", d ? d : "-");
    free (d); wm_free (g); }
  { wmsg *g = tok (A, PR ("GetAll", "s", "org.freedesktop.DBus")); char *d = g ? wm_dump (g) : NULL;
    T (g && g->sig && STREQ (g->sig, "a{sv}"), "GetAll returns a{sv}");
    T (d && strstr (d, "\"Features\"") && strstr (d, "\"Interfaces\""), "GetAll has Features and Interfaces (%s)", d ? d : "-");
    free (d); wm_free (g); }
  { wmsg *g = tok (A, PR ("GetAll", "s", "org.freedesktop.DBus.Monitoring")); T (g != NULL, "GetAll on the Monitoring interface works (no properties)"); wm_free (g); }
  T (terr (A, PR ("Get", "ss", "org.freedesktop.DBus", "Nope"), E_UNKNOWN_PROPERTY), "Get of an unknown property: UnknownProperty");
  T (terr (A, PR ("Get", "ss", "org.t.X", "Features"), E_UNKNOWN_INTERFACE), "Get on an unknown interface: UnknownInterface");
  T (terr (A, PR ("Get", "ss", "", "Features"), E_UNKNOWN_INTERFACE), "Get with an empty interface: UnknownInterface");
  T (terr (A, PR ("Get", "s", "org.freedesktop.DBus"), E_INVALID_ARGS), "Get with one argument: InvalidArgs");
  T (terr (A, PR ("GetAll", "s", "org.t.X"), E_UNKNOWN_INTERFACE), "GetAll on an unknown interface: UnknownInterface");
  T (terr (A, PR ("GetAll", "", NULL), E_INVALID_ARGS), "GetAll without argument: InvalidArgs");
  { wmsg *m = PR ("Set", "ss", "org.freedesktop.DBus", "Features"); wm_variant_begin (m, "u"); wm_u32 (m, 1); wm_setstr (&m->sig, "ssv");
    T (terr (A, m, E_PROPERTY_READ_ONLY), "Set of a read-only property: PropertyReadOnly"); }
  { wmsg *m = PR ("Set", "ss", "org.freedesktop.DBus", "Nope"); wm_variant_begin (m, "u"); wm_u32 (m, 1); wm_setstr (&m->sig, "ssv");
    T (terr (A, m, E_UNKNOWN_PROPERTY), "Set of an unknown property: UnknownProperty"); }
  T (terr (A, PR ("Set", "ss", "org.freedesktop.DBus", "Features"), E_INVALID_ARGS), "Set without a value: InvalidArgs");

  /* --- a client may use these without being the caller's business: replies are not broadcast */
  T (wc_silent (B, 150), "none of the above leaked to the bystander");

  T (th_healthy (D), "daemon healthy");
  wc_close (A); wc_close (B);
  th_stop (D);
MAIN_END

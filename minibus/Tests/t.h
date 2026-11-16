/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Shared glue for the ObjectTesting tools: Testing.h plus short helpers. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include "wire.h"
#include "harness.h"

#define T(cond, ...) PASS ((cond) ? YES : NO, __VA_ARGS__)
#define STREQ(a, b) ((a) && (b) && strcmp ((a), (b)) == 0)

#define E_UNKNOWN_METHOD "org.freedesktop.DBus.Error.UnknownMethod"
#define E_INVALID_ARGS "org.freedesktop.DBus.Error.InvalidArgs"
#define E_SERVICE_UNKNOWN "org.freedesktop.DBus.Error.ServiceUnknown"
#define E_NAME_HAS_NO_OWNER "org.freedesktop.DBus.Error.NameHasNoOwner"
#define E_MATCH_INVALID "org.freedesktop.DBus.Error.MatchRuleInvalid"
#define E_MATCH_NOT_FOUND "org.freedesktop.DBus.Error.MatchRuleNotFound"
#define E_NO_REPLY "org.freedesktop.DBus.Error.NoReply"
#define E_ACCESS_DENIED "org.freedesktop.DBus.Error.AccessDenied"
#define E_UNKNOWN_OBJECT "org.freedesktop.DBus.Error.UnknownObject"
#define E_UNKNOWN_INTERFACE "org.freedesktop.DBus.Error.UnknownInterface"
#define E_UNKNOWN_PROPERTY "org.freedesktop.DBus.Error.UnknownProperty"
#define E_PROPERTY_READ_ONLY "org.freedesktop.DBus.Error.PropertyReadOnly"

/* Send m (freed) and return the reply type; reply in *r (may be NULL). */
static inline int tcall (wconn *c, wmsg *m, wmsg **r)
{
  wmsg *rr = NULL;
  int t = wc_call (c, m, &rr, 5000);
  wm_free (m);
  if (r) *r = rr; else wm_free (rr);
  return t;
}

/* Call, expect a METHOD_RETURN; returns reply or NULL. */
static inline wmsg *tok (wconn *c, wmsg *m)
{
  wmsg *r = NULL;
  int t = tcall (c, m, &r);
  if (t == W_RETURN) return r;
  wm_free (r);
  return NULL;
}

/* Call and compare the error name. 1 when it matches. */
static inline int terr (wconn *c, wmsg *m, const char *name)
{
  wmsg *r = NULL; int ok;
  int t = tcall (c, m, &r);
  ok = t == W_ERROR && r && r->errname && strcmp (r->errname, name) == 0;
  if (!ok)
    fprintf (stderr, "  terr: expected %s got type %d %s\n", name, t,
             r && r->errname ? r->errname : "-");
  wm_free (r);
  return ok;
}

/* Dump a message for diagnostics. */
static inline void tdump (const char *tag, const wmsg *m)
{
  char *d;
  if (!m) { fprintf (stderr, "  %s: (null)\n", tag); return; }
  d = wm_dump (m);
  fprintf (stderr, "  %s: type=%d flags=%d ser=%u rs=%d/%u path=%s if=%s mb=%s err=%s dst=%s snd=%s sig=%s body=%s\n",
           tag, m->type, m->flags, m->serial, m->has_reply_serial, m->reply_serial,
           m->path ? m->path : "-", m->iface ? m->iface : "-", m->member ? m->member : "-",
           m->errname ? m->errname : "-", m->dest ? m->dest : "-",
           m->sender ? m->sender : "-", m->sig ? m->sig : "-", d);
  free (d);
}

/* Is s a valid unique name: ":" followed by elements with at least one dot */
static inline int is_unique_name (const char *s)
{
  int dots = 0;
  if (!s || s[0] != ':' || !s[1]) return 0;
  for (const char *p = s + 1; *p; p++)
    if (*p == '.') dots++;
    else if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'z')
               || (*p >= 'A' && *p <= 'Z') || *p == '_' || *p == '-'))
      return 0;
  return dots >= 1;
}

/* An unrelated client still works: used after hostile input. */
static inline int th_healthy (tdaemon *d)
{
  wconn *c = th_client (d);
  int ok = c && wc_sync (c) == 0;
  wc_close (c);
  return ok;
}

#define MAIN_BEGIN(name) \
  int main (void) { \
    NSAutoreleasePool *pool = [NSAutoreleasePool new]; \
    /* libobjc2 needs a real (not tagged, longer than 7 chars) constant string to link */ \
    if (getenv ("MBT_NEVER_SET")) NSLog (@"link anchor string, never printed"); \
    th_init (name);
#define MAIN_END \
    [pool release]; \
    return 0; }

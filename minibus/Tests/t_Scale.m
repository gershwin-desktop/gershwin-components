/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Many connections (beyond FD_SETSIZE), fan-out, slow readers, churn.
 * MINIBUS_TEST_CLIENTS sets the crowd size (default 1100), MINIBUS_TEST_FLOOD_MB
 * the volume sent at slow readers (default 96). */

#include "t.h"
#include <dirent.h>
#include <sys/socket.h>
#include <time.h>
#include <poll.h>

static tdaemon *D;

/* resident set of the daemon in KiB, -1 when unknown */
static long daemon_rss_kb (void)
{
  char p[64], l[200]; FILE *f; long kb = -1;
  snprintf (p, sizeof p, "/proc/%d/status", (int) D->pid);
  f = fopen (p, "r");
  if (!f) return -1;
  while (fgets (l, sizeof l, f)) if (strncmp (l, "VmRSS:", 6) == 0) kb = atol (l + 6);
  fclose (f);
  return kb;
}

static int daemon_fds (void)
{
  char p[64]; DIR *d; int n = 0;
  snprintf (p, sizeof p, "/proc/%d/fd", (int) D->pid);
  d = opendir (p);
  if (!d) return -1;
  while (readdir (d)) n++;
  closedir (d);
  return n;
}

/* read everything the daemon has queued for c; 1 when it ended with EOF */
static int drain_to_eof (wconn *c, int quiet_ms, long *bytes)
{
  char buf[65536]; long total = 0;
  for (;;)
    {
      struct pollfd pf = { c->fd, POLLIN, 0 }; int pr = poll (&pf, 1, quiet_ms);
      if (pr <= 0) break;
      ssize_t n = read (c->fd, buf, sizeof buf);
      if (n <= 0) { if (bytes) *bytes = total; return 1; }
      total += n;
    }
  if (bytes) *bytes = total;
  return 0;
}

MAIN_BEGIN ("t_Scale")
  int limit = th_resource_limit ();
  /* the real dbus-daemon keeps about four descriptors per connection (socket, pidfd, ...) and
   has the same 4096 hard limit as we do, so it can only serve about 1000 clients */
  int N = getenv ("MINIBUS_TEST_CLIENTS") ? atoi (getenv ("MINIBUS_TEST_CLIENTS")) : (th_is_real () ? 900 : 1100);
  int flood_mb = getenv ("MINIBUS_TEST_FLOOD_MB") ? atoi (getenv ("MINIBUS_TEST_FLOOD_MB")) : 96;
  if (N + 100 > limit / 2) { fprintf (stderr, "NOTE: fd limit %d too low for %d clients, reducing\n", limit, N); N = limit / 2 - 100; }
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  fprintf (stderr, "crowd of %d clients, fd limit %d\n", N, limit);

  /* --- the crowd */
  wconn **cs = calloc (N, sizeof *cs); int up = 0, maxfd = 0;
  for (int i = 0; i < N; i++)
    {
      cs[i] = th_raw (D);
      if (cs[i] && wc_auth (cs[i], WA_EXTERNAL) == 0 && wc_hello (cs[i]) == 0) { up++; if (cs[i]->fd > maxfd) maxfd = cs[i]->fd; }
      else { fprintf (stderr, "client %d could not be served (daemon fd limit?), crowd cut to %d\n", i, i); wc_close (cs[i]); cs[i] = NULL; break; }
    }
  { int served = up; T (up == N, "%d clients connected, authenticated and said Hello (%d)", N, up); N = served; }
  if (N < 2) { T (0, "need a crowd"); return 1; }
  { int distinct = 1; char **names = calloc (N, sizeof *names);
    for (int i = 0; i < N; i++) { names[i] = cs[i] ? cs[i]->unique : ""; }
    /* unique names are increasing, so adjacent comparison suffices after the numeric check */
    int last = -1; for (int i = 0; i < N; i++) { int n = cs[i] ? atoi (strrchr (cs[i]->unique, '.') + 1) : -1; if (n <= last) distinct = 0; last = n; }
    T (distinct, "all %d unique names are distinct and increasing", N); free (names); }
  wconn *probe = th_client (D);
  { wmsg *l = tok (probe, wm_bus ("ListNames", "")); int n = 0; char *d = l ? wm_dump (l) : NULL;
    for (const char *p = d; p && *p; p++) if (*p == ',') n++;
    T (n + 1 >= N, "ListNames with %d entries works (%d)", N, n + 1); free (d); wm_free (l); }
  { int ok = 1;
    for (int i = 0; i < N && ok; i += 7) ok = ok && cs[i] && wc_sync (cs[i]) == 0;
    T (ok, "every 7th client round-trips with the bus"); }
  { /* the clients with the highest descriptors in the daemon are the last ones connected */
    wconn *hi = cs[N - 1], *lo = cs[0]; wmsg *m, *g;
    wc_request_name (hi, "org.t.HighFd", 0);
    m = wm_call_args ("org.t.HighFd", "/", "t.I", "Hi", "s", "from low"); wc_send (lo, m); wm_free (m);
    g = wc_wait_call (hi, "Hi", 5000); T (g != NULL, "a call from the first to the last of %d clients (daemon fd well above 1024 if N > 1020)", N);
    if (g) { wc_reply_empty (hi, g); wm_free (g); }
    m = NULL; { int rc; while ((rc = wc_recv (lo, &m, 5000)) == 1 && m->type != W_RETURN) wm_free (m); T (rc == 1 && m->type == W_RETURN, "and the answer comes back"); } wm_free (m);
    m = wm_call_args (lo->unique, "/", "t.I", "Lo", ""); wc_send (hi, m); wm_free (m);
    g = wc_wait_call (lo, "Lo", 5000); T (g != NULL, "and in the other direction"); wm_free (g); }

  /* --- fan-out of broadcasts to the whole crowd */
  { int M = 20, ok = 1;
    for (int i = 0; i < N; i++) wc_add_match (cs[i], "type='signal',interface='t.Crowd'");
    wc_sync (probe);
    for (int k = 0; k < M; k++) { wmsg *m = wm_signal ("/c", "t.Crowd", "N"); wm_args (m, "u", (uint32_t) k); wc_send (probe, m); wm_free (m); }
    for (int i = 0; i < N && ok; i++)
      for (int k = 0; k < M && ok; k++)
        { wmsg *s = NULL; uint32_t v = 0; int rc;
          while ((rc = wc_recv (cs[i], &s, 10000)) == 1 && !(s->type == W_SIGNAL && s->member && STREQ (s->member, "N"))) wm_free (s);
          if (rc != 1 || !wm_arg_u32 (s, 0, &v) || (int) v != k) ok = 0;
          wm_free (s); }
    T (ok, "%d broadcasts reached all %d clients in order", M, N); }
  { /* names and ownership at scale: everybody queues for one name, then they leave */
    int ok = 1;
    for (int i = 0; i < N && ok; i++) ok = ok && wc_request_name (cs[i], "org.t.Everyone", 0) == (i ? 2 : 1);
    T (ok, "%d clients queue for one name", N);
    { wmsg *q = tok (probe, wm_bus ("ListQueuedOwners", "s", "org.t.Everyone")); int n = 0; char *d = q ? wm_dump (q) : NULL;
      for (const char *p = d; p && *p; p++) if (*p == ',') n++;
      T (n + 1 == N, "ListQueuedOwners has %d entries (%d)", N, n + 1); free (d); wm_free (q); } }

  /* --- everybody leaves at once */
  { int before = daemon_fds ();
    for (int i = 0; i < N; i++) { wc_close (cs[i]); cs[i] = NULL; }
    for (int i = 0; i < 200 && wc_name_has_owner (probe, "org.t.Everyone") == 1; i++) usleep (50000);
    T (wc_name_has_owner (probe, "org.t.Everyone") == 0, "after all %d owners and waiters disconnected the name is free", N);
    { wmsg *l = tok (probe, wm_bus ("ListNames", "")); char *d = l ? wm_dump (l) : NULL; int n = 0;
      for (const char *p = d; p && *p; p++) if (*p == ',') n++;
      T (n + 1 <= 3, "ListNames is back to the bus and the probe (%d entries)", n + 1); free (d); wm_free (l); }
    int after = daemon_fds ();
    T (before < 0 || after < before - N / 2 || after < 40, "the daemon released its descriptors (%d -> %d)", before, after); }
  free (cs);

  /* --- churn: connect, talk, disconnect, with a descriptor leak check */
  { int base, now; wconn *x = th_client (D); wc_close (x); usleep (200000); base = daemon_fds ();
    for (int i = 0; i < 1500; i++)
      {
        wconn *c = th_raw (D);
        if (!c) { T (0, "churn: connect %d", i); break; }
        switch (i % 4)
          {
          case 0: wc_auth (c, WA_EXTERNAL); wc_hello (c); wc_request_name (c, "org.t.Churn", 0); wc_add_match (c, "type='signal'"); break;
          case 1: wc_send_nul (c); break;
          case 2: wc_auth (c, WA_EXTERNAL); break;
          case 3: wc_auth (c, WA_EXTERNAL); wc_hello (c); wc_ping (c, "org.freedesktop.DBus"); break;
          }
        wc_close (c);
      }
    usleep (500000);
    now = daemon_fds ();
    T (th_healthy (D), "daemon healthy after 1500 connect/disconnect cycles");
    T (base < 0 || now <= base + 2, "no descriptor leak in the daemon (%d before, %d after)", base, now); }

  /* --- a slow reader must not hurt the others */
  {
    wconn *slow = th_client (D), *src = th_client (D), *other = th_client (D), *other2 = th_client (D);
    long rss0 = daemon_rss_kb ();
    int small = 4096; long sent = 0; int worst = 0;
    setsockopt (slow->fd, SOL_SOCKET, SO_RCVBUF, &small, sizeof small);
    wc_add_match (slow, "type='signal',interface='t.Flood'"); wc_sync (slow);
    wc_add_match (other2, "type='signal',interface='t.Flood'"); wc_sync (other2);
    wc_clear (slow);
    /* from here on 'slow' never reads until the end */
    {
      size_t chunk = 64 * 1024; long total = (long) flood_mb * 1024 * 1024; int n = 0;
      wmsg *m = wm_signal ("/f", "t.Flood", "B"); size_t tk; uint8_t *junk = calloc (1, chunk);
      wm_setstr (&m->sig, "ay"); tk = wm_array_begin (m, 1); wm_raw (m, junk, chunk); wm_array_end (m, tk, 1); free (junk);
      m->serial = 0;
      while (sent < total)
        {
          int t0, dt;
          m->serial = 0;
          if (!wc_send (src, m)) { T (0, "flood: sender stuck after %ld bytes", sent); break; }
          sent += (long) m->body.len; n++;
          /* the receiver that does read keeps up */
          { wmsg *r = NULL; if (wc_recv (other2, &r, 10000) == 1) wm_free (r); else { T (0, "flood: reading receiver starved at message %d", n); break; } }
          if (n % 8 == 0)
            {
              t0 = wire_ms (); if (wc_sync (other) != 0) { T (0, "flood: bystander lost"); break; } dt = wire_ms () - t0;
              if (dt > worst) worst = dt;
            }
        }
      wm_free (m);
      T (sent >= (long) flood_mb * 1024 * 1024 - 65536, "flood of %ld MiB sent in full", sent >> 20);
      T (worst < 2000, "a bystander's round trip during the flood never took longer than %d ms (limit 2000)", worst);
    }
    {
      long got = 0, rss1 = daemon_rss_kb (); int eof = drain_to_eof (slow, 1500, &got);
      /* the real daemon keeps the connection but stops queueing (about max_outgoing_bytes arrive); a daemon
         may as well disconnect. What it must not do is buffer the whole flood for a reader that never reads. */
      T (eof || got < sent / 2, "a reader that never read gets a bounded share: %s, %ld of %ld bytes received", eof ? "connection closed" : "connection kept", got, sent);
      T (rss0 < 0 || rss1 < 0 || rss1 - rss0 < (long) flood_mb * 1024 * 3 / 4, "daemon memory stays bounded during the flood (RSS %ld -> %ld KiB)", rss0, rss1);
    }
    T (th_healthy (D) && wc_sync (other) == 0 && wc_sync (other2) == 0 && wc_sync (src) == 0, "everybody else still works afterwards");
    wc_close (slow); wc_close (src); wc_close (other); wc_close (other2);
  }
  /* a monitor that never reads is subject to the same rule */
  {
    wconn *mon = th_client (D), *src = th_client (D), *other = th_client (D); int small = 4096; long sent = 0; const char *none[] = { NULL };
    setsockopt (mon->fd, SOL_SOCKET, SO_RCVBUF, &small, sizeof small);
    T (tcall (mon, wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu", none, 0, 0u), NULL) == W_RETURN, "monitor created");
    { size_t chunk = 64 * 1024; long total = (long) flood_mb * 1024 * 1024; wmsg *m = wm_signal ("/f", "t.Flood", "B"); size_t tk; uint8_t *junk = calloc (1, chunk);
      wm_setstr (&m->sig, "ay"); tk = wm_array_begin (m, 1); wm_raw (m, junk, chunk); wm_array_end (m, tk, 1); free (junk);
      while (sent < total) { m->serial = 0; if (!wc_send (src, m)) break; sent += (long) m->body.len; if ((sent >> 16) % 16 == 0) wc_sync (other); }
      wm_free (m); }
    T (sent >= (long) flood_mb * 1024 * 1024 - 65536 && wc_sync (other) == 0, "traffic flows while a monitor does not read");
    /* real dbus-daemon queues everything for a monitor that never reads, so only responsiveness is checked */
    T (th_healthy (D), "daemon healthy");
    wc_close (mon); wc_close (src); wc_close (other);
  }
  /* a client that sends requests but never reads the answers */
  {
    wconn *dd = th_client (D), *other = th_client (D); wbuf all = { 0 }; int n = 4000; uint32_t first = dd->next_serial; int ok = 1;
    for (int i = 0; i < n; i++) { wmsg *m = wm_bus ("GetId", ""); m->serial = dd->next_serial++; wm_encode (m, &all); wm_free (m); }
    wc_send_raw (dd, all.d, all.len); wbuf_free (&all);
    T (wc_sync (other) == 0, "a bystander is served while another client has %d unread answers pending", n);
    for (int i = 0; i < n && ok; i++) { wmsg *s = NULL; if (wc_recv (dd, &s, 5000) != 1 || s->type != W_RETURN || s->reply_serial != first + i) ok = 0; wm_free (s); }
    T (ok, "and when it finally reads, all %d answers are there in order", n);
    wc_close (dd); wc_close (other);
  }
  /* a peer that is slow to take a unicast: caller of a never-reading callee does not block others */
  {
    wconn *callee = th_client (D), *caller = th_client (D), *other = th_client (D); int small = 4096; int ok = 1;
    setsockopt (callee->fd, SOL_SOCKET, SO_RCVBUF, &small, sizeof small);
    for (int i = 0; i < 300 && ok; i++)
      { wmsg *m = wm_call_args (callee->unique, "/", "t.I", "Never", ""); m->flags = W_F_NOREPLY; ok = wc_send (caller, m) != 0; wm_free (m); if (i % 10 == 0) ok = ok && wc_sync (other) == 0; }
    T (ok, "300 calls to a callee that never reads: caller and bystander stay responsive");
    wc_close (callee); wc_close (caller); wc_close (other);
  }

  T (th_healthy (D), "daemon healthy at the end");
  T (th_alive (D), "daemon still running");
  wc_close (probe);
  th_stop (D);
MAIN_END

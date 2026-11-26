/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Unix file descriptor passing (SCM_RIGHTS, NEGOTIATE_UNIX_FD). */

#include "t.h"
#include <fcntl.h>
#include <dirent.h>


static tdaemon *D;

static wconn *client (int fd_ok)
{
  wconn *c = th_raw (D);
  if (wc_auth (c, WA_EXTERNAL | (fd_ok ? WA_FD : 0)) || wc_hello (c)) return NULL;
  wm_free (wc_wait_sig_arg0 (c, "NameAcquired", c->unique, 2000));
  return c;
}

/* an unlinked file holding s; reading it with pread works from any dup */
static int mkfile (const char *s)
{
  char p[300]; int fd;
  snprintf (p, sizeof p, "%s/fdfile.XXXXXX", D->dir);
  fd = mkstemp (p);
  if (fd < 0) return -1;
  unlink (p);
  if (write (fd, s, strlen (s)) < 0) { }
  return fd;
}
static int content_is (int fd, const char *s)
{
  char b[100] = { 0 };
  ssize_t n = pread (fd, b, sizeof b - 1, 0);
  if (!(n == (ssize_t) strlen (s) && strcmp (b, s) == 0)) fprintf (stderr, "  content_is: fd %d n=%zd got '%s' wanted '%s'\n", fd, n, b, s);
  return n == (ssize_t) strlen (s) && strcmp (b, s) == 0;
}

static wmsg *fdmsg (const char *dest, const char *member, int n, const int *fds)
{
  wmsg *m = wm_call (dest, "/f", "t.Fd", member); size_t tk;
  wm_setstr (&m->sig, "ah"); tk = wm_array_begin (m, 4);
  for (int i = 0; i < n; i++) wm_fd (m, fds[i]);
  wm_array_end (m, tk, 4);
  return m;
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

MAIN_BEGIN ("t_Fds")
  D = th_start (NULL);
  if (!D) { T (0, "daemon starts"); return 1; }
  wconn *a = client (1), *b = client (1), *c = client (1), *nn = client (0);
  wmsg *g;

  /* --- one fd, content really crosses */
  { int p[2]; pipe (p);
    wmsg *m = fdmsg (b->unique, "One", 1, &p[0]); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "One", 3000);
    T (g != NULL, "a call carrying one fd is delivered");
    T (g && g->nfds == 1 && g->fds[0] >= 0, "and arrives with exactly one fd");
    T (g && g->has_unix_fds && g->unix_fds == 1, "the UNIX_FDS header field says 1");
    T (g && g->fds[0] != p[0], "it is a new descriptor in the receiver (not the same number by accident of sharing)") ;
    if (g && g->nfds)
      {
        char buf[16] = { 0 }; ssize_t n;
        if (write (p[1], "hello", 5) < 0) { }
        n = read (g->fds[0], buf, sizeof buf);
        T (n == 5 && memcmp (buf, "hello", 5) == 0, "data written to the write end is read through the received fd");
        close (g->fds[0]);
      }
    wm_free (g); close (p[0]); close (p[1]); }

  /* --- three fds, order kept */
  { int f[3] = { mkfile ("zero"), mkfile ("one"), mkfile ("two") };
    wmsg *m = fdmsg (b->unique, "Three", 3, f); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Three", 3000);
    T (g && g->nfds == 3, "three fds arrive");
    T (g && g->nfds == 3 && content_is (g->fds[0], "zero") && content_is (g->fds[1], "one") && content_is (g->fds[2], "two"), "in the order they were sent, with the right files");
    { char *d = g ? wm_dump (g) : NULL; T (d && STREQ (d, "[fd#0,fd#1,fd#2]"), "the body indexes are 0,1,2 (%s)", d ? d : "-"); free (d); }
    for (int i = 0; g && i < g->nfds; i++) close (g->fds[i]);
    wm_free (g); for (int i = 0; i < 3; i++) close (f[i]); }

  /* --- 16 is the usual maximum, 17 is too many */
  { int f[17]; for (int i = 0; i < 17; i++) f[i] = mkfile ("x");
    wmsg *m = fdmsg (b->unique, "Sixteen", 16, f); wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Sixteen", 3000); T (g && g->nfds == 16, "16 fds in one message are delivered");
    for (int i = 0; g && i < g->nfds; i++) close (g->fds[i]); wm_free (g);
    { wconn *x = client (1); m = fdmsg (b->unique, "Seventeen", 17, f); wc_send (x, m); wm_free (m);
      T (wc_wait_eof (x, 3000), "17 fds in one message: the sender is disconnected");
      wc_close (x); }
    T (wc_sync (b) == 0 && wc_sync (a) == 0, "everybody else is unaffected");
    for (int i = 0; i < 17; i++) close (f[i]); }

  /* --- receiver that did not negotiate */
  { int f = mkfile ("nn");
    wmsg *m = fdmsg (nn->unique, "ToNN", 1, &f); wc_send (a, m); wm_free (m);
    g = NULL; wc_recv (a, &g, 3000);
    T (g && g->type == W_ERROR && STREQ (g->errname, "org.freedesktop.DBus.Error.NotSupported"), "fd to a client that never negotiated: sender gets NotSupported (%s)", g && g->errname ? g->errname : "-");
    wm_free (g);
    T (wc_silent (nn, 300), "the non-negotiating client sees nothing of it");
    T (wc_sync (a) == 0 && wc_sync (nn) == 0, "both connections live on");
    { wmsg *p = wm_call (nn->unique, "/", "t.I", "Plain"); wc_send (a, p); wm_free (p); g = wc_wait_call (nn, "Plain", 2000); T (g != NULL, "and plain messages still flow"); wm_free (g); }
    close (f); }
  { /* a broadcast with an fd is simply not delivered to a client that cannot take it */
    int f = mkfile ("bc"); wmsg *m; wc_add_match (nn, "type='signal',interface='t.FdBc'"); wc_add_match (b, "type='signal',interface='t.FdBc'"); wc_sync (nn); wc_sync (b); wc_clear (b); wc_clear (nn);
    m = wm_signal ("/f", "t.FdBc", "S"); wm_setstr (&m->sig, "h"); wm_fd (m, f); wc_send (a, m); wm_free (m);
    g = wc_wait_sig (b, "S", 3000); T (g && g->nfds == 1 && content_is (g->fds[0], "bc"), "broadcast with fd reaches the fd-capable subscriber"); if (g) close (g->fds[0]); wm_free (g);
    T (wc_silent (nn, 300), "... and skips the one that cannot receive fds");
    T (wc_sync (a) == 0 && wc_sync (nn) == 0, "nobody is dropped for it");
    wc_remove_match (nn, "type='signal',interface='t.FdBc'"); wc_remove_match (b, "type='signal',interface='t.FdBc'"); wc_clear (a); close (f); }

  /* --- sender that did not negotiate */
  { wconn *x = client (0); int f = mkfile ("x");
    wmsg *m = fdmsg (b->unique, "Illegal", 1, &f); wc_send (x, m); wm_free (m);
    T (wc_wait_eof (x, 3000), "fd sent by a client that did not negotiate: disconnected");
    T (wc_silent (b, 200), "and nothing is delivered"); wc_close (x); close (f); }

  /* --- header count versus fds actually attached */
  { wconn *x = client (1); int f = mkfile ("x");
    wmsg *m = fdmsg (b->unique, "TooFew", 1, &f); m->has_unix_fds = 1; m->unix_fds = 2; wc_send (x, m); wm_free (m);
    T (wc_wait_eof (x, 3000), "UNIX_FDS says 2 but only 1 fd came along: sender disconnected"); wc_close (x); close (f); }
  { /* throw-away sender and receiver: libdbus-style daemons keep surplus descriptors in a per-connection queue and
       attach them to the next message that carries fds, so the sender is desynchronised for good */
    wconn *rx = client (1), *tx = client (1); int f1 = mkfile ("one"), f2 = mkfile ("two"); wmsg *m = fdmsg (rx->unique, "TooMany", 1, &f1);
    m->fds[1] = f2; m->nfds = 2; m->has_unix_fds = 1; m->unix_fds = 1;
    wc_send (tx, m); wm_free (m);
    g = wc_wait_call (rx, "TooMany", 3000); T (g && g->nfds == 1, "UNIX_FDS says 1 and 2 fds came along: the message is delivered with 1");
    if (g) close (g->fds[0]); wm_free (g); T (wc_sync (tx) == 0, "sender not penalised"); close (f1); close (f2); wc_close (rx); wc_close (tx); }
  { int f = mkfile ("x"); wmsg *m = wm_call (b->unique, "/f", "t.Fd", "NoRef"); m->fds[0] = f; m->nfds = 1; wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "NoRef", 3000); T (g != NULL, "an fd that the body never references does not break delivery"); if (g && g->nfds) close (g->fds[0]); wm_free (g); close (f); }
  { wmsg *m = wm_call (b->unique, "/f", "t.Fd", "NoFds"); m->has_unix_fds = 1; m->unix_fds = 0; wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "NoFds", 3000); T (g != NULL && g->nfds == 0, "UNIX_FDS = 0 is fine"); wm_free (g); }

  /* --- fd in a reply, in a broadcast, in big endian */
  { wmsg *m = wm_call (b->unique, "/f", "t.Fd", "Get"); uint32_t s = wc_send (a, m); wm_free (m);
    g = wc_wait_call (b, "Get", 3000); int f = mkfile ("reply-fd");
    wmsg *rep = wm_return (g); wm_setstr (&rep->sig, "h"); wm_fd (rep, f); wc_send (b, rep); wm_free (rep); wm_free (g);
    wmsg *r = NULL; wc_recv (a, &r, 3000);
    T (r && r->type == W_RETURN && r->reply_serial == s && r->nfds == 1 && content_is (r->fds[0], "reply-fd"), "an fd can travel in a method return");
    if (r && r->nfds) close (r->fds[0]); wm_free (r); close (f); }
  { int f = mkfile ("shared"); wmsg *m;
    wc_add_match (b, "type='signal',interface='t.FdBc'"); wc_add_match (c, "type='signal',interface='t.FdBc'"); wc_sync (b); wc_sync (c); wc_clear (b); wc_clear (c);
    m = wm_signal ("/f", "t.FdBc", "S"); wm_setstr (&m->sig, "h"); wm_fd (m, f); wc_send (a, m); wm_free (m);
    wmsg *g1 = wc_wait_sig (b, "S", 3000), *g2 = wc_wait_sig (c, "S", 3000);
    T (g1 && g2 && g1->nfds == 1 && g2->nfds == 1, "a broadcast with an fd gives every receiver its own descriptor");
    T (g1 && g2 && g1->nfds && g2->nfds && content_is (g1->fds[0], "shared") && content_is (g2->fds[0], "shared"), "both read the file");
    T (g1 && g2 && g1->nfds && g2->nfds && g1->fds[0] != g2->fds[0], "and they are different descriptors");
    if (g1 && g1->nfds) close (g1->fds[0]); if (g2 && g2->nfds) close (g2->fds[0]); wm_free (g1); wm_free (g2);
    wc_remove_match (b, "type='signal',interface='t.FdBc'"); wc_remove_match (c, "type='signal',interface='t.FdBc'"); wc_clear (b); wc_clear (c); close (f); }
  { wconn *x = th_raw (D); wc_auth (x, WA_EXTERNAL | WA_FD); wire_endian = 'B'; wc_hello (x); int f = mkfile ("be");
    wmsg *m = fdmsg (b->unique, "BE", 1, &f); wire_endian = 'l'; wc_send (x, m); wm_free (m);
    g = wc_wait_call (b, "BE", 3000); T (g && g->nfds == 1 && content_is (g->fds[0], "be"), "fd in a big-endian message");
    if (g && g->nfds) close (g->fds[0]); wm_free (g); close (f); wc_close (x); }

  /* --- fd handed over in pieces */
  { int f = mkfile ("piece"); wmsg *m = fdmsg (b->unique, "Piece1", 1, &f); wbuf w = { 0 }; m->serial = a->next_serial++; wm_encode (m, &w);
    wc_send_raw (a, w.d, 10); usleep (80000); wc_send_raw_fds (a, w.d + 10, w.len - 10, &f, 1);
    g = wc_wait_call (b, "Piece1", 3000); T (g && g->nfds == 1 && content_is (g->fds[0], "piece"), "fd attached to the second chunk of a message");
    if (g && g->nfds) close (g->fds[0]); wm_free (g); wm_free (m); wbuf_free (&w);
    m = fdmsg (b->unique, "Piece2", 1, &f); wbuf w2 = { 0 }; m->serial = a->next_serial++; wm_encode (m, &w2);
    wc_send_raw_fds (a, w2.d, 10, &f, 1); usleep (80000); wc_send_raw (a, w2.d + 10, w2.len - 10);
    g = wc_wait_call (b, "Piece2", 3000); T (g && g->nfds == 1 && content_is (g->fds[0], "piece"), "fd attached to the first chunk of a message");
    if (g && g->nfds) close (g->fds[0]); wm_free (g); wm_free (m); wbuf_free (&w2); close (f); }

  /* --- fds stay with their own message */
  { int N = 20; int ok = 1; char name[16];
    for (int i = 0; i < N; i++)
      {
        int f; wmsg *m;
        snprintf (name, sizeof name, "msg%02d", i);
        if (i % 3 == 2) { m = wm_call (b->unique, "/f", "t.Fd", "Seq"); wm_setstr (&m->sig, "s"); wm_str (m, "nofd"); wc_send (a, m); wm_free (m); continue; }
        f = mkfile (name); m = fdmsg (b->unique, "Seq", 1, &f); wc_send (a, m); wm_free (m); close (f);
      }
    for (int i = 0; i < N && ok; i++)
      {
        wmsg *s = wc_wait_call (b, "Seq", 3000);
        if (!s) { ok = 0; break; }
        snprintf (name, sizeof name, "msg%02d", i);
        if (i % 3 == 2) { if (s->nfds != 0) ok = 0; }
        else if (s->nfds != 1 || !content_is (s->fds[0], name)) ok = 0;
        for (int k = 0; k < s->nfds; k++) close (s->fds[k]);
        wm_free (s);
      }
    T (ok, "20 messages, two of three with an fd: each fd stays with its message, in order"); }

  /* --- no descriptor leaks in the daemon */
  { int before, after; wconn *x;
    x = client (1); wc_sync (x); wc_close (x); usleep (200000);
    before = daemon_fds ();
    for (int round = 0; round < 100; round++)
      {
        int f = mkfile ("leak"); wmsg *m;
        x = client (1); wconn *y = client (1);
        m = fdmsg (y->unique, "Leak", 1, &f); wc_send (x, m); wm_free (m);
        { wmsg *gg = wc_wait_call (y, "Leak", 2000); if (gg && gg->nfds) close (gg->fds[0]); wm_free (gg); }
        m = fdmsg (nn->unique, "Leak", 1, &f); wc_send (x, m); wm_free (m);        /* refused */
        m = fdmsg ("org.t.Nope", "Leak", 1, &f); wc_send (x, m); wm_free (m);      /* no such destination */
        m = fdmsg ("org.freedesktop.DBus", "Frob", 1, &f); wc_send (x, m); wm_free (m); /* to the bus itself */
        wc_sync (x);
        close (f); wc_close (x); wc_close (y);
      }
    wc_clear (nn); usleep (500000);
    after = daemon_fds ();
    T (before < 0 || (after >= 0 && after <= before + 1), "daemon fd count after 100 rounds of fd traffic: %d before, %d after", before, after); }

  T (th_healthy (D), "daemon healthy");
  wc_close (a); wc_close (b); wc_close (c); wc_close (nn);
  th_stop (D);
MAIN_END

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Command line behaviour of the daemon: printing, signals, socket handling. */

#include "t.h"
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>

static char *dir;

/* argv for the daemon under test: address, nofork, then extras */
static pid_t spawn (const char *sock, const char *const *extra, int *out, const char *log)
{
  const char *argv[30]; int n = 0; char cfg[700], addr[400];
  argv[n++] = th_daemon_path ();
  if (th_is_real ()) { snprintf (cfg, sizeof cfg, "--config-file=%s/test-bus.conf", th_tests_dir ()); argv[n++] = cfg; argv[n++] = "--nopidfile"; }
  snprintf (addr, sizeof addr, "--address=unix:path=%s", sock);
  argv[n++] = addr; argv[n++] = "--nofork";
  for (int i = 0; extra && extra[i] && n < 28; i++) argv[n++] = extra[i];
  argv[n] = NULL;
  return th_spawn (argv, out, log);
}

static int read_line (int fd, char *b, size_t cap, int ms)
{
  size_t n = 0; int start = wire_ms ();
  while (n + 1 < cap)
    {
      struct pollfd pf = { fd, POLLIN, 0 }; char ch; int left = ms - (wire_ms () - start);
      if (left < 0) left = 0;
      if (poll (&pf, 1, left) <= 0) return -1;
      if (read (fd, &ch, 1) <= 0) return -2;
      if (ch == '\n') { b[n] = 0; return (int) n; }
      b[n++] = ch;
    }
  b[n] = 0; return (int) n;
}

static int reachable (const char *sock)
{
  wconn *c = wc_connect (sock); int ok = 0;
  if (c) { ok = wc_auth (c, WA_EXTERNAL) == 0 && wc_hello (c) == 0 && wc_sync (c) == 0; wc_close (c); }
  return ok;
}
static int wait_sock (const char *sock, int ms)
{
  int start = wire_ms ();
  while (wire_ms () - start < ms) { if (reachable (sock)) return 1; usleep (30000); }
  return 0;
}
static int exists (const char *p) { struct stat st; return stat (p, &st) == 0; }
static int is_guid_hex (const char *s)
{
  if (strlen (s) != 32) return 0;
  for (int i = 0; i < 32; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  return 1;
}

static void sockname (char *buf, size_t cap, const char *tag) { snprintf (buf, cap, "%s/%s", dir, tag); }

MAIN_BEGIN ("t_Cli")
  dir = th_mkdtemp ();
  if (!dir) { T (0, "temp dir"); return 1; }
  char sock[300], log[300], line[600]; int out, st; pid_t p;
  snprintf (log, sizeof log, "%s/log", dir);

  /* --- --print-address */
  sockname (sock, sizeof sock, "a");
  { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
  { int r = read_line (out, line, sizeof line, 8000); char want[400]; snprintf (want, sizeof want, "unix:path=%s", sock);
    T (r > 0 && strncmp (line, want, strlen (want)) == 0, "--print-address prints the address first (%s)", line);
    { const char *g = strstr (line, ",guid="); T (g == NULL || is_guid_hex (g + 6), "an optional guid part is 32 hex digits"); } }
  T (wait_sock (sock, 5000), "and the socket serves a full login");
  T (exists (sock), "the socket file exists");
  { struct pollfd pf = { out, POLLIN, 0 }; T (poll (&pf, 1, 300) == 0, "nothing else is printed on stdout"); }
  kill (p, SIGTERM);
  T (th_wait_pid (p, 4000, &st) == p, "SIGTERM ends the daemon");
  T (WIFEXITED (st) && WEXITSTATUS (st) == 0, "with exit status 0 (exit %d, signal %d)", WIFEXITED (st) ? WEXITSTATUS (st) : -1, WIFSIGNALED (st) ? WTERMSIG (st) : 0);
  T (!exists (sock), "and the socket file is removed");
  close (out);

  /* --- --print-pid */
  sockname (sock, sizeof sock, "b");
  { const char *x[] = { "--print-pid", NULL }; p = spawn (sock, x, &out, log); }
  { int r = read_line (out, line, sizeof line, 8000);
    T (r > 0 && atoi (line) == (int) p, "--print-pid prints the daemon's pid (%s vs %d)", line, (int) p); }
  T (wait_sock (sock, 5000), "daemon serves");
  kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out);

  /* --- both, address first */
  sockname (sock, sizeof sock, "c");
  { const char *real[] = { "--print-address=1", "--print-pid=1", NULL }, *mini[] = { "--print-address", "--print-pid", NULL };
    p = spawn (sock, th_is_real () ? real : mini, &out, log); }
  { int r1 = read_line (out, line, sizeof line, 8000), r2; char l2[100];
    T (r1 > 0 && strncmp (line, "unix:path=", 10) == 0, "with both options the address line comes first (%s)", line);
    r2 = read_line (out, l2, sizeof l2, 3000); T (r2 > 0 && atoi (l2) == (int) p, "then the pid (%s)", l2); }
  kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out);

  /* --- SIGINT */
  sockname (sock, sizeof sock, "d");
  { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
  read_line (out, line, sizeof line, 8000); wait_sock (sock, 5000);
  kill (p, SIGINT);
  T (th_wait_pid (p, 4000, &st) == p, "SIGINT ends the daemon");
  if (!th_is_real ()) { T (WIFEXITED (st) && WEXITSTATUS (st) == 0, "minibus: SIGINT is a clean exit (status 0)"); T (!exists (sock), "minibus: SIGINT removes the socket"); }
  else { T (1, "real: SIGINT kills the process by signal %d and leaves the socket file behind (documented difference)", WIFSIGNALED (st) ? WTERMSIG (st) : 0); unlink (sock); }
  close (out);

  /* --- SIGTERM with clients connected, SIGHUP in between */
  sockname (sock, sizeof sock, "e");
  { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
  read_line (out, line, sizeof line, 8000); wait_sock (sock, 5000);
  { wconn *c1 = wc_connect (sock), *c2 = wc_connect (sock);
    wc_auth (c1, WA_EXTERNAL); wc_hello (c1); wc_auth (c2, WA_EXTERNAL); wc_hello (c2);
    kill (p, SIGHUP); usleep (300000);
    T (th_wait_pid (p, 50, &st) == 0, "SIGHUP does not stop the daemon");
    T (wc_sync (c1) == 0 && wc_sync (c2) == 0, "and connected clients keep working");
    T (reachable (sock), "new clients can still log in");
    kill (p, SIGTERM);
    T (wc_wait_eof (c1, 4000) && wc_wait_eof (c2, 4000), "SIGTERM: connected clients see EOF");
    T (th_wait_pid (p, 4000, &st) == p && WIFEXITED (st) && WEXITSTATUS (st) == 0, "and the daemon exits with 0");
    wc_close (c1); wc_close (c2); }
  close (out);

  /* --- a stale socket file is replaced */
  sockname (sock, sizeof sock, "f");
  { int s = socket (AF_UNIX, SOCK_STREAM, 0); struct sockaddr_un sa; memset (&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; strcpy (sa.sun_path, sock);
    bind (s, (struct sockaddr *) &sa, sizeof sa); close (s); }
  T (exists (sock), "a stale socket file is in place (nobody listens)");
  { wconn *c = wc_connect (sock); T (c == NULL, "connecting to it fails"); wc_close (c); }
  { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
  T (read_line (out, line, sizeof line, 8000) > 0 && wait_sock (sock, 5000), "the daemon starts anyway and replaces the stale file");
  kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out);

  /* --- a socket that is in use is not stolen (the real daemon does steal it) */
  if (!th_is_real ())
    {
      pid_t p2; int out2;
      sockname (sock, sizeof sock, "g");
      { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
      read_line (out, line, sizeof line, 8000); wait_sock (sock, 5000);
      { const char *x[] = { "--print-address", NULL }; p2 = spawn (sock, x, &out2, log); }
      T (th_wait_pid (p2, 4000, &st) == p2 && !(WIFEXITED (st) && WEXITSTATUS (st) == 0), "minibus: a second daemon on a live socket exits with an error");
      T (reachable (sock), "minibus: the first daemon still owns the socket and serves");
      kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out); close (out2);
    }

  /* --- impossible addresses */
  { char bad[400]; int o; snprintf (bad, sizeof bad, "%s/no/such/dir/s", dir);
    const char *x[] = { "--print-address", NULL }; p = spawn (bad, x, &o, log);
    T (th_wait_pid (p, 5000, &st) == p && WIFEXITED (st) && WEXITSTATUS (st) != 0, "an address in a missing directory: exit with an error");
    { struct pollfd pf = { o, POLLIN, 0 }; char b[10]; T (poll (&pf, 1, 100) == 1 && read (o, b, sizeof b) == 0, "and no address is printed"); }
    close (o); }

  /* --- two daemons side by side */
  { char s1[300], s2[300]; pid_t p1, p2; int o1, o2; wconn *c1, *c2; char *i1, *i2;
    sockname (s1, sizeof s1, "h1"); sockname (s2, sizeof s2, "h2");
    { const char *x[] = { "--print-address", NULL }; p1 = spawn (s1, x, &o1, log); p2 = spawn (s2, x, &o2, log); }
    read_line (o1, line, sizeof line, 8000); read_line (o2, line, sizeof line, 8000);
    T (wait_sock (s1, 5000) && wait_sock (s2, 5000), "two daemons run at once");
    c1 = wc_connect (s1); c2 = wc_connect (s2);
    wc_auth (c1, WA_EXTERNAL); wc_hello (c1); wc_auth (c2, WA_EXTERNAL); wc_hello (c2);
    { wmsg *r = tok (c1, wm_bus ("GetId", "")); i1 = r ? wm_arg_str (r, 0) : NULL; wm_free (r); r = tok (c2, wm_bus ("GetId", "")); i2 = r ? wm_arg_str (r, 0) : NULL; wm_free (r); }
    T (i1 && i2 && strcmp (i1, i2) != 0, "each has its own bus id");
    wc_request_name (c1, "org.t.Both", 0);
    T (wc_name_has_owner (c2, "org.t.Both") == 0, "names are not shared between them");
    free (i1); free (i2); wc_close (c1); wc_close (c2);
    kill (p1, SIGTERM); kill (p2, SIGTERM); th_wait_pid (p1, 4000, &st); th_wait_pid (p2, 4000, &st); close (o1); close (o2); }

  /* --- restart cycles on one path */
  { int ok = 1; sockname (sock, sizeof sock, "i");
    for (int i = 0; i < 8 && ok; i++)
      {
        const char *x[] = { "--print-address", NULL };
        p = spawn (sock, x, &out, log);
        ok = read_line (out, line, sizeof line, 8000) > 0 && wait_sock (sock, 5000);
        kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out);
        ok = ok && !exists (sock);
      }
    T (ok, "8 start/stop cycles on the same socket path"); }

  /* --- clients that vanish while answers are pending must not hurt (SIGPIPE) */
  { sockname (sock, sizeof sock, "j");
    { const char *x[] = { "--print-address", NULL }; p = spawn (sock, x, &out, log); }
    read_line (out, line, sizeof line, 8000); wait_sock (sock, 5000);
    for (int i = 0; i < 300; i++)
      {
        wconn *c = wc_connect (sock); wbuf all = { 0 };
        wc_auth (c, WA_EXTERNAL | WA_NOBEGIN); wc_send_line (c, "BEGIN");
        { wmsg *m = wm_bus ("Hello", ""); m->serial = 1; wm_encode (&*m, &all); wm_free (m); }
        for (int k = 0; k < 20; k++) { wmsg *m = wm_bus ("ListNames", ""); m->serial = 2 + k; wm_encode (m, &all); wm_free (m); }
        wc_send_raw (c, all.d, all.len); wbuf_free (&all);
        if (i % 3 == 0) { struct linger l = { 1, 0 }; setsockopt (c->fd, SOL_SOCKET, SO_LINGER, &l, sizeof l); }   /* reset instead of FIN */
        wc_close (c);
      }
    T (th_wait_pid (p, 100, &st) == 0, "daemon survives 300 clients that hang up with answers pending");
    T (reachable (sock), "and still serves");
    kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out); }

  /* --- options only minibus is asked to have */
  if (!th_is_real ())
    {
      const char *flags[][4] = { { "--session", NULL }, { "--system", NULL }, { "--nopidfile", NULL }, { "--syslog", NULL }, { "--config-file=/nonexistent/x.conf", NULL }, { "--nopidfile", "--syslog", "--session", NULL } };
      for (unsigned i = 0; i < sizeof flags / sizeof flags[0]; i++)
        {
          const char *x[8]; int n = 0; char tag[16];
          for (int k = 0; flags[i][k]; k++) x[n++] = flags[i][k];
          x[n++] = "--print-address"; x[n] = NULL;
          snprintf (tag, sizeof tag, "k%u", i); sockname (sock, sizeof sock, tag);
          p = spawn (sock, x, &out, log);
          T (read_line (out, line, sizeof line, 8000) > 0 && wait_sock (sock, 5000), "minibus accepts %s%s", flags[i][0], flags[i][1] ? " ..." : "");
          kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (out);
        }
      { char pf[300], t[40]; snprintf (pf, sizeof pf, "--pid-file=%s/pidfile", dir);
        const char *x[] = { pf, "--print-address", NULL }; sockname (sock, sizeof sock, "pf"); p = spawn (sock, x, &out, log);
        read_line (out, line, sizeof line, 8000); wait_sock (sock, 5000);
        { FILE *f = fopen (pf + 11, "r"); int v = 0; if (f) { if (fscanf (f, "%d", &v) != 1) v = 0; fclose (f); } snprintf (t, sizeof t, "%d", v);
          T (v == (int) p, "minibus: --pid-file= holds the pid (%s vs %d)", t, (int) p); }
        kill (p, SIGTERM); th_wait_pid (p, 4000, &st);
        T (!exists (pf + 11), "minibus: the pid file is removed on SIGTERM"); close (out); }
      { /* bare path argument */
        const char *argv[] = { th_daemon_path (), sock, "--nofork", "--print-address", NULL }; int o;
        sockname (sock, sizeof sock, "bare"); argv[1] = sock;
        p = th_spawn (argv, &o, log);
        T (read_line (o, line, sizeof line, 8000) > 0 && wait_sock (sock, 5000), "minibus: a bare path argument is the socket path");
        kill (p, SIGTERM); th_wait_pid (p, 4000, &st); close (o); }
    }

  th_rmtree (dir);
MAIN_END

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* minibus only: system bus policy, address forms, command line options,
 * resource limits and reserved names. The real daemon uses an XML config
 * for most of this, so in that mode the tool skips itself. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1   /* struct ucred */
#endif
#include "t.h"
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <ctype.h>
#include <grp.h>
#include <pwd.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>

static char *dir;
static char dlog[300];

static pid_t dspawn (const char *const *args, int *out)
{
  const char *argv[40]; int n = 0;
  argv[n++] = th_daemon_path ();
  for (int i = 0; args[i] && n < 38; i++) argv[n++] = args[i];
  argv[n] = NULL;
  return th_spawn (argv, out, dlog);
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

/* first entry of a printed address: 'p' path, 'a' abstract, 0 otherwise */
static int addr_target (const char *addr, char *out, size_t cap)
{
  const char *p; int kind; size_t n = 0;
  if (!strncmp (addr, "unix:path=", 10)) { p = addr + 10; kind = 'p'; }
  else if (!strncmp (addr, "unix:abstract=", 14)) { p = addr + 14; kind = 'a'; }
  else return 0;
  while (*p && *p != ',' && *p != ';' && n + 1 < cap)
    {
      if (*p == '%' && isxdigit ((unsigned char) p[1]) && isxdigit ((unsigned char) p[2]))
        { char h[3] = { p[1], p[2], 0 }; out[n++] = (char) strtol (h, NULL, 16); p += 3; }
      else out[n++] = *p++;
    }
  out[n] = 0;
  return kind;
}

static wconn *conn_to (int kind, const char *target)
{
  if (kind == 'p') return wc_connect (target);
  if (kind == 'a')
    {
      struct sockaddr_un sa; int fd; wconn *c; socklen_t len;
      fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
      if (fd < 0) return NULL;
      memset (&sa, 0, sizeof sa);
      sa.sun_family = AF_UNIX;
      if (strlen (target) + 1 >= sizeof sa.sun_path) { close (fd); return NULL; }
      memcpy (sa.sun_path + 1, target, strlen (target));
      len = (socklen_t) (offsetof (struct sockaddr_un, sun_path) + 1 + strlen (target));
      if (connect (fd, (struct sockaddr *) &sa, len) < 0) { close (fd); return NULL; }
      c = calloc (1, sizeof *c);
      c->fd = fd; c->endian = 'l'; c->next_serial = 1;
      return c;
    }
  return NULL;
}

static wconn *login (const char *addr)
{
  char t[600]; int kind = addr_target (addr, t, sizeof t); wconn *c = conn_to (kind, t);
  if (!c) return NULL;
  if (wc_auth (c, WA_EXTERNAL) || wc_hello (c)) { wc_close (c); return NULL; }
  return c;
}

static int serves (const char *addr)
{
  wconn *c = login (addr); int ok = c && wc_sync (c) == 0;
  wc_close (c);
  return ok;
}

static int serves_retry (const char *addr, int ms)
{
  int start = wire_ms ();
  while (wire_ms () - start < ms) { if (serves (addr)) return 1; usleep (30000); }
  return 0;
}

static int exists (const char *p) { struct stat st; return stat (p, &st) == 0; }
static int modeof (const char *p) { struct stat st; return stat (p, &st) == 0 ? (int) (st.st_mode & 0777) : -1; }
static int is_guid_hex (const char *s)
{
  if (strlen (s) != 32) return 0;
  for (int i = 0; i < 32; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
  return 1;
}

static int exit_code (pid_t p)
{
  int st;
  if (th_wait_pid (p, 5000, &st) != p) { kill (p, SIGKILL); th_wait_pid (p, 2000, &st); return -2; }
  return WIFEXITED (st) ? WEXITSTATUS (st) : -1;
}

static void stop (pid_t p, int out)
{
  int st;
  kill (p, SIGTERM);
  if (th_wait_pid (p, 4000, &st) == 0) { kill (p, SIGKILL); th_wait_pid (p, 2000, &st); }
  if (out >= 0) close (out);
}

/* start with args, return the printed address line in addr; 0 pid on failure */
static pid_t start (const char *const *args, int *out, char *addr, size_t cap)
{
  pid_t p = dspawn (args, out);
  if (p < 0) return 0;
  if (read_line (*out, addr, cap, 8000) <= 0) { stop (p, *out); *out = -1; return 0; }
  return p;
}

/* daemon exits with this status when started with args */
static int exit_with (const char *const *args)
{
  int out; pid_t p = dspawn (args, &out); int rc;
  if (p < 0) return -3;
  rc = exit_code (p);
  close (out);
  return rc;
}

static const char *E_LIMITS = "org.freedesktop.DBus.Error.LimitsExceeded";

/* Run a body in a child that dropped to uid 65534; the exit code is the result. */
#define AS_NOBODY(body) ({ int _st = 0; pid_t _c = fork (); \
  if (_c == 0) { if (setgid (65534) || setgroups (0, NULL) || setuid (65534)) _exit (90); \
                 int _r = 0; body; _exit (_r); } \
  if (_c < 0 || waitpid (_c, &_st, 0) != _c) _st = -1; \
  WIFEXITED (_st) ? WEXITSTATUS (_st) : -1; })

static int may_own (const char *addr, wconn **keep)
{
  wconn *c = login (addr);
  int r = c ? wc_request_name (c, "org.t.Sys", 0) : -2;
  if (keep) *keep = c; else wc_close (c);
  return r;
}

MAIN_BEGIN ("t_System")
  if (th_is_real ()) { fprintf (stderr, "SKIP: t_System tests minibus-only options\n"); [pool release]; return 0; }
  dir = th_mkdtemp ();
  if (!dir) { T (0, "temp dir"); return 1; }
  snprintf (dlog, sizeof dlog, "%s/log", dir);
  char sock[400], addr[700], opt[600]; int out; pid_t p;
  uid_t me = getuid ();

  /* --- socket modes */
  {
    tdaemon *s = th_start ((const char *const[]) { "--system", NULL });
    tdaemon *n = th_start (NULL);
    T (s && n, "daemons start with and without --system");
    if (s) T (modeof (s->sock) == 0666, "--system: socket mode is 0666 (%o)", modeof (s->sock));
    if (n) T (modeof (n->sock) == 0600, "session bus: socket mode is 0600 (%o)", modeof (n->sock));
    th_stop (s); th_stop (n);
  }

  /* --- name ownership policy on the system bus */
  if (me > 999)
    {
      tdaemon *d = th_start ((const char *const[]) { "--system", NULL });
      wconn *c = d ? login (d->addr) : NULL;
      T (c != NULL, "system bus: client logs in");
      if (c)
        {
          int r = wc_request_name (c, "org.t.Sys", 0);
          T (r == -1 && STREQ (c->err, E_ACCESS_DENIED), "uid %u > 999: RequestName is AccessDenied (%s)", (unsigned) me, c->err);
          T (wc_sync (c) == 0, "and the connection stays up");
          { wmsg *rr = NULL;
            const char *none[] = { NULL };
            int t = tcall (c, wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu", none, 0, 0), &rr);
            T (t == W_RETURN, "BecomeMonitor by the bus owner's own uid works on the system bus");
            wm_free (rr); }
          wc_close (c);
        }
      th_stop (d);
    }
  else fprintf (stderr, "NOTE: uid %u <= 999, the AccessDenied checks were skipped\n", (unsigned) me);

  {
    char a[64]; tdaemon *d;
    snprintf (a, sizeof a, "--system-uid-max=%u", (unsigned) me);
    d = th_start ((const char *const[]) { "--system", a, NULL });
    T (d && may_own (d->addr, NULL) == 1, "--system-uid-max=<own uid>: RequestName succeeds");
    th_stop (d);
  }
  {
    struct passwd *pw = getpwuid (me); struct group *g = pw ? getgrgid (pw->pw_gid) : NULL;
    char a[200]; tdaemon *d;
    if (g)
      {
        snprintf (a, sizeof a, "--owner-group=%s", g->gr_name);
        d = th_start ((const char *const[]) { "--system", a, NULL });
        T (d && may_own (d->addr, NULL) == 1, "--owner-group=<primary group>: RequestName succeeds");
        th_stop (d);
      }
    else T (0, "primary group of the test user is known");

    /* supplementary group the passwd/group database lists the user in */
    {
      gid_t gl[128]; int ng = getgroups (128, gl); const char *sup = NULL;
      for (int i = 0; i < ng && pw && !sup; i++)
        {
          struct group *sg = getgrgid (gl[i]);
          if (!sg || gl[i] == pw->pw_gid) continue;
          for (char **m = sg->gr_mem; *m; m++) if (!strcmp (*m, pw->pw_name)) { sup = sg->gr_name; break; }
        }
      if (sup && me > 999)
        {
          snprintf (a, sizeof a, "--owner-group=%s", sup);
          d = th_start ((const char *const[]) { "--system", a, NULL });
          T (d && may_own (d->addr, NULL) == 1, "--owner-group=<supplementary group %s>: RequestName succeeds", sup);
          th_stop (d);
        }
      else fprintf (stderr, "NOTE: no supplementary group that lists the user in /etc/group, gr_mem check skipped\n");
    }
  }
  T (exit_with ((const char *[]) { "--system", "--address=unix:path=/nonexistent-dir/x", "--owner-group=no_such_group_xyz", "--nofork", NULL }) == 1, "--owner-group=<unknown>: exit status 1");
  snprintf (sock, sizeof sock, "--address=unix:path=%s/neg", dir);
  T (exit_with ((const char *[]) { sock, "--system-uid-max=-5", "--nofork", NULL }) == 1, "--system-uid-max=-5: exit status 1");
  T (exit_with ((const char *[]) { sock, "--owner-group=no_such_group_xyz", "--nofork", NULL }) == 1, "--owner-group=<unknown> on a session bus: exit status 1");

  /* --- root: policy for another uid */
  if (getuid () == 0)
    {
      char *sd = th_mkdtemp (); char path[400], *cfg;
      chmod (sd, 0755);
      snprintf (path, sizeof path, "%s/sys", sd);
      snprintf (opt, sizeof opt, "--address=unix:path=%s", path);
      cfg = opt;
      p = start ((const char *[]) { cfg, "--system", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
      T (p != 0, "root: system bus daemon starts");
      if (p)
        {
          int rc;
          T (modeof (path) == 0666, "root: system socket mode 0666");
          rc = AS_NOBODY ({ wconn *c = wc_connect (path); const char *none[] = { NULL };
            if (!c || wc_auth (c, WA_EXTERNAL) || wc_hello (c)) _r |= 1;
            else
              {
                if (wc_request_name (c, "org.t.Nobody", 0) != -1 || !STREQ (c->err, E_ACCESS_DENIED)) _r |= 2;
                if (!terr (c, wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu", none, 0, 0), E_ACCESS_DENIED)) _r |= 4;
              }
            wc_close (c); });
          T (rc == 0, "root bus: uid 65534 gets AccessDenied for RequestName and BecomeMonitor (child status %d)", rc);
          { wconn *c = login (addr); const char *none[] = { NULL };
            T (c && wc_request_name (c, "org.t.Root", 0) == 1, "root bus: root may own names");
            T (c && tcall (c, wm_call_args ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu", none, 0, 0), NULL) == W_RETURN, "root bus: root may become a monitor");
            wc_close (c); }
          stop (p, out);
        }
      snprintf (path, sizeof path, "%s/ses", sd);
      snprintf (opt, sizeof opt, "--address=unix:path=%s", path);
      p = start ((const char *[]) { cfg, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
      T (p != 0, "root: session bus daemon starts");
      if (p)
        {
          int rc;
          chmod (path, 0666);   /* let the other uid reach the SASL step */
          rc = AS_NOBODY ({ wconn *c = wc_connect (path);
            if (!c) _r = 1; else if (wc_auth (c, WA_EXTERNAL) == 0) _r = 2;
            wc_close (c); });
          T (rc == 0, "root session bus: AUTH EXTERNAL of uid 65534 is rejected (child status %d)", rc);
          T (serves (addr), "root session bus: root is accepted");
          stop (p, out);
        }
      th_rmtree (sd); free (sd);
    }
  else fprintf (stderr, "NOTE: not running as root, the uid 65534 checks were skipped\n");

  /* --- address forms */
  {
    char a[400], t[600]; int kind;
    /* tmpdir and dir */
    const char *keys[] = { "tmpdir", "dir" };
    for (int k = 0; k < 2; k++)
      {
        snprintf (a, sizeof a, "--address=unix:%s=%s", keys[k], dir);
        p = start ((const char *[]) { a, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
        snprintf (t, sizeof t, "unix:path=%s/dbus-", dir);
        T (p && !strncmp (addr, t, strlen (t)), "unix:%s=<dir> prints unix:path=<dir>/dbus-XXXXXXXX (%s)", keys[k], addr);
        if (p)
          {
            const char *g = strstr (addr, ",guid="), *base = addr + strlen (t);
            T (g && g - base == 8 && is_guid_hex (g + 6), "the generated name has 8 characters and the guid follows");
            kind = addr_target (addr, t, sizeof t);
            T (kind == 'p' && exists (t) && serves_retry (addr, 5000), "and that socket works");
            stop (p, out);
          }
      }
    /* runtime=yes */
    snprintf (a, sizeof a, "%s/rt", dir); mkdir (a, 0700);
    setenv ("XDG_RUNTIME_DIR", a, 1);
    p = start ((const char *[]) { "--address=unix:runtime=yes", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
    snprintf (t, sizeof t, "%s/rt/bus", dir);
    T (p && serves_retry (addr, 5000) && exists (t), "unix:runtime=yes uses $XDG_RUNTIME_DIR/bus (%s)", addr);
    if (p) stop (p, out);
    /* --session with XDG_RUNTIME_DIR */
    p = start ((const char *[]) { "--session", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
    T (p && serves_retry (addr, 5000) && exists (t), "--session listens on $XDG_RUNTIME_DIR/bus");
    T (modeof (t) == 0600, "--session socket mode 0600 (%o)", modeof (t));
    if (p) stop (p, out);
    unsetenv ("XDG_RUNTIME_DIR");

    /* abstract */
    snprintf (a, sizeof a, "--address=unix:abstract=mbt-sys-%d-%d", (int) getpid (), wire_ms ());
#if defined(__linux__)
    p = start ((const char *[]) { a, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
    T (p && !strncmp (addr, "unix:abstract=mbt-sys-", 22), "unix:abstract=<name> is printed as abstract (%s)", addr);
    T (p && serves_retry (addr, 5000), "and an abstract socket works");
    if (p) stop (p, out);
#else
    T (exit_with ((const char *[]) { a, "--nofork", NULL }) == 1, "abstract sockets: exit status 1 off Linux");
#endif

    /* escaping */
    {
      char sub[500];
      snprintf (sub, sizeof sub, "%s/a,b=c d", dir); mkdir (sub, 0700);
      snprintf (a, sizeof a, "--address=unix:path=%s/a%%2cb%%3dc%%20d/s", dir);
      p = start ((const char *[]) { a, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
      T (p && strstr (addr, "%2c") && strstr (addr, "%3d") && strstr (addr, "%20"), "a path with ',' '=' and a space is printed escaped (%s)", addr);
      T (p && serves_retry (addr, 5000), "and is connectable through the unescaped path");
      if (p) stop (p, out);
    }
    /* two addresses */
    {
      char a2[700], *semi; int ok;
      snprintf (a2, sizeof a2, "--address=unix:path=%s/m1;unix:path=%s/m2", dir, dir);
      p = start ((const char *[]) { a2, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
      semi = p ? strchr (addr, ';') : NULL;
      T (semi != NULL, "two addresses separated by ';' are printed together (%s)", addr);
      ok = semi && serves_retry (addr, 5000) && serves (semi + 1);
      T (ok, "both of them listen");
      if (p) stop (p, out);
    }
    /* things that must fail */
    T (exit_with ((const char *[]) { "--address=tcp:host=localhost", "--nofork", NULL }) == 1, "tcp:host=localhost: exit status 1");
    {
      char longp[400]; size_t n;
      snprintf (longp, sizeof longp, "--address=unix:path=%s/", dir);
      n = strlen (longp); memset (longp + n, 'x', 120); longp[n + 120] = 0;
      T (exit_with ((const char *[]) { longp, "--nofork", NULL }) == 1, "a path longer than sun_path: exit status 1");
    }
    T (exit_with ((const char *[]) { "--nofork", NULL }) == 1, "no address at all: exit status 1");
    T (exit_with ((const char *[]) { "--bogus-option", "--nofork", NULL }) == 1, "an unknown option: exit status 1");
    T (exit_with ((const char *[]) { "--address=unix:path", "--nofork", NULL }) == 1, "an address entry without '=': exit status 1");
    T (exit_with ((const char *[]) { "--address=unix:guid=00", "--nofork", NULL }) == 1, "an address without a path: exit status 1");
  }

  /* --- legacy bare path, version, help */
  snprintf (sock, sizeof sock, "%s/bare", dir);
  p = start ((const char *[]) { sock, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
  T (p && serves_retry (addr, 5000), "a bare socket path as the only address works");
  if (p) stop (p, out);
  {
    pid_t v = dspawn ((const char *[]) { "--version", NULL }, &out); char l[200];
    T (v > 0 && read_line (out, l, sizeof l, 4000) > 0 && !strncmp (l, "minibus", 7), "--version prints minibus (%s)", l);
    T (exit_code (v) == 0, "--version exits 0"); close (out);
    v = dspawn ((const char *[]) { "--help", NULL }, &out);
    T (read_line (out, l, sizeof l, 4000) > 0 && exit_code (v) == 0, "--help prints usage and exits 0"); close (out);
  }

  /* --- --syslog, ignored options */
  snprintf (opt, sizeof opt, "--address=unix:path=%s/sl", dir);
  p = start ((const char *[]) { opt, "--syslog", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
  T (p && serves_retry (addr, 5000), "--syslog starts and serves");
  if (p) stop (p, out);
  snprintf (opt, sizeof opt, "--address=unix:path=%s/ig", dir);
  p = start ((const char *[]) { opt, "--config-file=x", "--nopidfile", "--nosyslog", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
  T (p && serves_retry (addr, 5000), "--config-file=x --nopidfile --nosyslog are accepted and ignored");
  if (p) stop (p, out);
  snprintf (opt, sizeof opt, "--address=unix:path=%s/ig2", dir);
  p = start ((const char *[]) { opt, "--config-file", "x", "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
  T (p && serves_retry (addr, 5000), "--config-file x (separate argument) is accepted and ignored");
  if (p) stop (p, out);

  /* --- pid file */
  {
    char pf[400], pa[500]; int v = 0; FILE *f;
    snprintf (pf, sizeof pf, "%s/pidfile", dir);
    snprintf (pa, sizeof pa, "--pid-file=%s", pf);
    snprintf (opt, sizeof opt, "--address=unix:path=%s/pf", dir);
    p = start ((const char *[]) { opt, pa, "--nofork", "--print-address", NULL }, &out, addr, sizeof addr);
    T (p && serves_retry (addr, 5000), "--pid-file= daemon serves");
    if ((f = fopen (pf, "r"))) { if (fscanf (f, "%d", &v) != 1) v = 0; fclose (f); }
    T (p && v == (int) p, "the pid file holds the pid (%d vs %d)", v, (int) p);
    if (p) stop (p, out);
    T (!exists (pf), "the pid file is removed on SIGTERM");
    snprintf (pa, sizeof pa, "--pid-file=%s/no/such/dir/pid", dir);
    T (exit_with ((const char *[]) { opt, pa, "--nofork", NULL }) == 1, "an unwritable pid file: exit status 1");
  }

  /* --- --fork */
  {
    char l[100], pa[300]; pid_t child = 0; int o;
    snprintf (opt, sizeof opt, "--address=unix:path=%s/fk", dir);
    p = dspawn ((const char *[]) { opt, "--fork", "--print-pid", "--print-address", NULL }, &o);
    T (read_line (o, addr, sizeof addr, 8000) > 0 && !strncmp (addr, "unix:path=", 10), "--fork --print-address prints the address (%s)", addr);
    if (read_line (o, l, sizeof l, 4000) > 0) child = (pid_t) atoi (l);
    T (child > 1 && child != p, "--fork --print-pid prints the child's pid, not the parent's (%d, parent %d)", (int) child, (int) p);
    T (exit_code (p) == 0, "the parent exits 0");
    close (o);
    T (serves_retry (addr, 5000), "the forked child serves clients");
    T (child > 1 && kill (child, 0) == 0, "and the printed pid is alive");
#ifdef __linux__
    { /* clients take the bus's pid from the socket's peer credentials: they must
       * name the forked child that serves it, not the parent that has exited */
      char path[300]; const char *q = addr + 10; size_t k = 0;
      while (*q && *q != ',' && k + 1 < sizeof path) path[k++] = *q++;
      path[k] = 0;
      int fd = socket (AF_UNIX, SOCK_STREAM, 0); struct sockaddr_un su = { .sun_family = AF_UNIX };
      snprintf (su.sun_path, sizeof su.sun_path, "%s", path);
      struct ucred cr = { 0 }; socklen_t cl = sizeof cr;
      int ok = fd >= 0 && connect (fd, (struct sockaddr *) &su, sizeof su) == 0 &&
               getsockopt (fd, SOL_SOCKET, SO_PEERCRED, &cr, &cl) == 0;
      T (ok && cr.pid == child, "--fork: the socket's peer credentials name the child (%d, child %d)", (int) cr.pid, (int) child);
      if (fd >= 0) close (fd);
    }
#endif
    snprintf (pa, sizeof pa, "%s/fk", dir);
    if (child > 1)
      {
        kill (child, SIGTERM);
        for (int i = 0; i < 200 && kill (child, 0) == 0; i++) usleep (20000);
        T (kill (child, 0) != 0 || exists (pa) == 0, "SIGTERM stops the forked child");
        if (kill (child, 0) == 0) kill (child, SIGKILL);
        T (!exists (pa), "and its socket file is removed");
      }
  }

  /* --- limits */
  {
    tdaemon *D = th_start (NULL);
    if (!D) { T (0, "limits: daemon starts"); }
    else
      {
        wconn *c = th_client (D); int i, r = 0; char rule[100];
        for (i = 0; i < 2048; i++)
          {
            snprintf (rule, sizeof rule, "type='signal',member='M%d'", i);
            if ((r = wc_add_match (c, rule))) break;
          }
        T (i == 2048 && r == 0, "2048 match rules are accepted (stopped at %d: %s)", i, c->err);
        snprintf (rule, sizeof rule, "type='signal',member='M%d'", 2048);
        T (wc_add_match (c, rule) == -1 && STREQ (c->err, E_LIMITS), "the 2049th AddMatch is LimitsExceeded (%s)", c->err);
        T (wc_sync (c) == 0, "and the connection stays up");
        T (wc_remove_match (c, "type='signal',member='M0'") == 0 && wc_add_match (c, rule) == 0, "a removed rule frees a slot");
        wc_close (c);

        c = th_client (D);
        for (i = 0; i < 512; i++)
          {
            char nm[64]; snprintf (nm, sizeof nm, "org.t.Lim%d", i);
            if ((r = wc_request_name (c, nm, 0)) != 1) break;
          }
        T (i == 512, "512 names are granted (stopped at %d: %s)", i, c->err);
        T (wc_request_name (c, "org.t.Lim512", 0) == -1 && STREQ (c->err, E_LIMITS), "the 513th RequestName is LimitsExceeded (%s)", c->err);
        T (wc_request_name (c, "org.t.Lim0", 0) == 4, "asking again for a name already owned is still answered");
        T (wc_release_name (c, "org.t.Lim1") == 1 && wc_request_name (c, "org.t.Lim512", 0) == 1, "a released name frees a slot");
        wc_close (c);

        /* a reader that never reads */
        {
          wconn *rd = th_client (D), *snd = th_client (D); size_t big = 1024 * 1024;
          uint8_t *buf = calloc (1, big); int sent = 0, errs = 0, other = 0, got = 0;
          int ok;
          for (int k = 0; k < 64; k++)
            {
              wmsg *m = wm_call (rd->unique, "/t", "org.t.I", "Big"); size_t tk;
              wm_setstr (&m->sig, "ay"); tk = wm_array_begin (m, 1); wm_raw (m, buf, big); wm_array_end (m, tk, 1);
              ok = wc_send (snd, m) != 0; wm_free (m);
              if (!ok) break;
              sent++;
            }
          T (sent == 64, "the sender wrote 64 calls of 1 MiB (%d)", sent);
          {
            int start = wire_ms ();
            while (errs + other < 64 && wire_ms () - start < 20000)
              {
                wmsg *m = NULL; int rc = wc_recv (snd, &m, 1500);
                if (rc != 1) break;
                if (m->type == W_ERROR && STREQ (m->errname, E_LIMITS)) errs++; else other++;
                wm_free (m);
              }
          }
          T (errs > 0, "the sender got LimitsExceeded for %d calls", errs);
          T (errs < 64, "but not for all of them (%d)", errs);
          T (other == 0, "and no other error or message (%d)", other);
          T (wc_sync (snd) == 0, "the sender stays connected");
          wc_drain (rd, 3000);
          for (int k = 0; k < rd->ninbox; k++) if (rd->inbox[k]->type == W_CALL) got++;
          T (!rd->eof && wc_sync (rd) == 0, "the reader's connection stays up and works once it reads");
          T (got > 0 && got + errs <= 64 + 0 && got <= 64 - errs + 0, "the reader received %d of the calls, the rest were refused (%d)", got, errs);
          free (buf); wc_close (rd); wc_close (snd);
        }
        T (th_healthy (D), "daemon healthy after the limit tests");
        th_stop (D);
      }
  }

  /* --- reserved names */
  {
    tdaemon *D = th_start (NULL);
    if (!D) { T (0, "reserved: daemon starts"); }
    else
      {
        wconn *by = th_client (D), *c;
        c = th_client (D);
        { wmsg *m = wm_signal ("/t", "org.freedesktop.DBus.Local", "Disconnected"); wc_send (c, m); wm_free (m); }
        T (wc_wait_eof (c, 4000), "a signal on interface org.freedesktop.DBus.Local drops the sender");
        wc_close (c);
        T (wc_sync (by) == 0, "others are unaffected");
        c = th_client (D);
        { wmsg *m = wm_call ("org.freedesktop.DBus", "/org/freedesktop/DBus/Local", "org.freedesktop.DBus.Peer", "Ping"); wc_send (c, m); wm_free (m); }
        T (wc_wait_eof (c, 4000), "a method call with path /org/freedesktop/DBus/Local drops the sender");
        wc_close (c);
        c = th_client (D);
        { wmsg *m = wm_signal ("/org/freedesktop/DBus/Local", "org.t.I", "S"); wc_send (c, m); wm_free (m); }
        T (wc_wait_eof (c, 4000), "a signal with path /org/freedesktop/DBus/Local drops the sender");
        wc_close (c);
        T (wc_sync (by) == 0, "others are still unaffected");
        wc_close (by);
        T (th_healthy (D), "daemon healthy afterwards");
        th_stop (D);
      }
  }

  th_rmtree (dir);
MAIN_END

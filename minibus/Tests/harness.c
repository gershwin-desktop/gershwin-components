/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#define _GNU_SOURCE
#include "harness.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <dirent.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/resource.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif

int th_failures;

#define MAXLIVE 8
static tdaemon *live[MAXLIVE];
static char tests_dir[512];
static char tool_name[64];

static void kill_all (void)
{
  for (int i = 0; i < MAXLIVE; i++)
    if (live[i] && !live[i]->exited)
      kill (live[i]->pid, SIGKILL);
}

static void on_alarm (int s)
{
  static const char m[] = "WATCHDOG: test tool timed out\nFailed test: watchdog timeout\n";
  (void) s;
  if (write (2, m, sizeof m - 1) < 0) { }
  kill_all ();
  _exit (3);
}

static void on_crash (int s)
{
  static const char m[] = "Failed test: test tool crashed\n";
  if (write (2, m, sizeof m - 1) < 0) { }
  kill_all ();
  signal (s, SIG_DFL);
  raise (s);
}

const char *th_mode (void)
{
  const char *m = getenv ("MINIBUS_TEST_DAEMON");
  return m && *m ? m : "minibus";
}
int th_is_real (void) { return strcmp (th_mode (), "real") == 0; }
const char *th_tests_dir (void) { return tests_dir; }

const char *th_daemon_path (void)
{
  static char p[600];
  if (th_is_real ()) return "/usr/bin/dbus-daemon";
  if (getenv ("MINIBUS_BIN") && *getenv ("MINIBUS_BIN"))
    snprintf (p, sizeof p, "%s", getenv ("MINIBUS_BIN"));
  else
    snprintf (p, sizeof p, "%s/../obj/minibus", tests_dir);
  return p;
}

void th_init (const char *name)
{
  char exe[512]; ssize_t n;
  snprintf (tool_name, sizeof tool_name, "%s", name);
  if (getenv ("MINIBUS_TESTS_DIR") && *getenv ("MINIBUS_TESTS_DIR"))
    snprintf (tests_dir, sizeof tests_dir, "%s", getenv ("MINIBUS_TESTS_DIR"));
  else
    {
      n = readlink ("/proc/self/exe", exe, sizeof exe - 1);
      if (n > 0)
        {
          exe[n] = 0;
          snprintf (tests_dir, sizeof tests_dir, "%s/..", dirname (exe));
        }
      else
        snprintf (tests_dir, sizeof tests_dir, ".");
    }
  unsetenv ("DBUS_SESSION_BUS_ADDRESS");
  unsetenv ("DBUS_SYSTEM_BUS_ADDRESS");
  unsetenv ("DISPLAY");
  signal (SIGPIPE, SIG_IGN);
  signal (SIGALRM, on_alarm);
  signal (SIGSEGV, on_crash);
  signal (SIGABRT, on_crash);
  {
    const char *t = getenv ("MINIBUS_TEST_TIMEOUT");
    alarm (t ? (unsigned) atoi (t) : 240);
  }
  if (!th_is_real () && strcmp (th_mode (), "minibus") != 0)
    {
      fprintf (stderr, "MINIBUS_TEST_DAEMON must be real or minibus\n");
      exit (2);
    }
  if (!th_is_real () && access (th_daemon_path (), X_OK) != 0)
    {
      fprintf (stderr, "SKIP: %s: minibus binary %s not found\n", name, th_daemon_path ());
      exit (0);
    }
  fprintf (stderr, "== %s against %s (%s)\n", name, th_mode (), th_daemon_path ());
}

int th_resource_limit (void)
{
  struct rlimit rl;
  if (getrlimit (RLIMIT_NOFILE, &rl)) return 1024;
  if (rl.rlim_cur < rl.rlim_max)
    {
      rl.rlim_cur = rl.rlim_max > 8192 ? 8192 : rl.rlim_max;
      setrlimit (RLIMIT_NOFILE, &rl);
      getrlimit (RLIMIT_NOFILE, &rl);
    }
  return (int) rl.rlim_cur;
}

char *th_mkdtemp (void)
{
  const char *cands[4]; char t[300];
  cands[0] = getenv ("MINIBUS_TEST_TMP"); cands[1] = getenv ("TMPDIR");
  cands[2] = "/tmp"; cands[3] = NULL;
  for (int i = 0; i < 3; i++)
    {
      if (!cands[i] || !*cands[i]) continue;
      /* AF_UNIX paths are limited to ~107 bytes */
      if (strlen (cands[i]) > 70) continue;
      snprintf (t, sizeof t, "%s/mbt.XXXXXX", cands[i]);
      if (mkdtemp (t)) return strdup (t);
    }
  return NULL;
}

void th_rmtree (const char *dir)
{
  DIR *d = opendir (dir); struct dirent *e;
  if (!d) return;
  while ((e = readdir (d)))
    {
      char p[600]; struct stat st;
      if (!strcmp (e->d_name, ".") || !strcmp (e->d_name, "..")) continue;
      snprintf (p, sizeof p, "%s/%s", dir, e->d_name);
      if (lstat (p, &st) == 0 && S_ISDIR (st.st_mode)) th_rmtree (p);
      else unlink (p);
    }
  closedir (d);
  rmdir (dir);
}

int th_base_args (const char **argv, int max, const char *sockpath)
{
  static char cfg[700], addr[700];
  int n = 0;
  (void) max;
  argv[n++] = th_daemon_path ();
  if (th_is_real ())
    {
      snprintf (cfg, sizeof cfg, "--config-file=%s/test-bus.conf", tests_dir);
      argv[n++] = cfg;
    }
  snprintf (addr, sizeof addr, "--address=unix:path=%s", sockpath);
  argv[n++] = addr;
  argv[n++] = "--nofork";
  argv[n++] = "--print-address";
  if (th_is_real ()) argv[n++] = "--nopidfile";
  return n;
}

pid_t th_spawn (const char *const *args, int *outfd, const char *errlog)
{
  int pfd[2]; pid_t pid;
  if (pipe (pfd) < 0) return -1;
  pid = fork ();
  if (pid < 0) return -1;
  if (pid == 0)
    {
      int ef;
#if defined(__linux__)
      prctl (PR_SET_PDEATHSIG, SIGKILL);
#endif
      close (pfd[0]);
      dup2 (pfd[1], 1);
      close (pfd[1]);
      ef = open (errlog ? errlog : "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0600);
      if (ef >= 0) { dup2 (ef, 2); close (ef); }
      /* a script that started the suite in the background leaves SIGINT and SIGQUIT ignored */
      signal (SIGPIPE, SIG_DFL); signal (SIGALRM, SIG_DFL); signal (SIGINT, SIG_DFL);
      signal (SIGQUIT, SIG_DFL); signal (SIGHUP, SIG_DFL); signal (SIGTERM, SIG_DFL);
      signal (SIGUSR1, SIG_DFL); signal (SIGUSR2, SIG_DFL);
      execv (args[0], (char *const *) args);
      _exit (127);
    }
  close (pfd[1]);
  *outfd = pfd[0];
  return pid;
}

static int read_line_fd (int fd, char *out, size_t cap, int ms)
{
  size_t n = 0; int start = wire_ms ();
  while (n + 1 < cap)
    {
      struct pollfd pf = { fd, POLLIN, 0 }; char ch; int left = ms - (wire_ms () - start);
      if (left < 0) left = 0;
      if (poll (&pf, 1, left) <= 0) return -1;
      if (read (fd, &ch, 1) <= 0) return -2;
      if (ch == '\n') { out[n] = 0; return (int) n; }
      out[n++] = ch;
    }
  out[n] = 0;
  return (int) n;
}

tdaemon *th_start (const char *const *extra)
{
  tdaemon *d = calloc (1, sizeof *d);
  const char *argv[40]; int n; char *dir = th_mkdtemp ();
  if (!dir) { free (d); return NULL; }
  snprintf (d->dir, sizeof d->dir, "%s", dir); free (dir);
  snprintf (d->sock, sizeof d->sock, "%s/s", d->dir);
  snprintf (d->log, sizeof d->log, "%s/daemon.log", d->dir);
  n = th_base_args (argv, 30, d->sock);
  for (int i = 0; extra && extra[i] && n < 38; i++) argv[n++] = extra[i];
  argv[n] = NULL;
  d->pid = th_spawn (argv, &d->outfd, d->log);
  if (d->pid < 0) { th_rmtree (d->dir); free (d); return NULL; }
  for (int i = 0; i < MAXLIVE; i++) if (!live[i]) { live[i] = d; break; }
  {
    char l[400];
    int r = read_line_fd (d->outfd, l, sizeof l, 10000);
    if (r < 0)
      {
        fprintf (stderr, "daemon did not print an address (log %s)\n", d->log);
        th_stop (d);
        return NULL;
      }
    snprintf (d->addr, sizeof d->addr, "%s", l);
  }
  /* wait until it accepts */
  for (int i = 0; i < 100; i++)
    {
      wconn *c = wc_connect (d->sock);
      if (c) { wc_close (c); return d; }
      usleep (50000);
    }
  fprintf (stderr, "daemon socket never accepted\n");
  th_stop (d);
  return NULL;
}

int th_alive (tdaemon *d)
{
  int st;
  if (d->exited) return 0;
  if (waitpid (d->pid, &st, WNOHANG) == d->pid) { d->exited = 1; d->status = st; return 0; }
  return 1;
}

pid_t th_wait_pid (pid_t pid, int ms, int *status)
{
  int start = wire_ms (), st;
  for (;;)
    {
      pid_t r = waitpid (pid, &st, WNOHANG);
      if (r == pid) { if (status) *status = st; return r; }
      if (r < 0) return -1;
      if (wire_ms () - start > ms) return 0;
      usleep (10000);
    }
}

int th_wait_exit (tdaemon *d, int ms)
{
  if (d->exited) return 1;
  if (th_wait_pid (d->pid, ms, &d->status) == d->pid) { d->exited = 1; return 1; }
  return 0;
}

void th_stop (tdaemon *d)
{
  if (!d) return;
  if (!d->exited)
    {
      kill (d->pid, SIGTERM);
      if (!th_wait_exit (d, 3000))
        {
          kill (d->pid, SIGKILL);
          th_wait_exit (d, 3000);
        }
    }
  if (d->outfd > 0) close (d->outfd);
  for (int i = 0; i < MAXLIVE; i++) if (live[i] == d) live[i] = NULL;
  th_rmtree (d->dir);
  free (d);
}

wconn *th_raw (tdaemon *d) { return wc_connect (d->sock); }

wconn *th_client (tdaemon *d)
{
  wconn *c = wc_connect (d->sock);
  if (!c) return NULL;
  if (wc_auth (c, WA_EXTERNAL) || wc_hello (c)) { wc_close (c); return NULL; }
  /* swallow the NameAcquired for the unique name so tests start quiet */
  wm_free (wc_wait_sig_arg0 (c, "NameAcquired", c->unique, 2000));
  return c;
}

wconn *th_client_be (tdaemon *d)
{
  wconn *c = wc_connect (d->sock);
  if (!c) return NULL;
  c->endian = 'B';
  if (wc_auth (c, WA_EXTERNAL)) { wc_close (c); return NULL; }
  return c;
}

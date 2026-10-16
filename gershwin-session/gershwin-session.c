/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
/*
 * gershwin-session: the supervisor of one Gershwin desktop session.
 *
 * Supervises the apps given as command line arguments (their names are
 * resolved through $PATH), restarting any of them when they exit
 * unexpectedly, so each user's desktop is self-healing.  It shuts all of
 * them down cleanly when the session manager sends SIGTERM/SIGINT (e.g. on
 * logout).
 *
 * An app that burns more than 95% CPU for over ten seconds straight is
 * treated as runaway: the supervisor kills it and the normal restart
 * logic brings a fresh copy up, so one stuck app cannot pin a core and
 * freeze the whole desktop.
 *
 * An app that dies again within two seconds of being launched is restarted
 * after a delay that grows to a minute, so an app that cannot run at all
 * (a name that is not on the $PATH, a missing library) costs one log line
 * a minute instead of a fork several times a second.
 *
 * Usage:  gershwin-session AppName1 [AppName2 ...]
 * Example: gershwin-session Workspace Menu WindowManager
 *
 * The pid of this process is exported to every supervised app as the
 * GERSHWIN_SESSION_PID environment variable, so the desktop session (Menu,
 * Workspace) can signal its own supervisor - even when, as is the common
 * case, several users are logged in at the same time and each runs their
 * own copy of this process.
 *
 * For development, automatic restarting can be toggled while the session
 * supervisor is already running:
 *   kill -USR1 <gershwin-session pid>   disable auto restart
 *   kill -USR2 <gershwin-session pid>   enable auto restart
 *
 * This is plain C on purpose: the supervisor lives as long as the session
 * and has nothing to do that needs a Foundation runtime, which alone
 * cost it ten megabytes of private memory.
 */
#include <sys/types.h>
#include <sys/param.h>
#include <sys/wait.h>
#if defined(__FreeBSD__) || defined(__OpenBSD__)
#include <sys/sysctl.h>
#endif
#if defined(__FreeBSD__)
#include <sys/user.h>
#endif
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* A supervised app counts as runaway when its CPU time grows faster than
 * CPU_RUNAWAY_RATE cores continuously for longer than CPU_RUNAWAY_SECONDS.
 */
#define CPU_RUNAWAY_RATE    0.95
#define CPU_RUNAWAY_SECONDS 10.0

/* An app that exits again within CRASH_LOOP_FAST_SECONDS of being launched is
 * not relaunched at once.  gershwin-session restarts an app as soon as it
 * exits, so something that cannot run at all - a name that is not on the
 * $PATH, a missing shared library, a bundle whose loader is gone - would
 * otherwise be launched several times a second for the whole session and the
 * supervisor could never go idle.  The delay doubles on every such death up
 * to CRASH_LOOP_MAX_SECONDS, so a broken app costs one log line a minute; a
 * real app that runs normally is never delayed.
 */
#define CRASH_LOOP_FAST_SECONDS  2.0   /* died within this = crash loop */
#define CRASH_LOOP_FIRST_DELAY   5.0   /* first backoff, in seconds */
#define CRASH_LOOP_MAX_SECONDS  60.0   /* backoff ceiling, in seconds */
#define CRASH_LOOP_NOTICE_SECONDS 60.0 /* at most one log line per this */

/* Per-app state, one entry per supervised app (same order as the names). */
typedef struct {
  const char *name;
  pid_t pid;            /* the running instance, 0 = none */
  int launched;         /* an instance was started and has not been replaced */
  double lastCpu;       /* cumulative CPU seconds at last sample, -1 = unknown */
  double lastAt;        /* monotonic time of that sample */
  double highSince;     /* when the current >limit streak started, 0 = none */
  double launchedAt;    /* when the current instance was launched, 0 = none */
  double diedAt;        /* when it was first seen gone, 0 = still up */
  double nextLaunchAt;  /* do not relaunch before this time, 0 = now */
  double backoff;       /* current crash-loop delay in seconds, 0 = none */
  double lastNoticeAt;  /* when we last logged about the crash loop */
} App;

static volatile sig_atomic_t keepRunning = 1;
static volatile sig_atomic_t autoRestart = 1;

static void handleSignal(int signo)
{
  if (signo == SIGTERM || signo == SIGINT)
    {
      keepRunning = 0;
    }
  else if (signo == SIGUSR1)
    {
      autoRestart = 0;
    }
  else if (signo == SIGUSR2)
    {
      autoRestart = 1;
    }
}

/* No SA_RESTART: a signal has to cut the sleep of the main loop short. */
static void installSignalHandlers(void)
{
  struct sigaction a;

  memset(&a, 0, sizeof(a));
  sigemptyset(&a.sa_mask);
  a.sa_handler = handleSignal;
  sigaction(SIGTERM, &a, NULL);
  sigaction(SIGINT, &a, NULL);
  sigaction(SIGUSR1, &a, NULL);
  sigaction(SIGUSR2, &a, NULL);
}

static void logLine(const char *fmt, ...)
{
  struct timespec ts;
  struct tm tm;
  char stamp[32];
  va_list ap;

  clock_gettime(CLOCK_REALTIME, &ts);
  localtime_r(&ts.tv_sec, &tm);
  strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
  fprintf(stderr, "%s.%03ld gershwin-session[%d] ", stamp,
    ts.tv_nsec / 1000000L, (int)getpid());
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

static double monotonicSeconds(void)
{
  struct timespec ts;

  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void sleepSeconds(double seconds)
{
  struct timespec ts;

  ts.tv_sec = (time_t)seconds;
  ts.tv_nsec = (long)((seconds - (double)ts.tv_sec) * 1e9);
  nanosleep(&ts, NULL);
}

#if !defined(__linux__) && !defined(__FreeBSD__) && !defined(__OpenBSD__)
/* Parse a ps TIME/cputime value.  The column layout differs between
 * systems ("[[dd-]hh:]mm:ss" or "mmm:ss.hh"), so parse colon separated fields
 * from the right as seconds/minutes/hours, with an optional fractional part
 * on the last field and an optional day count before a dash.
 */
static double parsePsTime(char *s)
{
  double mult[] = { 1.0, 60.0, 3600.0, 86400.0 };
  double fields[5] = { 0 };
  double days = 0.0;
  char *dash = strchr(s, '-');
  char *tok;
  int nf = 0;
  double secs = 0.0;
  int i;

  if (dash != NULL)
    {
      *dash = '\0';
      days = atof(s);
      s = dash + 1;
    }
  while ((tok = strsep(&s, ":")) != NULL && nf < 4)
    {
      fields[nf++] = atof(tok);
    }
  for (i = 0; i < nf; i++)
    {
      secs += fields[nf - 1 - i] * mult[i];
    }
  return days * 86400.0 + secs;
}
#endif

/* Cumulative CPU seconds used by pid, or -1 if it cannot be determined. */
static double cpuSecondsForPid(pid_t pid)
{
#if defined(__linux__)
  char path[64];
  char buf[1024];
  FILE *fp;
  char *p;
  unsigned long utime, stime;
  size_t n;

  snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
  fp = fopen(path, "r");
  if (fp == NULL) return -1.0;
  n = fread(buf, 1, sizeof(buf) - 1, fp);
  fclose(fp);
  buf[n] = '\0';
  /* The command name may contain spaces and parentheses; the fields that
   * matter follow the last closing parenthesis: state ppid pgrp session
   * tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime. */
  p = strrchr(buf, ')');
  if (p == NULL) return -1.0;
  if (sscanf(p + 1, " %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu",
             &utime, &stime) != 2)
    {
      return -1.0;
    }
  return (double)(utime + stime) / (double)sysconf(_SC_CLK_TCK);
#elif defined(__FreeBSD__)
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
  struct kinfo_proc kp;
  size_t len = sizeof(kp);

  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len != sizeof(kp)
    || kp.ki_pid != pid)
    {
      return -1.0;
    }
  return (double)kp.ki_runtime / 1e6;     /* microseconds */
#elif defined(__OpenBSD__)
  int mib[6] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid,
                 (int)sizeof(struct kinfo_proc), 1 };
  struct kinfo_proc kp;
  size_t len = sizeof(kp);

  if (sysctl(mib, 6, &kp, &len, NULL, 0) != 0 || len != sizeof(kp))
    {
      return -1.0;
    }
  return (double)kp.p_rtime_sec + (double)kp.p_rtime_usec / 1e6;
#else
  /* Other BSDs (NetBSD, DragonFly, ...): their kinfo_proc layouts differ in
   * ways that cannot be checked here, but ps accepts the same cputime query
   * everywhere. */
  char cmd[64];
  char line[256];
  FILE *fp;
  double secs = -1.0;

  snprintf(cmd, sizeof(cmd), "ps -o cputime= -p %d", (int)pid);
  fp = popen(cmd, "r");
  if (fp == NULL) return -1.0;
  if (fgets(line, sizeof(line), fp) != NULL)
    {
      secs = parsePsTime(line);
    }
  pclose(fp);
  return secs;
#endif
}

/* Start one app.  The name is resolved through $PATH by execvp(); the
 * environment, with GERSHWIN_SESSION_PID, is inherited.  A name that cannot
 * be run ends the child at once with status 127, which the crash-loop
 * logic treats like any other fast death.
 */
static pid_t launchApp(const char *name)
{
  pid_t pid;

  logLine("Starting %s...", name);
  pid = fork();
  if (pid < 0)
    {
      logLine("Failed to launch %s: %s", name, strerror(errno));
      return 0;
    }
  if (pid == 0)
    {
      char *argv[2];

      argv[0] = (char *)name;
      argv[1] = NULL;
      execvp(name, argv);
      fprintf(stderr, "gershwin-session: %s: %s\n", name, strerror(errno));
      _exit(127);
    }
  return pid;
}

/* Reap the app if it exited; returns nonzero while it is still running. */
static int appIsRunning(App *a)
{
  int status;
  pid_t r;

  if (a->pid <= 0) return 0;
  r = waitpid(a->pid, &status, WNOHANG);
  if (r == 0) return 1;
  a->pid = 0;
  return 0;
}

/* Stop the given apps, SIGKILLing any that did not leave after SIGTERM so
 * we never leak a half-shut-down app into the next session.  All of them get
 * the signal first and share the grace period.
 */
static void terminateApps(App *apps, int count)
{
  int i, round, anyUp;

  for (i = 0; i < count; i++)
    {
      if (appIsRunning(&apps[i])) kill(apps[i].pid, SIGTERM);
    }
  for (round = 0, anyUp = 1; round < 20 && anyUp; round++)
    {
      anyUp = 0;
      for (i = 0; i < count; i++) anyUp |= appIsRunning(&apps[i]);
      if (anyUp) sleepSeconds(0.05);          /* up to ~1s */
    }
  for (i = 0; i < count; i++)
    {
      if (appIsRunning(&apps[i]))
        {
          logLine("%s did not exit after SIGTERM; SIGKILLing pid %d.",
            apps[i].name, (int)apps[i].pid);
          kill(apps[i].pid, SIGKILL);
        }
    }
  for (round = 0, anyUp = 1; round < 20 && anyUp; round++)
    {
      anyUp = 0;
      for (i = 0; i < count; i++) anyUp |= appIsRunning(&apps[i]);
      if (anyUp) sleepSeconds(0.05);
    }
}

/* Kill any supervised app that has been above the CPU limit for over
 * CPU_RUNAWAY_SECONDS straight; killing hands it to the normal restart
 * logic, which brings a fresh copy up.  Samples once per second.
 */
static void watchForRunawayApps(App *apps, int count)
{
  static double nextSampleAt = 0;
  double now = monotonicSeconds();
  int i;

  if (now < nextSampleAt) return;
  nextSampleAt = now + 1.0;

  for (i = 0; i < count; i++)
    {
      App *w = &apps[i];
      double cpu, dt, rate;

      if (!appIsRunning(w))
        {
          w->lastCpu = -1.0;
          w->highSince = 0.0;
          continue;
        }

      cpu = cpuSecondsForPid(w->pid);
      if (cpu < 0.0 || w->lastCpu < 0.0)
        {
          w->lastCpu = cpu;
          w->lastAt = now;
          continue;
        }

      dt = now - w->lastAt;
      rate = dt > 0.0 ? (cpu - w->lastCpu) / dt : 0.0;
      w->lastCpu = cpu;
      w->lastAt = now;

      if (rate > CPU_RUNAWAY_RATE)
        {
          if (w->highSince == 0.0)
            {
              w->highSince = now;
            }
          else if (now - w->highSince >= CPU_RUNAWAY_SECONDS)
            {
              logLine("%s (pid %d) has been using more than %.0f%% CPU"
                " for over %.0f seconds; restarting it.",
                w->name, (int)w->pid, CPU_RUNAWAY_RATE * 100,
                CPU_RUNAWAY_SECONDS);
              terminateApps(w, 1);
              w->lastCpu = -1.0;
              w->highSince = 0.0;
            }
        }
      else
        {
          w->highSince = 0.0;
        }
    }
}

/* (Re)start anything that exited.  An app that died within
 * CRASH_LOOP_FAST_SECONDS of being launched enters a crash loop: it is
 * retried after a delay that doubles up to CRASH_LOOP_MAX_SECONDS, so an app
 * that cannot run at all does not turn the supervisor into a fork bomb.  One
 * attempt survives longer than CRASH_LOOP_FAST_SECONDS and the app is
 * treated as healthy again, with no delay on its next restart.
 */
static void launchMissingApps(App *apps, int count)
{
  double now = monotonicSeconds();
  int i;

  for (i = 0; i < count; i++)
    {
      App *w = &apps[i];
      double ran;

      if (appIsRunning(w))
        {
          w->diedAt = 0.0;
          /* An instance that stays up past the crash-loop window means the
           * app works again, so the next death starts over with no delay. */
          if (w->backoff > 0.0 && w->launchedAt > 0.0
            && now - w->launchedAt >= CRASH_LOOP_FAST_SECONDS)
            {
              w->backoff = 0.0;
            }
          continue; /* still up */
        }

      /* First poll at which this instance is seen gone.  It is remembered,
       * because otherwise the time the instance ran would be measured
       * against whenever we next happened to look, and after a backoff has
       * overshot, every attempt would look like it had run for the whole
       * delay - so the delay would never grow.
       */
      if (w->launched && w->diedAt == 0.0)
        {
          w->diedAt = now;
        }

      /* Ignored for apps that died while auto restart was disabled, so a
       * developer can keep a broken instance down for debugging.
       */
      if (autoRestart == 0) continue;

      if (w->backoff > 0.0)
        {
          /* In a crash loop: wait out the delay, then try once more. */
          if (now < w->nextLaunchAt) continue;
        }
      else
        {
          /* How long the last instance lasted: from being launched to being
           * first seen gone.  Short means it is not getting anywhere. */
          ran = (w->launchedAt > 0.0 && w->diedAt > 0.0)
            ? w->diedAt - w->launchedAt : 0.0;

          if (w->launchedAt > 0.0 && ran < CRASH_LOOP_FAST_SECONDS)
            {
              w->backoff = CRASH_LOOP_FIRST_DELAY;
              w->nextLaunchAt = now + w->backoff;
              w->lastNoticeAt = now;
              logLine("%s keeps exiting after %.1fs; next attempt in %.0fs."
                " Check that %s is installed and on the PATH.",
                w->name, ran, w->backoff, w->name);
              continue;
            }
        }

      w->launchedAt = now;
      w->diedAt = 0.0;
      w->launched = 1;
      w->pid = launchApp(w->name);
      if (w->pid == 0)
        {
          w->diedAt = now; /* could not even start: the same fast death */
        }

      if (w->backoff > 0.0)
        {
          /* Hold off until this long after the attempt just made, so the
           * wait survives this round having launched something. */
          w->nextLaunchAt = now + w->backoff;

          /* One line a minute about an app that is still not coming up, so
           * the cause stays visible without filling the log. */
          if (now - w->lastNoticeAt >= CRASH_LOOP_NOTICE_SECONDS)
            {
              w->lastNoticeAt = now;
              logLine("%s still is not running; retrying about every %.0fs.",
                w->name, w->backoff);
            }

          /* The next death, if it dies again that fast, waits twice as
           * long. */
          if (w->backoff * 2.0 < CRASH_LOOP_MAX_SECONDS)
            {
              w->backoff *= 2.0;
            }
        }
    }
}

int main(int argc, char *argv[])
{
  App *apps;
  int count = argc - 1;
  int lastAutoRestart = -1;
  const char *display;
  char pidText[32];
  int i;

  if (count < 1)
    {
      fprintf(stderr,
        "Usage: %s AppName1 [AppName2 ...]\n"
        "Supervises the named apps, restarting any that exit.\n", argv[0]);
      return 1;
    }

  apps = calloc((size_t)count, sizeof(App));
  if (apps == NULL)
    {
      fprintf(stderr, "%s: out of memory\n", argv[0]);
      return 1;
    }
  for (i = 0; i < count; i++)
    {
      apps[i].name = argv[i + 1];
      apps[i].lastCpu = -1.0;
    }

  /* Make our own pid discoverable by the supervised apps so they can tell
   * their own session to log out, instead of acting on another user's
   * session that happens to run the same binary names.
   */
  snprintf(pidText, sizeof(pidText), "%d", (int)getpid());
  setenv("GERSHWIN_SESSION_PID", pidText, 1);

  installSignalHandlers();
  display = getenv("DISPLAY");
  logLine("Gershwin session supervisor started (pid %d, display %s)."
    " Supervising:", (int)getpid(), display != NULL ? display : "(none)");
  for (i = 0; i < count; i++) logLine("  %s", apps[i].name);
  logLine("Auto restart is on; send SIGUSR1 to disable, SIGUSR2 to enable.");

  while (keepRunning)
    {
      if (lastAutoRestart != autoRestart)
        {
          logLine("%s", autoRestart ? "Auto restart ENABLED."
                                    : "Auto restart DISABLED (dev mode).");
          lastAutoRestart = (int)autoRestart;
        }

      /* (Re)start anything that exited, with a backoff for apps that keep
       * dying at once. */
      launchMissingApps(apps, count);

      watchForRunawayApps(apps, count);

      if (keepRunning) sleepSeconds(0.25);
    }

  logLine("Shutdown signal received; terminating supervised apps.");
  terminateApps(apps, count);

  logLine("G session manager exiting.");
  free(apps);
  return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Daemon launcher and small helpers shared by the test tools. */

#ifndef MBT_HARNESS_H
#define MBT_HARNESS_H

#include <sys/types.h>
#include "wire.h"

typedef struct tdaemon {
  pid_t pid;
  char dir[200];
  char sock[256];
  char log[280];
  char addr[512];        /* what --print-address printed */
  int outfd;             /* stdout of the daemon, after the address line */
  int exited;
  int status;
} tdaemon;

/* Call first in main(): watchdog, environment scrub, skip when the chosen
 * daemon is unavailable (prints SKIP and exits 0). */
void th_init (const char *toolname);
int th_is_real (void);
const char *th_mode (void);
const char *th_tests_dir (void);

/* Start a daemon on a fresh private socket. extra: NULL terminated argv
 * additions (may be NULL). Returns NULL when it fails to come up. */
tdaemon *th_start (const char *const *extra);
/* Same, but with the exact argument list after the program (no --address
 * added). Used by the CLI tests. out gets the stdout pipe fd. */
pid_t th_spawn (const char *const *args, int *outfd, const char *errlog);
/* argv[0] of the daemon under test */
const char *th_daemon_path (void);
/* Build the leading arguments for the selected daemon (config etc.). */
int th_base_args (const char **argv, int max, const char *sockpath);
void th_stop (tdaemon *d);
int th_alive (tdaemon *d);
/* Wait for exit: returns 1 when exited within ms. status in d->status */
int th_wait_exit (tdaemon *d, int ms);
pid_t th_wait_pid (pid_t pid, int ms, int *status);
char *th_mkdtemp (void);     /* private dir, malloc'd; caller removes */
void th_rmtree (const char *dir);

/* New authenticated + Hello'd client, NULL on failure. */
wconn *th_client (tdaemon *d);
/* Connected, nothing sent. */
wconn *th_raw (tdaemon *d);
/* Client whose messages use big endian. */
wconn *th_client_be (tdaemon *d);

/* Report the tool's own failure counter (incremented by TCHECK). */
extern int th_failures;
int th_resource_limit (void);

#endif

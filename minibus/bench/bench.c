/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Measures a bus daemon: call/reply round trips and signal fan-out.
 *
 *   bench SOCKET DAEMON-PID [calls] [signals] [listeners]
 *
 * Prints messages per second and the CPU time and peak RSS the daemon spent,
 * read from /proc (Linux). The clients use the test suite's wire library. */

#include "../Tests/wire.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

/* utime+stime in seconds and VmHWM in KiB of pid */
static void daemon_stats(pid_t pid, double *cpu, long *hwm)
{
    char p[64], buf[4096];
    snprintf(p, sizeof p, "/proc/%d/stat", (int)pid);
    FILE *f = fopen(p, "r");
    *cpu = 0;
    if (f) {
        unsigned long ut = 0, st = 0;
        if (fgets(buf, sizeof buf, f)) {
            char *q = strrchr(buf, ')');
            if (q) sscanf(q + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lu %lu", &ut, &st);
        }
        fclose(f);
        *cpu = (double)(ut + st) / (double)sysconf(_SC_CLK_TCK);
    }
    snprintf(p, sizeof p, "/proc/%d/status", (int)pid);
    f = fopen(p, "r");
    *hwm = 0;
    if (f) {
        while (fgets(buf, sizeof buf, f))
            if (!strncmp(buf, "VmHWM:", 6)) *hwm = atol(buf + 6);
        fclose(f);
    }
}

static wconn *client(const char *sock)
{
    wconn *c = wc_connect(sock);
    if (!c || wc_auth(c, WA_EXTERNAL) != 0 || wc_hello(c) != 0) { fprintf(stderr, "connect failed\n"); exit(1); }
    return c;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: bench SOCKET DAEMON-PID [calls] [signals] [listeners]\n"); return 1; }
    const char *sock = argv[1];
    pid_t dpid = (pid_t)atoi(argv[2]);
    int ncalls = argc > 3 ? atoi(argv[3]) : 100000;
    int nsig = argc > 4 ? atoi(argv[4]) : 20000;
    int nlist = argc > 5 ? atoi(argv[5]) : 50;
    double c0, c1; long hwm;

    /* --- call/reply: a callee answers everything, the caller keeps 32 calls in flight */
    int ready[2];
    if (pipe(ready) != 0) return 1;
    pid_t callee = fork();
    if (callee == 0) {
        wconn *s = client(sock);
        wmsg *m = wm_bus("RequestName", "su", "org.bench.Callee", 0), *r = NULL;
        wc_call(s, m, &r, 5000); wm_free(m); wm_free(r);
        if (write(ready[1], "x", 1) != 1) _exit(1);
        for (;;) {
            wmsg *in = NULL;
            int rc = wc_recv(s, &in, 60000);
            if (rc != 1) _exit(0);
            if (in->type == W_CALL) { wmsg *rep = wm_return(in); wm_u32(rep, 1); wm_setstr(&rep->sig, "u"); wc_send(s, rep); wm_free(rep); }
            wm_free(in);
        }
    }
    char x;
    if (read(ready[0], &x, 1) != 1) return 1;
    wconn *a = client(sock);
    daemon_stats(dpid, &c0, &hwm);
    double t0 = now();
    int sent = 0, got = 0;
    while (got < ncalls) {
        while (sent < ncalls && sent - got < 32) {
            wmsg *m = wm_call("org.bench.Callee", "/b", "org.bench.I", "Call");
            wm_setstr(&m->sig, "s"); wm_str(m, "hello");
            wc_send(a, m); wm_free(m); sent++;
        }
        wmsg *in = NULL;
        if (wc_recv(a, &in, 10000) != 1) { fprintf(stderr, "call timeout at %d\n", got); return 1; }
        if (in->type == W_RETURN || in->type == W_ERROR) got++;
        wm_free(in);
    }
    double t1 = now();
    daemon_stats(dpid, &c1, &hwm);
    printf("calls:   %7d round trips in %.2f s = %8.0f/s, daemon CPU %.2f s (%.1f us per message)\n",
           ncalls, t1 - t0, ncalls / (t1 - t0), c1 - c0, (c1 - c0) * 1e6 / (2.0 * ncalls));
    kill(callee, SIGTERM); waitpid(callee, NULL, 0);

    /* --- fan-out: nlist listeners with 4 rules each, one of which matches */
    pid_t *kids = calloc((size_t)nlist, sizeof *kids);
    int done[2];
    if (pipe(done) != 0) return 1;
    for (int i = 0; i < nlist; i++) {
        kids[i] = fork();
        if (kids[i] == 0) {
            wconn *l = client(sock);
            const char *rules[] = { "type='signal',interface='org.other.A'",
                                    "type='signal',interface='org.bench.S',member='Other'",
                                    "type='signal',sender='org.nobody.X'",
                                    "type='signal',interface='org.bench.S',member='Tick',arg0='go'" };
            for (int k = 0; k < 4; k++) { wmsg *m = wm_bus("AddMatch", "s", rules[k]), *r = NULL; wc_call(l, m, &r, 5000); wm_free(m); wm_free(r); }
            if (write(ready[1], "x", 1) != 1) _exit(1);
            int n = 0;
            while (n < nsig) {
                wmsg *in = NULL;
                if (wc_recv(l, &in, 30000) != 1) break;
                if (in->type == W_SIGNAL && in->member && !strcmp(in->member, "Tick")) n++;
                wm_free(in);
            }
            if (write(done[1], "x", 1) != 1) _exit(1);
            _exit(n == nsig ? 0 : 1);
        }
    }
    for (int i = 0; i < nlist; i++) if (read(ready[0], &x, 1) != 1) return 1;
    daemon_stats(dpid, &c0, &hwm);
    t0 = now();
    for (int i = 0; i < nsig; i++) {
        wmsg *m = wm_signal("/b", "org.bench.S", "Tick");
        wm_setstr(&m->sig, "su"); wm_str(m, "go"); wm_u32(m, (uint32_t)i);
        wc_send(a, m); wm_free(m);
        if ((i & 255) == 0) { wmsg *in = NULL; while (wc_recv(a, &in, 0) == 1) wm_free(in); }
    }
    for (int i = 0; i < nlist; i++) if (read(done[0], &x, 1) != 1) return 1;
    t1 = now();
    daemon_stats(dpid, &c1, &hwm);
    int fails = 0;
    for (int i = 0; i < nlist; i++) { int st; waitpid(kids[i], &st, 0); if (!WIFEXITED(st) || WEXITSTATUS(st)) fails++; }
    printf("fan-out: %7d signals x %d listeners in %.2f s = %8.0f deliveries/s, daemon CPU %.2f s (%.2f us per delivery)%s\n",
           nsig, nlist, t1 - t0, (double)nsig * nlist / (t1 - t0), c1 - c0,
           (c1 - c0) * 1e6 / ((double)nsig * nlist), fails ? " INCOMPLETE" : "");
    printf("daemon peak RSS: %ld KiB\n", hwm);
    wc_close(a);
    return 0;
}

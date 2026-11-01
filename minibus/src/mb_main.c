/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Listening sockets, the poll loop and the command line. */

#include "mb_int.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

#define DEFAULT_MAX_CONN 4096
#define DEFAULT_MAX_INCOMPLETE 256
#define DEFAULT_AUTH_TIMEOUT_MS 30000

static mb_bus *g_bus;
static int g_listen_mode = -1;      /* chmod of the socket file, -1 leaves the umask result */
static int g_verbose;
static bool g_syslog;

void mb_log(int level, const char *fmt, ...)
{
    if (level > g_verbose) return;
    va_list ap;
    va_start(ap, fmt);
    if (g_syslog) {
        vsyslog(level ? LOG_DEBUG : LOG_NOTICE, fmt, ap);
    } else {
        char line[1024];
        vsnprintf(line, sizeof line, fmt, ap);
        fprintf(stderr, "minibus: %s\n", line);
    }
    va_end(ap);
}

/* ---------------------------------------------------------------- bus object */

static bool random_guid(char out[33])
{
    uint8_t raw[16];
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    ssize_t n = read(fd, raw, sizeof raw);
    close(fd);
    if (n != (ssize_t)sizeof raw) return false;
    for (int i = 0; i < 16; i++) snprintf(out + 2 * i, 3, "%02x", raw[i]);
    return true;
}

mb_bus *mb_bus_new(void)
{
    mb_bus *b = calloc(1, sizeof *b);
    if (!b) return NULL;
    if (!random_guid(b->guid)) { free(b); return NULL; }
    b->max_conn = DEFAULT_MAX_CONN;
    b->max_incomplete = DEFAULT_MAX_INCOMPLETE;
    b->auth_timeout_ms = DEFAULT_AUTH_TIMEOUT_MS;
    b->my_uid = (uint32_t)getuid();
    b->my_pid = (uint32_t)getpid();
    b->sys_uid_max = 999;
    if (pipe(b->wakefd) != 0) { free(b); return NULL; }
    for (int i = 0; i < 2; i++) {
        fcntl(b->wakefd[i], F_SETFL, O_NONBLOCK);
        fcntl(b->wakefd[i], F_SETFD, FD_CLOEXEC);
    }
    return b;
}

const char *mb_bus_id(mb_bus *b) { return b->guid; }

void mb_bus_free(mb_bus *b)
{
    if (!b) return;
    for (int i = 0; i < b->nconns; i++) mb_conn_free(b->conns[i]);
    free(b->conns);
    for (int i = 0; i < b->nlisteners; i++) {
        close(b->listeners[i].fd);
        if (b->listeners[i].path && !b->listeners[i].is_abstract) unlink(b->listeners[i].path);
        free(b->listeners[i].path);
    }
    free(b->listeners);
    for (int h = 0; h < MB_NAME_BUCKETS; h++) {
        mb_name *n = b->names[h];
        while (n) { mb_name *nx = n->hnext; free(n->owners); free(n->name); free(n); n = nx; }
    }
    for (int h = 0; h < MB_REPLY_BUCKETS; h++) {
        mb_reply *r = b->replies[h];
        while (r) { mb_reply *nx = r->next; free(r); r = nx; }
    }
    close(b->wakefd[0]);
    close(b->wakefd[1]);
    free(b);
}

/* --------------------------------------------------------------- listening */

static char *unescape(const char *s, size_t n)
{
    char *out = malloc(n + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '%' && i + 2 < n + 1) {
            char h[3] = { s[i + 1], s[i + 2], 0 };
            char *end;
            long v = strtol(h, &end, 16);
            if (!*end) { out[o++] = (char)v; i += 2; continue; }
        }
        out[o++] = s[i];
    }
    out[o] = 0;
    return out;
}

static void set_err(char *err, size_t len, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void set_err(char *err, size_t len, const char *fmt, ...)
{
    if (!err) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

static bool add_listener(mb_bus *b, int fd, const char *path, bool abstract)
{
    mb_listener *p = realloc(b->listeners, sizeof *p * (size_t)(b->nlisteners + 1));
    if (!p) return false;
    b->listeners = p;
    b->listeners[b->nlisteners].fd = fd;
    b->listeners[b->nlisteners].path = path ? strdup(path) : NULL;
    b->listeners[b->nlisteners].is_abstract = abstract;
    b->nlisteners++;
    return true;
}

static int make_listener(const char *path, bool abstract, char *err, size_t errlen)
{
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    size_t plen = strlen(path);
    if (plen + (abstract ? 1 : 0) >= sizeof sa.sun_path) {
        set_err(err, errlen, "socket path too long: %s", path);
        return -1;
    }
    socklen_t slen;
    if (abstract) {
#ifdef __linux__
        memcpy(sa.sun_path + 1, path, plen);
        slen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + plen);
#else
        set_err(err, errlen, "abstract sockets are not supported here%s", "");
        return -1;
#endif
    } else {
        memcpy(sa.sun_path, path, plen + 1);
        slen = (socklen_t)sizeof sa;
        /* a socket file nobody listens on is stale; one somebody serves is not ours to take */
        struct stat st;
        if (lstat(path, &st) == 0) {
            if (!S_ISSOCK(st.st_mode)) { set_err(err, errlen, "%s exists and is not a socket", path); return -1; }
            int probe = socket(AF_UNIX, SOCK_STREAM, 0);
            if (probe >= 0) {
                if (connect(probe, (struct sockaddr *)&sa, sizeof sa) == 0) {
                    close(probe);
                    set_err(err, errlen, "address already in use: %s", path);
                    return -1;
                }
                close(probe);
            }
            unlink(path);
        }
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { set_err(err, errlen, "socket: %s", strerror(errno)); return -1; }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    if (bind(fd, (struct sockaddr *)&sa, slen) != 0) {
        set_err(err, errlen, "cannot bind %s: %s", path, strerror(errno));
        close(fd);
        return -1;
    }
    if (!abstract && g_listen_mode >= 0) chmod(path, (mode_t)g_listen_mode);
    if (listen(fd, 128) != 0) {
        set_err(err, errlen, "listen: %s", strerror(errno));
        close(fd);
        if (!abstract) unlink(path);
        return -1;
    }
    return fd;
}

static bool random_suffix(char *out, size_t n)
{
    static const char alpha[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    uint8_t raw[16];
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    ssize_t r = read(fd, raw, n);
    close(fd);
    if (r != (ssize_t)n) return false;
    for (size_t i = 0; i < n; i++) out[i] = alpha[raw[i] % (sizeof alpha - 1)];
    out[n] = 0;
    return true;
}

/* One transport entry of an address, e.g. "unix:path=/x". */
static bool listen_one(mb_bus *b, const char *entry, char **actual, char *err, size_t errlen)
{
    if (strncmp(entry, "unix:", 5) != 0) {
        set_err(err, errlen, "unsupported address (only unix: is supported): %s", entry);
        return false;
    }
    const char *p = entry + 5;
    char *path = NULL;
    bool abstract = false, generate = false;
    const char *tmpdir = NULL;
    while (*p) {
        const char *eq = strchr(p, '=');
        const char *end = strchr(p, ',');
        if (!end) end = p + strlen(p);
        if (!eq || eq > end) { set_err(err, errlen, "malformed address: %s", entry); free(path); return false; }
        size_t klen = (size_t)(eq - p);
        char *val = unescape(eq + 1, (size_t)(end - eq - 1));
        if (!val) { free(path); return false; }
        if (klen == 4 && !strncmp(p, "path", 4)) { free(path); path = val; abstract = false; }
        else if (klen == 8 && !strncmp(p, "abstract", 8)) { free(path); path = val; abstract = true; }
        else if (klen == 6 && !strncmp(p, "tmpdir", 6)) { tmpdir = val; generate = true; free(path); path = NULL; }
        else if (klen == 3 && !strncmp(p, "dir", 3)) { tmpdir = val; generate = true; free(path); path = NULL; }
        else if (klen == 7 && !strncmp(p, "runtime", 7)) {
            const char *rt = getenv("XDG_RUNTIME_DIR");
            if (!strcmp(val, "yes") && rt && *rt) {
                free(path);
                path = malloc(strlen(rt) + 5);
                if (path) sprintf(path, "%s/bus", rt);
                abstract = false;
            }
            free(val);
        }
        else if (klen == 4 && !strncmp(p, "guid", 4)) free(val);
        else free(val);
        p = *end ? end + 1 : end;
    }
    char generated[512];
    if (generate) {
        char suf[9];
        if (!random_suffix(suf, 8)) { set_err(err, errlen, "no random numbers%s", ""); free(path); return false; }
        snprintf(generated, sizeof generated, "%s/dbus-%s", tmpdir, suf);
        free(path);
        path = strdup(generated);
        free((void *)tmpdir);
    }
    if (!path || !*path) { set_err(err, errlen, "address has no path: %s", entry); free(path); return false; }
    int fd = make_listener(path, abstract, err, errlen);
    if (fd < 0) { free(path); return false; }
    if (!add_listener(b, fd, path, abstract)) { close(fd); free(path); return false; }
    if (actual) {
        /* values are escaped so a path with ',' or '=' survives a round trip */
        size_t cap = strlen(path) * 3 + 80;
        char *a = malloc(cap);
        if (a) {
            size_t o = (size_t)snprintf(a, cap, "unix:%s=", abstract ? "abstract" : "path");
            for (const char *q = path; *q && o + 4 < cap; q++) {
                unsigned char ch = (unsigned char)*q;
                if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                    strchr("-_/.\\*", ch))
                    a[o++] = (char)ch;
                else o += (size_t)snprintf(a + o, cap - o, "%%%02x", ch);
            }
            snprintf(a + o, cap - o, ",guid=%s", b->guid);
            *actual = a;
        }
    }
    free(path);
    return true;
}

bool mb_bus_listen(mb_bus *b, const char *address, char **actual_address, char *err, size_t errlen)
{
    char *copy = strdup(address);
    if (!copy) return false;
    char *save = NULL, *tok = copy;
    bool ok = true;
    char *all = NULL;
    while (ok && (tok = strtok_r(tok, ";", &save)) != NULL) {
        char *one = NULL;
        ok = listen_one(b, tok, actual_address ? &one : NULL, err, errlen);
        if (ok && one) {
            size_t al = all ? strlen(all) : 0;
            char *n = realloc(all, al + strlen(one) + 2);
            if (n) { all = n; sprintf(all + al, "%s%s", al ? ";" : "", one); }
        }
        free(one);
        tok = NULL;
    }
    free(copy);
    if (actual_address) *actual_address = all; else free(all);
    return ok;
}

/* ---------------------------------------------------------------- main loop */

static bool conns_add(mb_bus *b, mb_conn *c)
{
    if (b->nconns == b->capconns) {
        int ncap = b->capconns ? b->capconns * 2 : 64;
        mb_conn **p = realloc(b->conns, sizeof *p * (size_t)ncap);
        if (!p) return false;
        b->conns = p; b->capconns = ncap;
    }
    b->conns[b->nconns++] = c;
    return true;
}

static void accept_clients(mb_bus *b, int lfd)
{
    for (int burst = 0; burst < 64; burst++) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) return;
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, O_NONBLOCK);
        int incomplete = 0;
        for (int i = 0; i < b->nconns; i++)
            if (b->conns[i]->state != MBC_ACTIVE && b->conns[i]->state != MBC_MONITOR) incomplete++;
        if (b->nconns >= b->max_conn || incomplete >= b->max_incomplete) { close(fd); continue; }
        mb_conn *c = mb_conn_new(b, fd);
        if (!c) { close(fd); continue; }
        if (!conns_add(b, c)) { mb_conn_free(c); continue; }
    }
}

static void reap(mb_bus *b)
{
    bool again = true;
    while (again) {
        again = false;
        for (int i = 0; i < b->nconns; i++) {
            mb_conn *c = b->conns[i];
            if (!c->closing && c->state != MBC_DEAD) continue;
            b->conns[i] = b->conns[--b->nconns];
            mb_bus_conn_closed(b, c);
            mb_conn_free(c);
            i--;
            again = true;
        }
    }
}

void mb_bus_run(mb_bus *b)
{
    b->running = true;
    struct pollfd *pfds = NULL;
    size_t cap = 0;
    while (b->running) {
        size_t need = (size_t)(b->nlisteners + b->nconns + 1);
        if (need > cap) {
            struct pollfd *np = realloc(pfds, sizeof *np * need * 2);
            if (!np) break;
            pfds = np; cap = need * 2;
        }
        size_t n = 0;
        pfds[n].fd = b->wakefd[0]; pfds[n].events = POLLIN; n++;
        for (int i = 0; i < b->nlisteners; i++) { pfds[n].fd = b->listeners[i].fd; pfds[n].events = POLLIN; n++; }
        size_t first_conn = n;
        int64_t now = mb_now_ms(), next_deadline = 0;
        for (int i = 0; i < b->nconns; i++) {
            mb_conn *c = b->conns[i];
            pfds[n].fd = c->fd;
            pfds[n].events = POLLIN | (mb_conn_wants_write(c) ? POLLOUT : 0);
            n++;
            if (c->deadline_ms && (!next_deadline || c->deadline_ms < next_deadline))
                next_deadline = c->deadline_ms;
        }
        int timeout = -1;
        if (next_deadline) {
            int64_t d = next_deadline - now;
            timeout = d < 0 ? 0 : (d > 60000 ? 60000 : (int)d + 1);
        }
        int rc = poll(pfds, (nfds_t)n, timeout);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pfds[0].revents & POLLIN) {
            char tmp[64];
            while (read(b->wakefd[0], tmp, sizeof tmp) > 0) { }
            if (!b->running) break;
        }
        for (int i = 0; i < b->nlisteners; i++)
            if (pfds[1 + (size_t)i].revents & POLLIN) accept_clients(b, b->listeners[i].fd);
        /* conns may have been added by accept; only the polled ones have events */
        size_t polled = n - first_conn;
        for (size_t i = 0; i < polled; i++) {
            mb_conn *c = b->conns[i];
            short ev = pfds[first_conn + i].revents;
            if (c->closing || c->state == MBC_DEAD) continue;
            if (ev & (POLLIN | POLLHUP | POLLERR)) {
                if (!mb_conn_read(c)) c->closing = true;
            }
            if (!c->closing && (ev & POLLOUT)) {
                if (!mb_conn_flush(c)) c->closing = true;
            }
        }
        /* push out what the handlers queued without waiting for another round */
        for (int i = 0; i < b->nconns; i++) {
            mb_conn *c = b->conns[i];
            if (!c->closing && mb_conn_wants_write(c) && !mb_conn_flush(c)) c->closing = true;
        }
        now = mb_now_ms();
        for (int i = 0; i < b->nconns; i++) {
            mb_conn *c = b->conns[i];
            if (c->deadline_ms && c->deadline_ms <= now) c->closing = true;
        }
        reap(b);
    }
    free(pfds);
}

/* ------------------------------------------------------------- command line */

static void on_signal(int sig)
{
    (void)sig;
    if (g_bus) {
        g_bus->running = false;
        char x = 1;
        if (write(g_bus->wakefd[1], &x, 1) < 0) { }
    }
}

static void usage(FILE *f)
{
    fprintf(f, "usage: minibus [--session | --system | --address=ADDR | SOCKET-PATH]\n"
               "               [--print-address[=FD]] [--print-pid[=FD]] [--pid-file=FILE]\n"
               "               [--fork | --nofork] [--syslog] [--verbose] [--version]\n"
               "               [--system-uid-max=UID] [--owner-group=GROUP]\n"
               "On the system bus, root, uids up to --system-uid-max (default 999) and members\n"
               "of --owner-group may own names. --config-file and --nopidfile are ignored.\n");
}

static void write_fd_line(int fd, const char *text)
{
    size_t n = strlen(text);
    while (n) {
        ssize_t w = write(fd, text, n);
        if (w < 0) { if (errno == EINTR) continue; return; }
        text += w; n -= (size_t)w;
    }
}

int mb_main(int argc, char **argv)
{
    const char *address = NULL, *pid_file = NULL, *owner_group = NULL;
    long sys_uid_max = 999;
    char *addr_buf = NULL;
    bool system_bus = false, session_bus = false, do_fork = false;
    int print_address_fd = -1, print_pid_fd = -1;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--system")) system_bus = true;
        else if (!strcmp(a, "--session")) session_bus = true;
        else if (!strncmp(a, "--address=", 10)) address = a + 10;
        else if (!strcmp(a, "--address") && i + 1 < argc) address = argv[++i];
        else if (!strcmp(a, "--print-address")) print_address_fd = 1;
        else if (!strncmp(a, "--print-address=", 16)) print_address_fd = atoi(a + 16);
        else if (!strcmp(a, "--print-pid")) print_pid_fd = 1;
        else if (!strncmp(a, "--print-pid=", 12)) print_pid_fd = atoi(a + 12);
        else if (!strncmp(a, "--pid-file=", 11)) pid_file = a + 11;
        else if (!strncmp(a, "--owner-group=", 14)) owner_group = a + 14;
        else if (!strncmp(a, "--system-uid-max=", 17)) sys_uid_max = strtol(a + 17, NULL, 10);
        else if (!strcmp(a, "--verbose") || !strcmp(a, "-v")) g_verbose = 1;
        else if (!strcmp(a, "--syslog") || !strcmp(a, "--syslog-only")) g_syslog = true;
        else if (!strcmp(a, "--fork")) do_fork = true;
        else if (!strcmp(a, "--nofork")) do_fork = false;
        else if (!strncmp(a, "--config-file=", 14) || !strcmp(a, "--nopidfile") ||
                 !strcmp(a, "--nosyslog")) { }
        else if (!strcmp(a, "--config-file") && i + 1 < argc) i++;
        else if (!strcmp(a, "--version")) { printf("minibus " MB_VERSION "\n"); return 0; }
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(stdout); return 0; }
        else if (a[0] == '-') { fprintf(stderr, "minibus: unknown option %s\n", a); usage(stderr); return 1; }
        else {
            /* legacy form: a bare socket path */
            addr_buf = malloc(strlen(a) * 3 + 16);
            if (!addr_buf) return 1;
            sprintf(addr_buf, "unix:path=%s", a);
            address = addr_buf;
        }
    }
    if (system_bus && !address) {
        struct stat st;
        address = (stat("/run", &st) == 0 && S_ISDIR(st.st_mode)) ? "unix:path=/run/dbus/system_bus_socket"
                                                                    : "unix:path=/var/run/dbus/system_bus_socket";
        g_listen_mode = 0666;
        char dir[128];
        snprintf(dir, sizeof dir, "%s", address + 10);
        char *slash = strrchr(dir, '/');
        if (slash) { *slash = 0; mkdir(dir, 0755); }
    } else if (session_bus && !address) {
        g_listen_mode = 0600;
        const char *rt = getenv("XDG_RUNTIME_DIR");
        if (rt && *rt) {
            addr_buf = malloc(strlen(rt) + 32);
            sprintf(addr_buf, "unix:path=%s/bus", rt);
            address = addr_buf;
        } else address = "unix:tmpdir=/tmp";
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }

    if (sys_uid_max < 0 || sys_uid_max > 0x7fffffffL) { fprintf(stderr, "minibus: bad --system-uid-max\n"); free(addr_buf); return 1; }
    if (g_syslog) openlog("minibus", LOG_PID, LOG_DAEMON);
    /* everyone reaches the system bus; only its owner reaches a session bus */
    g_listen_mode = system_bus ? 0666 : 0600;
    mb_bus *b = mb_bus_new();
    if (!b) { fprintf(stderr, "minibus: cannot start\n"); return 1; }
    b->system = system_bus;
    b->sys_uid_max = (uint32_t)sys_uid_max;
    if (owner_group) {
        struct group *gr = getgrnam(owner_group);
        if (!gr) { fprintf(stderr, "minibus: no such group %s\n", owner_group); mb_bus_free(b); return 1; }
        b->owner_gid = gr->gr_gid;
        b->have_owner_gid = true;
    }
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur > 128 && (rlim_t)b->max_conn > rl.rlim_cur - 64)
        b->max_conn = (int)(rl.rlim_cur - 64);

    if (!address) {
        fprintf(stderr, "minibus: no address to listen on\n");
        usage(stderr);
        mb_bus_free(b);
        return 1;
    }

    /* With --fork the child listens, so the sockets' peer credentials name the
     * process that serves them (clients read the bus's pid from there), and the
     * child tells the waiting parent the address or what went wrong. */
    int report = -1;
    if (do_fork) {
        int pp[2];
        if (pipe(pp) != 0) { perror("minibus: pipe"); mb_bus_free(b); return 1; }
        pid_t child = fork();
        if (child < 0) { perror("minibus: fork"); mb_bus_free(b); return 1; }
        if (child > 0) {
            close(pp[1]);
            char buf[4096];
            size_t got = 0;
            for (;;) {
                ssize_t r = read(pp[0], buf + got, sizeof buf - 1 - got);
                if (r < 0 && errno == EINTR) continue;
                if (r <= 0) break;
                got += (size_t)r;
                if (got == sizeof buf - 1) break;
            }
            buf[got] = 0;
            if (strncmp(buf, "OK ", 3) != 0) {
                fprintf(stderr, "minibus: %s", got > 4 ? buf + 4 : "the bus did not start\n");
                _exit(1);
            }
            if (print_address_fd >= 0) write_fd_line(print_address_fd, buf + 3);
            if (print_pid_fd >= 0) { char l[32]; snprintf(l, sizeof l, "%ld\n", (long)child); write_fd_line(print_pid_fd, l); }
            _exit(0);
        }
        close(pp[0]);
        report = pp[1];
        setsid();
        b->my_pid = (uint32_t)getpid();
    }

    char *actual = NULL;
    char err[256] = "";
    if (!mb_bus_listen(b, address, &actual, err, sizeof err)) {
        if (report >= 0) {
            char l[300];
            snprintf(l, sizeof l, "ERR %s\n", err);
            write_fd_line(report, l);
        } else {
            fprintf(stderr, "minibus: %s\n", err);
        }
        mb_bus_free(b);
        free(addr_buf);
        return 1;
    }
    free(addr_buf);

    if (pid_file) {
        FILE *f = fopen(pid_file, "w");
        if (!f) {
            char l[600];
            snprintf(l, sizeof l, "cannot write %s: %s\n", pid_file, strerror(errno));
            if (report >= 0) { write_fd_line(report, "ERR "); write_fd_line(report, l); }
            else fprintf(stderr, "minibus: %s", l);
            free(actual);
            mb_bus_free(b);
            return 1;
        }
        fprintf(f, "%ld\n", (long)getpid());
        fclose(f);
    }

    if (report >= 0) {
        write_fd_line(report, "OK ");
        write_fd_line(report, actual ? actual : "");
        write_fd_line(report, "\n");
        close(report);
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) { dup2(dn, 0); dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); }
    } else {
        if (print_address_fd >= 0 && actual) {
            write_fd_line(print_address_fd, actual);
            write_fd_line(print_address_fd, "\n");
        }
        if (print_pid_fd >= 0) {
            char l[32];
            snprintf(l, sizeof l, "%ld\n", (long)getpid());
            write_fd_line(print_pid_fd, l);
        }
    }
    free(actual);

    g_bus = b;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    mb_bus_run(b);

    g_bus = NULL;
    mb_bus_free(b);
    if (pid_file) unlink(pid_file);
    return 0;
}

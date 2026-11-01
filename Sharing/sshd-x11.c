/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#include "sshd-x11.h"

#include <errno.h>
#include <glob.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

/* A config nested deeper than this is not one we understand well enough to
 * edit. */
#define MAX_INCLUDE_DEPTH 8

/* Value an unreadable included file is reported with, so that the walk stops
 * with an error instead of skipping a file that may hold the directive. */
#define UNREADABLE "unreadable-include-file"

typedef struct {
    int found;          /* a global X11Forwarding directive was seen */
    int value;
    int in_include;     /* ... in an included file, not in the file itself */
    size_t line_end;    /* depth 0: end of the value token */
    size_t global_end;  /* depth 0: start of the first Match line */
    int has_match;
    int failed;
    char err[256];
} Walk;

static int is_ws(char c) { return c == ' ' || c == '\t'; }

static int parse_bool(const char *s, size_t n)
{
    if (n == 3 && strncasecmp(s, "yes", 3) == 0) return 1;
    if (n == 4 && strncasecmp(s, "true", 4) == 0) return 1;
    if (n == 2 && strncasecmp(s, "no", 2) == 0) return 0;
    if (n == 5 && strncasecmp(s, "false", 5) == 0) return 0;
    return -1;
}

static void fail(Walk *w, const char *what, long line)
{
    w->failed = 1;
    snprintf(w->err, sizeof(w->err), "%s on line %ld of the sshd configuration", what, line);
}

static void walk_text(const char *text, SshdIncludeLoader load, void *ctx,
                      int depth, Walk *w)
{
    size_t len = strlen(text);
    size_t pos = 0;
    long lineno = 0;

    while (pos < len && !w->failed) {
        size_t ls = pos;
        size_t le = ls;
        while (le < len && text[le] != '\n') le++;
        pos = le < len ? le + 1 : le;
        lineno++;

        size_t p = ls;
        while (p < le && is_ws(text[p])) p++;
        if (p == le || text[p] == '#') continue;

        size_t ks = p;
        while (p < le && !is_ws(text[p]) && text[p] != '=' && text[p] != '\r') p++;
        size_t kl = p - ks;
        while (p < le && is_ws(text[p])) p++;
        if (p < le && text[p] == '=') {
            p++;
            while (p < le && is_ws(text[p])) p++;
        }
        size_t vs = p;
        size_t ve = le;
        while (ve > vs && (is_ws(text[ve - 1]) || text[ve - 1] == '\r')) ve--;

        if (kl == 5 && strncasecmp(text + ks, "Match", 5) == 0) {
            if (depth == 0) {
                w->global_end = ls;
                w->has_match = 1;
            }
            return;
        }

        if (kl == 7 && strncasecmp(text + ks, "Include", 7) == 0) {
            if (w->found) continue;
            if (depth >= MAX_INCLUDE_DEPTH) {
                fail(w, "Include nested too deeply", lineno);
                return;
            }
            size_t q = vs;
            while (q < ve && !w->found && !w->failed) {
                char pat[1024];
                size_t ps = q;
                while (q < ve && !is_ws(text[q])) q++;
                size_t pl = q - ps;
                while (q < ve && is_ws(text[q])) q++;
                if (pl == 0 || pl >= sizeof(pat) || text[ps] == '"') {
                    fail(w, "Include pattern not understood", lineno);
                    return;
                }
                memcpy(pat, text + ps, pl);
                pat[pl] = '\0';
                for (int idx = 0; !w->found && !w->failed; idx++) {
                    char *inc = load(pat, idx, ctx);
                    if (!inc) break;
                    Walk sub;
                    memset(&sub, 0, sizeof(sub));
                    walk_text(inc, load, ctx, depth + 1, &sub);
                    free(inc);
                    if (sub.failed) {
                        w->failed = 1;
                        memcpy(w->err, sub.err, sizeof(w->err));
                    } else if (sub.found) {
                        w->found = 1;
                        w->value = sub.value;
                        w->in_include = 1;
                    }
                }
            }
            continue;
        }

        if (kl == 13 && strncasecmp(text + ks, "X11Forwarding", 13) == 0) {
            if (w->found) continue;
            size_t tl = 0;
            while (vs + tl < ve && !is_ws(text[vs + tl])) tl++;
            int b = parse_bool(text + vs, tl);
            size_t rest = vs + tl;
            while (rest < ve && is_ws(text[rest])) rest++;
            if (b < 0 || (rest < ve && text[rest] != '#')) {
                fail(w, "X11Forwarding is not set to yes or no", lineno);
                return;
            }
            w->found = 1;
            w->value = b;
            if (depth == 0) w->line_end = vs + tl;
        }
    }
}

static void run_walk(const char *text, SshdIncludeLoader load, void *ctx, Walk *w)
{
    memset(w, 0, sizeof(*w));
    walk_text(text, load, ctx, 0, w);
    if (!w->has_match) w->global_end = strlen(text);
}

static void set_err(char *err, size_t errlen, const char *msg)
{
    if (err && errlen) snprintf(err, errlen, "%s", msg);
}

int sshd_x11_effective(const char *text, SshdIncludeLoader load, void *ctx,
                       int *enabled, char *err, size_t errlen)
{
    Walk w;
    run_walk(text, load, ctx, &w);
    if (w.failed) { set_err(err, errlen, w.err); return -1; }
    *enabled = w.found ? w.value : 0;
    return 0;
}

int sshd_x11_edit(const char *text, SshdIncludeLoader load, void *ctx,
                  int enable, char **out, char *err, size_t errlen)
{
    Walk w;
    run_walk(text, load, ctx, &w);
    if (w.failed) { set_err(err, errlen, w.err); return -1; }

    size_t len = strlen(text);
    const char *word = enable ? "yes" : "no";
    size_t wl = strlen(word);
    char *res;

    if (w.found && w.value == enable) {
        res = strdup(text);
        if (!res) { set_err(err, errlen, "out of memory"); return -1; }
        *out = res;
        return 0;
    }

    if (w.found && w.in_include) {
        set_err(err, errlen, "X11Forwarding is decided by an included file that comes first; edit that file by hand");
        return -1;
    }

    if (w.found) {
        /* Replace only the value token so keyword case, spacing and a
         * trailing comment of the line stay as the administrator wrote them. */
        size_t vs = w.line_end;
        while (vs > 0 && !is_ws(text[vs - 1]) && text[vs - 1] != '=') vs--;
        res = malloc(len + wl + 1);
        if (!res) { set_err(err, errlen, "out of memory"); return -1; }
        memcpy(res, text, vs);
        memcpy(res + vs, word, wl);
        strcpy(res + vs + wl, text + w.line_end);
        *out = res;
        return 0;
    }

    /* No directive outside Match blocks: add one before the first Match,
     * since below it the line would only apply to that block. */
    static const char marker[] = "# Set by the Sharing preference pane\n";
    size_t at = w.global_end;
    int need_nl = (at > 0 && text[at - 1] != '\n');
    res = malloc(len + sizeof(marker) + 20 + wl);
    if (!res) { set_err(err, errlen, "out of memory"); return -1; }
    size_t n = at;
    memcpy(res, text, at);
    if (need_nl) res[n++] = '\n';
    memcpy(res + n, marker, sizeof(marker) - 1);
    n += sizeof(marker) - 1;
    n += (size_t)sprintf(res + n, "X11Forwarding %s\n", word);
    strcpy(res + n, text + at);
    *out = res;
    return 0;
}

static char *read_file(const char *path, char *err, size_t errlen)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        snprintf(err, errlen, "cannot read %s: %s", path, strerror(errno));
        return NULL;
    }
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    while (buf) {
        size_t r = fread(buf + n, 1, cap - n - 1, f);
        n += r;
        if (r == 0) break;
        if (cap - n < 2) {
            char *nb = realloc(buf, cap * 2);
            if (!nb) { free(buf); buf = NULL; break; }
            buf = nb;
            cap *= 2;
        }
    }
    int bad = ferror(f);
    fclose(f);
    if (!buf || bad) {
        free(buf);
        snprintf(err, errlen, "cannot read %s", path);
        return NULL;
    }
    buf[n] = '\0';
    if (strlen(buf) != n) {
        free(buf);
        snprintf(err, errlen, "%s contains a NUL byte", path);
        return NULL;
    }
    return buf;
}

char *sshd_x11_glob_loader(const char *pattern, int idx, void *ctx)
{
    char full[2048];
    if (pattern[0] == '/') snprintf(full, sizeof(full), "%s", pattern);
    else snprintf(full, sizeof(full), "%s/%s", (const char *)ctx, pattern);

    glob_t g;
    if (glob(full, 0, NULL, &g) != 0) return NULL;
    char *text = NULL;
    if ((size_t)idx < g.gl_pathc) {
        char e[64];
        text = read_file(g.gl_pathv[idx], e, sizeof(e));
        if (!text) text = strdup("X11Forwarding " UNREADABLE "\n");
    }
    globfree(&g);
    return text;
}

int sshd_x11_read_file(const char *path, int *enabled, char *err, size_t errlen)
{
    char *text = read_file(path, err, errlen);
    if (!text) return -1;
    char *pc = strdup(path);
    int rc = sshd_x11_effective(text, sshd_x11_glob_loader, dirname(pc), enabled, err, errlen);
    free(pc);
    free(text);
    return rc;
}

int sshd_x11_rewrite_file(const char *path, int enable,
                          SshdConfigValidator validate, void *vctx,
                          int *changed, char *err, size_t errlen)
{
    struct stat st;
    if (stat(path, &st) != 0) {
        snprintf(err, errlen, "cannot stat %s: %s", path, strerror(errno));
        return -1;
    }
    char *text = read_file(path, err, errlen);
    if (!text) return -1;

    char *pc = strdup(path);
    char *out = NULL;
    int rc = sshd_x11_edit(text, sshd_x11_glob_loader, dirname(pc), enable, &out, err, errlen);
    free(pc);
    if (rc != 0) { free(text); return -1; }

    *changed = strcmp(text, out) != 0;
    free(text);
    if (!*changed) { free(out); return 0; }

    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.sharing-new", path);
    FILE *f = fopen(tmp, "w");
    if (!f) {
        snprintf(err, errlen, "cannot write %s: %s", tmp, strerror(errno));
        free(out);
        return -1;
    }
    size_t olen = strlen(out);
    int bad = fwrite(out, 1, olen, f) != olen;
    bad |= fflush(f) != 0;
    bad |= fsync(fileno(f)) != 0;
    /* The new file must carry the original owner and mode, else a config the
     * administrator restricted would change its access rights. */
    bad |= fchmod(fileno(f), st.st_mode & 07777) != 0;
    if (geteuid() == 0) bad |= fchown(fileno(f), st.st_uid, st.st_gid) != 0;
    bad |= fclose(f) != 0;
    free(out);
    if (bad) {
        snprintf(err, errlen, "cannot write %s", tmp);
        unlink(tmp);
        return -1;
    }
    if (validate && validate(tmp, vctx) != 0) {
        snprintf(err, errlen, "sshd rejects the new configuration, %s left unchanged", path);
        unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        snprintf(err, errlen, "cannot replace %s: %s", path, strerror(errno));
        unlink(tmp);
        return -1;
    }
    return 0;
}

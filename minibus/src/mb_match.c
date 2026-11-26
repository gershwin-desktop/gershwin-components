/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "mb_int.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static const char *E_INVALID = "org.freedesktop.DBus.Error.MatchRuleInvalid";

void mb_rule_free(mb_rule *r)
{
    free(r->sender); free(r->interface); free(r->member);
    free(r->path); free(r->path_ns); free(r->destination);
    for (int i = 0; i < r->nargs; i++) free(r->args[i].val);
    free(r->args);
    memset(r, 0, sizeof *r);
}

static bool streq(const char *a, const char *b)
{
    if (!a || !b) return a == b;
    return strcmp(a, b) == 0;
}

bool mb_rule_equal(const mb_rule *a, const mb_rule *b)
{
    if (a->type != b->type || a->eavesdrop != b->eavesdrop || a->nargs != b->nargs) return false;
    if (!streq(a->sender, b->sender) || !streq(a->interface, b->interface) ||
        !streq(a->member, b->member) || !streq(a->path, b->path) ||
        !streq(a->path_ns, b->path_ns) || !streq(a->destination, b->destination))
        return false;
    for (int i = 0; i < a->nargs; i++) {
        bool found = false;
        for (int j = 0; j < b->nargs; j++)
            if (a->args[i].idx == b->args[j].idx && a->args[i].kind == b->args[j].kind &&
                strcmp(a->args[i].val, b->args[j].val) == 0) { found = true; break; }
        if (!found) return false;
    }
    return true;
}

/* Valid namespace prefix: dotted elements, not necessarily two of them. */
static bool valid_namespace(const char *s)
{
    size_t n = strlen(s);
    if (n == 0 || n > MB_MAX_NAME) return false;
    bool elem = false;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '.') { if (!elem) return false; elem = false; }
        else if (isalnum(c) || c == '_' || c == '-') elem = true;
        else return false;
    }
    return elem;
}

static bool set_str(char **slot, const char *v, bool ok)
{
    if (*slot || !ok) return false;
    *slot = strdup(v);
    return *slot != NULL;
}

static bool add_arg(mb_rule *r, int idx, int kind, const char *v)
{
    for (int i = 0; i < r->nargs; i++)
        if (r->args[i].idx == idx) return false;
    mb_match_arg *n = realloc(r->args, sizeof *n * (size_t)(r->nargs + 1));
    if (!n) return false;
    r->args = n;
    r->args[r->nargs].idx = idx;
    r->args[r->nargs].kind = kind;
    r->args[r->nargs].val = strdup(v);
    if (!r->args[r->nargs].val) return false;
    r->nargs++;
    return true;
}

static bool apply(mb_rule *r, const char *key, const char *v, bool *seen_type, bool *seen_eav,
                  const char **errmsg)
{
    if (strcmp(key, "type") == 0) {
        if (*seen_type) return false;
        *seen_type = true;
        if (!strcmp(v, "signal")) r->type = MB_SIGNAL;
        else if (!strcmp(v, "method_call")) r->type = MB_METHOD_CALL;
        else if (!strcmp(v, "method_return")) r->type = MB_METHOD_RETURN;
        else if (!strcmp(v, "error")) r->type = MB_ERROR;
        else { *errmsg = "Unknown message type in match rule"; return false; }
        return true;
    }
    if (!strcmp(key, "sender")) return set_str(&r->sender, v, mb_valid_bus_name(v));
    if (!strcmp(key, "interface")) return set_str(&r->interface, v, mb_valid_interface(v));
    if (!strcmp(key, "member")) return set_str(&r->member, v, mb_valid_member(v));
    if (!strcmp(key, "path")) return !r->path_ns && set_str(&r->path, v, mb_valid_object_path(v));
    if (!strcmp(key, "path_namespace")) return !r->path && set_str(&r->path_ns, v, mb_valid_object_path(v));
    if (!strcmp(key, "destination")) return set_str(&r->destination, v, mb_valid_bus_name(v));
    if (!strcmp(key, "eavesdrop")) {
        if (*seen_eav) return false;
        *seen_eav = true;
        if (!strcmp(v, "true")) r->eavesdrop = true;
        else if (!strcmp(v, "false")) r->eavesdrop = false;
        else return false;
        return true;
    }
    if (!strncmp(key, "arg", 3) && isdigit((unsigned char)key[3])) {
        char *end;
        long idx = strtol(key + 3, &end, 10);
        if (idx < 0 || idx > 63) return false;
        if (!*end) return add_arg(r, (int)idx, 0, v);
        if (!strcmp(end, "path")) return add_arg(r, (int)idx, 1, v);
        if (!strcmp(end, "namespace") && idx == 0) return valid_namespace(v) && add_arg(r, 0, 2, v);
    }
    return false;
}

bool mb_rule_parse(const char *text, mb_rule *out, const char **errname, const char **errmsg)
{
    mb_rule r;
    memset(&r, 0, sizeof r);
    bool seen_type = false, seen_eav = false;
    const char *p = text;
    *errname = E_INVALID;
    *errmsg = "Invalid match rule";
    while (*p) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        const char *ks = p;
        while (*p && *p != '=') p++;
        if (*p != '=' || p == ks) goto bad;
        size_t klen = (size_t)(p - ks);
        char key[32];
        if (klen >= sizeof key) goto bad;
        memcpy(key, ks, klen); key[klen] = 0;
        p++;
        /* value: quotes toggle, backslash outside quotes escapes the next char */
        size_t cap = strlen(p) + 1, n = 0;
        char *val = malloc(cap);
        if (!val) goto bad;
        bool quoted = false;
        while (*p) {
            if (quoted) {
                if (*p == '\'') quoted = false; else val[n++] = *p;
                p++;
            } else if (*p == '\'') { quoted = true; p++; }
            else if (*p == '\\') {
                if (!p[1]) { free(val); goto bad; }
                val[n++] = p[1]; p += 2;
            } else if (*p == ',') break;
            else val[n++] = *p++;
        }
        val[n] = 0;
        if (quoted) { free(val); goto bad; }
        bool ok = apply(&r, key, val, &seen_type, &seen_eav, errmsg);
        free(val);
        if (!ok) goto bad;
        /* one comma separates pairs; a trailing one is tolerated like the reference daemon does */
        if (*p == ',') p++;
    }
    *out = r;
    return true;
bad:
    mb_rule_free(&r);
    return false;
}

/* Sender comparison: rules may name the owner of a well-known name. */
static bool sender_matches(const mb_rule *r, const mb_msg *m, const mb_conn *sc)
{
    if (!sc) return m->sender && strcmp(m->sender, r->sender) == 0;
    if (mb_is_unique_name(r->sender)) return strcmp(sc->unique, r->sender) == 0;
    return mb_conn_owns_name(sc, r->sender);
}

bool mb_rule_matches(const mb_rule *r, const mb_msg *m, const mb_conn *sc, const char *recipient)
{
    if (r->type && r->type != m->type) return false;
    if (r->sender && !sender_matches(r, m, sc)) return false;
    if (r->interface && !streq(r->interface, m->interface)) return false;
    if (r->member && !streq(r->member, m->member)) return false;
    if (r->path && !streq(r->path, m->path)) return false;
    if (r->path_ns) {
        if (!m->path) return false;
        size_t n = strlen(r->path_ns);
        if (strcmp(r->path_ns, "/") != 0) {
            if (strncmp(m->path, r->path_ns, n) != 0) return false;
            if (m->path[n] != 0 && m->path[n] != '/') return false;
        }
    }
    (void)recipient;
    if (r->destination && !(m->destination && strcmp(m->destination, r->destination) == 0)) return false;
    for (int i = 0; i < r->nargs; i++) {
        const mb_match_arg *a = &r->args[i];
        char type = 0;
        const char *s = mb_msg_arg_string(m, (unsigned)a->idx, &type);
        if (!s) return false;
        /* argN compares strings; argNpath also object paths; namespaces only strings */
        if (type != 's' && !(a->kind == 1 && type == 'o')) return false;
        if (a->kind == 0) {
            if (strcmp(s, a->val) != 0) return false;
        } else if (a->kind == 1) {
            size_t sl = strlen(s), vl = strlen(a->val);
            bool ok = strcmp(s, a->val) == 0 ||
                      (sl > 0 && sl < vl && s[sl - 1] == '/' && strncmp(a->val, s, sl) == 0) ||
                      (vl > 0 && vl < sl && a->val[vl - 1] == '/' && strncmp(s, a->val, vl) == 0);
            if (!ok) return false;
        } else {
            size_t vl = strlen(a->val);
            if (strncmp(s, a->val, vl) != 0 || (s[vl] != 0 && s[vl] != '.')) return false;
        }
    }
    return true;
}

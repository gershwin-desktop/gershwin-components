/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The methods of org.freedesktop.DBus and the interfaces every peer has. */

#include "mb_int.h"

#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DBUS_NAME "org.freedesktop.DBus"
#define IFACE_PEER "org.freedesktop.DBus.Peer"
#define IFACE_INTRO "org.freedesktop.DBus.Introspectable"
#define IFACE_PROPS "org.freedesktop.DBus.Properties"
#define IFACE_MON "org.freedesktop.DBus.Monitoring"

#define E_FAILED "org.freedesktop.DBus.Error.Failed"
#define E_INVALID_ARGS "org.freedesktop.DBus.Error.InvalidArgs"
#define E_NO_OWNER "org.freedesktop.DBus.Error.NameHasNoOwner"
#define E_LIMITS "org.freedesktop.DBus.Error.LimitsExceeded"

#define MAX_NAMES_PER_CONN 512
#define MAX_RULES_PER_CONN 2048

static const char *introspect_xml =
"<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
" \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
"<node>\n"
"  <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
"    <method name=\"Introspect\"><arg name=\"xml_data\" type=\"s\" direction=\"out\"/></method>\n"
"  </interface>\n"
"  <interface name=\"org.freedesktop.DBus.Peer\">\n"
"    <method name=\"Ping\"></method>\n"
"    <method name=\"GetMachineId\"><arg name=\"machine_uuid\" type=\"s\" direction=\"out\"/></method>\n"
"  </interface>\n"
"  <interface name=\"org.freedesktop.DBus.Properties\">\n"
"    <method name=\"Get\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"out\"/></method>\n"
"    <method name=\"GetAll\"><arg type=\"s\" direction=\"in\"/><arg type=\"a{sv}\" direction=\"out\"/></method>\n"
"    <method name=\"Set\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/><arg type=\"v\" direction=\"in\"/></method>\n"
"    <signal name=\"PropertiesChanged\"><arg type=\"s\"/><arg type=\"a{sv}\"/><arg type=\"as\"/></signal>\n"
"  </interface>\n"
"  <interface name=\"org.freedesktop.DBus\">\n"
"    <method name=\"Hello\"><arg direction=\"out\" type=\"s\"/></method>\n"
"    <method name=\"RequestName\"><arg direction=\"in\" type=\"s\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"u\"/></method>\n"
"    <method name=\"ReleaseName\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"u\"/></method>\n"
"    <method name=\"StartServiceByName\"><arg direction=\"in\" type=\"s\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"u\"/></method>\n"
"    <method name=\"UpdateActivationEnvironment\"><arg direction=\"in\" type=\"a{ss}\"/></method>\n"
"    <method name=\"NameHasOwner\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"b\"/></method>\n"
"    <method name=\"ListNames\"><arg direction=\"out\" type=\"as\"/></method>\n"
"    <method name=\"ListActivatableNames\"><arg direction=\"out\" type=\"as\"/></method>\n"
"    <method name=\"AddMatch\"><arg direction=\"in\" type=\"s\"/></method>\n"
"    <method name=\"RemoveMatch\"><arg direction=\"in\" type=\"s\"/></method>\n"
"    <method name=\"GetNameOwner\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"s\"/></method>\n"
"    <method name=\"ListQueuedOwners\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"as\"/></method>\n"
"    <method name=\"GetConnectionUnixUser\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"u\"/></method>\n"
"    <method name=\"GetConnectionUnixProcessID\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"u\"/></method>\n"
"    <method name=\"GetAdtAuditSessionData\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"ay\"/></method>\n"
"    <method name=\"GetConnectionSELinuxSecurityContext\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"ay\"/></method>\n"
"    <method name=\"GetConnectionCredentials\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"a{sv}\"/></method>\n"
"    <method name=\"ReloadConfig\"></method>\n"
"    <method name=\"GetId\"><arg direction=\"out\" type=\"s\"/></method>\n"
"    <property name=\"Features\" type=\"as\" access=\"read\"/>\n"
"    <property name=\"Interfaces\" type=\"as\" access=\"read\"/>\n"
"    <signal name=\"NameOwnerChanged\"><arg type=\"s\"/><arg type=\"s\"/><arg type=\"s\"/></signal>\n"
"    <signal name=\"NameLost\"><arg type=\"s\"/></signal>\n"
"    <signal name=\"NameAcquired\"><arg type=\"s\"/></signal>\n"
"  </interface>\n"
"  <interface name=\"org.freedesktop.DBus.Monitoring\">\n"
"    <method name=\"BecomeMonitor\"><arg type=\"as\" direction=\"in\"/><arg type=\"u\" direction=\"in\"/></method>\n"
"  </interface>\n"
"</node>\n";

/* -------------------------------------------------------------- helpers */

static void write_string_array(mb_w *w, const char *const *items, int n);

static void reply(mb_bus *b, mb_msg *call, const char *sig, mb_w *w)
{
    if (call->flags & MB_FLAG_NO_REPLY) return;
    mb_msg_spec s;
    memset(&s, 0, sizeof s);
    s.big = call->big;
    s.type = MB_METHOD_RETURN;
    s.flags = MB_FLAG_NO_REPLY;
    s.serial = mb_bus_next_serial();
    s.reply_serial = call->serial;
    s.has_reply_serial = true;
    s.destination = call->sender;
    s.sender = DBUS_NAME;
    s.signature = sig;
    if (w) { s.body = w->b.p; s.body_len = w->b.len; }
    mb_msg *m = mb_msg_build(&s);
    if (!m) return;
    mb_bus_route(b, m, NULL);
    mb_msg_unref(m);
}

static bool sig_is(const mb_msg *m, const char *want)
{
    return strcmp(m->signature ? m->signature : "", want) == 0;
}

static bool need_sig(mb_bus *b, mb_msg *m, const char *want)
{
    if (sig_is(m, want)) return true;
    mb_bus_send_error(b, m, E_INVALID_ARGS,
                      "Type of message, '%s', does not match expected type '%s'",
                      m->signature ? m->signature : "", want);
    return false;
}

static void reply_u32(mb_bus *b, mb_msg *m, uint32_t v)
{
    mb_w w;
    mb_w_init(&w, m->big);
    mb_w_u32(&w, v);
    reply(b, m, "u", &w);
    mb_w_free(&w);
}

static void reply_str(mb_bus *b, mb_msg *m, const char *s)
{
    mb_w w;
    mb_w_init(&w, m->big);
    mb_w_str(&w, s);
    reply(b, m, "s", &w);
    mb_w_free(&w);
}

static const char *first_string(mb_msg *m)
{
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    return mb_r_str(&r);
}

/* Resolve a name argument to a connection; NULL when the name has no owner.
 * *is_bus is set for the bus's own name. */
static mb_conn *resolve(mb_bus *b, const char *name, bool *is_bus)
{
    *is_bus = strcmp(name, DBUS_NAME) == 0;
    if (*is_bus) return NULL;
    mb_conn *c = mb_is_unique_name(name) ? mb_bus_find_unique(b, name) : mb_bus_find_owner(b, name);
    return c && c->state == MBC_ACTIVE ? c : NULL;
}

bool mb_read_machine_id(char out[33])
{
    static const char *paths[] = { "/etc/machine-id", "/var/lib/dbus/machine-id",
                                   "/var/db/dbus/machine-id", NULL };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        char buf[64] = {0};
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        if (n < 32) continue;
        bool ok = true;
        for (int k = 0; k < 32; k++)
            if (!((buf[k] >= '0' && buf[k] <= '9') || (buf[k] >= 'a' && buf[k] <= 'f'))) ok = false;
        if (!ok) continue;
        memcpy(out, buf, 32);
        out[32] = 0;
        return true;
    }
    return false;
}

/* ----------------------------------------------------------- permissions */

static bool uid_in_group(uint32_t uid, gid_t gid)
{
    struct passwd *pw = getpwuid((uid_t)uid);
    if (!pw) return false;
    if (pw->pw_gid == gid) return true;
    struct group *gr = getgrgid(gid);
    if (!gr) return false;
    for (char **m = gr->gr_mem; *m; m++)
        if (strcmp(*m, pw->pw_name) == 0) return true;
    return false;
}

bool mb_may_own_names(mb_bus *b, const mb_conn *c)
{
    if (!b->system) return true;
    if (!c->have_uid) return false;
    if (c->uid == 0 || c->uid <= b->sys_uid_max) return true;
    return b->have_owner_gid && uid_in_group(c->uid, b->owner_gid);
}

bool mb_may_monitor(mb_bus *b, const mb_conn *c)
{
    return c->have_uid && (c->uid == 0 || c->uid == b->my_uid);
}

/* --------------------------------------------------------------- methods */

static void m_request_name(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (!need_sig(b, m, "su")) return;
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    const char *name = mb_r_str(&r);
    uint32_t flags = mb_r_u32(&r);
    if (name[0] == ':') {
        mb_bus_send_error(b, m, E_INVALID_ARGS,
                          "Cannot acquire a service starting with ':' such as \"%s\"", name);
        return;
    }
    if (strcmp(name, DBUS_NAME) == 0) {
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.AccessDenied",
                          "Connection \"%s\" is not allowed to own the service \"%s\"",
                          c->unique, name);
        return;
    }
    if (!mb_valid_well_known_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    if (!mb_may_own_names(b, c)) {
        mb_log(0, "uid %u (%s) may not own %s on the system bus", c->uid, c->unique, name);
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.AccessDenied",
                          "Connection \"%s\" is not allowed to own the service \"%s\"", c->unique, name);
        return;
    }
    if (c->nnames >= MAX_NAMES_PER_CONN && !mb_conn_owns_name(c, name)) {
        mb_bus_send_error(b, m, E_LIMITS, "Connection \"%s\" is not allowed to own more services", c->unique);
        return;
    }
    unsigned rc = mb_bus_request_name(b, c, name, flags);
    if (!rc) { mb_bus_send_error(b, m, E_FAILED, "Out of memory"); return; }
    reply_u32(b, m, rc);
}

static void m_release_name(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    if (name[0] == ':') {
        mb_bus_send_error(b, m, E_INVALID_ARGS,
                          "Cannot release a service starting with ':' such as \"%s\"", name);
        return;
    }
    if (strcmp(name, DBUS_NAME) == 0) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Cannot release the %s service because it is owned by the bus", name);
        return;
    }
    if (!mb_valid_well_known_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Given bus name \"%s\" is not valid", name);
        return;
    }
    reply_u32(b, m, mb_bus_release_name(b, c, name));
}

static void m_list_queued_owners(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    if (!mb_valid_well_known_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    if (strcmp(name, DBUS_NAME) == 0) {
        const char *self[] = { DBUS_NAME };
        mb_w w;
        mb_w_init(&w, m->big);
        write_string_array(&w, self, 1);
        reply(b, m, "as", &w);
        mb_w_free(&w);
        return;
    }
    mb_name *n = mb_bus_find_name(b, name);
    if (!n || !n->nowners) {
        mb_bus_send_error(b, m, E_NO_OWNER, "Could not get owners of name '%s': no such name", name);
        return;
    }
    mb_w w;
    mb_w_init(&w, m->big);
    size_t t = mb_w_array_begin(&w, 4);
    for (int i = 0; i < n->nowners; i++) mb_w_str(&w, n->owners[i].conn->unique);
    mb_w_array_end(&w, t, 4);
    reply(b, m, "as", &w);
    mb_w_free(&w);
}

static void m_list_names(mb_bus *b, mb_msg *m)
{
    mb_w w;
    mb_w_init(&w, m->big);
    size_t t = mb_w_array_begin(&w, 4);
    mb_w_str(&w, DBUS_NAME);
    for (int i = 0; i < b->nconns; i++)
        if (b->conns[i]->state == MBC_ACTIVE) mb_w_str(&w, b->conns[i]->unique);
    for (int h = 0; h < MB_NAME_BUCKETS; h++)
        for (mb_name *n = b->names[h]; n; n = n->hnext)
            if (n->nowners) mb_w_str(&w, n->name);
    mb_w_array_end(&w, t, 4);
    reply(b, m, "as", &w);
    mb_w_free(&w);
}

static void m_list_activatable(mb_bus *b, mb_msg *m)
{
    mb_w w;
    mb_w_init(&w, m->big);
    size_t t = mb_w_array_begin(&w, 4);
    mb_w_str(&w, DBUS_NAME);
    mb_w_array_end(&w, t, 4);
    reply(b, m, "as", &w);
    mb_w_free(&w);
}

static void m_name_has_owner(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    bool is_bus = false;
    bool has = mb_valid_bus_name(name) && (resolve(b, name, &is_bus) != NULL || is_bus);
    mb_w w;
    mb_w_init(&w, m->big);
    mb_w_bool(&w, has);
    reply(b, m, "b", &w);
    mb_w_free(&w);
}

static void m_start_service(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "su")) return;
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    const char *name = mb_r_str(&r);
    if (!mb_valid_bus_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    /* without activation nothing is startable, owned or not (as the reference daemon
     * answers for names that have no service file) */
    mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.ServiceUnknown",
                      "The name %s was not provided by any .service files", name);
}

static void m_get_name_owner(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    if (!mb_valid_bus_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    bool is_bus;
    mb_conn *c = resolve(b, name, &is_bus);
    if (is_bus) { reply_str(b, m, DBUS_NAME); return; }
    if (!c) {
        mb_bus_send_error(b, m, E_NO_OWNER, "Could not get owner of name '%s': no such name", name);
        return;
    }
    reply_str(b, m, c->unique);
}

enum { Q_UID, Q_PID };

static void m_unix_id(mb_bus *b, mb_msg *m, int which)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    if (!mb_valid_bus_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    bool is_bus;
    mb_conn *c = resolve(b, name, &is_bus);
    if (is_bus) { reply_u32(b, m, which == Q_UID ? b->my_uid : b->my_pid); return; }
    if (!c) {
        mb_bus_send_error(b, m, E_NO_OWNER, "Could not get %s of name '%s': no such name",
                          which == Q_UID ? "UID" : "PID", name);
        return;
    }
    if (which == Q_UID ? !c->have_uid : !c->have_pid) {
        mb_bus_send_error(b, m, E_FAILED, which == Q_UID ? "Unix user ID is not available"
                                                         : "UNIX process ID is not available");
        return;
    }
    reply_u32(b, m, which == Q_UID ? c->uid : c->pid);
}

static void m_credentials(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    if (!mb_valid_bus_name(name)) {
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Requested bus name \"%s\" is not valid", name);
        return;
    }
    bool is_bus;
    mb_conn *c = resolve(b, name, &is_bus);
    if (!c && !is_bus) {
        mb_bus_send_error(b, m, E_NO_OWNER, "Could not get credentials of name '%s': no such name", name);
        return;
    }
    mb_w w;
    mb_w_init(&w, m->big);
    size_t t = mb_w_array_begin(&w, 8);
    bool have_uid = is_bus || c->have_uid, have_pid = is_bus || c->have_pid;
    if (have_pid) {
        mb_w_align(&w, 8);
        mb_w_str(&w, "ProcessID"); mb_w_sig(&w, "u"); mb_w_u32(&w, is_bus ? b->my_pid : c->pid);
    }
    if (have_uid) {
        mb_w_align(&w, 8);
        mb_w_str(&w, "UnixUserID"); mb_w_sig(&w, "u"); mb_w_u32(&w, is_bus ? b->my_uid : c->uid);
    }
    mb_w_array_end(&w, t, 8);
    reply(b, m, "a{sv}", &w);
    mb_w_free(&w);
}

static void m_add_match(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *text = first_string(m);
    mb_rule rule;
    const char *en, *em;
    if (!mb_rule_parse(text, &rule, &en, &em)) { mb_bus_send_error(b, m, en, "%s", em); return; }
    if (c->nrules >= MAX_RULES_PER_CONN) {
        mb_rule_free(&rule);
        mb_bus_send_error(b, m, E_LIMITS, "Maximum number of match rules (%d) for this connection exceeded", MAX_RULES_PER_CONN);
        return;
    }
    if (c->nrules == c->caprules) {
        int ncap = c->caprules ? c->caprules * 2 : 8;
        mb_rule *p = realloc(c->rules, sizeof *p * (size_t)ncap);
        if (!p) { mb_rule_free(&rule); mb_bus_send_error(b, m, E_FAILED, "Out of memory"); return; }
        c->rules = p; c->caprules = ncap;
    }
    c->rules[c->nrules++] = rule;
    reply(b, m, "", NULL);
}

static void m_remove_match(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (!need_sig(b, m, "s")) return;
    const char *text = first_string(m);
    mb_rule rule;
    const char *en, *em;
    if (!mb_rule_parse(text, &rule, &en, &em)) { mb_bus_send_error(b, m, en, "%s", em); return; }
    for (int i = c->nrules - 1; i >= 0; i--) {
        if (mb_rule_equal(&c->rules[i], &rule)) {
            mb_rule_free(&c->rules[i]);
            memmove(&c->rules[i], &c->rules[i + 1], sizeof(mb_rule) * (size_t)(c->nrules - i - 1));
            c->nrules--;
            mb_rule_free(&rule);
            reply(b, m, "", NULL);
            return;
        }
    }
    mb_rule_free(&rule);
    mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.MatchRuleNotFound",
                      "The given match rule wasn't found and can't be removed");
}

/* minibus keeps no audit or security label data */
static void m_no_security_data(mb_bus *b, mb_msg *m, const char *errname)
{
    if (!need_sig(b, m, "s")) return;
    const char *name = first_string(m);
    bool is_bus;
    if (!mb_valid_bus_name(name) || (!resolve(b, name, &is_bus) && !is_bus)) {
        mb_bus_send_error(b, m, E_NO_OWNER, "Could not get data of name '%s': no such name", name);
        return;
    }
    mb_bus_send_error(b, m, errname, "This information is not available");
}

static void m_get_id(mb_bus *b, mb_msg *m)
{
    reply_str(b, m, mb_bus_id(b));
}

static void m_update_env(mb_bus *b, mb_msg *m)
{
    if (!need_sig(b, m, "a{ss}")) return;
    reply(b, m, "", NULL);
}

static void m_become_monitor(mb_bus *b, mb_conn *c, mb_msg *m)
{
    if (!need_sig(b, m, "asu")) return;
    mb_r r;
    mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
    uint32_t n = mb_r_u32(&r);
    size_t start = r.pos, stop = start + n;
    mb_rule *rules = NULL;
    int nr = 0;
    while (r.pos < stop) {
        const char *s = mb_r_str(&r);
        const char *en, *em;
        mb_rule one;
        if (!mb_rule_parse(s, &one, &en, &em)) {
            for (int i = 0; i < nr; i++) mb_rule_free(&rules[i]);
            free(rules);
            mb_bus_send_error(b, m, en, "%s", em);
            return;
        }
        mb_rule *p = realloc(rules, sizeof *p * (size_t)(nr + 1));
        if (!p) { mb_rule_free(&one); break; }
        rules = p;
        rules[nr++] = one;
    }
    uint32_t flags = mb_r_u32(&r);
    if (flags != 0) {
        for (int i = 0; i < nr; i++) mb_rule_free(&rules[i]);
        free(rules);
        mb_bus_send_error(b, m, E_INVALID_ARGS, "Flags must be 0, but got %u", flags);
        return;
    }
    if (!mb_may_monitor(b, c)) {
        for (int i = 0; i < nr; i++) mb_rule_free(&rules[i]);
        free(rules);
        mb_log(0, "uid %u (%s) may not become a monitor", c->uid, c->unique);
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.AccessDenied",
                          "Only root or the owner of the bus may become a monitor");
        return;
    }
    /* A monitor owns nothing and listens to nothing but what it asked for. */
    mb_log(0, "%s (uid %u) became a monitor", c->unique, c->uid);
    reply(b, m, "", NULL);
    mb_bus_release_all_names(b, c);
    mb_bus_drop_rules(c);
    free(c->rules);
    c->rules = rules;
    c->nrules = nr;
    c->caprules = nr;
    /* a monitor gives up its unique name, as with the reference daemon */
    mb_bus_monitor_lost_name(b, c);
    c->state = MBC_MONITOR;
}

/* ------------------------------------------------------------ properties */

static void write_string_array(mb_w *w, const char *const *items, int n)
{
    size_t t = mb_w_array_begin(w, 4);
    for (int i = 0; i < n; i++) mb_w_str(w, items[i]);
    mb_w_array_end(w, t, 4);
}

static const char *const interfaces_prop[] = { IFACE_MON };

static void property_value(mb_w *w, const char *name)
{
    mb_w_sig(w, "as");
    if (strcmp(name, "Features") == 0) write_string_array(w, NULL, 0);
    else write_string_array(w, interfaces_prop, 1);
}

static void m_properties(mb_bus *b, mb_msg *m)
{
    const char *member = m->member;
    if (strcmp(member, "Get") == 0) {
        if (!need_sig(b, m, "ss")) return;
        mb_r r;
        mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
        const char *iface = mb_r_str(&r), *prop = mb_r_str(&r);
        if (strcmp(iface, DBUS_NAME) != 0) {
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownInterface",
                              "No such interface '%s'", iface);
            return;
        }
        if (strcmp(prop, "Features") && strcmp(prop, "Interfaces")) {
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownProperty",
                              "No such property '%s'", prop);
            return;
        }
        mb_w w;
        mb_w_init(&w, m->big);
        property_value(&w, prop);
        reply(b, m, "v", &w);
        mb_w_free(&w);
    } else if (strcmp(member, "GetAll") == 0) {
        if (!need_sig(b, m, "s")) return;
        const char *iface = first_string(m);
        if (strcmp(iface, IFACE_MON) == 0) {
            mb_w w;
            mb_w_init(&w, m->big);
            size_t t = mb_w_array_begin(&w, 8);
            mb_w_array_end(&w, t, 8);
            reply(b, m, "a{sv}", &w);
            mb_w_free(&w);
            return;
        }
        if (strcmp(iface, DBUS_NAME) != 0) {
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownInterface",
                              "No such interface '%s'", iface);
            return;
        }
        mb_w w;
        mb_w_init(&w, m->big);
        size_t t = mb_w_array_begin(&w, 8);
        mb_w_align(&w, 8); mb_w_str(&w, "Features"); property_value(&w, "Features");
        mb_w_align(&w, 8); mb_w_str(&w, "Interfaces"); property_value(&w, "Interfaces");
        mb_w_array_end(&w, t, 8);
        reply(b, m, "a{sv}", &w);
        mb_w_free(&w);
    } else if (strcmp(member, "Set") == 0) {
        if (!need_sig(b, m, "ssv")) return;
        mb_r r;
        mb_r_init(&r, m->data + m->body_off, m->body_len, m->big);
        const char *iface = mb_r_str(&r), *prop = mb_r_str(&r);
        if (strcmp(iface, DBUS_NAME) != 0)
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownInterface", "No such interface '%s'", iface);
        else if (strcmp(prop, "Features") && strcmp(prop, "Interfaces"))
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownProperty", "No such property '%s'", prop);
        else
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.PropertyReadOnly",
                              "Property '%s' of interface '%s' is not settable", prop, iface);
    } else {
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownMethod",
                          "No such method '%s' on interface " IFACE_PROPS, member);
    }
}

/* -------------------------------------------------------------- dispatch */

void mb_driver_handle(mb_bus *b, mb_conn *c, mb_msg *m)
{
    const char *iface = m->interface, *mem = m->member;

    bool peer_member = !strcmp(mem, "Ping") || !strcmp(mem, "GetMachineId");
    if ((iface && strcmp(iface, IFACE_PEER) == 0) || (!iface && peer_member)) {
        if (strcmp(mem, "Ping") == 0) {
            if (need_sig(b, m, "")) reply(b, m, "", NULL);
        } else if (strcmp(mem, "GetMachineId") == 0) {
            char id[33];
            if (!need_sig(b, m, "")) return;
            if (!mb_read_machine_id(id)) {
                mb_bus_send_error(b, m, E_FAILED, "Machine ID is not available");
                return;
            }
            reply_str(b, m, id);
        } else {
            mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownMethod",
                              "No such method '%s' on interface " IFACE_PEER, mem);
        }
        return;
    }
    if (iface && strcmp(iface, IFACE_INTRO) == 0) {
        if (strcmp(mem, "Introspect") == 0) { if (need_sig(b, m, "")) reply_str(b, m, introspect_xml); }
        else mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownMethod",
                               "No such method '%s' on interface " IFACE_INTRO, mem);
        return;
    }
    if (iface && strcmp(iface, IFACE_PROPS) == 0) { m_properties(b, m); return; }
    if (iface && strcmp(iface, IFACE_MON) == 0) {
        if (strcmp(mem, "BecomeMonitor") == 0) m_become_monitor(b, c, m);
        else mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownMethod",
                               "No such method '%s' on interface " IFACE_MON, mem);
        return;
    }
    if (iface && strcmp(iface, DBUS_NAME) != 0) {
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownInterface",
                          "No such interface '%s'", iface);
        return;
    }

    if (!strcmp(mem, "Hello")) { if (need_sig(b, m, "")) mb_bus_send_error(b, m, E_FAILED, "Already handled an Hello message"); }
    else if (!strcmp(mem, "RequestName")) m_request_name(b, c, m);
    else if (!strcmp(mem, "ReleaseName")) m_release_name(b, c, m);
    else if (!strcmp(mem, "ListQueuedOwners")) m_list_queued_owners(b, m);
    else if (!strcmp(mem, "ListNames")) { if (need_sig(b, m, "")) m_list_names(b, m); }
    else if (!strcmp(mem, "ListActivatableNames")) { if (need_sig(b, m, "")) m_list_activatable(b, m); }
    else if (!strcmp(mem, "NameHasOwner")) m_name_has_owner(b, m);
    else if (!strcmp(mem, "StartServiceByName")) m_start_service(b, m);
    else if (!strcmp(mem, "UpdateActivationEnvironment")) m_update_env(b, m);
    else if (!strcmp(mem, "GetNameOwner")) m_get_name_owner(b, m);
    else if (!strcmp(mem, "GetConnectionUnixUser")) m_unix_id(b, m, Q_UID);
    else if (!strcmp(mem, "GetConnectionUnixProcessID")) m_unix_id(b, m, Q_PID);
    else if (!strcmp(mem, "GetConnectionCredentials")) m_credentials(b, m);
    else if (!strcmp(mem, "GetAdtAuditSessionData")) m_no_security_data(b, m, "org.freedesktop.DBus.Error.AdtAuditDataUnknown");
    else if (!strcmp(mem, "GetConnectionSELinuxSecurityContext")) m_no_security_data(b, m, "org.freedesktop.DBus.Error.SELinuxSecurityContextUnknown");
    else if (!strcmp(mem, "AddMatch")) m_add_match(b, c, m);
    else if (!strcmp(mem, "RemoveMatch")) m_remove_match(b, c, m);
    else if (!strcmp(mem, "GetId")) { if (need_sig(b, m, "")) m_get_id(b, m); }
    else if (!strcmp(mem, "ReloadConfig")) { if (need_sig(b, m, "")) reply(b, m, "", NULL); }
    else if (!strcmp(mem, "BecomeMonitor")) m_become_monitor(b, c, m);
    else {
        mb_bus_send_error(b, m, "org.freedesktop.DBus.Error.UnknownMethod",
                          "Unknown method '%s' on interface " DBUS_NAME, mem);
    }
}

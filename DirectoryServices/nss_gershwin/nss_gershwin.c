/*
 * nss_gershwin - NSS module for Gershwin Directory Services
 *
 * The `gershwin` source for the passwd and group databases in
 * nsswitch.conf(5) (and shadow on Linux). It resolves users and groups
 * straight from the DirectoryServices plists, with no daemon and no
 * socket:
 *
 *   /Network/Library/DirectoryServices/{Users,Groups}.plist when present,
 *   /Local/Library/DirectoryServices/{Users,Groups}.plist otherwise.
 *
 * The choice is made on every lookup, so joining or leaving a directory
 * server (mounting or unmounting /Network) switches sources at once. A
 * missing or unparsable plist makes this source unavailable, and the next
 * source in nsswitch.conf answers, so local accounts keep working.
 *
 * The module used to ask dshelper over /var/run/dshelper.sock, which
 * made every lookup, sudo included, depend on that daemon staying up.
 * The rules dshelper applied are kept: the password hash goes only to
 * root, the home is /Network/Users/<name> on a client and
 * /Local/Users/<name> otherwise, members of admin get wheel (and sudo
 * where the system has it), and every directory user gets the
 * hardware-access groups the system defines.
 *
 * The plist reader and the database (plist.c, dsdb.c) are adapted from
 * NextBSD's nss_directory_services (nextbsd/nextbsd-userland), which
 * reads the same files; this file is the nsswitch glue for FreeBSD's
 * ns_mtab interface and glibc's _nss_* interface.
 *
 * Install to: /System/Library/Libraries/nss_gershwin.so.1 (FreeBSD)
 *             /System/Library/Libraries/libnss_gershwin.so.2 (Linux)
 */

#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <sys/types.h>
#include <errno.h>
#include <grp.h>
#include <pthread.h>
#include <pwd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "dsdb.h"

/* Only FreeBSD and glibc have an interface this module plugs into. */
#if defined(__linux__) || defined(__FreeBSD__)

static size_t pw_cursor;
static size_t gr_cursor;

/*
 * After fork(2) the single-threaded child must not inherit the database
 * lock held by another thread.
 */
static pthread_once_t atfork_once = PTHREAD_ONCE_INIT;

static void
install_atfork(void)
{
    (void)pthread_atfork(dsdb_lock, dsdb_unlock, dsdb_atfork_child);
}

/*
 * Lookup results shared by both interfaces. Each returns one of these and
 * leaves an errno value in *err for DS_ERANGE.
 */
enum ds_result {
    DS_SUCCESS,
    DS_NOTFOUND,
    DS_UNAVAIL,
    DS_ERANGE
};

enum lookup {
    LT_NAME,
    LT_ID,
    LT_ALL
};

static enum ds_result
lookup_passwd(enum lookup how, const char *name, uid_t uid,
              struct passwd *pwd, char *buffer, size_t buflen, int *err)
{
    const struct ds_user *u;
    int rv;

    (void)pthread_once(&atfork_once, install_atfork);
    dsdb_lock();
    if (dsdb_refresh_users() != DSDB_OK) {
        dsdb_unlock();
        return DS_UNAVAIL;
    }
    switch (how) {
    case LT_NAME:
        u = dsdb_user_by_name(name);
        break;
    case LT_ID:
        u = dsdb_user_by_uid(uid);
        break;
    default:
        u = dsdb_user_at(pw_cursor);
        if (u != NULL)
            pw_cursor++;
        break;
    }
    if (u == NULL) {
        dsdb_unlock();
        return DS_NOTFOUND;
    }
    rv = dsdb_pack_passwd(u, geteuid() == 0, dsdb_users_from_network(),
                          pwd, buffer, buflen);
    if (rv != 0 && how == LT_ALL)
        pw_cursor--;            /* let the retry see this record */
    dsdb_unlock();
    if (rv != 0) {
        *err = rv;
        return DS_ERANGE;
    }
    return DS_SUCCESS;
}

static enum ds_result
lookup_group(enum lookup how, const char *name, gid_t gid,
             struct group *grp, char *buffer, size_t buflen, int *err)
{
    const struct ds_group *g;
    int rv;

    (void)pthread_once(&atfork_once, install_atfork);
    dsdb_lock();
    if (dsdb_refresh_groups() != DSDB_OK) {
        dsdb_unlock();
        return DS_UNAVAIL;
    }
    if (how != LT_ALL) {
        /* wheel and sudo come from /etc/group, with the admins added. */
        rv = dsdb_pack_admin_group(how == LT_NAME ? name : NULL, gid,
                                   DS_ETC_GROUP, grp, buffer, buflen);
        if (rv != ENOENT) {
            dsdb_unlock();
            if (rv != 0) {
                *err = rv;
                return DS_ERANGE;
            }
            return DS_SUCCESS;
        }
    }
    switch (how) {
    case LT_NAME:
        g = dsdb_group_by_name(name);
        break;
    case LT_ID:
        g = dsdb_group_by_gid(gid);
        break;
    default:
        g = dsdb_group_at(gr_cursor);
        if (g != NULL)
            gr_cursor++;
        break;
    }
    if (g == NULL) {
        dsdb_unlock();
        return DS_NOTFOUND;
    }
    rv = dsdb_pack_group(g, grp, buffer, buflen);
    if (rv != 0 && how == LT_ALL)
        gr_cursor--;
    dsdb_unlock();
    if (rv != 0) {
        *err = rv;
        return DS_ERANGE;
    }
    return DS_SUCCESS;
}

static void
rewind_cursor(size_t *cursor)
{
    dsdb_lock();
    *cursor = 0;
    dsdb_unlock();
}

/*
 * The full group set for a directory user, malloc'd. -1 with DS_UNAVAIL
 * semantics when the users plist cannot be read, -2 when the user is not
 * a directory user.
 */
static int
user_groupset(const char *user, gid_t agroup, gid_t **list, int *count)
{
    int rv;

    (void)pthread_once(&atfork_once, install_atfork);
    dsdb_lock();
    if (dsdb_refresh_users() != DSDB_OK) {
        dsdb_unlock();
        return -1;
    }
    /* Without a readable Groups.plist the user still has a primary gid. */
    (void)dsdb_refresh_groups();
    rv = dsdb_groupset(user, agroup, DS_ETC_GROUP, list, count);
    dsdb_unlock();
    return rv == 0 ? 0 : -2;
}

#endif /* __linux__ || __FreeBSD__ */

#ifdef __linux__
/*
 * glibc interface: _nss_gershwin_* functions, dlopen'ed from
 * libnss_gershwin.so.2.
 */
#include <nss.h>
#include <shadow.h>

static enum nss_status
nss_status_of(enum ds_result r, int err, int *errnop)
{
    switch (r) {
    case DS_SUCCESS:
        return NSS_STATUS_SUCCESS;
    case DS_NOTFOUND:
        return NSS_STATUS_NOTFOUND;
    case DS_UNAVAIL:
        return NSS_STATUS_UNAVAIL;
    default:
        *errnop = err;
        return NSS_STATUS_TRYAGAIN;
    }
}

enum nss_status
_nss_gershwin_getpwnam_r(const char *name, struct passwd *pwd,
                         char *buffer, size_t buflen, int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_passwd(LT_NAME, name, 0, pwd, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_getpwuid_r(uid_t uid, struct passwd *pwd,
                         char *buffer, size_t buflen, int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_passwd(LT_ID, NULL, uid, pwd, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_getpwent_r(struct passwd *pwd, char *buffer, size_t buflen,
                         int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_passwd(LT_ALL, NULL, 0, pwd, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_setpwent(int stayopen __attribute__((unused)))
{
    rewind_cursor(&pw_cursor);
    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_endpwent(void)
{
    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_getgrnam_r(const char *name, struct group *grp,
                         char *buffer, size_t buflen, int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_group(LT_NAME, name, 0, grp, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_getgrgid_r(gid_t gid, struct group *grp,
                         char *buffer, size_t buflen, int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_group(LT_ID, NULL, gid, grp, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_getgrent_r(struct group *grp, char *buffer, size_t buflen,
                         int *errnop)
{
    int err = 0;
    enum ds_result r = lookup_group(LT_ALL, NULL, 0, grp, buffer, buflen, &err);
    return nss_status_of(r, err, errnop);
}

enum nss_status
_nss_gershwin_setgrent(int stayopen __attribute__((unused)))
{
    rewind_cursor(&gr_cursor);
    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_endgrent(void)
{
    return NSS_STATUS_SUCCESS;
}

/*
 * Shadow lookup, for a `shadow: gershwin files` line. Only root sees the
 * hash, as with /etc/shadow; anyone else gets "*".
 */
enum nss_status
_nss_gershwin_getspnam_r(const char *name, struct spwd *spw,
                         char *buffer, size_t buflen, int *errnop)
{
    const struct ds_user *u;
    const char *hash;
    size_t nlen, hlen;

    (void)pthread_once(&atfork_once, install_atfork);
    dsdb_lock();
    if (dsdb_refresh_users() != DSDB_OK) {
        dsdb_unlock();
        return NSS_STATUS_UNAVAIL;
    }
    u = dsdb_user_by_name(name);
    if (u == NULL) {
        dsdb_unlock();
        return NSS_STATUS_NOTFOUND;
    }
    hash = dsdb_password_field(u, geteuid() == 0);
    nlen = strlen(u->name) + 1;
    hlen = strlen(hash) + 1;
    if (nlen + hlen > buflen) {
        dsdb_unlock();
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }
    memset(spw, 0, sizeof(*spw));
    memcpy(buffer, u->name, nlen);
    memcpy(buffer + nlen, hash, hlen);
    dsdb_unlock();
    spw->sp_namp = buffer;
    spw->sp_pwdp = buffer + nlen;
    spw->sp_lstchg = -1;    /* last changed: unknown */
    spw->sp_min = -1;       /* no minimum age */
    spw->sp_max = -1;       /* never expires */
    spw->sp_warn = -1;
    spw->sp_inact = -1;
    spw->sp_expire = -1;
    spw->sp_flag = ~0UL;
    return NSS_STATUS_SUCCESS;
}

/*
 * initgroups(3) and getgrouplist(3): append the user's groups other than
 * `group` (already in the list) to *groupsp, growing it up to `limit`
 * (no limit when limit <= 0).
 */
enum nss_status
_nss_gershwin_initgroups_dyn(const char *user, gid_t group, long int *start,
                             long int *size, gid_t **groupsp, long int limit,
                             int *errnop)
{
    gid_t *list, *groups = *groupsp;
    int count, i, rv;
    long int j, newsize;

    rv = user_groupset(user, group, &list, &count);
    if (rv == -1)
        return NSS_STATUS_UNAVAIL;
    if (rv != 0)
        return NSS_STATUS_NOTFOUND;

    for (i = 0; i < count; i++) {
        if (list[i] == group)
            continue;
        for (j = 0; j < *start; j++)
            if (groups[j] == list[i])
                break;
        if (j < *start)
            continue;
        if (*start == *size) {
            if (limit > 0 && *size >= limit)
                break;          /* full: what fits is the answer */
            newsize = *size > 0 ? 2 * *size : 16;
            if (limit > 0 && newsize > limit)
                newsize = limit;
            groups = realloc(groups, (size_t)newsize * sizeof(gid_t));
            if (groups == NULL) {
                free(list);
                *errnop = ENOMEM;
                return NSS_STATUS_TRYAGAIN;
            }
            *groupsp = groups;
            *size = newsize;
        }
        groups[(*start)++] = list[i];
    }
    free(list);
    return NSS_STATUS_SUCCESS;
}
#endif /* __linux__ */

#ifdef __FreeBSD__
/*
 * FreeBSD interface: nsdispatch(3) loads nss_gershwin.so.1 and calls
 * nss_module_register for the method table.
 */
#include <nsswitch.h>
#include <stdarg.h>

static int
ns_status_of(enum ds_result r, int err, int *errnop)
{
    switch (r) {
    case DS_SUCCESS:
        return NS_SUCCESS;
    case DS_NOTFOUND:
        return NS_NOTFOUND;
    case DS_UNAVAIL:
        return NS_UNAVAIL;
    default:
        /* libc's own sources: ERANGE + NS_RETURN makes the caller retry
         * with a larger buffer. */
        *errnop = err;
        return NS_RETURN;
    }
}

static int
ns_passwd(void *retval, void *mdata, va_list ap)
{
    enum lookup how = (enum lookup)(uintptr_t)mdata;
    const char *name = NULL;
    uid_t uid = 0;
    struct passwd *pwd;
    char *buffer;
    size_t buflen;
    int *errnop, err = 0, rv;

    if (how == LT_NAME)
        name = va_arg(ap, const char *);
    else if (how == LT_ID)
        uid = va_arg(ap, uid_t);
    pwd = va_arg(ap, struct passwd *);
    buffer = va_arg(ap, char *);
    buflen = va_arg(ap, size_t);
    errnop = va_arg(ap, int *);

    rv = ns_status_of(lookup_passwd(how, name, uid, pwd, buffer, buflen, &err),
                      err, errnop);
    if (rv == NS_SUCCESS && retval != NULL)
        *(struct passwd **)retval = pwd;
    return rv;
}

static int
ns_group(void *retval, void *mdata, va_list ap)
{
    enum lookup how = (enum lookup)(uintptr_t)mdata;
    const char *name = NULL;
    gid_t gid = 0;
    struct group *grp;
    char *buffer;
    size_t buflen;
    int *errnop, err = 0, rv;

    if (how == LT_NAME)
        name = va_arg(ap, const char *);
    else if (how == LT_ID)
        gid = va_arg(ap, gid_t);
    grp = va_arg(ap, struct group *);
    buffer = va_arg(ap, char *);
    buflen = va_arg(ap, size_t);
    errnop = va_arg(ap, int *);

    rv = ns_status_of(lookup_group(how, name, gid, grp, buffer, buflen, &err),
                      err, errnop);
    if (rv == NS_SUCCESS && retval != NULL)
        *(struct group **)retval = grp;
    return rv;
}

/* setpwent/endpwent and setgrent/endgrent: nothing is kept open. */
static int
ns_pwcursor(void *retval __unused, void *mdata __unused, va_list ap __unused)
{
    rewind_cursor(&pw_cursor);
    return NS_UNAVAIL;          /* every source is run */
}

static int
ns_grcursor(void *retval __unused, void *mdata __unused, va_list ap __unused)
{
    rewind_cursor(&gr_cursor);
    return NS_UNAVAIL;
}

/*
 * getgrouplist(3). For a directory user the answer is complete here, so
 * NS_SUCCESS ends the search. For anyone else, NS_NOTFOUND lets `files`
 * answer.
 */
static int
ns_getgroupmembership(void *retval __unused, void *mdata __unused, va_list ap)
{
    const char *user = va_arg(ap, const char *);
    gid_t agroup = va_arg(ap, gid_t);
    gid_t *groups = va_arg(ap, gid_t *);
    int maxgrp = va_arg(ap, int);
    int *grpcnt = va_arg(ap, int *);
    gid_t *list;
    int count, n, rv;

    rv = user_groupset(user, agroup, &list, &count);
    if (rv == -1)
        return NS_UNAVAIL;
    if (rv != 0)
        return NS_NOTFOUND;
    n = count < maxgrp ? count : maxgrp;
    if (n > 0)
        memcpy(groups, list, (size_t)n * sizeof(gid_t));
    free(list);
    *grpcnt = count;
    return NS_SUCCESS;
}

static ns_mtab methods[] = {
    { NSDB_PASSWD, "getpwnam_r", ns_passwd, (void *)LT_NAME },
    { NSDB_PASSWD, "getpwuid_r", ns_passwd, (void *)LT_ID },
    { NSDB_PASSWD, "getpwent_r", ns_passwd, (void *)LT_ALL },
    { NSDB_PASSWD, "setpwent", ns_pwcursor, NULL },
    { NSDB_PASSWD, "endpwent", ns_pwcursor, NULL },
    { NSDB_GROUP,  "getgrnam_r", ns_group, (void *)LT_NAME },
    { NSDB_GROUP,  "getgrgid_r", ns_group, (void *)LT_ID },
    { NSDB_GROUP,  "getgrent_r", ns_group, (void *)LT_ALL },
    { NSDB_GROUP,  "setgrent", ns_grcursor, NULL },
    { NSDB_GROUP,  "endgrent", ns_grcursor, NULL },
    { NSDB_GROUP,  "getgroupmembership", ns_getgroupmembership, NULL },
};

/* nsswitch.h declares the type of this entry point but not the function. */
ns_mtab *nss_module_register(const char *, unsigned int *,
                             nss_module_unregister_fn *);

ns_mtab *
nss_module_register(const char *name __unused, unsigned int *size,
                    nss_module_unregister_fn *unregister)
{
    (void)pthread_once(&atfork_once, install_atfork);
    *size = sizeof(methods) / sizeof(methods[0]);
    *unregister = NULL;
    return methods;
}
#endif /* __FreeBSD__ */

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Counts the Objective-C objects a program holds, class by class, so that a
 * leak can be named in the language the program is written in: "NSImage,
 * 1204 more than a minute ago" says more than a list of allocation sites.
 *
 * The count is taken where the runtime itself creates and destroys an
 * instance. Foundation's own counting (GSDebugAllocationActive) hangs off
 * -[NSObject init], which the class clusters never reach, so strings, arrays
 * and dictionaries would all be missing from the answer.
 *
 * Nothing here allocates while counting: the table is claimed once and every
 * count is an atomic addition, so a program that allocates from several
 * threads is slowed as little as possible and can never deadlock against
 * its own allocator. The report is served on a socket of this library's own,
 * because a program that is leaking may no longer be answering on its.
 */

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>

typedef void *PRClassRef;
typedef void *PRObjectRef;

/* Two powers of two: the table is never rehashed, so counting stays free of
   locks, and a program with more classes than this simply leaves the last
   ones uncounted rather than paying for a growable table on every object. */
#define PR_SLOTS 16384
#define PR_SLOT_MASK (PR_SLOTS - 1)

typedef struct {
    PRClassRef class;
    int64_t live;
    int64_t total;
    int64_t peak;
} PRSlot;

static PRSlot pr_slots[PR_SLOTS];
static PRObjectRef (*pr_real_create)(PRClassRef, size_t);
static void (*pr_real_dispose)(PRObjectRef);
static PRClassRef (*pr_object_class)(PRObjectRef);
static const char *(*pr_class_name)(PRClassRef);
static int pr_listen_fd = -1;

static PRSlot *pr_slot_for(PRClassRef class)
{
    uintptr_t hash = (uintptr_t)class;
    unsigned int index;

    /* The pointer is aligned, so its low bits carry no information. */
    hash = (hash >> 4) ^ (hash >> 20);

    for (index = 0; index < PR_SLOTS; index++) {
        PRSlot *slot = &pr_slots[(hash + index) & PR_SLOT_MASK];
        PRClassRef seen = __atomic_load_n(&slot->class, __ATOMIC_ACQUIRE);

        if (seen == class)
            return slot;
        if (seen == NULL) {
            PRClassRef empty = NULL;
            if (__atomic_compare_exchange_n(&slot->class, &empty, class, 0,
                                            __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
                return slot;
            /* Another thread took the slot; it may hold this very class. */
            if (empty == class)
                return slot;
        }
    }
    return NULL;
}

static void pr_note_created(PRClassRef class)
{
    PRSlot *slot = pr_slot_for(class);
    int64_t live;

    if (slot == NULL)
        return;
    live = __atomic_add_fetch(&slot->live, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&slot->total, 1, __ATOMIC_RELAXED);
    /* The peak may miss a race by one, which no one reading it would act on. */
    if (live > __atomic_load_n(&slot->peak, __ATOMIC_RELAXED))
        __atomic_store_n(&slot->peak, live, __ATOMIC_RELAXED);
}

static void pr_note_destroyed(PRClassRef class)
{
    PRSlot *slot = pr_slot_for(class);

    if (slot != NULL)
        __atomic_add_fetch(&slot->live, -1, __ATOMIC_RELAXED);
}

/* The runtime's own entry points, replaced here and called through. */
PRObjectRef class_createInstance(PRClassRef class, size_t extraBytes)
{
    PRObjectRef object;

    if (pr_real_create == NULL)
        pr_real_create = dlsym(RTLD_NEXT, "class_createInstance");
    object = pr_real_create(class, extraBytes);
    if (object != NULL)
        pr_note_created(class);
    return object;
}

void object_dispose(PRObjectRef object)
{
    if (pr_real_dispose == NULL)
        pr_real_dispose = dlsym(RTLD_NEXT, "object_dispose");
    if (object != NULL && pr_object_class != NULL)
        pr_note_destroyed(pr_object_class(object));
    pr_real_dispose(object);
}

static void pr_write(int fd, const char *text)
{
    size_t left = strlen(text);

    while (left > 0) {
        ssize_t written = write(fd, text, left);
        if (written <= 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        text += written;
        left -= (size_t)written;
    }
}

static void pr_send_census(int fd)
{
    char line[512];
    unsigned int index;

    if (pr_class_name == NULL) {
        pr_write(fd, "error this program has no Objective-C runtime\n");
        return;
    }

    for (index = 0; index < PR_SLOTS; index++) {
        PRSlot *slot = &pr_slots[index];
        PRClassRef class = __atomic_load_n(&slot->class, __ATOMIC_ACQUIRE);
        const char *name;

        if (class == NULL)
            continue;
        name = pr_class_name(class);
        if (name == NULL)
            continue;
        snprintf(line, sizeof(line), "%lld %lld %lld %s\n",
                 (long long)__atomic_load_n(&slot->live, __ATOMIC_RELAXED),
                 (long long)__atomic_load_n(&slot->peak, __ATOMIC_RELAXED),
                 (long long)__atomic_load_n(&slot->total, __ATOMIC_RELAXED),
                 name);
        pr_write(fd, line);
    }
    pr_write(fd, ".\n");
}

static void pr_handle(int fd)
{
    char buffer[256];
    size_t filled = 0;

    for (;;) {
        ssize_t got = read(fd, buffer + filled, sizeof(buffer) - filled - 1);
        char *newline;

        if (got <= 0)
            return;
        filled += (size_t)got;
        buffer[filled] = '\0';

        while ((newline = strchr(buffer, '\n')) != NULL) {
            size_t rest;

            *newline = '\0';
            if (strcmp(buffer, "census") == 0)
                pr_send_census(fd);
            else
                pr_write(fd, "error unknown command\n");

            rest = filled - (size_t)(newline - buffer) - 1;
            memmove(buffer, newline + 1, rest);
            filled = rest;
            buffer[filled] = '\0';
        }

        if (filled + 1 >= sizeof(buffer))
            filled = 0;
    }
}

static void *pr_serve(void *ignored)
{
    (void)ignored;

    for (;;) {
        int fd = accept(pr_listen_fd, NULL, NULL);

        if (fd < 0) {
            if (errno == EINTR)
                continue;
            return NULL;
        }
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        pr_handle(fd);
        close(fd);
    }
}

/* A program starts helpers of its own, and they inherit the environment
   that put this library in place, so the socket is named after the process
   it belongs to. The profiler knows which process it started and looks for
   that name; the helpers answer on names of their own and disturb nobody. */
static char pr_socket_path[108];
static pid_t pr_owner_pid;

/* A program that forks keeps this library, and the child would otherwise
   take the parent's socket file with it when it exits. */
static void pr_remove_socket(void)
{
    if (pr_socket_path[0] != '\0' && getpid() == pr_owner_pid)
        unlink(pr_socket_path);
}

__attribute__((constructor))
static void pr_start(void)
{
    const char *stem = getenv("PR_CENSUS_SOCKET");
    struct sockaddr_un address;
    pthread_t thread;

    pr_real_create = dlsym(RTLD_NEXT, "class_createInstance");
    pr_real_dispose = dlsym(RTLD_NEXT, "object_dispose");
    pr_object_class = dlsym(RTLD_DEFAULT, "object_getClass");
    pr_class_name = dlsym(RTLD_DEFAULT, "class_getName");

    if (stem == NULL || *stem == '\0')
        return;
    if (snprintf(pr_socket_path, sizeof(pr_socket_path), "%s.%d",
                 stem, (int)getpid()) >= (int)sizeof(pr_socket_path)) {
        pr_socket_path[0] = '\0';
        return;
    }

    pr_listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (pr_listen_fd < 0)
        return;
    /* A program that starts another one must not hand it this socket, or
       two processes would answer for one name. */
    fcntl(pr_listen_fd, F_SETFD, FD_CLOEXEC);
    pr_owner_pid = getpid();

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, pr_socket_path, sizeof(address.sun_path) - 1);
    unlink(pr_socket_path);

    if (bind(pr_listen_fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(pr_listen_fd, 1) != 0) {
        close(pr_listen_fd);
        pr_listen_fd = -1;
        return;
    }

    if (pthread_create(&thread, NULL, pr_serve, NULL) == 0) {
        pthread_detach(thread);
        atexit(pr_remove_socket);
    }
}

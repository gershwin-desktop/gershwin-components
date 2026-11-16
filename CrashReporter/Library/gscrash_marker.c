/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "gscrash_marker.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/*
 * Async-signal-safe JSON emission for a small crash marker. We avoid malloc and
 * use only the open/write/close syscalls over fixed stack buffers. The content
 * is intentionally tiny so it fits in one write.
 */

#define MK_APP       "application"
#define MK_VERSION   "version"
#define MK_PID       "pid"
#define MK_UID       "uid"
#define MK_EXEC      "executable"
#define MK_SIGNAL    "signal"
#define MK_EXCEPTION "exception"
#define MK_REASON    "reason"
#define MK_TIMESTAMP "timestamp"
#define MK_BUILD     "build_id"

static int write_all(int fd, const char *buf, size_t len)
{
    while (len > 0)
    {
        ssize_t n = write(fd, buf, len);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static void json_escape(char *out, size_t outsz, const char *in)
{
    size_t j = 0;
    if (in == NULL)
        in = "";
    for (size_t i = 0; in[i] && j + 2 < outsz; i++)
    {
        char c = in[i];
        if (c == '"' || c == '\\')
        {
            out[j++] = '\\';
            out[j++] = c;
        }
        else if (c == '\n')
        {
            out[j++] = '\\';
            out[j++] = 'n';
        }
        else
        {
            out[j++] = c;
        }
    }
    out[j] = '\0';
}

int gscrash_write_signal_marker(const char *markersDir,
                                const char *appName,
                                const char *execPath,
                                pid_t pid,
                                uid_t uid,
                                const char *signalName,
                                const char *exceptionName,
                                const char *exceptionReason,
                                const char *buildID)
{
    if (markersDir == NULL)
        return -1;

    char safeApp[256];
    char safeExec[1024];
    char safeSig[64];
    char safeExc[256];
    char safeReason[1024];
    char safeBuild[128];

    json_escape(safeApp, sizeof(safeApp), appName);
    json_escape(safeExec, sizeof(safeExec), execPath);
    json_escape(safeSig, sizeof(safeSig), signalName);
    json_escape(safeExc, sizeof(safeExc), exceptionName);
    json_escape(safeReason, sizeof(safeReason), exceptionReason);
    json_escape(safeBuild, sizeof(safeBuild), buildID);

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;

    char path[2048];
    int rc = snprintf(path, sizeof(path), "%s/%d-%lld.marker",
                      markersDir, (int)pid, ms);
    if (rc < 0 || (size_t)rc >= sizeof(path))
        return -1;

    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0 && errno == EEXIST)
    {
        static volatile int counter = 0;
        int c = counter++;
        rc = snprintf(path, sizeof(path), "%s/%d-%lld-%d.marker",
                      markersDir, (int)pid, ms, c);
        if (rc < 0 || (size_t)rc >= sizeof(path))
            return -1;
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    }
    if (fd < 0)
        return -1;

    char buf[4096];
    int n = snprintf(buf, sizeof(buf),
        "{"
        "\"%s\":\"%s\","
        "\"%s\":\"\","
        "\"%s\":%d,"
        "\"%s\":%u,"
        "\"%s\":\"%s\","
        "\"%s\":\"%s\","
        "\"%s\":\"%s\","
        "\"%s\":\"%s\","
        "\"%s\":%lld,"
        "\"%s\":\"%s\""
        "}\n",
        MK_APP, safeApp,
        MK_VERSION,
        MK_PID, (int)pid,
        MK_UID, (unsigned)uid,
        MK_EXEC, safeExec,
        MK_SIGNAL, safeSig,
        MK_EXCEPTION, safeExc,
        MK_REASON, safeReason,
        MK_TIMESTAMP, ms,
        MK_BUILD, safeBuild);

    int result = 0;
    if (n < 0 || (size_t)n >= sizeof(buf))
        result = -1;
    else if (write_all(fd, buf, (size_t)n) != 0)
        result = -1;

    if (fsync(fd) != 0)
    {
        /* non-fatal */
    }
    if (close(fd) != 0)
        result = -1;
    return result;
}

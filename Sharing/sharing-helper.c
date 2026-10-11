/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sharing Helper - Privileged operations for Sharing preference pane
 * 
 * This is a standalone C program that performs operations requiring root privileges.
 * It can be called via sudo/doas or installed as setuid root.
 * 
 * Supported platforms: Linux (systemd and other init systems such as in Devuan, Artix), FreeBSD, OpenBSD, NetBSD
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <syslog.h>
#include <ctype.h>
#include <sys/wait.h>

#include "sshd-x11.h"

#define MAX_HOSTNAME_LEN 256

/* Platform detection */
#if defined(__linux__)
#define PLATFORM_LINUX 1
#elif defined(__FreeBSD__)
#define PLATFORM_FREEBSD 1
#elif defined(__OpenBSD__)
#define PLATFORM_OPENBSD 1
#elif defined(__NetBSD__)
#define PLATFORM_NETBSD 1
#endif

/* Validate hostname according to RFC 1123 */
static int validate_hostname(const char *hostname)
{
    size_t len = strlen(hostname);
    
    if (len == 0 || len > 63) {
        return 0;
    }
    
    /* Cannot start or end with hyphen */
    if (hostname[0] == '-' || hostname[len-1] == '-') {
        return 0;
    }
    
    /* Only alphanumeric and hyphen allowed */
    for (size_t i = 0; i < len; i++) {
        if (!isalnum(hostname[i]) && hostname[i] != '-') {
            return 0;
        }
    }
    
    return 1;
}

/* Get current hostname */
static void cmd_get_hostname(void)
{
    struct utsname buf;
    
    if (uname(&buf) == 0) {
        printf("%s\n", buf.nodename);
        exit(0);
    } else {
        fprintf(stderr, "Failed to get hostname\n");
        exit(1);
    }
}

/* Set hostname */
static void cmd_set_hostname(const char *hostname)
{
    if (!validate_hostname(hostname)) {
        fprintf(stderr, "Invalid hostname format\n");
        syslog(LOG_ERR, "sharing-helper: Invalid hostname format: %s", hostname);
        exit(1);
    }
    
    syslog(LOG_INFO, "sharing-helper: Setting hostname to: %s", hostname);
    
#ifdef PLATFORM_LINUX
    /* Set hostname using sethostname() */
    if (sethostname(hostname, strlen(hostname)) != 0) {
        perror("sethostname");
        syslog(LOG_ERR, "sharing-helper: Failed to set hostname");
        exit(1);
    }
    
    /* Update /etc/hostname */
    FILE *f = fopen("/etc/hostname", "w");
    if (f) {
        fprintf(f, "%s\n", hostname);
        fclose(f);
    }
    
    /* Try to update /etc/hosts */
    char cmd[512];
    snprintf(cmd, sizeof(cmd), 
             "sed -i 's/127.0.1.1.*/127.0.1.1\\t%s/' /etc/hosts 2>/dev/null || true", 
             hostname);
    system(cmd);
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    /* Set hostname using sethostname() */
    if (sethostname(hostname, strlen(hostname)) != 0) {
        perror("sethostname");
        syslog(LOG_ERR, "sharing-helper: Failed to set hostname");
        exit(1);
    }
    
    /* Update /etc/rc.conf */
    char cmd[512];
    snprintf(cmd, sizeof(cmd), 
             "sysrc hostname=\"%s\" || "
             "(grep -v '^hostname=' /etc/rc.conf > /tmp/rc.conf.tmp && "
             "echo 'hostname=\"%s\"' >> /tmp/rc.conf.tmp && "
             "mv /tmp/rc.conf.tmp /etc/rc.conf)",
             hostname, hostname);
    system(cmd);
    
#elif defined(PLATFORM_OPENBSD)
    /* Set hostname using sethostname() */
    if (sethostname(hostname, strlen(hostname)) != 0) {
        perror("sethostname");
        syslog(LOG_ERR, "sharing-helper: Failed to set hostname");
        exit(1);
    }
    
    /* Update /etc/myname */
    FILE *f = fopen("/etc/myname", "w");
    if (f) {
        fprintf(f, "%s\n", hostname);
        fclose(f);
    }
#endif

    /* Restart or notify the mDNS daemon so it picks up the new hostname.
     * Changing /etc/hostname + sethostname() does not propagate to
     * avahi-daemon or mDNSResponder automatically.  Try every available
     * service manager — SIGHUP via killall is a last resort because some
     * Avahi versions don't re-read the hostname on SIGHUP. */
#ifdef PLATFORM_LINUX
    system("systemctl restart avahi-daemon 2>/dev/null || "
           "systemctl restart systemd-resolved 2>/dev/null || "
           "service avahi-daemon restart 2>/dev/null || "
           "/etc/init.d/avahi-daemon restart 2>/dev/null || "
           "rc-service avahi-daemon restart 2>/dev/null || "
           "pkill -HUP -x avahi-daemon 2>/dev/null || true");
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("/usr/sbin/service avahi-daemon restart 2>/dev/null || "
           "/usr/sbin/service mdnsd restart 2>/dev/null || "
           "pkill -HUP -x avahi-daemon mdnsd mDNSResponder 2>/dev/null || true");
#elif defined(PLATFORM_OPENBSD)
    system("/usr/sbin/rcctl restart avahi_daemon 2>/dev/null || "
           "pkill -HUP -x avahi-daemon mdnsd mDNSResponder 2>/dev/null || true");
#endif

    /* Also try to explicitly publish the new hostname address so it
     * resolves immediately even if Avahi's hostname registration
     * hasn't picked up the change yet.  This runs as a background
     * daemon that survives the helper's exit. */
    system("avahi-publish-address -s $(hostname) "
           "$(hostname -I 2>/dev/null | cut -d' ' -f1) "
           ">/dev/null 2>&1 &");

    syslog(LOG_INFO, "sharing-helper: Hostname set to: %s", hostname);
    printf("Hostname set successfully\n");
    exit(0);
}

/* Check if a binary exists in PATH using POSIX command -v for portability.
 * Falls back to checking common paths in case PATH is minimal
 * (e.g., GUI apps on some BSD systems). */
static int binary_exists(const char *name)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "command -v %s >/dev/null 2>&1", name);
    if (system(cmd) == 0) {
        return 1;
    }
    /* Fallback: check common directories directly */
    const char *prefixes[] = {
        "/usr/bin/", "/usr/sbin/",
        "/usr/local/bin/", "/usr/local/sbin/",
        "/bin/", "/sbin/", NULL
    };
    char path[512];
    for (int i = 0; prefixes[i] != NULL; i++) {
        snprintf(path, sizeof(path), "%s%s", prefixes[i], name);
        if (access(path, X_OK) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Check if SFTP subsystem is configured in sshd_config (shared helper) */
static int sftp_subsystem_configured(void)
{
    const char *sshd_config_paths[] = {
        "/etc/ssh/sshd_config",
        "/usr/local/etc/ssh/sshd_config",
        NULL
    };
    for (int i = 0; sshd_config_paths[i] != NULL; i++) {
        FILE *f = fopen(sshd_config_paths[i], "r");
        if (f) {
            char line[512];
            while (fgets(line, sizeof(line), f)) {
                char *p = line;
                while (*p == ' ' || *p == '\t') p++;
                if (*p == '#' || *p == '\n') continue;
                if (strncmp(p, "Subsystem", 9) == 0) {
                    p += 9;
                    while (*p == ' ' || *p == '\t') p++;
                    if (strncmp(p, "sftp", 4) == 0) {
                        fclose(f);
                        return 1;
                    }
                }
            }
            fclose(f);
        }
    }
    return 0;
}

/* Check if a service is running */
static int check_service_running(const char *service)
{
#ifdef PLATFORM_LINUX
    char cmd[256];
    
    /* Try systemctl first (systemd) */
    snprintf(cmd, sizeof(cmd), "systemctl is-active %s >/dev/null 2>&1", service);
    if (system(cmd) == 0) {
        return 1;
    }
    
    /* Fall back to service command (sysvinit/upstart) */
    snprintf(cmd, sizeof(cmd), "service %s status >/dev/null 2>&1", service);
    if (system(cmd) == 0) {
        return 1;
    }
    
    /* Check if init script exists and try it directly */
    snprintf(cmd, sizeof(cmd), "/etc/init.d/%s status >/dev/null 2>&1", service);
    return (system(cmd) == 0);
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    char cmd[256];
    /* Use full path to avoid PATH issues in GUI context */
    snprintf(cmd, sizeof(cmd), "/usr/sbin/service %s status >/dev/null 2>&1", service);
    return (system(cmd) == 0);

#elif defined(PLATFORM_OPENBSD)
    char cmd[256];
    /* Use full path to avoid PATH issues in GUI context */
    snprintf(cmd, sizeof(cmd), "/usr/sbin/rcctl check %s >/dev/null 2>&1", service);
    return (system(cmd) == 0);
#endif
    return 0;
}

/* SSH status */
static void cmd_ssh_status(void)
{
#ifdef PLATFORM_LINUX
    /* Check both systemd service names and sysvinit service names */
    if (check_service_running("sshd.service") || 
        check_service_running("ssh.service") ||
        check_service_running("sshd") || 
        check_service_running("ssh")) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#else
    if (check_service_running("sshd")) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#endif
    exit(0);
}

/* SSH installed */
static void cmd_ssh_installed(void)
{
    if (binary_exists("sshd")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start SSH */
static void cmd_ssh_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting SSH service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        if (system("systemctl start sshd.service >/dev/null 2>&1") != 0) {
            system("systemctl start ssh.service >/dev/null 2>&1");
        }
        system("systemctl enable sshd.service >/dev/null 2>&1 || systemctl enable ssh.service >/dev/null 2>&1");
    } else {
        /* Fall back to service command (sysvinit/upstart) */
        if (system("service sshd start >/dev/null 2>&1") != 0) {
            system("service ssh start >/dev/null 2>&1");
        }
        /* Or try init scripts directly */
        if (system("test -x /etc/init.d/sshd") == 0) {
            system("/etc/init.d/sshd start >/dev/null 2>&1");
        } else if (system("test -x /etc/init.d/ssh") == 0) {
            system("/etc/init.d/ssh start >/dev/null 2>&1");
        }
    }
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("sysrc sshd_enable=YES");
    system("service sshd start");
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable sshd");
    system("rcctl start sshd");
#endif
    
    syslog(LOG_INFO, "sharing-helper: SSH service started");
    exit(0);
}

/* Stop SSH */
static void cmd_ssh_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping SSH service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop sshd.service >/dev/null 2>&1 || systemctl stop ssh.service >/dev/null 2>&1");
    } else {
        /* Fall back to service command (sysvinit/upstart) */
        if (system("service sshd stop >/dev/null 2>&1") != 0) {
            system("service ssh stop >/dev/null 2>&1");
        }
        /* Or try init scripts directly */
        if (system("test -x /etc/init.d/sshd") == 0) {
            system("/etc/init.d/sshd stop >/dev/null 2>&1");
        } else if (system("test -x /etc/init.d/ssh") == 0) {
            system("/etc/init.d/ssh stop >/dev/null 2>&1");
        }
    }
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("service sshd stop");
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop sshd");
#endif
    
    syslog(LOG_INFO, "sharing-helper: SSH service stopped");
    exit(0);
}

/* VNC status - checks for various VNC servers */
/* X11 forwarding - the X11Forwarding directive of sshd_config */

static const char *find_sshd(void)
{
    static const char *candidates[] = {
        "/usr/sbin/sshd", "/usr/local/sbin/sshd",
        "/usr/bin/sshd", "/usr/local/bin/sshd", NULL
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        if (access(candidates[i], X_OK) == 0) {
            return candidates[i];
        }
    }
    return NULL;
}

/* The configuration belongs to the sshd that is installed: one from the
 * ports/packages tree reads /usr/local/etc/ssh, the base system one /etc/ssh. */
static const char *sshd_config_path(const char *sshd)
{
    return strncmp(sshd, "/usr/local/", 11) == 0
        ? "/usr/local/etc/ssh/sshd_config" : "/etc/ssh/sshd_config";
}

static int sshd_running(void)
{
#ifdef PLATFORM_LINUX
    return check_service_running("sshd.service") ||
           check_service_running("ssh.service") ||
           check_service_running("sshd") ||
           check_service_running("ssh");
#else
    return check_service_running("sshd");
#endif
}

/* sshd reads its configuration at start and on SIGHUP only, so a running
 * daemon has to be told; new sessions then see the change while existing ones
 * are not dropped.  Returns 0 on success. */
static int reload_sshd(void)
{
    if (!sshd_running()) {
        return 0;
    }
#ifdef PLATFORM_LINUX
    if (system("systemctl reload sshd.service >/dev/null 2>&1") == 0 ||
        system("systemctl reload ssh.service >/dev/null 2>&1") == 0 ||
        system("service sshd reload >/dev/null 2>&1") == 0 ||
        system("service ssh reload >/dev/null 2>&1") == 0 ||
        system("/etc/init.d/sshd reload >/dev/null 2>&1") == 0 ||
        system("/etc/init.d/ssh reload >/dev/null 2>&1") == 0) {
        return 0;
    }
    return 1;
#elif defined(PLATFORM_OPENBSD)
    return system("/usr/sbin/rcctl reload sshd >/dev/null 2>&1") == 0 ? 0 : 1;
#else
    return system("/usr/sbin/service sshd reload >/dev/null 2>&1") == 0 ? 0 : 1;
#endif
}

static int validate_with_sshd(const char *path, void *ctx)
{
    const char *sshd = ctx;
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        freopen("/dev/null", "w", stdout);
        execl(sshd, "sshd", "-t", "-f", path, (char *)NULL);
        _exit(127);
    }
    int status;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static void cmd_x11_installed(void)
{
    const char *sshd = find_sshd();
    if (sshd && access(sshd_config_path(sshd), R_OK) == 0 && binary_exists("xauth")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

static void cmd_x11_status(void)
{
    const char *sshd = find_sshd();
    int enabled;
    char err[512];

    if (!sshd) {
        fprintf(stderr, "sshd not found\n");
        exit(1);
    }
    if (sshd_x11_read_file(sshd_config_path(sshd), &enabled, err, sizeof(err)) != 0) {
        fprintf(stderr, "%s\n", err);
        exit(1);
    }
    printf("%s\n", enabled ? "enabled" : "disabled");
    exit(0);
}

static void cmd_x11_set(int enable)
{
    const char *sshd = find_sshd();
    int changed;
    char err[512];

    if (!sshd) {
        fprintf(stderr, "sshd not found\n");
        exit(1);
    }
    syslog(LOG_INFO, "sharing-helper: %s X11 forwarding", enable ? "Enabling" : "Disabling");
    if (sshd_x11_rewrite_file(sshd_config_path(sshd), enable, validate_with_sshd,
                              (void *)sshd, &changed, err, sizeof(err)) != 0) {
        fprintf(stderr, "%s\n", err);
        syslog(LOG_ERR, "sharing-helper: X11 forwarding: %s", err);
        exit(1);
    }
    if (changed && reload_sshd() != 0) {
        fprintf(stderr, "Configuration written but sshd could not be reloaded\n");
        syslog(LOG_ERR, "sharing-helper: sshd reload failed");
        exit(1);
    }
    exit(0);
}

static void cmd_vnc_status(void)
{
    int running = 0;
    
#ifdef PLATFORM_LINUX
    /* Check for various VNC services */
    running = check_service_running("vncserver@:1.service") ||
              check_service_running("x11vnc.service") ||
              check_service_running("tigervncserver@:1.service") ||
              check_service_running("tightvncserver@:1.service");
    
    /* Also check for running VNC processes */
    if (!running) {
        running = (system("pgrep -x Xvnc >/dev/null 2>&1") == 0) ||
                  (system("pgrep -x x11vnc >/dev/null 2>&1") == 0);
    }
#else
    /* Check for VNC processes on BSD systems */
    running = (system("pgrep -x Xvnc >/dev/null 2>&1") == 0) ||
              (system("pgrep -x x11vnc >/dev/null 2>&1") == 0);
#endif
    
    if (running) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
    exit(0);
}

/* VNC installed */
static void cmd_vnc_installed(void)
{
    if (binary_exists("Xvnc") || binary_exists("x11vnc") || binary_exists("vncserver")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start VNC */
static void cmd_vnc_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting VNC service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        /* Try common VNC service names */
        if (system("systemctl start x11vnc.service >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("systemctl start vncserver@:1.service >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("systemctl start tigervncserver@:1.service >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    }
    
    /* Try service command (sysvinit/OpenRC/upstart) */
    if (system("service x11vnc start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    if (system("service vncserver start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    
    /* Try init scripts directly */
    if (system("test -x /etc/init.d/x11vnc && /etc/init.d/x11vnc start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    if (system("test -x /etc/init.d/vncserver && /etc/init.d/vncserver start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    
    /* Fall back to starting x11vnc directly if available */
    if (binary_exists("x11vnc")) {
        syslog(LOG_WARNING, "sharing-helper: No VNC service found, starting x11vnc directly");
        /* Try various auth locations */
        if (system("x11vnc -display :0 -auth /var/run/xauth -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("x11vnc -display :0 -auth /var/run/lightdm/root/:0 -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("x11vnc -display :0 -auth /run/user/$(id -u)/gdm/Xauthority -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("x11vnc -display :0 -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
        if (system("x11vnc -display :0 -auth guess -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    } else if (binary_exists("vncserver")) {
        /* Try TigerVNC or TightVNC server */
        if (system("vncserver :1 >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    }
    
    fprintf(stderr, "Failed to start VNC server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start VNC server");
    exit(1);
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    /* Try service command */
    if (system("service x11vnc start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    if (system("service vncserver start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    
    /* Try rc.d scripts directly */
    if (system("test -x /usr/local/etc/rc.d/x11vnc && /usr/local/etc/rc.d/x11vnc start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    if (system("test -x /etc/rc.d/vncserver && /etc/rc.d/vncserver start >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    
    /* Fall back to direct start */
    if (binary_exists("x11vnc")) {
        syslog(LOG_WARNING, "sharing-helper: No VNC service found, starting x11vnc directly");
        if (system("x11vnc -display :0 -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    } else if (binary_exists("vncserver")) {
        if (system("vncserver :1 >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    }
    
    fprintf(stderr, "Failed to start VNC server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start VNC server");
    exit(1);
    
#elif defined(PLATFORM_OPENBSD)
    /* Try rcctl */
    if (system("rcctl start x11vnc >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    if (system("rcctl start vncserver >/dev/null 2>&1") == 0) {
        goto vnc_started;
    }
    
    /* Fall back to direct start */
    if (binary_exists("x11vnc")) {
        syslog(LOG_WARNING, "sharing-helper: No VNC service found, starting x11vnc directly");
        if (system("x11vnc -display :0 -forever -bg -rfbport 5900 -nopw >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    } else if (binary_exists("vncserver")) {
        if (system("vncserver :1 >/dev/null 2>&1") == 0) {
            goto vnc_started;
        }
    }
    
    fprintf(stderr, "Failed to start VNC server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start VNC server");
    exit(1);
#endif

vnc_started:
    syslog(LOG_INFO, "sharing-helper: VNC service started");
    exit(0);
}

/* Stop VNC */
static void cmd_vnc_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping VNC service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop x11vnc.service >/dev/null 2>&1");
        system("systemctl stop vncserver@:1.service >/dev/null 2>&1");
        system("systemctl stop tigervncserver@:1.service >/dev/null 2>&1");
    }
    
    /* Try service command (sysvinit/OpenRC/upstart) */
    system("service x11vnc stop >/dev/null 2>&1");
    system("service vncserver stop >/dev/null 2>&1");
    
    /* Try init scripts directly */
    system("test -x /etc/init.d/x11vnc && /etc/init.d/x11vnc stop >/dev/null 2>&1");
    system("test -x /etc/init.d/vncserver && /etc/init.d/vncserver stop >/dev/null 2>&1");
    
    /* Kill any remaining VNC processes */
    system("pkill -x x11vnc >/dev/null 2>&1");
    system("pkill -x Xvnc >/dev/null 2>&1");
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    /* Try service command */
    system("service x11vnc stop >/dev/null 2>&1");
    system("service vncserver stop >/dev/null 2>&1");
    
    /* Try rc.d scripts directly */
    system("test -x /usr/local/etc/rc.d/x11vnc && /usr/local/etc/rc.d/x11vnc stop >/dev/null 2>&1");
    system("test -x /etc/rc.d/vncserver && /etc/rc.d/vncserver stop >/dev/null 2>&1");
    
    /* Kill any remaining processes */
    system("pkill -x x11vnc >/dev/null 2>&1");
    system("pkill -x Xvnc >/dev/null 2>&1");
    system("vncserver -kill :1 >/dev/null 2>&1");
    
#elif defined(PLATFORM_OPENBSD)
    /* Try rcctl */
    system("rcctl stop x11vnc >/dev/null 2>&1");
    system("rcctl stop vncserver >/dev/null 2>&1");
    
    /* Kill any remaining processes */
    system("pkill -x x11vnc >/dev/null 2>&1");
    system("pkill -x Xvnc >/dev/null 2>&1");
    system("vncserver -kill :1 >/dev/null 2>&1");
#endif
    
    syslog(LOG_INFO, "sharing-helper: VNC service stopped");
    exit(0);
}

/* SFTP status - SFTP uses SSH daemon, but we check config for SFTP subsystem */
static void cmd_sftp_status(void)
{
    /* SFTP is typically enabled if SSH is running and SFTP subsystem is configured */
    /* Check if SSH is running first */
#ifdef PLATFORM_LINUX
    if (!check_service_running("sshd.service") && 
        !check_service_running("ssh.service") &&
        !check_service_running("sshd") && 
        !check_service_running("ssh")) {
        printf("stopped\n");
        exit(0);
    }
#else
    if (!check_service_running("sshd")) {
        printf("stopped\n");
        exit(0);
    }
#endif
    
    /* Check if SFTP subsystem is configured in sshd_config */
    if (sftp_subsystem_configured()) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
    exit(0);
}

/* SFTP installed */
static void cmd_sftp_installed(void)
{
    /* Check if sshd binary exists */
    if (!binary_exists("sshd")) {
        printf("not-installed\n");
        exit(0);
    }

    /* Check if SFTP subsystem is configured */
    if (sftp_subsystem_configured()) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start SFTP - Ensures SSH is running and SFTP subsystem is enabled */
static void cmd_sftp_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting SFTP service");
    
    /* First ensure SSH is running */
    cmd_ssh_start(); /* This will exit, so we won't reach here */
}

/* Stop SFTP - We don't actually stop SSH, just note that SFTP won't be available */
static void cmd_sftp_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: SFTP service stop requested (SSH remains running)");
    /* SFTP uses SSH daemon - we don't stop SSH when SFTP is disabled */
    /* The service is controlled at the SSH level */
    exit(0);
}

/* AFP status */
static void cmd_afp_status(void)
{
#ifdef PLATFORM_LINUX
    /* Check for Netatalk AFP daemon */
    if (check_service_running("netatalk.service") ||
        check_service_running("netatalk") ||
        (system("pgrep -x afpd >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#else
    /* BSD systems */
    if (check_service_running("netatalk") ||
        (system("pgrep -x afpd >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#endif
    exit(0);
}

/* AFP installed */
static void cmd_afp_installed(void)
{
    if (binary_exists("afpd")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start AFP */
static void cmd_afp_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting AFP service");
    
    /* Check if Netatalk is installed */
    if (!binary_exists("afpd")) {
        fprintf(stderr, "AFP server (Netatalk) is not installed\n");
        syslog(LOG_ERR, "sharing-helper: AFP server (Netatalk) not found");
        exit(1);
    }
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        if (system("systemctl start netatalk.service >/dev/null 2>&1") == 0) {
            system("systemctl enable netatalk.service >/dev/null 2>&1");
            goto afp_started;
        }
    }
    
    /* Try service command (sysvinit/OpenRC/upstart) */
    if (system("service netatalk start >/dev/null 2>&1") == 0) {
        goto afp_started;
    }
    
    /* Try init script directly */
    if (system("test -x /etc/init.d/netatalk && /etc/init.d/netatalk start >/dev/null 2>&1") == 0) {
        goto afp_started;
    }
    
    /* Try starting afpd directly */
    if (system("afpd -F /etc/netatalk/afp.conf >/dev/null 2>&1 &") == 0) {
        goto afp_started;
    }
    
    fprintf(stderr, "Failed to start AFP server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start AFP server");
    exit(1);
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("sysrc netatalk_enable=YES");
    if (system("service netatalk start") == 0) {
        goto afp_started;
    }
    
    fprintf(stderr, "Failed to start AFP server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start AFP server");
    exit(1);
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable netatalk");
    if (system("rcctl start netatalk") == 0) {
        goto afp_started;
    }
    
    fprintf(stderr, "Failed to start AFP server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start AFP server");
    exit(1);
#endif

afp_started:
    syslog(LOG_INFO, "sharing-helper: AFP service started");
    exit(0);
}

/* Stop AFP */
static void cmd_afp_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping AFP service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop netatalk.service >/dev/null 2>&1");
    }
    
    /* Try service command */
    system("service netatalk stop >/dev/null 2>&1");
    
    /* Try init script */
    system("test -x /etc/init.d/netatalk && /etc/init.d/netatalk stop >/dev/null 2>&1");
    
    /* Kill any remaining afpd processes */
    system("pkill -x afpd >/dev/null 2>&1");
    system("pkill -x cnid_metad >/dev/null 2>&1");
    
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("service netatalk stop");
    system("pkill -x afpd >/dev/null 2>&1");
    system("pkill -x cnid_metad >/dev/null 2>&1");
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop netatalk");
    system("pkill -x afpd >/dev/null 2>&1");
    system("pkill -x cnid_metad >/dev/null 2>&1");
#endif
    
    syslog(LOG_INFO, "sharing-helper: AFP service stopped");
    exit(0);
}

/* Samba status */
static void cmd_smb_status(void)
{
#ifdef PLATFORM_LINUX
    /* Check for various Samba service names */
    if (check_service_running("smbd.service") ||
        check_service_running("smb.service") ||
        check_service_running("samba.service") ||
        check_service_running("smbd") ||
        check_service_running("smb") ||
        (system("pgrep -x smbd >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#else
    /* BSD systems */
    if (check_service_running("samba_server") ||
        check_service_running("smbd") ||
        (system("pgrep -x smbd >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#endif
    exit(0);
}

/* SMB installed */
static void cmd_smb_installed(void)
{
    if (binary_exists("smbd")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start Samba */
static void cmd_smb_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting Samba service");
    
    /* Check if Samba is installed */
    if (!binary_exists("smbd")) {
        fprintf(stderr, "Samba server is not installed\n");
        syslog(LOG_ERR, "sharing-helper: Samba server not found");
        exit(1);
    }
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        /* Try common service names */
        if (system("systemctl start smbd.service nmbd.service >/dev/null 2>&1") == 0) {
            system("systemctl enable smbd.service nmbd.service >/dev/null 2>&1");
            goto smb_started;
        }
        if (system("systemctl start smb.service nmb.service >/dev/null 2>&1") == 0) {
            system("systemctl enable smb.service nmb.service >/dev/null 2>&1");
            goto smb_started;
        }
        if (system("systemctl start samba.service >/dev/null 2>&1") == 0) {
            system("systemctl enable samba.service >/dev/null 2>&1");
            goto smb_started;
        }
    }
    
    /* Try service command (sysvinit/OpenRC/upstart) */
    if (system("service smbd start >/dev/null 2>&1 && service nmbd start >/dev/null 2>&1") == 0) {
        goto smb_started;
    }
    if (system("service smb start >/dev/null 2>&1") == 0) {
        goto smb_started;
    }
    if (system("service samba start >/dev/null 2>&1") == 0) {
        goto smb_started;
    }
    
    /* Try init scripts directly */
    if (system("test -x /etc/init.d/smbd && /etc/init.d/smbd start >/dev/null 2>&1") == 0) {
        system("test -x /etc/init.d/nmbd && /etc/init.d/nmbd start >/dev/null 2>&1");
        goto smb_started;
    }
    if (system("test -x /etc/init.d/samba && /etc/init.d/samba start >/dev/null 2>&1") == 0) {
        goto smb_started;
    }
    
    fprintf(stderr, "Failed to start Samba server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start Samba server");
    exit(1);
    
#elif defined(PLATFORM_FREEBSD)
    system("sysrc samba_server_enable=YES");
    if (system("service samba_server start") == 0) {
        goto smb_started;
    }
    
    fprintf(stderr, "Failed to start Samba server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start Samba server");
    exit(1);
    
#elif defined(PLATFORM_NETBSD)
    /* NetBSD uses separate smbd/nmbd services */
    system("echo smbd=YES >> /etc/rc.conf");
    system("echo nmbd=YES >> /etc/rc.conf");
    if (system("service smbd start && service nmbd start") == 0) {
        goto smb_started;
    }
    
    fprintf(stderr, "Failed to start Samba server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start Samba server");
    exit(1);
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable smbd");
    system("rcctl enable nmbd");
    if (system("rcctl start smbd && rcctl start nmbd") == 0) {
        goto smb_started;
    }
    
    fprintf(stderr, "Failed to start Samba server\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start Samba server");
    exit(1);
#endif

smb_started:
    syslog(LOG_INFO, "sharing-helper: Samba service started");
    exit(0);
}

/* Stop Samba */
static void cmd_smb_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping Samba service");
    
#ifdef PLATFORM_LINUX
    /* Try systemctl first (systemd) */
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop smbd.service nmbd.service >/dev/null 2>&1");
        system("systemctl stop smb.service nmb.service >/dev/null 2>&1");
        system("systemctl stop samba.service >/dev/null 2>&1");
    }
    
    /* Try service command */
    system("service smbd stop >/dev/null 2>&1");
    system("service nmbd stop >/dev/null 2>&1");
    system("service smb stop >/dev/null 2>&1");
    system("service samba stop >/dev/null 2>&1");
    
    /* Try init scripts */
    system("test -x /etc/init.d/smbd && /etc/init.d/smbd stop >/dev/null 2>&1");
    system("test -x /etc/init.d/nmbd && /etc/init.d/nmbd stop >/dev/null 2>&1");
    system("test -x /etc/init.d/samba && /etc/init.d/samba stop >/dev/null 2>&1");
    
    /* Kill any remaining processes */
    system("pkill -x smbd >/dev/null 2>&1");
    system("pkill -x nmbd >/dev/null 2>&1");
    
#elif defined(PLATFORM_FREEBSD)
    system("service samba_server stop");
    system("pkill -x smbd >/dev/null 2>&1");
    system("pkill -x nmbd >/dev/null 2>&1");
    
#elif defined(PLATFORM_NETBSD)
    system("service smbd stop");
    system("service nmbd stop");
    system("pkill -x smbd >/dev/null 2>&1");
    system("pkill -x nmbd >/dev/null 2>&1");
    
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop smbd");
    system("rcctl stop nmbd");
    system("pkill -x smbd >/dev/null 2>&1");
    system("pkill -x nmbd >/dev/null 2>&1");
#endif
    
    syslog(LOG_INFO, "sharing-helper: Samba service stopped");
    exit(0);
}

/* Web Server (nginx) status */
static void cmd_web_status(void)
{
#ifdef PLATFORM_LINUX
    if (check_service_running("nginx.service") ||
        check_service_running("nginx") ||
        (system("pgrep -x nginx >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#else
    if (check_service_running("nginx") ||
        (system("pgrep -x nginx >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#endif
    exit(0);
}

/* Web Server installed */
static void cmd_web_installed(void)
{
    if (binary_exists("nginx")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start nginx */
static void cmd_web_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting nginx");

    if (!binary_exists("nginx")) {
        fprintf(stderr, "nginx is not installed\n");
        syslog(LOG_ERR, "sharing-helper: nginx not found");
        exit(1);
    }

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        if (system("systemctl start nginx.service >/dev/null 2>&1") == 0) {
            system("systemctl enable nginx.service >/dev/null 2>&1");
            goto web_started;
        }
    }
    if (system("service nginx start >/dev/null 2>&1") == 0) {
        goto web_started;
    }
    if (system("test -x /etc/init.d/nginx && /etc/init.d/nginx start >/dev/null 2>&1") == 0) {
        goto web_started;
    }
    if (system("nginx >/dev/null 2>&1") == 0) {
        goto web_started;
    }
    fprintf(stderr, "Failed to start nginx\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start nginx");
    exit(1);
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("sysrc nginx_enable=YES");
    if (system("service nginx start") == 0) {
        goto web_started;
    }
    fprintf(stderr, "Failed to start nginx\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start nginx");
    exit(1);
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable nginx");
    if (system("rcctl start nginx") == 0) {
        goto web_started;
    }
    fprintf(stderr, "Failed to start nginx\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start nginx");
    exit(1);
#endif

web_started:
    syslog(LOG_INFO, "sharing-helper: nginx started");
    exit(0);
}

/* Stop nginx */
static void cmd_web_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping nginx");

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop nginx.service >/dev/null 2>&1");
    }
    system("service nginx stop >/dev/null 2>&1");
    system("test -x /etc/init.d/nginx && /etc/init.d/nginx stop >/dev/null 2>&1");
    system("pkill -x nginx >/dev/null 2>&1");
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("service nginx stop");
    system("pkill -x nginx >/dev/null 2>&1");
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop nginx");
    system("pkill -x nginx >/dev/null 2>&1");
#endif

    syslog(LOG_INFO, "sharing-helper: nginx stopped");
    exit(0);
}

/* Media Sharing (MiniDLNA/ReadyMedia) status */
static void cmd_media_status(void)
{
    /* Binary may be minidlna or minidlnad depending on distribution */
    int running = 0;
    running = (system("pgrep -x minidlna >/dev/null 2>&1") == 0) ||
              (system("pgrep -x minidlnad >/dev/null 2>&1") == 0);
#ifdef PLATFORM_LINUX
    if (!running) {
        running = check_service_running("minidlna.service") ||
                  check_service_running("minidlna");
    }
#else
    if (!running) {
        running = check_service_running("minidlna");
    }
#endif
    if (running) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
    exit(0);
}

/* Media Sharing installed */
static void cmd_media_installed(void)
{
    if (binary_exists("minidlna") || binary_exists("minidlnad")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start MiniDLNA */
static void cmd_media_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting MiniDLNA");

    if (!binary_exists("minidlna") && !binary_exists("minidlnad")) {
        fprintf(stderr, "MiniDLNA is not installed\n");
        syslog(LOG_ERR, "sharing-helper: MiniDLNA not found");
        exit(1);
    }

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        if (system("systemctl start minidlna.service >/dev/null 2>&1") == 0) {
            system("systemctl enable minidlna.service >/dev/null 2>&1");
            goto media_started;
        }
    }
    if (system("service minidlna start >/dev/null 2>&1") == 0) {
        goto media_started;
    }
    if (system("test -x /etc/init.d/minidlna && /etc/init.d/minidlna start >/dev/null 2>&1") == 0) {
        goto media_started;
    }
    /* Try direct invocation — binary may be minidlna or minidlnad */
    if (system("minidlnad >/dev/null 2>&1 &") == 0 ||
        system("minidlna >/dev/null 2>&1 &") == 0) {
        goto media_started;
    }
    fprintf(stderr, "Failed to start MiniDLNA\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start MiniDLNA");
    exit(1);
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("sysrc minidlna_enable=YES");
    if (system("service minidlna start") == 0) {
        goto media_started;
    }
    fprintf(stderr, "Failed to start MiniDLNA\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start MiniDLNA");
    exit(1);
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable minidlna");
    if (system("rcctl start minidlna") == 0) {
        goto media_started;
    }
    fprintf(stderr, "Failed to start MiniDLNA\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start MiniDLNA");
    exit(1);
#endif

media_started:
    syslog(LOG_INFO, "sharing-helper: MiniDLNA started");
    exit(0);
}

/* Stop MiniDLNA */
static void cmd_media_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping MiniDLNA");

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop minidlna.service >/dev/null 2>&1");
    }
    system("service minidlna stop >/dev/null 2>&1");
    system("test -x /etc/init.d/minidlna && /etc/init.d/minidlna stop >/dev/null 2>&1");
    system("pkill -x minidlna minidlnad >/dev/null 2>&1");
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("service minidlna stop");
    system("pkill -x minidlna minidlnad >/dev/null 2>&1");
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop minidlna");
    system("pkill -x minidlna minidlnad >/dev/null 2>&1");
#endif

    syslog(LOG_INFO, "sharing-helper: MiniDLNA stopped");
    exit(0);
}

/* Remote Desktop (xrdp) status */
static void cmd_rdp_status(void)
{
#ifdef PLATFORM_LINUX
    if (check_service_running("xrdp.service") ||
        check_service_running("xrdp") ||
        (system("pgrep -x xrdp >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#else
    if (check_service_running("xrdp") ||
        (system("pgrep -x xrdp >/dev/null 2>&1") == 0)) {
        printf("running\n");
    } else {
        printf("stopped\n");
    }
#endif
    exit(0);
}

/* Remote Desktop installed */
static void cmd_rdp_installed(void)
{
    if (binary_exists("xrdp")) {
        printf("installed\n");
    } else {
        printf("not-installed\n");
    }
    exit(0);
}

/* Start xrdp */
static void cmd_rdp_start(void)
{
    syslog(LOG_INFO, "sharing-helper: Starting xrdp");

    if (!binary_exists("xrdp")) {
        fprintf(stderr, "xrdp is not installed\n");
        syslog(LOG_ERR, "sharing-helper: xrdp not found");
        exit(1);
    }

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        if (system("systemctl start xrdp.service >/dev/null 2>&1") == 0) {
            system("systemctl enable xrdp.service >/dev/null 2>&1");
            goto rdp_started;
        }
    }
    if (system("service xrdp start >/dev/null 2>&1") == 0) {
        goto rdp_started;
    }
    if (system("test -x /etc/init.d/xrdp && /etc/init.d/xrdp start >/dev/null 2>&1") == 0) {
        goto rdp_started;
    }
    if (system("xrdp >/dev/null 2>&1 &") == 0) {
        goto rdp_started;
    }
    fprintf(stderr, "Failed to start xrdp\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start xrdp");
    exit(1);
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("sysrc xrdp_enable=YES");
    if (system("service xrdp start") == 0) {
        goto rdp_started;
    }
    fprintf(stderr, "Failed to start xrdp\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start xrdp");
    exit(1);
#elif defined(PLATFORM_OPENBSD)
    system("rcctl enable xrdp");
    if (system("rcctl start xrdp") == 0) {
        goto rdp_started;
    }
    fprintf(stderr, "Failed to start xrdp\n");
    syslog(LOG_ERR, "sharing-helper: Failed to start xrdp");
    exit(1);
#endif

rdp_started:
    syslog(LOG_INFO, "sharing-helper: xrdp started");
    exit(0);
}

/* Stop xrdp */
static void cmd_rdp_stop(void)
{
    syslog(LOG_INFO, "sharing-helper: Stopping xrdp");

#ifdef PLATFORM_LINUX
    if (system("which systemctl >/dev/null 2>&1") == 0) {
        system("systemctl stop xrdp.service >/dev/null 2>&1");
    }
    system("service xrdp stop >/dev/null 2>&1");
    system("test -x /etc/init.d/xrdp && /etc/init.d/xrdp stop >/dev/null 2>&1");
    system("pkill -x xrdp >/dev/null 2>&1");
#elif defined(PLATFORM_FREEBSD) || defined(PLATFORM_NETBSD)
    system("service xrdp stop");
    system("pkill -x xrdp >/dev/null 2>&1");
#elif defined(PLATFORM_OPENBSD)
    system("rcctl stop xrdp");
    system("pkill -x xrdp >/dev/null 2>&1");
#endif

    syslog(LOG_INFO, "sharing-helper: xrdp stopped");
    exit(0);
}

/* Usage */
static void usage(const char *progname)
{
    fprintf(stderr, "Usage: %s <command> [args]\n", progname);
    fprintf(stderr, "\nCommands:\n");
    fprintf(stderr, "  get-hostname          Get system hostname\n");
    fprintf(stderr, "  set-hostname <name>   Set system hostname\n");
    fprintf(stderr, "  ssh-status            Check SSH daemon status\n");
    fprintf(stderr, "  ssh-installed         Check if SSH daemon is installed\n");
    fprintf(stderr, "  ssh-start             Start SSH daemon\n");
    fprintf(stderr, "  ssh-stop              Stop SSH daemon\n");
    fprintf(stderr, "  x11-status            Check if sshd allows X11 forwarding\n");
    fprintf(stderr, "  x11-installed         Check if sshd and xauth are installed\n");
    fprintf(stderr, "  x11-start             Allow X11 forwarding in sshd_config\n");
    fprintf(stderr, "  x11-stop              Disallow X11 forwarding in sshd_config\n");
    fprintf(stderr, "  sftp-status           Check SFTP status\n");
    fprintf(stderr, "  sftp-installed        Check if SFTP subsystem is installed\n");
    fprintf(stderr, "  sftp-start            Start SFTP (enables SSH)\n");
    fprintf(stderr, "  sftp-stop             Stop SFTP announcement\n");
    fprintf(stderr, "  afp-status            Check AFP server status\n");
    fprintf(stderr, "  afp-installed         Check if AFP server (Netatalk) is installed\n");
    fprintf(stderr, "  afp-start             Start AFP server (Netatalk)\n");
    fprintf(stderr, "  afp-stop              Stop AFP server\n");
    fprintf(stderr, "  smb-status            Check Samba server status\n");
    fprintf(stderr, "  smb-installed         Check if Samba server is installed\n");
    fprintf(stderr, "  smb-start             Start Samba server\n");
    fprintf(stderr, "  smb-stop              Stop Samba server\n");
    fprintf(stderr, "  vnc-status            Check VNC server status\n");
    fprintf(stderr, "  vnc-installed         Check if VNC server is installed\n");
    fprintf(stderr, "  vnc-start             Start VNC server\n");
    fprintf(stderr, "  vnc-stop              Stop VNC server\n");
    fprintf(stderr, "  web-status            Check Web Server (nginx) status\n");
    fprintf(stderr, "  web-installed         Check if nginx is installed\n");
    fprintf(stderr, "  web-start             Start Web Server (nginx)\n");
    fprintf(stderr, "  web-stop              Stop Web Server (nginx)\n");
    fprintf(stderr, "  media-status          Check Media Sharing (MiniDLNA) status\n");
    fprintf(stderr, "  media-installed       Check if MiniDLNA is installed\n");
    fprintf(stderr, "  media-start           Start Media Sharing (MiniDLNA)\n");
    fprintf(stderr, "  media-stop            Stop Media Sharing (MiniDLNA)\n");
    fprintf(stderr, "  rdp-status            Check Remote Desktop (xrdp) status\n");
    fprintf(stderr, "  rdp-installed         Check if xrdp is installed\n");
    fprintf(stderr, "  rdp-start             Start Remote Desktop (xrdp)\n");
    fprintf(stderr, "  rdp-stop              Stop Remote Desktop (xrdp)\n");
    exit(1);
}

int main(int argc, char *argv[])
{
    openlog("sharing-helper", LOG_PID | LOG_CONS, LOG_USER);
    
    if (argc < 2) {
        usage(argv[0]);
    }
    
    const char *cmd = argv[1];
    
    /* Commands that don't require root */
    if (strcmp(cmd, "get-hostname") == 0) {
        cmd_get_hostname();
    } else if (strcmp(cmd, "ssh-status") == 0) {
        cmd_ssh_status();
    } else if (strcmp(cmd, "ssh-installed") == 0) {
        cmd_ssh_installed();
    } else if (strcmp(cmd, "x11-status") == 0) {
        cmd_x11_status();
    } else if (strcmp(cmd, "x11-installed") == 0) {
        cmd_x11_installed();
    } else if (strcmp(cmd, "sftp-status") == 0) {
        cmd_sftp_status();
    } else if (strcmp(cmd, "sftp-installed") == 0) {
        cmd_sftp_installed();
    } else if (strcmp(cmd, "afp-status") == 0) {
        cmd_afp_status();
    } else if (strcmp(cmd, "afp-installed") == 0) {
        cmd_afp_installed();
    } else if (strcmp(cmd, "smb-status") == 0) {
        cmd_smb_status();
    } else if (strcmp(cmd, "smb-installed") == 0) {
        cmd_smb_installed();
    } else if (strcmp(cmd, "vnc-status") == 0) {
        cmd_vnc_status();
    } else if (strcmp(cmd, "vnc-installed") == 0) {
        cmd_vnc_installed();
    } else if (strcmp(cmd, "web-status") == 0) {
        cmd_web_status();
    } else if (strcmp(cmd, "web-installed") == 0) {
        cmd_web_installed();
    } else if (strcmp(cmd, "media-status") == 0) {
        cmd_media_status();
    } else if (strcmp(cmd, "media-installed") == 0) {
        cmd_media_installed();
    } else if (strcmp(cmd, "rdp-status") == 0) {
        cmd_rdp_status();
    } else if (strcmp(cmd, "rdp-installed") == 0) {
        cmd_rdp_installed();
    }
    
    /* Commands that require root */
    if (geteuid() != 0) {
        fprintf(stderr, "Error: This operation requires root privileges\n");
        fprintf(stderr, "Please run with sudo: sudo %s %s\n", argv[0], cmd);
        syslog(LOG_ERR, "sharing-helper: Attempted privileged operation without root: %s", cmd);
        exit(1);
    }
    
    if (strcmp(cmd, "set-hostname") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: set-hostname requires a hostname argument\n");
            exit(1);
        }
        cmd_set_hostname(argv[2]);
    } else if (strcmp(cmd, "ssh-start") == 0) {
        cmd_ssh_start();
    } else if (strcmp(cmd, "ssh-stop") == 0) {
        cmd_ssh_stop();
    } else if (strcmp(cmd, "x11-start") == 0) {
        cmd_x11_set(1);
    } else if (strcmp(cmd, "x11-stop") == 0) {
        cmd_x11_set(0);
    } else if (strcmp(cmd, "sftp-start") == 0) {
        cmd_sftp_start();
    } else if (strcmp(cmd, "sftp-stop") == 0) {
        cmd_sftp_stop();
    } else if (strcmp(cmd, "afp-start") == 0) {
        cmd_afp_start();
    } else if (strcmp(cmd, "afp-stop") == 0) {
        cmd_afp_stop();
    } else if (strcmp(cmd, "smb-start") == 0) {
        cmd_smb_start();
    } else if (strcmp(cmd, "smb-stop") == 0) {
        cmd_smb_stop();
    } else if (strcmp(cmd, "vnc-start") == 0) {
        cmd_vnc_start();
    } else if (strcmp(cmd, "vnc-stop") == 0) {
        cmd_vnc_stop();
    } else if (strcmp(cmd, "web-start") == 0) {
        cmd_web_start();
    } else if (strcmp(cmd, "web-stop") == 0) {
        cmd_web_stop();
    } else if (strcmp(cmd, "media-start") == 0) {
        cmd_media_start();
    } else if (strcmp(cmd, "media-stop") == 0) {
        cmd_media_stop();
    } else if (strcmp(cmd, "rdp-start") == 0) {
        cmd_rdp_start();
    } else if (strcmp(cmd, "rdp-stop") == 0) {
        cmd_rdp_stop();
    } else {
        fprintf(stderr, "Error: Unknown command: %s\n", cmd);
        usage(argv[0]);
    }
    
    closelog();
    return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CrashHandler - GNUstep bundle loaded into every GUI app through GSAppKitUserBundles.
 *
 * A fatal signal or an uncaught Objective-C exception writes a report to ~/Library/Logs/<App>-crash-<time>-<pid>.txt
 * and to stderr.  The file is created inside the handler and never earlier, so a report file never exists empty.
 * Reports stay on this machine.
 *
 * Apps add context without linking anything by posting notifications:
 *   GSCrashHandlerBreadcrumbNotification   object: NSString, one line for the ring of recent actions
 *   GSCrashHandlerContextNotification      userInfo: @"key" and @"value" (NSString), a "current state" line
 */

/* REG_RIP and pthread_setname_np live behind this on glibc. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#import <AppKit/AppKit.h>
#include <objc/runtime.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__) || defined(__FreeBSD__)
#include <link.h>
#endif
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <ucontext.h>
#endif
#if defined(__has_include)
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define GS_HAVE_EXECINFO 1
#endif
#endif

/* A signal handler may only call async-signal-safe functions, so everything it prints comes from buffers that were
   filled in beforehand: the paths and identity at startup, the breadcrumbs and context as they happen. */
enum {
  kBreadcrumbCount = 64,
  kBreadcrumbLength = 160,
  kContextSlots = 16,
  kContextKeyLength = 32,
  kContextValueLength = 192,
  kAltStackSize = 128 * 1024,
  kMaxFrames = 64,
  kExceptionTextLength = 4096,
  kPathLength = 1024
};

@interface GSCrashHandler : NSObject
+ (void)crashNow;
+ (void)raiseTestException;
@end

static NSString *const GSCrashHandlerBreadcrumbNotification = @"GSCrashHandlerBreadcrumbNotification";
static NSString *const GSCrashHandlerContextNotification = @"GSCrashHandlerContextNotification";

static char gBreadcrumbs[kBreadcrumbCount][kBreadcrumbLength];
static atomic_uint gBreadcrumbSerial;
static char gContextKeys[kContextSlots][kContextKeyLength];
static char gContextValues[kContextSlots][kContextValueLength];
static char gLogDirectory[kPathLength];
static char gAppName[64];
static char gExecutablePath[kPathLength];
static char gSymbolizerPath[kPathLength];
static char gAppVersion[64];
static char gBuildId[80];
static char gLastReportedException[kExceptionTextLength];
static char gReportPath[kPathLength + 128];
static int gReportFd = -1;
static long gUtcOffset;
static pthread_t gMainThread;
static struct timespec gStartTime;
static char gAltStack[kAltStackSize];
static atomic_int gClaimed;
static atomic_int gFinished;
static pthread_mutex_t gContextLock = PTHREAD_MUTEX_INITIALIZER;

static const int gSignals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL};
#define kSignalCount (sizeof gSignals / sizeof gSignals[0])
static struct sigaction gPreviousActions[kSignalCount];
static NSUncaughtExceptionHandler *gBaseExceptionHandler;
static NSUncaughtExceptionHandler *gChainedExceptionHandler;
static atomic_int gExceptionSeen;

#pragma mark - async-signal-safe output

static void WriteBoth(const char *bytes, size_t length)
{
  if (gReportFd >= 0) {
    (void)!write(gReportFd, bytes, length);
  }
  (void)!write(STDERR_FILENO, bytes, length);
}

static void WriteString(const char *string)
{
  WriteBoth(string, strlen(string));
}

static size_t FormatUnsigned(char *out, unsigned long long value, unsigned base, unsigned minDigits)
{
  char digits[24];
  unsigned count = 0;
  do {
    digits[count++] = "0123456789abcdef"[value % base];
    value /= base;
  } while (value != 0 && count < sizeof digits);
  while (count < minDigits && count < sizeof digits) {
    digits[count++] = '0';
  }
  for (unsigned i = 0; i < count; i++) {
    out[i] = digits[count - 1 - i];
  }
  return count;
}

static void WriteUnsigned(unsigned long long value, unsigned base)
{
  char out[24];
  WriteBoth(out, FormatUnsigned(out, value, base, 1));
}

static void WriteHex(unsigned long long value)
{
  WriteString("0x");
  WriteUnsigned(value, 16);
}

static void WriteSigned(long long value)
{
  if (value < 0) {
    WriteString("-");
    value = -value;
  }
  WriteUnsigned((unsigned long long)value, 10);
}

static const char *SignalName(int signo)
{
  switch (signo) {
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGABRT: return "SIGABRT";
    case SIGFPE: return "SIGFPE";
    case SIGILL: return "SIGILL";
    default: return "signal";
  }
}

static unsigned long long CurrentThreadId(void)
{
#ifdef __linux__
  return (unsigned long long)syscall(SYS_gettid);
#else
  return (unsigned long long)(uintptr_t)pthread_self();
#endif
}

#pragma mark - report file

static void Append(char *buffer, size_t *length, size_t capacity, const char *text)
{
  size_t n = strlen(text);
  if (*length + n >= capacity) {
    n = capacity - *length - 1;
  }
  memcpy(buffer + *length, text, n);
  *length += n;
  buffer[*length] = '\0';
}

/* The calendar breakdown is done by hand because localtime() is not async-signal-safe; the zone offset was taken at
   startup, which is only wrong for a daylight saving switch while the app runs. */
static void FormatStamp(time_t when, char *out)
{
  long long seconds = (long long)when + gUtcOffset;
  long long days = seconds / 86400;
  long long rest = seconds % 86400;
  if (rest < 0) {
    rest += 86400;
    days--;
  }
  days += 719468;
  long long era = (days >= 0 ? days : days - 146096) / 146097;
  long long dayOfEra = days - era * 146097;
  long long yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365;
  long long year = yearOfEra + era * 400;
  long long dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
  long long mp = (5 * dayOfYear + 2) / 153;
  long long day = dayOfYear - (153 * mp + 2) / 5 + 1;
  long long month = mp < 10 ? mp + 3 : mp - 9;
  if (month <= 2) {
    year++;
  }
  size_t n = 0;
  n += FormatUnsigned(out + n, (unsigned long long)year, 10, 4);
  n += FormatUnsigned(out + n, (unsigned long long)month, 10, 2);
  n += FormatUnsigned(out + n, (unsigned long long)day, 10, 2);
  out[n++] = '-';
  n += FormatUnsigned(out + n, (unsigned long long)(rest / 3600), 10, 2);
  n += FormatUnsigned(out + n, (unsigned long long)(rest % 3600 / 60), 10, 2);
  n += FormatUnsigned(out + n, (unsigned long long)(rest % 60), 10, 2);
  out[n] = '\0';
}

/* O_EXCL so that an existing file is never appended to or truncated; a failure leaves the report on stderr only. */
static void OpenReportFile(void)
{
  if (gLogDirectory[0] == '\0') {
    return;
  }
  char stamp[32];
  FormatStamp(time(NULL), stamp);
  char pid[24];
  pid[FormatUnsigned(pid, (unsigned long long)getpid(), 10, 1)] = '\0';
  for (int attempt = 0; attempt < 10; attempt++) {
    size_t length = 0;
    gReportPath[0] = '\0';
    Append(gReportPath, &length, sizeof gReportPath, gLogDirectory);
    Append(gReportPath, &length, sizeof gReportPath, "/");
    Append(gReportPath, &length, sizeof gReportPath, gAppName);
    Append(gReportPath, &length, sizeof gReportPath, "-crash-");
    Append(gReportPath, &length, sizeof gReportPath, stamp);
    Append(gReportPath, &length, sizeof gReportPath, "-");
    Append(gReportPath, &length, sizeof gReportPath, pid);
    if (attempt > 0) {
      char suffix[3] = {'.', (char)('0' + attempt), '\0'};
      Append(gReportPath, &length, sizeof gReportPath, suffix);
    }
    Append(gReportPath, &length, sizeof gReportPath, ".txt");
    int fd = open(gReportPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd >= 0) {
      gReportFd = fd;
      return;
    }
    if (errno != EEXIST) {
      return;
    }
  }
}

/* One report per process: the first thread in writes, a second crashing thread waits for it instead of re-faulting
   into the default action while the file is still being written.  Returns YES for the thread that writes. */
static BOOL ClaimReport(void)
{
  if (atomic_exchange(&gClaimed, 1) == 0) {
    return YES;
  }
  struct timespec pause = {0, 10 * 1000 * 1000};
  for (int i = 0; i < 500 && atomic_load(&gFinished) == 0; i++) {
    nanosleep(&pause, NULL);
  }
  return NO;
}

static void FinishReport(void)
{
  if (gReportFd >= 0) {
    close(gReportFd);
    gReportFd = -1;
  }
  atomic_store(&gFinished, 1);
}

#pragma mark - report sections

/* The maps lines of every executable segment plus every offset-0 mapping, enough for addr2line on the executable and on
   each library offline; /proc does not exist on the BSDs, where the raw addresses and the image path have to do. */
static void WriteMaps(void)
{
#ifdef __linux__
  int fd = open("/proc/self/maps", O_RDONLY);
  if (fd < 0) {
    return;
  }
  char chunk[1024];
  char line[512];
  size_t lineLength = 0;
  ssize_t got;
  while ((got = read(fd, chunk, sizeof chunk)) > 0) {
    for (ssize_t i = 0; i < got; i++) {
      char c = chunk[i];
      if (c != '\n') {
        if (lineLength < sizeof line - 1) {
          line[lineLength++] = c;
        }
        continue;
      }
      line[lineLength] = '\0';
      if (strchr(line, '/') != NULL && (strstr(line, " r-xp ") != NULL || strstr(line, " 00000000 ") != NULL)) {
        WriteString("map ");
        WriteBoth(line, lineLength);
        WriteString("\n");
      }
      lineLength = 0;
    }
  }
  close(fd);
#endif
}

static void WriteBreadcrumbs(void)
{
  unsigned serial = atomic_load(&gBreadcrumbSerial);
  unsigned first = serial > kBreadcrumbCount ? serial - kBreadcrumbCount : 0;
  WriteString("--- last user actions (oldest first) ---\n");
  for (unsigned n = first; n < serial; n++) {
    WriteString("  ");
    WriteUnsigned(n, 10);
    WriteString(" ");
    WriteString(gBreadcrumbs[n % kBreadcrumbCount]);
    WriteString("\n");
  }
  if (serial == 0) {
    WriteString("  (none recorded)\n");
  }
  if (gLastReportedException[0] != '\0') {
    WriteString("--- last exception reported by the run loop (caught, the app went on) ---\n");
    WriteString(gLastReportedException);
  }
}

static void WriteHeader(const char *title)
{
  WriteString("=== ");
  WriteString(gAppName);
  WriteString(" crash report: ");
  WriteString(title);
  WriteString(" ===\nversion: ");
  WriteString(gAppVersion);
  WriteString("\nbuild id: ");
  WriteString(gBuildId);
  WriteString("\nexecutable: ");
  WriteString(gExecutablePath);
  WriteString("\npid: ");
  WriteSigned(getpid());
  WriteString("\nthread: ");
  WriteSigned((long long)CurrentThreadId());
#ifdef __linux__
  char name[32];
  memset(name, 0, sizeof name);
  prctl(PR_GET_NAME, name, 0, 0, 0);
  WriteString(" name=\"");
  WriteString(name);
  WriteString("\"");
#endif
  WriteString(pthread_equal(pthread_self(), gMainThread) ? " (main thread)" : " (secondary thread)");
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  WriteString("\nseconds since start: ");
  WriteSigned((long long)(now.tv_sec - gStartTime.tv_sec));
  WriteString("\n");
  for (int slot = 0; slot < kContextSlots; slot++) {
    if (gContextKeys[slot][0] == '\0') {
      continue;
    }
    WriteString(gContextKeys[slot]);
    WriteString(": ");
    WriteString(gContextValues[slot]);
    WriteString("\n");
  }
}

static void WriteBacktrace(void)
{
#ifdef GS_HAVE_EXECINFO
  void *frames[kMaxFrames];
  int count = backtrace(frames, kMaxFrames);
  WriteString("--- native backtrace (symbolize offline: sh ");
  WriteString(gSymbolizerPath);
  WriteString(" <this report>) ---\n");
  if (gReportFd >= 0) {
    backtrace_symbols_fd(frames, count, gReportFd);
  }
  backtrace_symbols_fd(frames, count, STDERR_FILENO);
#else
  WriteString("--- no native backtrace on this platform ---\n");
#endif
}

#pragma mark - signal handler

static void CrashSignalHandler(int signo, siginfo_t *info, void *context)
{
  /* An uncaught exception already reported itself; the abort() that follows it is the same crash. */
  if (atomic_load(&gExceptionSeen) != 0) {
    return;
  }
  if (ClaimReport()) {
    OpenReportFile();
    WriteHeader("fatal signal");
    WriteString("signal: ");
    WriteString(SignalName(signo));
    WriteString(" (");
    WriteSigned(signo);
    WriteString(") code ");
    WriteSigned(info != NULL ? info->si_code : 0);
    WriteString(" fault address ");
    WriteHex(info != NULL ? (unsigned long long)(uintptr_t)info->si_addr : 0);
    WriteString("\n");
#if defined(__linux__) && defined(__x86_64__)
    if (context != NULL) {
      WriteString("faulting pc: ");
      WriteHex((unsigned long long)((ucontext_t *)context)->uc_mcontext.gregs[REG_RIP]);
      WriteString("\n");
    }
#elif defined(__linux__) && defined(__aarch64__)
    if (context != NULL) {
      WriteString("faulting pc: ");
      WriteHex((unsigned long long)((ucontext_t *)context)->uc_mcontext.pc);
      WriteString("\n");
    }
#else
    (void)context;
#endif
    WriteBacktrace();
    WriteMaps();
    WriteBreadcrumbs();
    WriteString("=== end of report; the default action follows ===\n");
    FinishReport();
  }
  /* Whoever had the signal before us gets it too; with the default action, returning re-runs the fault (SA_RESETHAND
     restored it), so the exit status stays 128 plus the signal. */
  for (size_t i = 0; i < kSignalCount; i++) {
    if (gSignals[i] != signo) {
      continue;
    }
    struct sigaction *previous = &gPreviousActions[i];
    if (previous->sa_flags & SA_SIGINFO) {
      if (previous->sa_sigaction != NULL) {
        previous->sa_sigaction(signo, info, context);
      }
    } else if (previous->sa_handler != SIG_DFL && previous->sa_handler != SIG_IGN) {
      previous->sa_handler(signo);
    }
  }
}

#pragma mark - uncaught exceptions

static void UncaughtExceptionHandler(NSException *exception)
{
  /* The GUI library's handler re-raises after its alert panel, which lands here a second time; that one goes to the
     handler Foundation had, so the process ends the way it always did. */
  if (atomic_exchange(&gExceptionSeen, 1) != 0) {
    if (gBaseExceptionHandler != NULL && gBaseExceptionHandler != UncaughtExceptionHandler) {
      gBaseExceptionHandler(exception);
    }
    return;
  }
  /* Runs on an ordinary stack, so Foundation may be used. */
  if (ClaimReport()) {
    OpenReportFile();
    WriteHeader("uncaught Objective-C exception");
    NSString *text = [NSString stringWithFormat:@"exception: %@\nreason: %@\n--- call stack ---\n%@\n",
                                                [exception name], [exception reason],
                                                [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
    const char *utf8 = [text UTF8String];
    WriteBoth(utf8, strlen(utf8));
    /* Foundation's own stack can be short; the native one starts at the raising frame and symbolizes offline. */
    WriteBacktrace();
    WriteMaps();
    WriteBreadcrumbs();
    WriteString("=== end of exception report ===\n");
    FinishReport();
  }
  /* Before the alert panel of the GUI library, which blocks until the user answers. */
  if (gChainedExceptionHandler != NULL && gChainedExceptionHandler != UncaughtExceptionHandler) {
    gChainedExceptionHandler(exception);
  }
}

/* The run loop catches exceptions and only logs them; when such a program crashes later, the exception is the clue. */
static void (*gOriginalReportException)(id, SEL, NSException *);

static void ReportExceptionReplacement(id self, SEL command, NSException *exception)
{
  NSString *text = [NSString stringWithFormat:@"  %@: %@\n%@\n", [exception name], [exception reason],
                                              [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
  snprintf(gLastReportedException, sizeof gLastReportedException, "%s", [text UTF8String]);
  gOriginalReportException(self, command, exception);
}

#pragma mark - breadcrumbs and context

static void AddBreadcrumb(const char *text)
{
  unsigned serial = atomic_fetch_add(&gBreadcrumbSerial, 1);
  char *slot = gBreadcrumbs[serial % kBreadcrumbCount];
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  int prefix = snprintf(slot, kBreadcrumbLength, "[+%lds] ", (long)(now.tv_sec - gStartTime.tv_sec));
  snprintf(slot + prefix, (size_t)(kBreadcrumbLength - prefix), "%s", text);
}

static void SetContext(const char *key, const char *value)
{
  pthread_mutex_lock(&gContextLock);
  int slot = -1;
  for (int i = 0; i < kContextSlots; i++) {
    if (strncmp(gContextKeys[i], key, kContextKeyLength - 1) == 0 && gContextKeys[i][0] != '\0') {
      slot = i;
      break;
    }
    if (slot < 0 && gContextKeys[i][0] == '\0') {
      slot = i;
    }
  }
  if (slot >= 0) {
    /* Format on the side and copy, so the handler never sees a half-written value for longer than one memcpy. */
    char copy[kContextValueLength];
    snprintf(copy, sizeof copy, "%s", value);
    memcpy(gContextValues[slot], copy, sizeof copy);
    snprintf(gContextKeys[slot], kContextKeyLength, "%s", key);
  }
  pthread_mutex_unlock(&gContextLock);
}

static BOOL (*gOriginalSendAction)(id, SEL, SEL, id, id);

/* Every control and menu item goes through here, which makes it the one place that knows what the user just did. */
static BOOL SendActionReplacement(id self, SEL command, SEL action, id target, id sender)
{
  NSString *title = nil;
  if ([sender isKindOfClass:[NSMenuItem class]]) {
    title = [(NSMenuItem *)sender title];
  } else if ([sender respondsToSelector:@selector(title)]) {
    id candidate = [sender title];
    title = [candidate isKindOfClass:[NSString class]] ? candidate : nil;
  }
  char line[kBreadcrumbLength];
  snprintf(line, sizeof line, "action %s from %s \"%s\" to %s", action != NULL ? sel_getName(action) : "(nil)",
           sender != nil ? object_getClassName(sender) : "(nil)", [title UTF8String] ?: "",
           target != nil ? object_getClassName(target) : "(responder chain)");
  AddBreadcrumb(line);
  return gOriginalSendAction(self, command, action, target, sender);
}

static void ObserveApplication(void)
{
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserverForName:GSCrashHandlerBreadcrumbNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    id text = [note object];
                    if ([text isKindOfClass:[NSString class]]) {
                      AddBreadcrumb([text UTF8String]);
                    }
                  }];
  [center addObserverForName:GSCrashHandlerContextNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    id key = [[note userInfo] objectForKey:@"key"];
                    id value = [[note userInfo] objectForKey:@"value"];
                    if ([key isKindOfClass:[NSString class]]) {
                      SetContext([key UTF8String], [value isKindOfClass:[NSString class]] ? [value UTF8String] : "");
                    }
                  }];
  [center addObserverForName:NSWindowDidBecomeKeyNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    NSWindow *window = [note object];
                    const char *title = [[window title] UTF8String] ?: "";
                    char line[kBreadcrumbLength];
                    snprintf(line, sizeof line, "key window: %s (%s)", title, class_getName([window class]));
                    AddBreadcrumb(line);
                    SetContext("key window", title);
                    NSWindowController *controller = [window windowController];
                    if ([controller respondsToSelector:@selector(document)]) {
                      NSString *name = [[(id)controller document] displayName];
                      if (name != nil) {
                        SetContext("document", [name UTF8String]);
                      }
                    }
                  }];
  /* The GUI library installs its own exception handler during application initialization, after this bundle was
     loaded; taking over again once the app is up keeps the report ahead of its alert panel. */
  [center addObserverForName:NSApplicationDidFinishLaunchingNotification
                      object:nil
                       queue:nil
                  usingBlock:^(NSNotification *note) {
                    (void)note;
                    NSUncaughtExceptionHandler *current = NSGetUncaughtExceptionHandler();
                    if (current != UncaughtExceptionHandler) {
                      gChainedExceptionHandler = current;
                      NSSetUncaughtExceptionHandler(UncaughtExceptionHandler);
                    }
                    AddBreadcrumb("application finished launching");
                  }];
  Method send = class_getInstanceMethod([NSApplication class], @selector(sendAction:to:from:));
  if (send != NULL) {
    gOriginalSendAction = (BOOL(*)(id, SEL, SEL, id, id))(void *)method_getImplementation(send);
    method_setImplementation(send, (IMP)(void *)SendActionReplacement);
  }
  Method report = class_getInstanceMethod([NSApplication class], @selector(reportException:));
  if (report != NULL) {
    gOriginalReportException = (void (*)(id, SEL, NSException *))(void *)method_getImplementation(report);
    method_setImplementation(report, (IMP)(void *)ReportExceptionReplacement);
  }
}

#pragma mark - identity at startup

static void DiscoverExecutablePath(void)
{
#ifdef __linux__
  ssize_t length = readlink("/proc/self/exe", gExecutablePath, sizeof gExecutablePath - 1);
  if (length > 0) {
    gExecutablePath[length] = '\0';
    return;
  }
#endif
  NSString *path = [[NSBundle mainBundle] executablePath] ?: [[[NSProcessInfo processInfo] arguments] firstObject];
  snprintf(gExecutablePath, sizeof gExecutablePath, "%s", [path fileSystemRepresentation] ?: "(unknown)");
}

#if defined(__linux__) || defined(__FreeBSD__)
/* The first object dl_iterate_phdr reports is the executable; its GNU build id ties the report to the exact binary. */
static int FindBuildId(struct dl_phdr_info *info, size_t size, void *data)
{
  (void)size;
  (void)data;
  for (int i = 0; i < info->dlpi_phnum; i++) {
    const ElfW(Phdr) *header = &info->dlpi_phdr[i];
    if (header->p_type != PT_NOTE) {
      continue;
    }
    const char *cursor = (const char *)(info->dlpi_addr + header->p_vaddr);
    const char *end = cursor + header->p_memsz;
    while (cursor + sizeof(ElfW(Nhdr)) <= end) {
      const ElfW(Nhdr) *note = (const ElfW(Nhdr) *)cursor;
      const char *name = cursor + sizeof *note;
      const unsigned char *desc = (const unsigned char *)(name + ((note->n_namesz + 3) & ~3u));
      if (note->n_type == 3 && note->n_namesz == 4 && strcmp(name, "GNU") == 0) {
        size_t length = 0;
        for (size_t b = 0; b < note->n_descsz && length + 2 < sizeof gBuildId; b++) {
          length += FormatUnsigned(gBuildId + length, desc[b], 16, 2);
        }
        gBuildId[length] = '\0';
        return 1;
      }
      cursor = (const char *)desc + ((note->n_descsz + 3) & ~3u);
    }
  }
  return 1;
}
#endif

static void CollectIdentity(void)
{
  snprintf(gBuildId, sizeof gBuildId, "(none)");
#if defined(__linux__) || defined(__FreeBSD__)
  dl_iterate_phdr(FindBuildId, NULL);
#endif
  NSString *name = [[NSProcessInfo processInfo] processName];
  NSMutableString *safe = [NSMutableString string];
  for (NSUInteger i = 0; i < [name length] && i < sizeof gAppName - 1; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    [safe appendString:plain ? [NSString stringWithCharacters:&c length:1] : @"_"];
  }
  snprintf(gAppName, sizeof gAppName, "%s", [safe length] > 0 ? [safe UTF8String] : "app");
  NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
  NSString *version = [info objectForKey:@"CFBundleShortVersionString"] ?: [info objectForKey:@"CFBundleVersion"];
  snprintf(gAppVersion, sizeof gAppVersion, "%s", version != nil ? [version UTF8String] : "(unknown)");
  NSString *script = [[NSBundle bundleForClass:NSClassFromString(@"GSCrashHandler")] pathForResource:@"symbolize" ofType:@"sh"];
  snprintf(gSymbolizerPath, sizeof gSymbolizerPath, "%s", script != nil ? [script fileSystemRepresentation] : "symbolize.sh");
  DiscoverExecutablePath();
  /* The environment variable lets a test keep its reports out of the real log directory. */
  const char *override = getenv("GSCrashHandlerDir");
  NSString *logs = override != NULL ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:override length:strlen(override)]
                                    : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
  /* Created now because mkdir is not something the handler may do. */
  if ([[NSFileManager defaultManager] createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:NULL]) {
    snprintf(gLogDirectory, sizeof gLogDirectory, "%s", [logs fileSystemRepresentation]);
  }
  time_t now = time(NULL);
  struct tm local;
  localtime_r(&now, &local);
  gUtcOffset = local.tm_gmtoff;
}

static void InstallSignalHandlers(void)
{
  /* The stack of the thread that overflowed is the one thing the handler cannot run on.  An alternate stack belongs
     to one thread; secondary threads run the handler on their own stack, which is fine for anything but an overflow. */
  stack_t stack;
  memset(&stack, 0, sizeof stack);
  stack.ss_sp = gAltStack;
  stack.ss_size = sizeof gAltStack;
  sigaltstack(&stack, NULL);
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_sigaction = CrashSignalHandler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
  sigemptyset(&action.sa_mask);
  for (size_t i = 0; i < kSignalCount; i++) {
    sigaction(gSignals[i], &action, &gPreviousActions[i]);
  }
}

#pragma mark - deliberate crashes

static void *CrashOnThread(void *arg)
{
#ifdef __linux__
  pthread_setname_np(pthread_self(), "crash-test");
#endif
  *(volatile int *)0 = 1;
  return arg;
}

__attribute__((noinline)) static int RecurseForever(int depth)
{
  volatile char pad[4096];
  pad[0] = (char)depth;
  if (depth < 0) {
    return 0;
  }
  return RecurseForever(depth + 1) + pad[0];
}

/* GSCrashHandlerTest=segv|abort|nsexception|stackoverflow|thread-segv crashes the app once its run loop is going,
   which is how the reporter is verified in any app; unset, nothing happens. */
static void CrashIfRequested(void)
{
  const char *kind = getenv("GSCrashHandlerTest");
  if (kind == NULL || kind[0] == '\0') {
    return;
  }
  char line[kBreadcrumbLength];
  snprintf(line, sizeof line, "deliberate crash test: %s", kind);
  AddBreadcrumb(line);
  if (strcmp(kind, "segv") == 0) {
    *(volatile int *)0 = 1;
  } else if (strcmp(kind, "abort") == 0) {
    abort();
  } else if (strcmp(kind, "stackoverflow") == 0) {
    RecurseForever(0);
  } else if (strcmp(kind, "thread-segv") == 0) {
    pthread_t thread;
    pthread_create(&thread, NULL, CrashOnThread, NULL);
    pthread_join(thread, NULL);
  } else if (strcmp(kind, "nsexception") == 0) {
    /* The run loop would catch an exception raised on the main thread, so this one is raised where nothing does. */
    [NSThread detachNewThreadSelector:@selector(raiseTestException) toTarget:[GSCrashHandler class] withObject:nil];
    [NSThread sleepForTimeInterval:30];
  }
}

#pragma mark - the bundle

@implementation GSCrashHandler

+ (void)crashNow
{
  CrashIfRequested();
}

+ (void)raiseTestException
{
  [NSException raise:@"GSCrashHandlerTest" format:@"deliberate exception"];
}

/* Instantiated once by gsapp_user_bundles() while NSApplication initializes. */
- (instancetype)init
{
  self = [super init];
  static BOOL installed;
  if (self == nil || installed || [[NSUserDefaults standardUserDefaults] boolForKey:@"GSCrashHandlerDisabled"]) {
    return self;
  }
  installed = YES;
  clock_gettime(CLOCK_MONOTONIC, &gStartTime);
  gMainThread = pthread_self();
  CollectIdentity();
#ifdef GS_HAVE_EXECINFO
  /* The first backtrace() call loads libgcc and may allocate; do it now rather than inside the handler. */
  void *prime[2];
  backtrace(prime, 2);
#endif
  InstallSignalHandlers();
  gBaseExceptionHandler = NSGetUncaughtExceptionHandler();
  gChainedExceptionHandler = gBaseExceptionHandler;
  NSSetUncaughtExceptionHandler(UncaughtExceptionHandler);
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GSCrashHandlerEnableCoreDumps"]) {
    struct rlimit limit = {RLIM_INFINITY, RLIM_INFINITY};
    setrlimit(RLIMIT_CORE, &limit);
  }
  ObserveApplication();
  char line[kBreadcrumbLength];
  snprintf(line, sizeof line, "started pid %d", (int)getpid());
  AddBreadcrumb(line);
  /* Not from inside the launch notification, whose exceptions the run loop would swallow. */
  if (getenv("GSCrashHandlerTest") != NULL) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                    (void)note;
                                                    [GSCrashHandler performSelector:@selector(crashNow) withObject:nil afterDelay:0.5];
                                                  }];
  }
  return self;
}

@end

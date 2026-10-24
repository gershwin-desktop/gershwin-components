/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashAnalyzer.h"
#import "GSCrashReport.h"
#import "GSCrashConstants.h"
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>

@interface GSCrashAnalyzer ()

@property (nonatomic, copy) NSString *executableHint;
@property (nonatomic, copy) NSString *coreHint;
@property (nonatomic, assign) NSTimeInterval timeout;

/* The raw, unfiltered debugger log, accumulated across runs. */
@property (nonatomic, copy) NSString *rawLog;

@end

@implementation GSCrashAnalyzer

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _timeout = 60.0;
    }
    return self;
}

- (void)setExecutableHint:(NSString *)path { _executableHint = [path copy]; }
- (void)setCoreHint:(NSString *)path { _coreHint = [path copy]; }
- (void)setTimeoutSeconds:(NSTimeInterval)seconds { _timeout = (seconds > 0) ? seconds : 60.0; }

/* ------------------------------------------------------------------ */
/* Entry point                                                         */
/* ------------------------------------------------------------------ */

- (BOOL)analyzeCrashDirectory:(NSString *)dir error:(NSError **)error
{
    dir = [dir stringByStandardizingPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir])
    {
        [self setError:error code:1 message:@"crash directory does not exist: %@", dir];
        return NO;
    }

    GSCrashReport *report = [self loadExistingReportFromDirectory:dir];
    if (report == nil)
        report = [GSCrashReport report];

    [self loadMetadataInto:report directory:dir];

    /* Resolve the executable. */
    NSString *executable = report.executablePath ?: self.executableHint;
    if (executable == nil)
    {
        NSDictionary *meta = [self readJSON:[dir stringByAppendingPathComponent:GSCrashMetadataFile]];
        executable = meta[@"executable"];
    }
    if (executable == nil)
    {
        NSString *core = [self corePathIn:dir];
        if (core != nil)
            executable = [self deriveExecutableFromCore:core];
    }
    if (executable != nil && [fm fileExistsAtPath:executable])
        report.executablePath = executable;

    /* Resolve the core. */
    NSString *core = [self corePathIn:dir];

    /* Fill system fields if missing. */
    [self fillSystemFields:report];

    if (core != nil && report.executablePath != nil)
    {
        NSString *log = [self runDebuggerWithCore:core executable:report.executablePath];
        _rawLog = log;
        if (log != nil && [log length] > 0)
        {
            [self parseDebuggerLog:log into:report];
            report.coreAvailable = YES;
            report.coreDumpPath = GSCrashCoreFile;
            struct stat st;
            if (stat([core fileSystemRepresentation], &st) == 0)
                report.coreDumpSize = (long long)st.st_size;
        }
        else
        {
            report.coreAvailable = NO;
            report.coreUnavailableReason = @"the debugger could not read the core file.";
        }
    }
    else
    {
        report.coreAvailable = NO;
        if (core == nil)
            report.coreUnavailableReason = @"no core dump was produced.";
        else
            report.coreUnavailableReason = @"the executable required to analyze the core is missing.";
    }

    [self applyClassification:report];
    [self applyDiagnosis:report];

    /* Write the sidecar artifacts. */
    [self writeSidecars:report directory:dir];

    BOOL ok = [report writeToDirectory:dir];
    if (!ok && error)
        [self setError:error code:2 message:@"failed to write report.json in %@", dir];

    /* The shared library's dictionaryRepresentation omits the top-level
       `backtrace` array (it keeps frames only inside `threads`), so we
       re-inject the crashing-thread backtrace into report.json ourselves. */
    if (ok && [report.backtrace count])
        [self augmentReportJSON:dir withBacktrace:report.backtrace];

    return ok;
}

/* ------------------------------------------------------------------ */
/* Metadata / system fields                                            */
/* ------------------------------------------------------------------ */

- (GSCrashReport *)loadExistingReportFromDirectory:(NSString *)dir
{
    /* The shared library's reportFromDirectory/populateFromDictionary
       over-releases the loaded object graph under ARC, so we map the
       canonical report.json keys onto a freshly created report ourselves. */
    GSCrashReport *r = [GSCrashReport report];

    NSString *jsonPath = [dir stringByAppendingPathComponent:GSCrashReportJSON];
    NSData *data = [NSData dataWithContentsOfFile:jsonPath];
    if (data == nil)
        return r;
    NSError *e = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0 error:&e];
    if (![dict isKindOfClass:[NSDictionary class]])
        return r;

    NSDictionary *app = dict[@"application"];
    if ([app isKindOfClass:[NSDictionary class]])
    {
        if ([app[@"name"] isKindOfClass:[NSString class]]) r.applicationName = app[@"name"];
        if ([app[@"version"] isKindOfClass:[NSString class]]) r.applicationVersion = app[@"version"];
        if ([app[@"pid"] isKindOfClass:[NSNumber class]]) r.pid = [app[@"pid"] intValue];
        if ([app[@"executable"] isKindOfClass:[NSString class]]) r.executablePath = app[@"executable"];
    }
    NSDictionary *sys = dict[@"system"];
    if ([sys isKindOfClass:[NSDictionary class]])
    {
        if ([sys[@"os"] isKindOfClass:[NSString class]]) r.osName = sys[@"os"];
        if ([sys[@"os_version"] isKindOfClass:[NSString class]]) r.osVersion = sys[@"os_version"];
        if ([sys[@"architecture"] isKindOfClass:[NSString class]]) r.architecture = sys[@"architecture"];
        if ([sys[@"hostname"] isKindOfClass:[NSString class]]) r.hostname = sys[@"hostname"];
        if ([sys[@"gnustep_base"] isKindOfClass:[NSString class]]) r.gnustepBaseVersion = sys[@"gnustep_base"];
        if ([sys[@"gnustep_gui"] isKindOfClass:[NSString class]]) r.gnustepGuiVersion = sys[@"gnustep_gui"];
        if ([sys[@"build_id"] isKindOfClass:[NSString class]]) r.buildID = sys[@"build_id"];
        if ([sys[@"uid"] isKindOfClass:[NSNumber class]]) r.uid = [sys[@"uid"] unsignedIntValue];
    }
    NSDictionary *crash = dict[@"crash"];
    if ([crash isKindOfClass:[NSDictionary class]])
    {
        if ([crash[@"signal"] isKindOfClass:[NSString class]]) r.signal = crash[@"signal"];
        if ([crash[@"exception"] isKindOfClass:[NSString class]]) r.exceptionName = crash[@"exception"];
        if ([crash[@"exception_reason"] isKindOfClass:[NSString class]]) r.exceptionReason = crash[@"exception_reason"];
        if ([crash[@"fault_address"] isKindOfClass:[NSString class]]) r.faultAddress = crash[@"fault_address"];
        if ([crash[@"thread"] isKindOfClass:[NSNumber class]]) r.crashingThread = [crash[@"thread"] integerValue];
        if ([crash[@"instruction_pointer"] isKindOfClass:[NSString class]]) r.instructionPointer = crash[@"instruction_pointer"];
        if ([crash[@"stack_pointer"] isKindOfClass:[NSString class]]) r.stackPointer = crash[@"stack_pointer"];
        if ([crash[@"signal_info"] isKindOfClass:[NSString class]]) r.signalInfo = crash[@"signal_info"];
        if ([crash[@"detection_method"] isKindOfClass:[NSString class]]) r.detectionMethod = crash[@"detection_method"];
        if ([crash[@"collector"] isKindOfClass:[NSString class]]) r.collector = crash[@"collector"];
        if ([crash[@"timestamp"] isKindOfClass:[NSString class]])
            r.timestamp = [NSDate dateWithTimeIntervalSince1970:[crash[@"timestamp"] doubleValue]];
    }
    NSDictionary *analysis = dict[@"analysis"];
    if ([analysis isKindOfClass:[NSDictionary class]])
    {
        if ([analysis[@"classification"] isKindOfClass:[NSString class]]) r.classification = analysis[@"classification"];
        if ([analysis[@"diagnosis"] isKindOfClass:[NSString class]]) r.diagnosis = analysis[@"diagnosis"];
        if ([analysis[@"confidence"] isKindOfClass:[NSString class]]) r.diagnosisConfidence = analysis[@"confidence"];
        if ([analysis[@"symbolicated"] isKindOfClass:[NSNumber class]]) r.symbolsAvailable = [analysis[@"symbolicated"] boolValue];
        if ([analysis[@"core_available"] isKindOfClass:[NSNumber class]]) r.coreAvailable = [analysis[@"core_available"] boolValue];
        if ([analysis[@"core_unavailable_reason"] isKindOfClass:[NSString class]]) r.coreUnavailableReason = analysis[@"core_unavailable_reason"];
    }
    /* Collection fields (threads/registers/modules/backtrace) are intentionally
       NOT carried over from the stored file: they are re-derived from the core
       by the debugger each run, which is authoritative, and copying the
       JSON-originated collection objects into the report triggers an
       over-release in this ARC/GNUstep configuration. Scalar fields below are
       safe and preserved. */


    NSDictionary *files = dict[@"files"];
    if ([files isKindOfClass:[NSDictionary class]])
    {
        if ([files[@"core"] isKindOfClass:[NSString class]]) r.coreDumpPath = files[@"core"];
        if ([files[@"core_size"] isKindOfClass:[NSNumber class]]) r.coreDumpSize = [files[@"core_size"] longLongValue];
        if ([files[@"directory"] isKindOfClass:[NSString class]]) r.crashDirectory = files[@"directory"];
    }
    if (r.crashDirectory == nil)
        r.crashDirectory = dir;
    return r;
}

- (void)loadMetadataInto:(GSCrashReport *)report directory:(NSString *)dir
{
    NSDictionary *meta = [self readJSON:[dir stringByAppendingPathComponent:GSCrashMetadataFile]];
    if (![meta isKindOfClass:[NSDictionary class]])
        return;

    if (report.executablePath == nil && [meta[@"executable"] isKindOfClass:[NSString class]])
        report.executablePath = meta[@"executable"];
    if (report.pid == 0 && [meta[@"pid"] isKindOfClass:[NSNumber class]])
        report.pid = [meta[@"pid"] intValue];
    if (report.signal == nil && [meta[@"signal"] isKindOfClass:[NSString class]])
        report.signal = meta[@"signal"];
    if (report.exceptionName == nil && [meta[@"exception"] isKindOfClass:[NSString class]])
        report.exceptionName = meta[@"exception"];
    if (report.exceptionReason == nil && [meta[@"reason"] isKindOfClass:[NSString class]])
        report.exceptionReason = meta[@"reason"];
    if (report.timestamp == nil && [meta[@"timestamp"] isKindOfClass:[NSString class]])
    {
        NSTimeInterval ti = [meta[@"timestamp"] doubleValue];
        if (ti > 0)
            report.timestamp = [NSDate dateWithTimeIntervalSince1970:ti];
    }
    if (report.applicationName == nil)
    {
        NSString *exe = report.executablePath ?: meta[@"executable"];
        if (exe != nil)
            report.applicationName = [exe lastPathComponent];
    }
}

- (void)fillSystemFields:(GSCrashReport *)report
{
    if (report.osName == nil) report.osName = GSCrashOSName();
    if (report.osVersion == nil) report.osVersion = GSCrashOSVersion();
    if (report.architecture == nil) report.architecture = GSCrashArchitecture();
    if (report.gnustepBaseVersion == nil) report.gnustepBaseVersion = GSCrashGNUstepBaseVersion();
    if (report.gnustepGuiVersion == nil) report.gnustepGuiVersion = GSCrashGNUstepGUIVersion();
    if (report.hostname == nil)
    {
        NSString *h = [[NSProcessInfo processInfo] hostName];
        if (h == nil || [h length] == 0)
        {
            char buf[256] = {0};
            if (gethostname(buf, sizeof(buf)) == 0)
                h = @(buf);
        }
        report.hostname = h;
    }
    if (report.timestamp == nil)
        report.timestamp = [NSDate date];
}

/* ------------------------------------------------------------------ */
/* Core / executable resolution                                        */
/* ------------------------------------------------------------------ */

- (NSString *)corePathIn:(NSString *)dir
{
    if (self.coreHint != nil)
        return self.coreHint;
    NSString *p = [dir stringByAppendingPathComponent:GSCrashCoreFile];
    if ([[NSFileManager defaultManager] fileExistsAtPath:p])
        return p;
    return nil;
}

- (NSString *)deriveExecutableFromCore:(NSString *)core
{
    NSString *outp = [self runDebugger:@[@"-batch", @"-nx", @"-ex", @"set pagination off",
                                         @"-ex", @"info proc", @"-c", core]
                            executable:nil];
    if (outp == nil)
        return nil;
    /* "Exec file: '/path/to/exe'" appears in "info proc". */
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"Exec file:\\s*'([^']+)'"
                                                  options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:outp
                                             options:0
                                               range:NSMakeRange(0, [outp length])];
    if (m != nil)
        return [outp substringWithRange:[m rangeAtIndex:1]];
    return nil;
}

/* ------------------------------------------------------------------ */
/* Debugger execution                                                  */
/* ------------------------------------------------------------------ */

/* Sentinel markers let us split the unfiltered batch log into known sections
   even though gdb does not echo the -ex commands in batch mode. */
static NSString *const kMarkProc    = @"===GSCRASH_PROC===";
static NSString *const kMarkRegs    = @"===GSCRASH_REGISTERS===";
static NSString *const kMarkBt      = @"===GSCRASH_BT===";
static NSString *const kMarkThreads = @"===GSCRASH_THREADS===";
static NSString *const kMarkLibs    = @"===GSCRASH_LIBS===";
static NSString *const kMarkSiginfo = @"===GSCRASH_SIGINFO===";

- (NSString *)runDebuggerWithCore:(NSString *)core executable:(NSString *)executable
{
    NSArray *gdbArgs = @[@"-batch", @"-nx",
                         @"-ex", @"set pagination off",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkProc UTF8String]],
                         @"-ex", @"info proc",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkRegs UTF8String]],
                         @"-ex", @"info registers",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkSiginfo UTF8String]],
                         @"-ex", @"p/x $_siginfo._sifields._sigfault.si_addr",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkBt UTF8String]],
                         @"-ex", @"bt",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkThreads UTF8String]],
                         @"-ex", @"thread apply all bt",
                         @"-ex", [NSString stringWithFormat:@"printf \"\\n%s\\n\"", [kMarkLibs UTF8String]],
                         @"-ex", @"info sharedlibrary",
                         @"-c", core, executable];
    NSString *outp = [self runDebugger:gdbArgs executable:executable];
    if (outp != nil)
        return outp;
    if ([self debuggerAvailable:@"/bin/gdb"])
        return nil;
    /* Fall back to lldb when gdb is missing. lldb layout differs and the
       sentinels are harmless extra output there. */
    NSArray *lldbArgs = @[@"-c", core, executable,
                          @"-b",
                          @"-o", @"settings set use-color false",
                          @"-o", @"bt all",
                          @"-o", @"image list",
                          @"-o", @"register read"];
    return [self runDebugger:lldbArgs executable:executable];
}

- (BOOL)debuggerAvailable:(NSString *)path
{
    return [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

- (NSString *)runDebugger:(NSArray *)args executable:(NSString *)executable
{
    NSString *tool = @"/bin/gdb";
    if (![self debuggerAvailable:tool])
        tool = @"/bin/lldb";
    if (![self debuggerAvailable:tool])
        return nil;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:tool];
    [task setArguments:args];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[task standardOutput]];

    NSError *launchErr = nil;
    @try
    {
        [task launch];
    }
    @catch (NSException *e)
    {
        return nil;
    }
    if (launchErr != nil)
        return nil;

    /* Watchdog: enforce the wall-clock timeout so a pathological core cannot
       hang the analyzer (SPEC section 15). Control flags live on the heap
       (never on this stack frame and never as an Objective-C object) so the
       watchdog thread can be cleanly joined before this method returns,
       avoiding cross-thread over-release under ARC. */
    typedef struct {
        volatile BOOL stop;
        volatile BOOL done;
        volatile BOOL killed;
        pid_t pid;
        NSTimeInterval to;
    } GSWatch;
    GSWatch *w = calloc(1, sizeof(GSWatch));
    w->pid = [task processIdentifier];
    w->to = self.timeout;
    NSThread *wd = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool
        {
            NSTimeInterval remaining = w->to;
            while (!w->stop && remaining > 0)
            {
                NSTimeInterval slice = (remaining > 0.25) ? 0.25 : remaining;
                [NSThread sleepForTimeInterval:slice];
                remaining -= slice;
            }
            if (!w->stop && kill(w->pid, 0) == 0)
            {
                kill(w->pid, SIGKILL);
                w->killed = YES;
            }
            w->done = YES;
        }
    }];
    [wd start];

    NSData *data = [[[task standardOutput] fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    /* Stop and join the watchdog before touching anything it referenced. */
    w->stop = YES;
    while (!w->done)
        [NSThread sleepForTimeInterval:0.01];
    BOOL killed = w->killed;
    free(w);

    if (killed)
        return nil;

    if (data == nil)
        return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/* ------------------------------------------------------------------ */
/* Parsing                                                             */
/* ------------------------------------------------------------------ */

- (NSString *)section:(NSString *)marker inLog:(NSString *)log
{
    NSRange start = [log rangeOfString:marker];
    if (start.location == NSNotFound)
        return nil;
    NSUInteger from = start.location + start.length;
    NSRange end = [log rangeOfString:@"===GSCRASH_"
                              options:0
                                range:NSMakeRange(from, [log length] - from)];
    NSUInteger to = (end.location == NSNotFound) ? [log length] : end.location;
    return [log substringWithRange:NSMakeRange(from, to - from)];
}

- (void)parseDebuggerLog:(NSString *)log into:(GSCrashReport *)report
{
    [self parseBanner:log into:report];

    NSString *regs = [self section:kMarkRegs inLog:log];
    [self parseRegisters:regs into:report];

    NSString *siginfo = [self section:kMarkSiginfo inLog:log];
    [self parseSiginfo:siginfo into:report];

    NSString *bt = [self section:kMarkBt inLog:log];
    NSMutableArray<NSString *> *btFrames = [self parseFrames:bt];

    NSString *threads = [self section:kMarkThreads inLog:log];
    NSMutableArray<NSMutableDictionary *> *threadList = [self parseThreads:threads];

    NSString *libs = [self section:kMarkLibs inLog:log];
    NSArray<NSString *> *libList = [self parseLibraries:libs];

    if ([btFrames count])
        report.backtrace = btFrames;

    if ([threadList count] == 0 && [btFrames count])
    {
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        t[@"id"] = @(1);
        t[@"crashed"] = @YES;
        t[@"frames"] = btFrames;
        [threadList addObject:t];
        report.crashingThread = 1;
    }
    if ([threadList count])
    {
        report.threads = threadList;
        if ([btFrames count])
        {
            NSString *top = [btFrames firstObject];
            for (NSMutableDictionary *t in threadList)
            {
                NSArray *frames = t[@"frames"];
                if ([frames count] && [[frames firstObject] isEqualToString:top])
                {
                    t[@"crashed"] = @YES;
                    report.crashingThread = [t[@"id"] integerValue];
                    break;
                }
            }
        }
        if (report.crashingThread < 0)
        {
            for (NSMutableDictionary *t in threadList)
            {
                if ([t[@"frames"] count])
                {
                    t[@"crashed"] = @YES;
                    report.crashingThread = [t[@"id"] integerValue];
                    break;
                }
            }
        }
    }

    /* Symbols available if any frame resolved to file:line. */
    BOOL symbols = NO;
    NSMutableArray<NSString *> *allFrames = [NSMutableArray arrayWithArray:btFrames];
    for (NSDictionary *t in threadList)
        [allFrames addObjectsFromArray:t[@"frames"]];
    for (NSString *f in allFrames)
    {
        if ([f rangeOfString:@".c:"].location != NSNotFound ||
            [f rangeOfString:@".m:"].location != NSNotFound ||
            [f rangeOfString:@" at "].location != NSNotFound)
        {
            symbols = YES;
            break;
        }
    }
    report.symbolsAvailable = symbols;

    if ([libList count])
        report.loadedLibraries = libList;
}

- (void)parseBanner:(NSString *)log into:(GSCrashReport *)report
{
    NSRegularExpression *sigRe =
        [NSRegularExpression regularExpressionWithPattern:
            @"Program terminated with signal\\s+([A-Z]+)(?:,\\s*fault address\\s+(\\S+))?"
                                                  options:0 error:nil];
    NSTextCheckingResult *m = [sigRe firstMatchInString:log
                                                options:0
                                                  range:NSMakeRange(0, [log length])];
    if (m != nil)
    {
        NSString *sig = [log substringWithRange:[m rangeAtIndex:1]];
        if (report.signal == nil || [report.signal length] == 0)
            report.signal = sig;
        if ([m rangeAtIndex:2].location != NSNotFound)
        {
            NSString *fa = [log substringWithRange:[m rangeAtIndex:2]];
            report.faultAddress = fa;
        }
    }
}

- (void)parseSiginfo:(NSString *)section into:(GSCrashReport *)report
{
    if (section == nil || [section length] == 0)
        return;
    /* gdb prints "$N = 0x..." for `p/x $_siginfo.si_addr`. */
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"=\\s*(0x[0-9a-fA-F]+)"
                                                  options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:section
                                             options:0
                                               range:NSMakeRange(0, [section length])];
    if (m != nil)
    {
        NSString *fa = [section substringWithRange:[m rangeAtIndex:1]];
        if (report.faultAddress == nil || [report.faultAddress length] == 0)
            report.faultAddress = fa;
    }
}

- (void)parseRegisters:(NSString *)section into:(GSCrashReport *)report
{
    if (section == nil)
        return;
    NSMutableArray<NSString *> *registers = [NSMutableArray array];
    NSString *r15val = nil;
    NSRegularExpression *regRe =
        [NSRegularExpression regularExpressionWithPattern:@"^\\s*([a-z0-9]+)\\s+(0x[0-9a-f]+)"
                                                  options:0 error:nil];
    for (NSString *line in [section componentsSeparatedByString:@"\n"])
    {
        if ([line hasPrefix:@"#"])
            continue;
        NSTextCheckingResult *m = [regRe firstMatchInString:line
                                                    options:0
                                                      range:NSMakeRange(0, [line length])];
        if (m != nil)
        {
            NSString *name = [line substringWithRange:[m rangeAtIndex:1]];
            NSString *val = [line substringWithRange:[m rangeAtIndex:2]];
            [registers addObject:[NSString stringWithFormat:@"%@=%@", name, val]];
            /* Prefer the real instruction pointer (rip/pc/eip); only fall back
               to r15 (which doubles as the PC on some architectures) if no
               dedicated IP register was seen, since r15 is listed before rip. */
            if ([name isEqualToString:@"rip"] || [name isEqualToString:@"pc"] ||
                [name isEqualToString:@"eip"])
                report.instructionPointer = val;
            else if ([name isEqualToString:@"r15"])
                r15val = val;
        }
    }
    if ([registers count])
        report.registers = registers;
    if (report.instructionPointer == nil && r15val != nil)
        report.instructionPointer = r15val;
}

- (NSMutableArray<NSString *> *)parseFrames:(NSString *)section
{
    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    if (section == nil)
        return frames;
    for (NSString *line in [section componentsSeparatedByString:@"\n"])
    {
        if ([line hasPrefix:@"#"])
            [frames addObject:[self cleanFrame:line]];
    }
    return frames;
}

- (NSMutableArray<NSMutableDictionary *> *)parseThreads:(NSString *)section
{
    NSMutableArray<NSMutableDictionary *> *threads = [NSMutableArray array];
    NSMutableDictionary *cur = nil;
    if (section == nil)
        return threads;
    NSRegularExpression *thRe =
        [NSRegularExpression regularExpressionWithPattern:@"^Thread\\s+(\\d+)\\s*\\(.*\\)\\s*:?\\s*$"
                                                  options:0 error:nil];
    for (NSString *line in [section componentsSeparatedByString:@"\n"])
    {
        NSTextCheckingResult *tm = [thRe firstMatchInString:line
                                                     options:0
                                                       range:NSMakeRange(0, [line length])];
        if (tm != nil)
        {
            NSInteger tid = [[line substringWithRange:[tm rangeAtIndex:1]] integerValue];
            cur = [NSMutableDictionary dictionary];
            cur[@"id"] = @(tid);
            cur[@"crashed"] = @NO;
            cur[@"frames"] = [NSMutableArray array];
            [threads addObject:cur];
            continue;
        }
        if (cur != nil && [line hasPrefix:@"#"])
            [cur[@"frames"] addObject:[self cleanFrame:line]];
    }
    return threads;
}

- (NSArray<NSString *> *)parseLibraries:(NSString *)section
{
    NSMutableArray<NSString *> *libs = [NSMutableArray array];
    if (section == nil)
        return libs;
    NSRegularExpression *libRe =
        [NSRegularExpression regularExpressionWithPattern:@"^\\s*0x[0-9a-f]+\\s+0x[0-9a-f]+\\s+(\\S+)\\s+(.+)$"
                                                  options:0 error:nil];
    for (NSString *line in [section componentsSeparatedByString:@"\n"])
    {
        if ([line rangeOfString:@"No shared libraries loaded"].location != NSNotFound)
            break;
        NSTextCheckingResult *m = [libRe firstMatchInString:line
                                                     options:0
                                                       range:NSMakeRange(0, [line length])];
        if (m != nil)
        {
            NSString *state = [line substringWithRange:[m rangeAtIndex:1]];
            NSString *rest = [[line substringWithRange:[m rangeAtIndex:2]]
                                 stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
            if ([state isEqualToString:@"Yes"] || [state isEqualToString:@"no"])
                [libs addObject:rest];
        }
    }
    return libs;
}

- (NSString *)cleanFrame:(NSString *)line
{
    /* Strip the leading "#n  " and any gdb indentation/address noise we keep
       the symbolized form. We keep the whole frame text which gdb already
       presents readably, but drop a stray leading prompt fragment. */
    NSString *s = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
    if ([s hasPrefix:@"#"])
    {
        NSRange space = [s rangeOfString:@"  "];
        if (space.location != NSNotFound)
            s = [s substringFromIndex:space.location + 2];
    }
    return s;
}

/* ------------------------------------------------------------------ */
/* Classification / diagnosis (SPEC 17)                               */
/* ------------------------------------------------------------------ */

- (void)applyClassification:(GSCrashReport *)report
{
    NSString *classification = nil;
    if (report.exceptionName != nil && [report.exceptionName length])
        classification = @"Uncaught Objective-C exception";
    else
    {
        NSString *sig = report.signal ?: @"";
        if ([sig isEqualToString:@"SIGSEGV"])
            classification = @"Invalid memory access";
        else if ([sig isEqualToString:@"SIGBUS"])
            classification = @"Bus error";
        else if ([sig isEqualToString:@"SIGILL"])
            classification = @"Illegal instruction";
        else if ([sig isEqualToString:@"SIGFPE"])
            classification = @"Floating-point exception";
        else if ([sig isEqualToString:@"SIGABRT"])
            classification = @"Aborted process";
    }
    if (classification == nil)
        classification = @"Unknown crash";
    report.classification = classification;
}

- (void)applyDiagnosis:(GSCrashReport *)report
{
    report.diagnosisConfidence = @"Unknown";
    report.diagnosis = nil;

    NSString *sig = report.signal ?: @"";
    if (!([sig isEqualToString:@"SIGSEGV"] || [sig isEqualToString:@"SIGBUS"]))
        return;
    if (report.faultAddress == nil || [report.faultAddress length] == 0)
        return;
    unsigned long long fa = 0;
    NSString *s = report.faultAddress;
    if ([s hasPrefix:@"0x"])
        fa = strtoull([s UTF8String] + 2, NULL, 16);
    else
        fa = strtoull([s UTF8String], NULL, 0);
    if (fa <= 0x1000)
    {
        report.diagnosis = @"Probable NULL-pointer dereference";
        report.diagnosisConfidence = @"Probable";
    }
}

/* ------------------------------------------------------------------ */
/* Sidecars                                                            */
/* ------------------------------------------------------------------ */

- (void)augmentReportJSON:(NSString *)dir withBacktrace:(NSArray<NSString *> *)backtrace
{
    NSString *path = [dir stringByAppendingPathComponent:GSCrashReportJSON];
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d == nil)
        return;
    NSError *e = nil;
    NSMutableDictionary *dict = [[NSJSONSerialization JSONObjectWithData:d
                                                                options:NSJSONReadingMutableContainers
                                                                  error:&e] mutableCopy];
    if (![dict isKindOfClass:[NSMutableDictionary class]])
        return;
    dict[@"backtrace"] = backtrace;
    NSData *out = [NSJSONSerialization dataWithJSONObject:dict
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:&e];
    if (out != nil)
    {
        [out writeToFile:path atomically:YES];
        chmod([path fileSystemRepresentation], 0600);
    }
}

- (void)writeSidecars:(GSCrashReport *)report directory:(NSString *)dir
{
    if (_rawLog != nil)
        [self writeString:_rawLog to:[dir stringByAppendingPathComponent:GSCrashBacktraceFile]];
    if ([report.registers count])
    {
        NSMutableString *s = [NSMutableString string];
        for (NSString *r in report.registers)
            [s appendFormat:@"%@\n", r];
        [self writeString:s to:[dir stringByAppendingPathComponent:GSCrashRegistersFile]];
    }
    if ([report.loadedLibraries count])
    {
        NSMutableString *s = [NSMutableString string];
        for (NSString *l in report.loadedLibraries)
            [s appendFormat:@"%@\n", l];
        [self writeString:s to:[dir stringByAppendingPathComponent:GSCrashModulesFile]];
    }
}

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

- (void)writeString:(NSString *)s to:(NSString *)path
{
    NSError *e = nil;
    if (![s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e])
        NSLog(@"gs-crash-analyzer: cannot write %@: %@", path, e);
    else
        chmod([path fileSystemRepresentation], 0600);
}

- (NSDictionary *)readJSON:(NSString *)path
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d == nil)
        return nil;
    NSError *e = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if ([obj isKindOfClass:[NSDictionary class]])
        return obj;
    return nil;
}

- (void)setError:(NSError **)error code:(NSInteger)code message:(NSString *)fmt, ...
{
    if (error == nil)
        return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *error = [NSError errorWithDomain:@"io.github.gershwin-desktop.CrashReporter"
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end

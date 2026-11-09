/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashReport.h"
#import "GSCrashConstants.h"
#import <sys/stat.h>

@implementation GSCrashReport

+ (instancetype)report
{
    return [[self alloc] init];
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _crashingThread = -1;
        _coreAvailable = NO;
        _symbolsAvailable = NO;
        _diagnosisConfidence = @"Unknown";
        _threads = @[];
        _backtrace = @[];
        _loadedLibraries = @[];
        _registers = @[];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    GSCrashReport *r = [[[self class] allocWithZone:zone] init];
    r.applicationName = self.applicationName;
    r.applicationVersion = self.applicationVersion;
    r.pid = self.pid;
    r.executablePath = self.executablePath;
    r.uid = self.uid;
    r.timestamp = self.timestamp;
    r.hostname = self.hostname;
    r.osName = self.osName;
    r.osVersion = self.osVersion;
    r.architecture = self.architecture;
    r.gnustepBaseVersion = self.gnustepBaseVersion;
    r.gnustepGuiVersion = self.gnustepGuiVersion;
    r.buildID = self.buildID;
    r.signal = self.signal;
    r.exceptionName = self.exceptionName;
    r.exceptionReason = self.exceptionReason;
    r.faultAddress = self.faultAddress;
    r.crashingThread = self.crashingThread;
    r.instructionPointer = self.instructionPointer;
    r.stackPointer = self.stackPointer;
    r.signalInfo = self.signalInfo;
    r.crashDirectory = self.crashDirectory;
    r.coreDumpPath = self.coreDumpPath;
    r.coreDumpSize = self.coreDumpSize;
    r.coreAvailable = self.coreAvailable;
    r.symbolsAvailable = self.symbolsAvailable;
    r.coreUnavailableReason = self.coreUnavailableReason;
    r.threads = self.threads;
    r.backtrace = self.backtrace;
    r.loadedLibraries = self.loadedLibraries;
    r.registers = self.registers;
    r.classification = self.classification;
    r.diagnosis = self.diagnosis;
    r.diagnosisConfidence = self.diagnosisConfidence;
    r.detectionMethod = self.detectionMethod;
    r.collector = self.collector;
    return r;
}

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"format"] = @(1);
    if (_applicationName) d[@"application"] = @{
        @"name": _applicationName ?: [NSNull null],
        @"version": _applicationVersion ?: [NSNull null],
        @"pid": @(_pid),
        @"executable": _executablePath ?: [NSNull null]
    };
    NSMutableDictionary *sys = [NSMutableDictionary dictionary];
    if (_osName) sys[@"os"] = _osName;
    if (_osVersion) sys[@"os_version"] = _osVersion;
    if (_architecture) sys[@"architecture"] = _architecture;
    if (_hostname) sys[@"hostname"] = _hostname;
    if (_gnustepBaseVersion) sys[@"gnustep_base"] = _gnustepBaseVersion;
    if (_gnustepGuiVersion) sys[@"gnustep_gui"] = _gnustepGuiVersion;
    if (_buildID) sys[@"build_id"] = _buildID;
    if (_uid) sys[@"uid"] = @(_uid);
    d[@"system"] = sys;

    NSMutableDictionary *crash = [NSMutableDictionary dictionary];
    if (_signal) crash[@"signal"] = _signal;
    if (_exceptionName) crash[@"exception"] = _exceptionName;
    if (_exceptionReason) crash[@"exception_reason"] = _exceptionReason;
    if (_faultAddress) crash[@"fault_address"] = _faultAddress;
    if (_crashingThread >= 0) crash[@"thread"] = @(_crashingThread);
    if (_instructionPointer) crash[@"instruction_pointer"] = _instructionPointer;
    if (_stackPointer) crash[@"stack_pointer"] = _stackPointer;
    if (_signalInfo) crash[@"signal_info"] = _signalInfo;
    if (_detectionMethod) crash[@"detection_method"] = _detectionMethod;
    if (_collector) crash[@"collector"] = _collector;
    if (_timestamp)
        crash[@"timestamp"] = [NSString stringWithFormat:@"%.0f",
                               [_timestamp timeIntervalSince1970]];
    d[@"crash"] = crash;

    NSMutableDictionary *analysis = [NSMutableDictionary dictionary];
    if (_classification) analysis[@"classification"] = _classification;
    if (_diagnosis) analysis[@"diagnosis"] = _diagnosis;
    if (_diagnosisConfidence) analysis[@"confidence"] = _diagnosisConfidence;
    if (_symbolsAvailable) analysis[@"symbolicated"] = @YES;
    if (_coreAvailable) analysis[@"core_available"] = @YES;
    if (_coreUnavailableReason) analysis[@"core_unavailable_reason"] = _coreUnavailableReason;
    d[@"analysis"] = analysis;

    if (_threads) d[@"threads"] = _threads;
    if (_loadedLibraries) d[@"modules"] = _loadedLibraries;
    if (_registers) d[@"registers"] = _registers;

    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    if (_coreDumpPath) files[@"core"] = _coreDumpPath;
    if (_coreDumpSize) files[@"core_size"] = @(_coreDumpSize);
    files[@"report"] = GSCrashReportJSON;
    files[@"text"] = GSCrashReportTXT;
    files[@"backtrace"] = GSCrashBacktraceFile;
    files[@"maps"] = GSCrashMapsFile;
    files[@"modules"] = GSCrashModulesFile;
    files[@"registers"] = GSCrashRegistersFile;
    files[@"metadata"] = GSCrashMetadataFile;
    if (_crashDirectory) files[@"directory"] = _crashDirectory;
    d[@"files"] = files;

    return d;
}

/*
 * "copy"-prefixed helpers so ARC returns a +1 retained object (NOT autoreleased).
 * This avoids an autorelease-pool double-release interaction seen with the
 * JSON/plist-loaded graph on this runtime. All leaves are freshly allocated so
 * the report owns its data independently of the source dictionary.
 */
- (NSMutableArray *)copyArray:(NSArray *)src
{
    NSMutableArray *a = [[NSMutableArray alloc] initWithCapacity:[src count]];
    for (id item in src)
        [a addObject:[self copyObject:item]];
    return a;
}

- (NSMutableDictionary *)copyDictionary:(NSDictionary *)src
{
    NSMutableDictionary *d = [[NSMutableDictionary alloc] initWithCapacity:[src count]];
    for (id k in src)
    {
        NSString *nk = [[NSString alloc] initWithString:[k description]];
        d[nk] = [self copyObject:src[k]];
    }
    return d;
}

- (id)copyObject:(id)obj
{
    if ([obj isKindOfClass:[NSArray class]])
        return [self copyArray:obj];
    if ([obj isKindOfClass:[NSDictionary class]])
        return [self copyDictionary:obj];
    if ([obj isKindOfClass:[NSString class]])
        return [[NSString alloc] initWithString:obj];
    if ([obj isKindOfClass:[NSNumber class]])
        return [[NSNumber alloc] initWithDouble:[obj doubleValue]];
    if ([obj isKindOfClass:[NSNull class]])
        return [NSNull null];
    return [[NSString alloc] initWithString:[obj description]];
}

- (void)populateFromDictionary:(NSDictionary *)dict
{
    NSDictionary *app = dict[@"application"];
    if ([app isKindOfClass:[NSDictionary class]])
    {
        self.applicationName = [app[@"name"] isKindOfClass:[NSString class]] ? app[@"name"] : nil;
        self.applicationVersion = [app[@"version"] isKindOfClass:[NSString class]] ? app[@"version"] : nil;
        if ([app[@"pid"] isKindOfClass:[NSNumber class]]) _pid = [app[@"pid"] intValue];
        self.executablePath = [app[@"executable"] isKindOfClass:[NSString class]] ? app[@"executable"] : nil;
    }
    NSDictionary *sys = dict[@"system"];
    if ([sys isKindOfClass:[NSDictionary class]])
    {
        self.osName = sys[@"os"];
        self.osVersion = sys[@"os_version"];
        self.architecture = sys[@"architecture"];
        self.hostname = sys[@"hostname"];
        self.gnustepBaseVersion = sys[@"gnustep_base"];
        self.gnustepGuiVersion = sys[@"gnustep_gui"];
        self.buildID = sys[@"build_id"];
        if ([sys[@"uid"] isKindOfClass:[NSNumber class]]) _uid = [sys[@"uid"] unsignedIntValue];
    }
    NSDictionary *crash = dict[@"crash"];
    if ([crash isKindOfClass:[NSDictionary class]])
    {
        self.signal = crash[@"signal"];
        self.exceptionName = crash[@"exception"];
        self.exceptionReason = crash[@"exception_reason"];
        self.faultAddress = crash[@"fault_address"];
        if ([crash[@"thread"] isKindOfClass:[NSNumber class]]) _crashingThread = [crash[@"thread"] integerValue];
        self.instructionPointer = crash[@"instruction_pointer"];
        self.stackPointer = crash[@"stack_pointer"];
        self.signalInfo = crash[@"signal_info"];
        self.detectionMethod = crash[@"detection_method"];
        self.collector = crash[@"collector"];
        if ([crash[@"timestamp"] isKindOfClass:[NSString class]])
            self.timestamp = [NSDate dateWithTimeIntervalSince1970:[crash[@"timestamp"] doubleValue]];
    }
    NSDictionary *analysis = dict[@"analysis"];
    if ([analysis isKindOfClass:[NSDictionary class]])
    {
        self.classification = analysis[@"classification"];
        self.diagnosis = analysis[@"diagnosis"];
        self.diagnosisConfidence = analysis[@"confidence"] ?: @"Unknown";
        if ([analysis[@"symbolicated"] isKindOfClass:[NSNumber class]]) _symbolsAvailable = [analysis[@"symbolicated"] boolValue];
        if ([analysis[@"core_available"] isKindOfClass:[NSNumber class]]) _coreAvailable = [analysis[@"core_available"] boolValue];
        self.coreUnavailableReason = analysis[@"core_unavailable_reason"];
    }
    if ([dict[@"threads"] isKindOfClass:[NSArray class]]) _threads = [self copyArray:dict[@"threads"]];
    if ([dict[@"modules"] isKindOfClass:[NSArray class]]) _loadedLibraries = [self copyArray:dict[@"modules"]];
    if ([dict[@"registers"] isKindOfClass:[NSArray class]]) _registers = [self copyArray:dict[@"registers"]];
    if ([dict[@"backtrace"] isKindOfClass:[NSArray class]]) _backtrace = [self copyArray:dict[@"backtrace"]];
    NSDictionary *files = dict[@"files"];
    if ([files isKindOfClass:[NSDictionary class]])
    {
        self.coreDumpPath = files[@"core"];
        if ([files[@"core_size"] isKindOfClass:[NSNumber class]]) _coreDumpSize = [files[@"core_size"] longLongValue];
        self.crashDirectory = files[@"directory"];
    }
}

+ (instancetype)reportFromDirectory:(NSString *)directory
{
    NSString *jsonPath = [directory stringByAppendingPathComponent:GSCrashReportJSON];
    /*
     * Load from the property-list sidecar (report.plist) which GNUstep's
     * NSPropertyListSerialization handles reliably. Fall back to the canonical
     * JSON (report.json) if the plist is unavailable. Both are written by
     * -writeToDirectory: so the JSON remains the spec-facing format.
     */
    NSString *plistPath = [directory stringByAppendingPathComponent:@"report.plist"];
    id obj = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (obj == nil)
    {
        NSData *data = [NSData dataWithContentsOfFile:jsonPath];
        if (data == nil)
            return nil;
        NSError *err = nil;
        obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    }
    if (obj == nil || ![obj isKindOfClass:[NSDictionary class]])
        return nil;
    GSCrashReport *r = [self report];
    [r populateFromDictionary:obj];
    r.crashDirectory = directory;
    return r;
}

- (BOOL)writeToDirectory:(NSString *)directory
{
    if (_crashDirectory == nil)
        _crashDirectory = directory;
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self dictionaryRepresentation]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (data == nil)
    {
        NSLog(@"CrashReporter: cannot serialize report: %@", err);
        return NO;
    }
    NSString *jsonPath = [directory stringByAppendingPathComponent:GSCrashReportJSON];
    if (![data writeToFile:jsonPath options:NSDataWritingAtomic error:&err])
    {
        NSLog(@"CrashReporter: cannot write %@: %@", jsonPath, err);
        return NO;
    }
    chmod([jsonPath fileSystemRepresentation], 0600);
    /* Robust native sidecar for reloading (SPEC format stays JSON). */
    NSString *plistPath = [directory stringByAppendingPathComponent:@"report.plist"];
    if (![[self dictionaryRepresentation] writeToFile:plistPath atomically:YES])
        NSLog(@"CrashReporter: cannot write %@", plistPath);
    else
        chmod([plistPath fileSystemRepresentation], 0600);
    NSString *txtPath = [directory stringByAppendingPathComponent:GSCrashReportTXT];
    if (![[self textReport] writeToFile:txtPath
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:&err])
    {
        NSLog(@"CrashReporter: cannot write %@: %@", txtPath, err);
        return NO;
    }
    chmod([txtPath fileSystemRepresentation], 0600);
    return YES;
}

- (NSString *)pathForArtifact:(NSString *)name
{
    if (_crashDirectory == nil)
        return name;
    return [_crashDirectory stringByAppendingPathComponent:name];
}

- (NSString *)textReport
{
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"GNUstep CrashReporter\n"];
    [s appendString:@"=======================\n\n"];

    [s appendString:@"Application\n"];
    [s appendFormat:@"  Name:        %@\n", _applicationName ?: @"?"];
    if (_applicationVersion) [s appendFormat:@"  Version:     %@\n", _applicationVersion];
    [s appendFormat:@"  PID:         %d\n", (int)_pid];
    if (_executablePath) [s appendFormat:@"  Executable:  %@\n", _executablePath];
    if (_buildID) [s appendFormat:@"  Build ID:    %@\n", _buildID];
    [s appendString:@"\n"];

    [s appendString:@"System\n"];
    [s appendFormat:@"  OS:          %@ %@\n", _osName ?: @"?", _osVersion ?: @""];
    if (_architecture) [s appendFormat:@"  Arch:        %@\n", _architecture];
    if (_hostname) [s appendFormat:@"  Host:        %@\n", _hostname];
    if (_gnustepBaseVersion) [s appendFormat:@"  GNUstep Base:%@\n", _gnustepBaseVersion];
    if (_gnustepGuiVersion) [s appendFormat:@"  GNUstep GUI: %@\n", _gnustepGuiVersion];
    [s appendString:@"\n"];

    [s appendString:@"Crash\n"];
    if (_signal) [s appendFormat:@"  Signal:      %@\n", _signal];
    if (_exceptionName)
    {
        [s appendFormat:@"  Exception:   %@\n", _exceptionName];
        if (_exceptionReason) [s appendFormat:@"  Reason:      %@\n", _exceptionReason];
    }
    if (_faultAddress) [s appendFormat:@"  Fault:       %@\n", _faultAddress];
    if (_crashingThread >= 0) [s appendFormat:@"  Thread:      %ld\n", (long)_crashingThread];
    if (_instructionPointer) [s appendFormat:@"  RIP:         %@\n", _instructionPointer];
    if (_signalInfo) [s appendFormat:@"  Signal info: %@\n", _signalInfo];
    if (_timestamp)
    {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        [f setDateStyle:NSDateFormatterLongStyle];
        [f setTimeStyle:NSDateFormatterMediumStyle];
        [s appendFormat:@"  Time:        %@\n", [f stringFromDate:_timestamp]];
    }
    [s appendString:@"\n"];

    [s appendString:@"Analysis\n"];
    if (_classification) [s appendFormat:@"  Class:       %@\n", _classification];
    if (_diagnosis)
        [s appendFormat:@"  Likely cause: %@ (confidence: %@)\n",
                        _diagnosis, _diagnosisConfidence ?: @"Unknown"];
    if (_coreAvailable)
    {
        [s appendFormat:@"  Core dump:   captured (%lld bytes)\n", _coreDumpSize];
        if (_coreDumpPath) [s appendFormat:@"               %@\n", _coreDumpPath];
    }
    else
    {
        [s appendString:@"  Core dump:   NOT captured\n"];
        if (_coreUnavailableReason)
            [s appendFormat:@"               (%@)\n", _coreUnavailableReason];
    }
    [s appendFormat:@"  Symbols:     %@\n", _symbolsAvailable ? @"available" : @"not available"];
    [s appendString:@"\n"];

    if ([_backtrace count])
    {
        [s appendString:@"Backtrace (crashing thread)\n"];
        for (NSString *line in _backtrace)
            [s appendFormat:@"  %@\n", line];
        [s appendString:@"\n"];
    }

    if ([_threads count] > 1)
    {
        [s appendString:@"Other threads\n"];
        for (NSDictionary *t in _threads)
        {
            if ([t[@"crashed"] boolValue])
                continue;
            [s appendFormat:@"  Thread %@: %lu frames\n",
                            t[@"id"], (unsigned long)[(t[@"frames"] ?: @[]) count]];
        }
        [s appendString:@"\n"];
    }

    if ([_loadedLibraries count])
    {
        [s appendString:@"Loaded libraries\n"];
        for (NSString *lib in _loadedLibraries)
            [s appendFormat:@"  %@\n", lib];
        [s appendString:@"\n"];
    }

    if ([_registers count])
    {
        [s appendString:@"Registers\n"];
        for (NSString *reg in _registers)
            [s appendFormat:@"  %@\n", reg];
        [s appendString:@"\n"];
    }

    [s appendFormat:@"Crash files saved to:\n  %@\n", _crashDirectory ?: @"?"];
    return s;
}

@end

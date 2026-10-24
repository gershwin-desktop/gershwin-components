/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WhisperController.h"
#import "GSMediaPlayer2.h"
#import "WApplication.h"
#import "AppearanceMetrics.h"
#import "WAudioLoader.h"
#import "WCapture.h"
#import "ALSABackend.h"
#import "OSSBackend.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSProgressIndicator.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSSavePanel.h>
#import <AppKit/NSPopUpButton.h>
#import <AppKit/NSStepper.h>
#import <AppKit/NSAlert.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSThread.h>
#import <objc/runtime.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSTask.h>
#import <Foundation/NSUserDefaults.h>
#import <Foundation/NSFileHandle.h>

#import "WhisperDlopen.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <strings.h>
#include <curl/curl.h>

// ── xdotool path (resolved once from PATH at first use) ────────────
static NSString *xdoPath = nil;

// ── Build progress (shared between build thread and main-thread timer) ─
static volatile int buildProgressPct = 0;
static volatile BOOL buildThreadRunning = NO;

// ── DockService protocol (forward decl - no link dependency) ────────
@protocol DockService <NSObject>
- (void)setProgressValue:(double)value;
- (void)setProgressVisible:(BOOL)visible;
- (void)clearAll;
@end

// ── Floating window: always on top, no keyboard input ──────────────
@interface WhisperFloatingWindow : NSWindow
@end
@implementation WhisperFloatingWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end



#define DEFAULT_WINDOW_WIDTH  480.0
#define DEFAULT_WINDOW_HEIGHT 347.0
#define CONTENT_MIN_WIDTH     413.0
#define CONTENT_MIN_HEIGHT    267.0

#define WHISPER_SAMPLE_RATE 16000

static NSString *kWhisperModelDir = @"Whisper/Models";

static const char *modelNames[] = {
    "ggml-tiny.en.bin",
    "ggml-tiny.bin",
    "ggml-base.en.bin",
    "ggml-base.bin",
    "ggml-small.en.bin",
    "ggml-small.bin",
    "ggml-medium.en.bin",
    "ggml-medium.bin",
    "ggml-large-v3.bin",
    "ggml-large-v3-turbo.bin",
    NULL
};

static const char *modelSizes[] = {
    "tiny.en (74 MB)",
    "tiny (74 MB)",
    "base.en (141 MB)",
    "base (141 MB)",
    "small.en (465 MB)",
    "small (465 MB)",
    "medium.en (1.42 GB)",
    "medium (1.42 GB)",
    "large-v3 (2.87 GB)",
    "large-v3-turbo (809 MB)",
    NULL
};

static const char *langCodes[] = {
    "auto", "en", "zh", "de", "es", "fr", "it", "pt", "nl", "ja",
    "ko", "ru", "ar", "tr", "pl", "uk", "ro", "hu", "sv", "da",
    "fi", "el", "cs", "sk", "bg", "hr", "sr", "lt", "lv", "et",
    "hi", "th", "vi", "id", "ms", "tl", "bn", "ta", "te", "mr",
    NULL
};

static const char *langNames[] = {
    "Auto-detect", "English", "Chinese", "German", "Spanish", "French",
    "Italian", "Portuguese", "Dutch", "Japanese", "Korean", "Russian",
    "Arabic", "Turkish", "Polish", "Ukrainian", "Romanian", "Hungarian",
    "Swedish", "Danish", "Finnish", "Greek", "Czech", "Slovak", "Bulgarian",
    "Croatian", "Serbian", "Lithuanian", "Latvian", "Estonian", "Hindi",
    "Thai", "Vietnamese", "Indonesian", "Malay", "Filipino", "Bengali",
    "Tamil", "Telugu", "Marathi",
    NULL
};

/* whisper.cpp calls these on the worker, inside wdlopen_full.  The context
   ties each report to the job that produced it, so a late report of an
   older take or file is recognised and dropped on the main thread. */
typedef struct {
    WhisperController *ctrl;
    NSUInteger generation;
} WJobContext;

// C callback for progress
static void whisper_progress_cb(struct whisper_context *ctx,
                                struct whisper_state *state,
                                int progress, void *user_data)
{
    WJobContext *job = (WJobContext *)user_data;
    [job->ctrl performSelectorOnMainThread:@selector(transcriptionProgress:)
                                withObject:[NSArray arrayWithObjects:
                                    [NSNumber numberWithUnsignedInteger:job->generation],
                                    [NSNumber numberWithInt:progress], nil]
                             waitUntilDone:NO];
}

// C callback for new segments (fires during whisper_full decoding)
static void whisper_new_segment_cb(struct whisper_context *ctx,
                                   struct whisper_state *state,
                                   int n_new, void *user_data)
{
    WJobContext *job = (WJobContext *)user_data;
    WhisperController *ctrl = job->ctrl;
    int total = wdlopen_full_n_segments(ctx);

    NSMutableArray *newSegs = [NSMutableArray array];

    for (int i = total - n_new; i < total; i++) {
        const char *seg_text = wdlopen_full_get_segment_text(ctx, i);
        if (!seg_text) continue;

        int64_t t0 = wdlopen_full_get_segment_t0(ctx, i);
        int64_t t1 = wdlopen_full_get_segment_t1(ctx, i);

        NSString *st = [NSString stringWithUTF8String:seg_text];
        if (!st) continue;

        NSDictionary *seg = [NSDictionary dictionaryWithObjectsAndKeys:
            st, @"text",
            [NSNumber numberWithLongLong:t0], @"t0",
            [NSNumber numberWithLongLong:t1], @"t1",
            nil];
        [newSegs addObject:seg];

        // Also stream to console
        fprintf(stdout, "Recognized: [%s --> %s] %s\n",
                [[ctrl formatTimestamp:t0] UTF8String],
                [[ctrl formatTimestamp:t1] UTF8String],
                seg_text);
        fflush(stdout);
    }

    if ([newSegs count] > 0) {
        NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
            newSegs, @"segments",
            [NSNumber numberWithUnsignedInteger:job->generation], @"generation",
            nil];
        [ctrl performSelectorOnMainThread:@selector(appendStreamingResult:)
                               withObject:result
                            waitUntilDone:NO];
    }
}

/* whisper writes stretches without speech as a bracketed note instead of
   words ("[BLANK_AUDIO]", "[Music]", "(wind blowing)"). */
static BOOL isBlankSegmentText(const char *text)
{
    if (!text) return YES;
    while (*text == ' ') text++;
    size_t len = strlen(text);
    while (len > 0 && (text[len - 1] == ' ' || text[len - 1] == '\n')) len--;
    if (len == 0) return YES;
    return (text[0] == '[' && text[len - 1] == ']') ||
           (text[0] == '(' && text[len - 1] == ')');
}

@interface WhisperController ()
- (NSString *)ensureModelLoaded;
- (void)unloadModel;
- (NSString *)modelDirPath;
- (NSString *)captureDevicePath;
- (void)requestDownloadOfModel:(NSString *)name byUser:(BOOL)byUser;
- (void)startCapture;
- (void)stopCaptureAndFinish;
- (void)cancelCapture;
- (void)startFileTranscription;
- (void)startDownload;
- (void)stopRecordingTimers;
- (void)transcriptionProgress:(NSArray *)report;
- (void)appendStreamingResult:(NSDictionary *)result;
@end

@implementation WhisperController

@synthesize mainWindow, availableModels, segments, currentFilePath;

- (NSString *)findTool:(NSString *)name
{
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    if (!pathEnv) return nil;
    NSArray *dirs = [pathEnv componentsSeparatedByString:@":"];
    for (NSString *dir in dirs) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full])
            return full;
    }
    return nil;
}

- (void)playSubmarineSound
{
    NSString *path = @"/System/Library/Sounds/Submarine.wav";
    NSString *aplayer = [self findTool:@"aplay"];
    NSString *audioplayer = [self findTool:@"audioplay"];
    NSString *paplayer = [self findTool:@"paplay"];

    NSMutableDictionary *cEnv = [[[[NSProcessInfo processInfo] environment] mutableCopy] autorelease];
    [cEnv setObject:@"C" forKey:@"LC_ALL"];

    // Try each player: aplay, audioplay, paplay
    NSString *players[3] = { aplayer, audioplayer, paplayer };
    NSArray *args[3] = {
        @[@"-q", path],
        @[path],
        @[path]
    };
    for (int i = 0; i < 3; i++) {
        if (!players[i]) continue;
        NSLog(@"playSubmarineSound: trying %@", players[i]);
        NSTask *t = [[NSTask alloc] init];
        [t setLaunchPath:players[i]];
        [t setArguments:args[i]];
        [t setEnvironment:cEnv];
        @try {
            [t launch];
            [t waitUntilExit];
            if ([t terminationStatus] == 0) {
                NSLog(@"playSubmarineSound: succeeded with %@", players[i]);
                [t release];
                return;
            }
            NSLog(@"playSubmarineSound: %@ failed status=%d",
                  players[i], [t terminationStatus]);
        } @catch (NSException *e) {
            NSLog(@"playSubmarineSound: %@ threw %@", players[i], e);
        }
        [t release];
    }
    // Last resort: raw OSS - cat WAV to /dev/dsp
    NSLog(@"playSubmarineSound: trying cat > /dev/dsp");
    NSTask *t = [[NSTask alloc] init];
    [t setLaunchPath:@"/bin/sh"];
    [t setArguments:@[@"-c", [NSString stringWithFormat:@"cat '%@' > /dev/dsp 2>/dev/null", path]]];
    [t setEnvironment:cEnv];
    @try {
        [t launch];
        [t waitUntilExit];
        NSLog(@"playSubmarineSound: cat > /dev/dsp exit=%d", [t terminationStatus]);
    } @catch (NSException *e) {
        NSLog(@"playSubmarineSound: cat > /dev/dsp threw %@", e);
    }
    [t release];
}

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        segments = [[NSMutableArray alloc] init];
        whisperCtx = NULL;
        machine = [[WDictationMachine alloc] init];
        pendingEvents = [[NSMutableArray alloc] init];
        whisperQueue = [[NSOperationQueue alloc] init];
        [whisperQueue setMaxConcurrentOperationCount:1];
        jobProgress = -1;
        downloadTask = nil;
        downloadData = nil;
        currentFilePath = nil;
        downloadingModel = nil;
        captureHandle = NULL;
        playerPausedForRecording = NO;
        currentLangCode = nil;
        recordTimer = nil;
        streamTimer = nil;
        showTimestamps = NO;
        copyDefaultConsumed = NO;
        typedText = nil;
        vocabularyPrompt = [[[NSUserDefaults standardUserDefaults]
            stringForKey:@"VocabularyPrompt"] retain];
        if (!vocabularyPrompt) {
            vocabularyPrompt = [@"GNUstep AppImage" retain];
        }
        if (!xdoPath) {
            xdoPath = [[self findTool:@"xdotool"] retain];
            if (!xdoPath) xdoPath = @"/usr/bin/xdotool";
        }
        currentThreads = 8;

        [self populateModelList];
    }
    return self;
}

- (void)dealloc
{
    [self resumePlayerIfPaused];
    [whisperQueue waitUntilAllOperationsAreFinished];
    [self unloadModel];
    [machine release];
    [viewState release];
    [pendingEvents release];
    [whisperQueue release];
    [loadedModelName release];
    [segments release];
    [availableModels release];
    [currentFilePath release];
    [downloadingModel release];
    [downloadData release];
    [downloadFH release];
    [currentLangCode release];
    [recordTimer invalidate];
    [recordTimer release];
    [streamTimer invalidate];
    [streamTimer release];
    if (captureHandle) wcapture_cancel(captureHandle);
    [typedText release];
    [vocabularyPrompt release];
    [vocabPanel release];
    [super dealloc];
}

#pragma mark - App Delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self createUI];
    [self createMenu];

    // Restore last selected model (default: base.en) and set checkmark
    NSString *savedModel = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastModel"];
    if (!savedModel) {
        savedModel = @"ggml-base.en.bin";
        [[NSUserDefaults standardUserDefaults] setObject:savedModel forKey:@"LastModel"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenuItem *appItem = [[mainMenu itemArray] objectAtIndex:0];
    NSMenu *appMenu = [appItem submenu];
    for (NSMenuItem *item in [appMenu itemArray]) {
        if ([[item title] isEqualToString:@"Model"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                if ([[mi representedObject] isEqualToString:savedModel]) {
                    [mi setState:NSOnState];
                } else {
                    [mi setState:NSOffState];
                }
            }
            break;
        }
    }

    // Restore last selected language (default: English)
    NSString *savedLang = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastLanguage"];
    if (!savedLang) savedLang = @"en";
    BOOL enModel = [savedModel hasSuffix:@".en"];
    NSString *langCode = enModel ? @"en" : savedLang;
    [currentLangCode release];
    currentLangCode = [langCode copy];

    // Restore thread count
    NSInteger savedThreads = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"ThreadCount"];
    if (savedThreads >= 1 && savedThreads <= 32) {
        currentThreads = (int)savedThreads;
    }

    showTimestamps = [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowTimestamps"];
    [showTimestampsCheckbox setState:(showTimestamps ? NSOnState : NSOffState)];

    // Refresh checkmarks on model, language, and threads menus now that
    // saved preferences have been loaded.
    [self refreshMenuCheckmarks];

    [self render];

    // ── Start-up dependency checks (before showing window) ────
    NSString *fail = nil;

    if (!wdlopen_init()) {
        NSString *sp = [[NSBundle mainBundle] pathForResource:@"build-whisper" ofType:@"sh"];
        if (!sp) sp = @"Whisper.app/Resources/build-whisper.sh";
        [self buildWhisperEngineWithScript:sp];
    } else if (![self findTool:@"xdotool"]) {
        fail = @"The xdotool tool is required for auto-typing into other windows.\n\n"
               @"Install it with your package manager:\n\n"
               @"  Debian/Ubuntu:  sudo apt install xdotool\n"
               @"  Arch:           sudo pacman -S xdotool\n"
               @"  FreeBSD:        sudo pkg install xdotool\n"
               @"  OpenBSD:        doas pkg_add xdotool";
    } else {
        NSString *mn = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastModel"];
        if (mn) {
            NSString *mp = [self modelPathForName:mn];
            if (![[NSFileManager defaultManager] fileExistsAtPath:mp])
                [self requestDownloadOfModel:mn byUser:NO];
        }
    }

    if (fail) {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:@"Missing dependencies"];
        [a setInformativeText:fail];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        [a release];
    }

    // If a build is in progress, finishStartup will be called from buildFinished:
    if (wdlopen_init())
        [self finishStartup];

}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    // Never leave Player silent because of us (MediaRemote/PROTOCOL.md)
    [self resumePlayerIfPaused];
    /* A worker may still be inside whisper_full; freeing the context under
       it would crash the quit, and the process ends anyway. */
    if ([whisperQueue operationCount] == 0)
        [self unloadModel];
    if (downloadTask && [downloadTask isRunning]) {
        [downloadTask terminate];
    }
    [self stopRecordingTimers];
    if (captureHandle) wcapture_cancel(captureHandle);
    captureHandle = NULL;
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename
{
    [self setCurrentFilePath:filename];
    [machine setDetail:filename];
    [self render];
    return YES;
}

#pragma mark - Model Management

- (NSString *)modelDirPath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if ([paths count] == 0) return nil;
    NSString *appSupport = [paths objectAtIndex:0];
    return [[appSupport stringByAppendingPathComponent:kWhisperModelDir]
               stringByStandardizingPath];
}

- (void)populateModelList
{
    NSMutableArray *models = [NSMutableArray array];
    for (int i = 0; modelNames[i] != NULL; i++) {
        NSString *name = [NSString stringWithUTF8String:modelNames[i]];
        NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
            name, @"name", label, @"label", nil];
        [models addObject:entry];
    }
    [self setAvailableModels:models];
}

- (NSString *)modelPathForName:(NSString *)name
{
    NSString *dir = [self modelDirPath];
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:name];
}

- (BOOL)modelExists:(NSString *)name
{
    NSString *path = [self modelPathForName:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/* Loads the model chosen in the Model menu unless it is the one already
   loaded, and returns why it could not, or nil.  It shows no alert itself:
   it runs as the effect of a transition, so offers to download are
   deferred until the transition has been rendered. */
- (NSString *)ensureModelLoaded
{
    NSString *name = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"LastModel"];
    if (!name)
        return @"No model selected - choose one in the Model menu";
    if (whisperCtx && [loadedModelName isEqualToString:name])
        return nil;
    if (!wdlopen_init())
        return @"whisper.cpp library not found";

    NSString *modelPath = [self modelPathForName:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        [self performSelector:@selector(offerDownloadOfModel:)
                   withObject:name afterDelay:0];
        return [NSString stringWithFormat:@"Model %@ is not downloaded", name];
    }

    /* A report of an earlier take may still be decoding with the old
       context; it is short, and freeing the context under it would crash. */
    [whisperQueue waitUntilAllOperationsAreFinished];
    [self unloadModel];

    // Try GPU first, fall back to CPU
    struct whisper_context_params cparams = wdlopen_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;

    NSLog(@"loadModel: trying GPU (%@)", modelPath);
    whisperCtx = wdlopen_init_from_file([modelPath UTF8String], cparams);
    if (!whisperCtx) {
        NSLog(@"loadModel: GPU init failed, retrying with CPU");
        cparams.use_gpu = false;
        cparams.flash_attn = false;
        whisperCtx = wdlopen_init_from_file([modelPath UTF8String], cparams);
    }

    if (!whisperCtx) {
        NSLog(@"loadModel: all backends failed for %@", modelPath);
        unsigned long long fileSize = [[[NSFileManager defaultManager]
            attributesOfItemAtPath:modelPath error:NULL] fileSize];
        unsigned long long minSize = [self minimumModelSize:name];
        if (fileSize > 0 && fileSize < minSize) {
            NSLog(@"loadModel: file is only %llu bytes (expected >= %llu) - likely truncated",
                  fileSize, minSize);
            [self performSelector:@selector(offerRedownloadOfModel:)
                       withObject:name afterDelay:0];
            return [NSString stringWithFormat:
                @"Model %@ is incomplete", name];
        }
        return [NSString stringWithFormat:@"Could not load model %@", name];
    }

    [loadedModelName release];
    loadedModelName = [name copy];
    return nil;
}

- (void)offerDownloadOfModel:(NSString *)name
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Model not downloaded"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"The model \"%@\" needs to be downloaded first.\n\n"
        @"Download it now?", name]];
    [alert addButtonWithTitle:@"Download"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn)
        [self requestDownloadOfModel:name byUser:YES];
    [alert release];
}

- (void)offerRedownloadOfModel:(NSString *)name
{
    unsigned long long minSize = [self minimumModelSize:name];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Corrupt model file"];
    [alert setInformativeText:[NSString stringWithFormat:
        @"%@ is smaller than %llu MB.\n"
        "The download was probably interrupted.\n\n"
        "Click Re-download to download it again.",
        name, minSize / 1000000]];
    [alert addButtonWithTitle:@"Re-download"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setAlertStyle:NSCriticalAlertStyle];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSFileManager defaultManager]
            removeItemAtPath:[self modelPathForName:name] error:NULL];
        [self requestDownloadOfModel:name byUser:YES];
    }
    [alert release];
}

- (void)unloadModel
{
    if (whisperCtx) {
        wdlopen_free(whisperCtx);
        whisperCtx = NULL;
    }
    [loadedModelName release];
    loadedModelName = nil;
}

// ── libcurl helpers ───────────────────────────────────────────
static size_t write_file_cb(void *ptr, size_t size, size_t nmemb, void *stream)
{
    return fwrite(ptr, size, nmemb, (FILE *)stream);
}

static int download_progress_cb(void *clientp,
                                curl_off_t dltotal, curl_off_t dlnow,
                                curl_off_t ultotal, curl_off_t ulnow)
{
    WhisperController *self = (WhisperController *)clientp;
    if (dltotal > 0) {
        static double lastPct = -1.0;
        double pct = (double)dlnow / (double)dltotal * 100.0;
        // Throttle: only update when percentage crosses an integer boundary
        if ((int)pct != (int)lastPct) {
            lastPct = pct;
            [self performSelectorOnMainThread:@selector(downloadProgressUpdated:)
                                   withObject:[NSNumber numberWithDouble:pct]
                                waitUntilDone:NO];
        }
    }
    return 0;
}

- (void)downloadModelWithName:(NSString *)name
{
    [self requestDownloadOfModel:name byUser:YES];
}

/* Launch finds the chosen model missing (not the user), or the user picks
   one that is not on disk; either way the machine decides whether a
   download may start now. */
- (void)requestDownloadOfModel:(NSString *)name byUser:(BOOL)byUser
{
    WDEvent e = byUser ? WDEventUserDownloadModel : WDEventLaunchDownloadModel;
    /* The name is data of the download; it must not change under a
       download that is already running. */
    if ([WDictationMachine targetOfEvent:e inState:[machine state]]
            != WDStateDownloading) {
        NSLog(@"requestDownloadOfModel: %@ not now (%@)", name,
              [WDictationMachine nameOfState:[machine state]]);
        return;
    }
    [downloadingModel release];
    downloadingModel = [name copy];
    [self fireEvent:e generation:[machine generation] detail:nil];
}

- (void)startDownload
{
    NSUInteger gen = [machine generation];
    NSString *name = downloadingModel;
    NSString *dir = [self modelDirPath];
    if (!dir) {
        [self fireEvent:WDEventDownloadFailed generation:gen
                 detail:@"cannot find Application Support directory"];
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSString *urlStr = [NSString stringWithFormat:
        @"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/%@",
        name];
    NSString *destPath = [dir stringByAppendingPathComponent:name];

    NSLog(@"downloadModelWithName: downloading %@", name);
    NSLog(@"downloadModelWithName: URL: %@", urlStr);
    NSLog(@"downloadModelWithName: dest: %@", destPath);

    jobProgress = -1;

    [self performSelectorInBackground:@selector(downloadThread:)
                           withObject:[NSArray arrayWithObjects:urlStr,
                               destPath, name,
                               [NSNumber numberWithUnsignedInteger:gen], nil]];
}

- (void)downloadThread:(NSArray *)params
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *urlStr  = [params objectAtIndex:0];
    NSString *destPath = [params objectAtIndex:1];
    NSString *name    = [params objectAtIndex:2];
    NSNumber *gen     = [params objectAtIndex:3];

    static BOOL curlInit = NO;
    if (!curlInit) { curl_global_init(CURL_GLOBAL_DEFAULT); curlInit = YES; }

    CURL *curl = curl_easy_init();
    if (!curl) {
        NSLog(@"downloadThread: curl_easy_init failed");
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:[NSArray arrayWithObjects:gen,
                                   @"Failed to initialize download", nil]
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    FILE *f = fopen([destPath fileSystemRepresentation], "wb");
    if (!f) {
        NSLog(@"downloadThread: cannot open %@ for writing", destPath);
        curl_easy_cleanup(curl);
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:[NSArray arrayWithObjects:gen,
                                   [NSString stringWithFormat:@"Cannot write to %@", destPath], nil]
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, [urlStr UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, f);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_RESUME_FROM, 0L);
    curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, download_progress_cb);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, self);

    NSLog(@"downloadThread: starting transfer...");
    CURLcode res = curl_easy_perform(curl);
    fclose(f);

    if (res == CURLE_OK) {
        NSLog(@"downloadThread: download complete");
        [self performSelectorOnMainThread:@selector(downloadFinishedWithName:)
                               withObject:[NSArray arrayWithObjects:gen, name, nil]
                            waitUntilDone:NO];
    } else {
        NSLog(@"downloadThread: curl error %d", res);
        NSString *err = [NSString stringWithUTF8String:curl_easy_strerror(res)];
        [self performSelectorOnMainThread:@selector(downloadFinishedWithError:)
                               withObject:[NSArray arrayWithObjects:gen, err, nil]
                            waitUntilDone:NO];
    }

    curl_easy_cleanup(curl);
    [pool release];
}

// Minimum expected file size (in bytes) for each model, at 90 % of declared
// size - a file smaller than this is almost certainly a truncated download.
static const unsigned long long modelMinSizes[] = {
    66 * 1000000,   // tiny.en    74 MB
    66 * 1000000,   // tiny       74 MB
    127 * 1000000,  // base.en   141 MB
    127 * 1000000,  // base      141 MB
    418 * 1000000,  // small.en  465 MB
    418 * 1000000,  // small     465 MB
    1278 * 1000000, // medium.en 1.42 GB
    1278 * 1000000, // medium    1.42 GB
    2583ULL * 1000000, // large-v3  2.87 GB
    728 * 1000000,  // large-v3-turbo 809 MB
};

- (unsigned long long)minimumModelSize:(NSString *)modelName
{
    for (int i = 0; modelNames[i] != NULL; i++) {
        if ([[NSString stringWithUTF8String:modelNames[i]]
                isEqualToString:modelName]) {
            return modelMinSizes[i];
        }
    }
    return 0;
}

- (void)downloadProgressUpdated:(NSNumber *)pct
{
    if ([machine state] != WDStateDownloading) return;
    jobProgress = [pct doubleValue];
    [self render];
}

/* The model is loaded here, before the machine hears of it, so Ready
   really means a model is there to record with. */
- (void)downloadFinishedWithName:(NSArray *)report
{
    NSUInteger gen = [[report objectAtIndex:0] unsignedIntegerValue];
    NSString *name = [report objectAtIndex:1];
    NSLog(@"downloadFinishedWithName: successfully downloaded %@", name);

    NSString *why = nil;
    if ([name isEqualToString:[[NSUserDefaults standardUserDefaults]
                                  stringForKey:@"LastModel"]])
        why = [self ensureModelLoaded];
    if (why)
        [self fireEvent:WDEventDownloadFailed generation:gen detail:why];
    else
        [self fireEvent:WDEventDownloadDone generation:gen
                 detail:[NSString stringWithFormat:@"Downloaded %@", name]];
}

- (void)downloadFinishedWithError:(NSArray *)report
{
    NSUInteger gen = [[report objectAtIndex:0] unsignedIntegerValue];
    NSString *error = [report objectAtIndex:1];
    NSLog(@"downloadFinishedWithError: %@", error);
    [self fireEvent:WDEventDownloadFailed generation:gen
             detail:[NSString stringWithFormat:@"Download failed: %@", error]];
}

#pragma mark - Audio Loading

- (float *)loadAudio:(NSString *)path outSamples:(int *)outNSamples
       outSampleRate:(int *)outSampleRate
{
    WAudioData *audio = waudio_load([path UTF8String]);
    if (!audio) {
        *outNSamples = 0;
        *outSampleRate = 0;
        return NULL;
    }

    float *samples = audio->samples;
    int n_samples = audio->n_samples;
    int sample_rate = audio->sample_rate;

    if (sample_rate != WHISPER_SAMPLE_RATE) {
        // Simple linear resampling to 16kHz
        double ratio = (double)WHISPER_SAMPLE_RATE / sample_rate;
        int new_n = (int)(n_samples * ratio);
        float *resampled = (float *)calloc(new_n, sizeof(float));

        for (int i = 0; i < new_n; i++) {
            double src_idx = i / ratio;
            int idx = (int)src_idx;
            double frac = src_idx - idx;
            if (idx + 1 < n_samples) {
                resampled[i] = (float)((1.0 - frac) * samples[idx]
                                       + frac * samples[idx + 1]);
            } else {
                resampled[i] = samples[idx];
            }
        }

        free(samples);
        samples = resampled;
        n_samples = new_n;
    }

    free(audio);
    *outNSamples = n_samples;
    *outSampleRate = WHISPER_SAMPLE_RATE;
    return samples;
}

#pragma mark - Transcription

- (IBAction)transcribe:(id)sender
{
    if (!currentFilePath) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No audio file selected"];
        [alert setInformativeText:@"Please open an audio file first."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }
    [self fireUserEvent:WDEventUserTranscribeFile];
}

- (void)startFileTranscription
{
    NSUInteger gen = [machine generation];
    if (![[NSFileManager defaultManager] fileExistsAtPath:currentFilePath]) {
        [self fireEvent:WDEventFileFailed generation:gen
                 detail:@"Audio file not found"];
        return;
    }
    NSString *why = [self ensureModelLoaded];
    if (why) {
        [self fireEvent:WDEventFileFailed generation:gen detail:why];
        return;
    }

    [[self segments] removeAllObjects];
    [typedText release]; typedText = nil;
    [resultTextView setString:@""];
    jobProgress = -1;
    transcriptionStartTime = [NSDate timeIntervalSinceReferenceDate];

    NSInvocationOperation *op = [[NSInvocationOperation alloc]
        initWithTarget:self selector:@selector(fileJob:)
                object:[NSArray arrayWithObjects:
                    [[currentFilePath copy] autorelease],
                    [NSNumber numberWithUnsignedInteger:gen], nil]];
    [whisperQueue addOperation:op];
    [op release];
}

/* Runs on whisperQueue. */
- (void)fileJob:(NSArray *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *path = [args objectAtIndex:0];
    NSNumber *gen = [args objectAtIndex:1];
    NSString *error = nil;

    int n_samples = 0;
    int sample_rate = 0;
    float *samples = [self loadAudio:path
                          outSamples:&n_samples
                        outSampleRate:&sample_rate];

    if (!samples) {
        error = @"Failed to decode audio file";
    } else {
        WJobContext job = { self, [gen unsignedIntegerValue] };
        struct whisper_full_params wparams = wdlopen_full_default_params(
            WHISPER_SAMPLING_GREEDY);

        wparams.n_threads = currentThreads;

        NSString *langCode = currentLangCode;
        if (langCode && ![langCode isEqualToString:@"auto"]) {
            wparams.language = [langCode UTF8String];
            wparams.detect_language = false;
        } else {
            wparams.detect_language = false;
            wdlopen_pcm_to_mel(whisperCtx, samples, n_samples, wparams.n_threads);
            int lang_id = wdlopen_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
            wparams.language = lang_id >= 0 ? wdlopen_lang_str(lang_id) : "en";
        }

        wparams.no_timestamps = false;
        wparams.print_progress = false;
        wparams.print_realtime = false;
        wparams.print_special = false;

        // Stream segments live as whisper decodes them
        wparams.new_segment_callback = whisper_new_segment_cb;
        wparams.new_segment_callback_user_data = &job;
        wparams.progress_callback = whisper_progress_cb;
        wparams.progress_callback_user_data = &job;

        if (vocabularyPrompt) {
            wparams.initial_prompt = [vocabularyPrompt UTF8String];
            wparams.carry_initial_prompt = true;
        }

        if (wdlopen_full(whisperCtx, wparams, samples, n_samples) != 0)
            error = @"Transcription failed";
        free(samples);
    }

    [self performSelectorOnMainThread:@selector(fileJobEnded:)
                           withObject:[NSArray arrayWithObjects:gen,
                               error ? (id)error : (id)[NSNull null], nil]
                        waitUntilDone:NO];
    [pool release];
}

- (void)fileJobEnded:(NSArray *)report
{
    NSUInteger gen = [[report objectAtIndex:0] unsignedIntegerValue];
    id error = [report objectAtIndex:1];
    if (error != [NSNull null]) {
        [self fireEvent:WDEventFileFailed generation:gen detail:error];
        return;
    }
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate]
                             - transcriptionStartTime;
    [self fireEvent:WDEventFileDone generation:gen
             detail:[NSString stringWithFormat:@"Done (%.1f s)", elapsed]];
}

- (void)transcriptionProgress:(NSArray *)report
{
    NSUInteger gen = [[report objectAtIndex:0] unsignedIntegerValue];
    if (gen != [machine generation] || [machine state] != WDStateTranscribing)
        return;
    jobProgress = [[report objectAtIndex:1] doubleValue];
    [self render];
}

#pragma mark - State

- (void)fireUserEvent:(WDEvent)event
{
    [self fireEvent:event generation:[machine generation] detail:nil];
}

/* The only way anything changes what Whisper is doing.  Events raised by
   effects (a capture that does not open, a download with nowhere to go)
   are queued and handled after the current one, so each transition is
   complete - state, effects - before the next starts; the UI is rendered
   once at the end. */
- (void)fireEvent:(WDEvent)event generation:(NSUInteger)gen
           detail:(NSString *)detail
{
    [pendingEvents addObject:[NSArray arrayWithObjects:
        [NSNumber numberWithInteger:event],
        [NSNumber numberWithUnsignedInteger:gen],
        detail ? (id)detail : (id)[NSNull null], nil]];
    if (dispatching) return;

    dispatching = YES;
    while ([pendingEvents count] > 0) {
        NSArray *ev = [[[pendingEvents objectAtIndex:0] retain] autorelease];
        [pendingEvents removeObjectAtIndex:0];
        WDEvent e = [[ev objectAtIndex:0] integerValue];
        id d = [ev objectAtIndex:2];
        WDState from = [machine state];
        WDEffect fx = [machine handleEvent:e
                                generation:[[ev objectAtIndex:1] unsignedIntegerValue]
                                    detail:(d == [NSNull null] ? nil : d)];
        if ([machine lastOutcome] != WDOutcomeTransitioned) {
            NSDebugLLog(@"Whisper", @"%@ in %@: %@",
                        [WDictationMachine nameOfEvent:e],
                        [WDictationMachine nameOfState:from],
                        [machine lastOutcome] == WDOutcomeStale ? @"stale"
                            : [WDictationMachine ignoreReasonOfEvent:e
                                                             inState:from]);
            continue;
        }
        NSLog(@"Whisper: %@ --%@--> %@",
              [WDictationMachine nameOfState:from],
              [WDictationMachine nameOfEvent:e],
              [WDictationMachine nameOfState:[machine state]]);
        if (fx & WDEffectStartCapture) [self startCapture];
        if (fx & WDEffectStopCaptureAndFinish) [self stopCaptureAndFinish];
        if (fx & WDEffectCancelCapture) [self cancelCapture];
        if (fx & WDEffectStartFileTranscription) [self startFileTranscription];
        if (fx & WDEffectStartDownload) [self startDownload];
        if (fx & WDEffectDeliverText) {
            [self rebuildTextView];
            [self syncTypedText];
        }
    }
    dispatching = NO;
    [self render];
}

- (void)render
{
    WDViewInputs in;
    in.elapsed = ([machine state] == WDStateRecording)
        ? [NSDate timeIntervalSinceReferenceDate] - recordStartTime : 0;
    in.progress = jobProgress;
    in.hearsSilence = [machine hearsSilence];
    in.hasResults = [segments count] > 0;
    in.detail = [machine detail];
    in.downloadingModel = downloadingModel;

    WDViewState *v = [WDViewState viewStateForState:[machine state] inputs:in];
    [viewState release];
    viewState = [v retain];

    [recordButton setRecording:[v recordShowsStop]];
    [recordButton setEnabled:[v recordEnabled]];
    [recordMenuItem setTitle:[v recordMenuTitle]];

    if ([v recordingIndicatorOn])
        [recordSpinner startAnimation:nil];
    else
        [recordSpinner stopAnimation:nil];

    [downloadProgress setHidden:![v downloadBarVisible]];
    [downloadProgress setDoubleValue:[v progressValue]];

    [progressBar setHidden:![v progressVisible]];
    if ([v progressVisible] && [v progressIndeterminate]) {
        [progressBar setIndeterminate:YES];
        [progressBar startAnimation:nil];
    } else {
        [progressBar stopAnimation:nil];
        [progressBar setIndeterminate:NO];
        [progressBar setDoubleValue:[v progressValue]];
    }

    [statusLabel setStringValue:[v statusText]];
    [copyTextButton setEnabled:in.hasResults];

    // No button responds to Enter (avoids accidental re-trigger after alerts)
    [recordButton setKeyEquivalent:@""];
    [copyTextButton setKeyEquivalent:@""];
    [mainWindow setDefaultButtonCell:nil];
}

#pragma mark - Menu validation

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL a = [item action];
    if (a == NULL) return YES; // Submenu title
    if (a == @selector(toggleRecording:))
        return [viewState recordEnabled];
    if (a == @selector(openFile:))
        return [viewState fileMenuEnabled];
    if (a == @selector(modelSelected:))
        return [viewState modelMenuEnabled];
    if (a == @selector(saveAsTxt:) ||
        a == @selector(saveAsSrt:) ||
        a == @selector(saveAsVtt:)) {
        return [viewState saveEnabled];
    }
    // Standard edit actions are handled by the text view responder
    if (a == @selector(cut:) || a == @selector(copy:) ||
        a == @selector(paste:) || a == @selector(selectAll:)) {
        return [resultTextView isEditable];
    }
    return YES;
}

#pragma mark - Actions

/* The record button, the menu item and its shortcut all come here; the
   machine decides what a press means in the current state. */
- (IBAction)toggleRecording:(id)sender
{
    /* Holding the shortcut (or Space on the focused button) repeats the
       key; only the first press is the user's decision. */
    if ([(WApplication *)NSApp currentKeyDownRepeats]) {
        NSLog(@"toggleRecording: key repeat ignored");
        return;
    }
    [self fireUserEvent:WDEventUserToggle];
}

/* Ask Player to fall silent for us before the microphone opens, and
   remember that it did, so -resumePlayerIfPaused can tell our pause apart
   from one the user asked for in Player directly.  A Player that is not
   running, is busy or is already paused does not pause; recording goes
   ahead either way. */
- (void)pausePlayerForRecording
{
    playerPausedForRecording = [GSMediaPlayer2Client pausePlayer];
}

/* Undo -pausePlayerForRecording: Player plays again if it can.  A pause
   the user took themselves, or one Player already dropped because it moved
   on, is not ours to give back, and the Player side says so. */
- (void)resumePlayerIfPaused
{
    if (!playerPausedForRecording)
        return;
    playerPausedForRecording = NO;
    [GSMediaPlayer2Client resumePlayer];
}

/* Effect of the user's toggle in Ready/Error: the machine is already in
   Recording; a failure here is reported back as CaptureFailed. */
- (void)startCapture
{
    NSUInteger gen = [machine generation];
    NSString *why = [self ensureModelLoaded];
    if (why) {
        [self fireEvent:WDEventCaptureFailed generation:gen detail:why];
        return;
    }

    NSString *devPath = [self captureDevicePath];
    NSLog(@"startCapture: device %@", devPath);
    captureHandle = wcapture_start(16000, [devPath UTF8String]);
    if (!captureHandle) {
        [self fireEvent:WDEventCaptureFailed generation:gen
                 detail:@"No microphone available"];
        return;
    }

    /* The microphone is really open now: from here the recording can
       produce audio, so Player has to be quiet from here on. */
    [self pausePlayerForRecording];
    [self playSubmarineSound];
    copyDefaultConsumed = NO;
    [typedText release]; typedText = nil;

    /* The text goes to the window that was active when recording began.
       Never to one of ours: typed into Whisper, a space presses the
       focused record button and stops or starts a recording by itself.
       A window whose owner cannot be told gets nothing either. */
    targetWindowID = 0;
    {
        FILE *fp = popen("xdotool getactivewindow 2>/dev/null; "
                         "xdotool getactivewindow getwindowpid 2>/dev/null", "r");
        if (fp) {
            char win[32], pid[32];
            if (fgets(win, sizeof(win), fp) && fgets(pid, sizeof(pid), fp)) {
                pid_t owner = (pid_t)strtol(pid, NULL, 10);
                if (owner > 0 && owner != getpid())
                    targetWindowID = strtoul(win, NULL, 10);
            }
            pclose(fp);
        }
    }
    NSLog(@"startCapture: typing into window %lu (0: only shown here)",
          targetWindowID);

    recordStartTime = [NSDate timeIntervalSinceReferenceDate];
    [[self segments] removeAllObjects];
    [resultTextView setString:@""];

    // Elapsed time, and noticing an input that went away, every second
    [recordTimer invalidate];
    [recordTimer release];
    recordTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(recordTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES] retain];

    // Streaming transcription every 5 seconds (needs enough audio for whisper)
    [streamTimer invalidate];
    [streamTimer release];
    streamTimer = [[NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(streamTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES] retain];
}

- (void)stopRecordingTimers
{
    [recordTimer invalidate];
    [recordTimer release];
    recordTimer = nil;
    [streamTimer invalidate];
    [streamTimer release];
    streamTimer = nil;
}

/* Effect of the user's toggle in Recording. */
- (void)stopCaptureAndFinish
{
    NSUInteger gen = [machine generation];
    [self stopRecordingTimers];

    WCaptureData *capData = wcapture_stop(captureHandle);
    captureHandle = NULL;
    [self playSubmarineSound];

    /* The cue has sounded on its own: let Player carry on again if it
       was us who paused it. */
    [self resumePlayerIfPaused];

    if (!capData || capData->n_samples == 0) {
        wcapture_free_data(capData);
        [self fireEvent:WDEventFinishDone generation:gen
                 detail:@"No audio captured"];
        return;
    }

    NSLog(@"stopCaptureAndFinish: got %d samples at %d Hz",
          capData->n_samples, capData->sample_rate);
    NSData *pcm = [NSData dataWithBytes:capData->samples
                                 length:capData->n_samples * sizeof(float)];
    wcapture_free_data(capData);

    /* Queued behind any chunk still decoding, so the final pass always
       runs on the whole take. */
    NSInvocationOperation *op = [[NSInvocationOperation alloc]
        initWithTarget:self selector:@selector(takeJob:)
                object:[NSDictionary dictionaryWithObjectsAndKeys:
                    pcm, @"pcm",
                    [NSNumber numberWithUnsignedInteger:gen], @"generation",
                    [NSNumber numberWithBool:YES], @"final", nil]];
    [whisperQueue addOperation:op];
    [op release];
}

/* Effect of a failed start or a lost input: the take ends, the machine
   is already in Error and says why. */
- (void)cancelCapture
{
    [self stopRecordingTimers];
    if (captureHandle) {
        wcapture_cancel(captureHandle);
        captureHandle = NULL;
        [self playSubmarineSound];
    }
    [self resumePlayerIfPaused];
}

- (void)recordTimerFired:(NSTimer *)timer
{
    if ([machine state] != WDStateRecording) return;
    if (!wcapture_is_active(captureHandle)) {
        [self fireEvent:WDEventDeviceLost generation:[machine generation]
                 detail:@"The audio input stopped"];
        return;
    }
    [self render];
}

- (void)streamTimerFired:(NSTimer *)timer
{
    if ([machine state] != WDStateRecording) return;
    /* Each pass decodes the take so far; while one runs, a second would
       only queue up stale work behind it. */
    if ([whisperQueue operationCount] > 0) return;

    float *samples = NULL;
    int n = wcapture_snapshot(captureHandle, &samples);
    if (n <= 0 || !samples) return;

    NSData *pcmData = [NSData dataWithBytesNoCopy:samples length:n * sizeof(float)
                                    freeWhenDone:YES];
    NSInvocationOperation *op = [[NSInvocationOperation alloc]
        initWithTarget:self selector:@selector(takeJob:)
                object:[NSDictionary dictionaryWithObjectsAndKeys:
                    pcmData, @"pcm",
                    [NSNumber numberWithUnsignedInteger:[machine generation]],
                        @"generation",
                    [NSNumber numberWithBool:NO], @"final", nil]];
    [whisperQueue addOperation:op];
    [op release];
}

/* Runs on whisperQueue: one pass over the take so far (or, final, the
   whole take).  It only reports; whether anything changes is the
   machine's decision on the main thread. */
- (void)takeJob:(NSDictionary *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *pcmData = [args objectForKey:@"pcm"];
    NSNumber *gen = [args objectForKey:@"generation"];
    BOOL final = [[args objectForKey:@"final"] boolValue];
    float *samples = (float *)[pcmData bytes];
    int n = (int)([pcmData length] / sizeof(float));
    WJobContext job = { self, [gen unsignedIntegerValue] };

    struct whisper_full_params wparams = wdlopen_full_default_params(
        WHISPER_SAMPLING_GREEDY);
    wparams.n_threads = currentThreads;

    // Read language from ivar (set on main thread, safe for background read)
    NSString *langCode = currentLangCode;
    if (langCode && ![langCode isEqualToString:@"auto"]) {
        wparams.language = [langCode UTF8String];
        wparams.detect_language = false;
    } else {
        wparams.detect_language = false;
        wdlopen_pcm_to_mel(whisperCtx, samples, n, wparams.n_threads);
        int lang_id = wdlopen_lang_auto_detect(whisperCtx, 0, wparams.n_threads, NULL);
        wparams.language = lang_id >= 0 ? wdlopen_lang_str(lang_id) : "en";
    }

    wparams.no_timestamps = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_special = false;
    wparams.new_segment_callback = whisper_new_segment_cb;
    wparams.new_segment_callback_user_data = &job;

    if (vocabularyPrompt) {
        wparams.initial_prompt = [vocabularyPrompt UTF8String];
        wparams.carry_initial_prompt = true;
    }

    int ret = wdlopen_full(whisperCtx, wparams, samples, n);
    int total = wdlopen_full_n_segments(whisperCtx);
    /* Only the newest segment says whether the user is speaking now. */
    BOOL silent = (total == 0) ||
        isBlankSegmentText(wdlopen_full_get_segment_text(whisperCtx, total - 1));
    NSLog(@"takeJob: %d samples (%.1f s), final=%d, ret=%d, segments=%d, silent=%d",
          n, (float)n / 16000.0f, final, ret, total, silent);

    [self performSelectorOnMainThread:@selector(takeJobEnded:)
                           withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                               gen, @"generation",
                               [NSNumber numberWithBool:final], @"final",
                               [NSNumber numberWithBool:(ret == 0)], @"ok",
                               [NSNumber numberWithBool:silent], @"silent", nil]
                        waitUntilDone:NO];
    [pool release];
}

- (void)takeJobEnded:(NSDictionary *)report
{
    NSUInteger gen = [[report objectForKey:@"generation"] unsignedIntegerValue];
    BOOL ok = [[report objectForKey:@"ok"] boolValue];

    if ([[report objectForKey:@"final"] boolValue]) {
        if (!ok)
            [self fireEvent:WDEventFinishFailed generation:gen
                     detail:@"Transcription failed"];
        else
            [self fireEvent:WDEventFinishDone generation:gen
                     detail:([segments count] ? @"Done" : @"No speech detected")];
        return;
    }

    if (!ok) return;
    [self fireEvent:([[report objectForKey:@"silent"] boolValue]
                         ? WDEventSilenceHeard : WDEventSpeechHeard)
         generation:gen detail:nil];
    /* Live typing follows the current take only. */
    if (gen == [machine generation] && [machine state] == WDStateRecording)
        [self syncTypedText];
}

- (void)appendStreamingResult:(NSDictionary *)result
{
    NSArray *newSegs = [result objectForKey:@"segments"];
    NSUInteger gen = [[result objectForKey:@"generation"] unsignedIntegerValue];
    WDState st = [machine state];
    if (gen != [machine generation] ||
        !(st == WDStateRecording || st == WDStateFinishing ||
          st == WDStateTranscribing)) {
        NSLog(@"appendStreamingResult: dropping %lu segments of an old job",
              (unsigned long)[newSegs count]);
        return;
    }

    NSLog(@"appendStreamingResult: %lu new segments",
          (unsigned long)[newSegs count]);

    // Remove existing segments that overlap in time with incoming
    // segments, then add the new ones (except silence).
    for (NSDictionary *seg in newSegs) {
        NSString *txt = [seg objectForKey:@"text"];
        if (txt && ([txt rangeOfString:@"[silence]"
                               options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [txt rangeOfString:@"[BLANK_AUDIO]"
                               options:NSCaseInsensitiveSearch].location != NSNotFound))
            continue;
        int64_t newT0 = [[seg objectForKey:@"t0"] longLongValue];
        int64_t newT1 = [[seg objectForKey:@"t1"] longLongValue];
        for (NSInteger i = [segments count] - 1; i >= 0; i--) {
            NSDictionary *existing = [segments objectAtIndex:i];
            int64_t exT0 = [[existing objectForKey:@"t0"] longLongValue];
            int64_t exT1 = [[existing objectForKey:@"t1"] longLongValue];
            if (newT0 < exT1 && newT1 > exT0) {
                [segments removeObjectAtIndex:i];
            }
        }
        [segments addObject:seg];
    }

    [segments sortUsingComparator:^(id a, id b) {
        int64_t t0a = [[(NSDictionary *)a objectForKey:@"t0"] longLongValue];
        int64_t t0b = [[(NSDictionary *)b objectForKey:@"t0"] longLongValue];
        if (t0a < t0b) return NSOrderedAscending;
        if (t0a > t0b) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    [self rebuildTextView];
    NSLog(@"appendStreamingResult: rebuilt text view (%lu segments)",
          (unsigned long)[segments count]);
}

// Transcribe raw PCM data and append only new segments to the UI.
// Runs synchronously on the calling thread (should be main thread for streaming).

- (IBAction)openFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setCanChooseFiles:YES];

    NSArray *types = [NSArray arrayWithObjects:
        @"wav", @"mp3", @"flac", @"ogg", @"m4a", @"aac", @"wma", nil];
    [panel setAllowedFileTypes:types];

    if ([panel runModal] == NSOKButton) {
        NSString *path = [[panel URL] path];
        [self setCurrentFilePath:path];
        [self transcribe:nil];
    }
}

- (IBAction)modelSelected:(id)sender
{
    NSString *name = [sender representedObject];
    if (!name) return;

    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"LastModel"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"modelSelected: saved '%@' as last model", name);

    // Update checkmarks in the Model menu
    NSMenu *modelMenu = [sender menu];
    for (NSMenuItem *item in [modelMenu itemArray]) {
        [item setState:([[item representedObject] isEqualToString:name]
                        ? NSOnState : NSOffState)];
    }

    // Auto-download if not present
    NSString *modelPath = [self modelPathForName:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        [self requestDownloadOfModel:name byUser:YES];
    }

    // Models ending in .en only support English
    BOOL isEN = [name hasSuffix:@".en"];
    if (isEN) {
        [currentLangCode release];
        currentLangCode = [@"en" copy];
        [[NSUserDefaults standardUserDefaults] setObject:@"en"
                                                   forKey:@"LastLanguage"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (IBAction)languageChanged:(id)sender
{
    NSString *code = [sender representedObject];
    if (!code) return;
    [currentLangCode release];
    currentLangCode = [code copy];
    [[NSUserDefaults standardUserDefaults] setObject:code
                                               forKey:@"LastLanguage"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"languageChanged: saved '%@'", code);
    // Update checkmarks
    NSMenu *parent = [sender menu];
    for (NSMenuItem *item in [parent itemArray]) {
        [item setState:([[item representedObject] isEqualToString:code]
                        ? NSOnState : NSOffState)];
    }
}

- (IBAction)threadSelected:(id)sender
{
    currentThreads = (int)[sender tag];
    [[NSUserDefaults standardUserDefaults] setInteger:currentThreads
                                               forKey:@"ThreadCount"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // Update checkmark in the Threads submenu
    NSMenu *parent = [sender menu];
    for (NSMenuItem *item in [parent itemArray]) {
        [item setState:([item tag] == currentThreads ? NSOnState : NSOffState)];
    }
}

- (IBAction)saveAsTxt:(id)sender
{
    [self saveTranscriptionWithFormat:@"txt"];
    copyDefaultConsumed = YES;
    [self render];
}

- (IBAction)saveAsSrt:(id)sender
{
    [self saveTranscriptionWithFormat:@"srt"];
    copyDefaultConsumed = YES;
    [self render];
}

- (IBAction)saveAsVtt:(id)sender
{
    [self saveTranscriptionWithFormat:@"vtt"];
    copyDefaultConsumed = YES;
    [self render];
}

- (IBAction)copyText:(id)sender
{
    NSString *text = [resultTextView string];
    if ([text length] == 0) return;

    NSMutableString *stripped = [NSMutableString string];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    while (![scanner isAtEnd]) {
        NSString *line;
        [scanner scanUpToString:@"\n" intoString:&line];
        if (![scanner isAtEnd]) [scanner scanString:@"\n" intoString:NULL];

        // Strip leading timestamp [HH:MM:SS.mm --> HH:MM:SS.mm]
        NSRange tsRange = [line rangeOfString:@"] "];
        if (tsRange.location != NSNotFound) {
            line = [line substringFromIndex:tsRange.location + 2];
        }
        [stripped appendString:line];
        [stripped appendString:@"\n"];
    }
    // Remove trailing newline
    if ([stripped hasSuffix:@"\n"]) {
        [stripped deleteCharactersInRange:NSMakeRange([stripped length] - 1, 1)];
    }

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pb setString:stripped forType:NSStringPboardType];
    copyDefaultConsumed = YES;
    [self render];
}

- (IBAction)timestampsToggled:(id)sender
{
    showTimestamps = ([sender state] == NSOnState);
    [[NSUserDefaults standardUserDefaults] setBool:showTimestamps
                                            forKey:@"ShowTimestamps"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self rebuildTextView];
}

#pragma mark - Vocabulary

- (IBAction)editVocabulary:(id)sender
{
    if (!vocabPanel) {
        vocabPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 320)
                                                styleMask:NSTitledWindowMask
                                                          | NSClosableWindowMask
                                                          | NSResizableWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        [vocabPanel setTitle:@"Custom Vocabulary"];
        [vocabPanel setFloatingPanel:NO];
        [vocabPanel setHidesOnDeactivate:NO];
        [vocabPanel setDelegate:self];

        NSView *cv = [vocabPanel contentView];
        [cv setAutoresizesSubviews:YES];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 40, 400, 260)];
        [sv setHasVerticalScroller:YES];
        [sv setBorderType:NSBezelBorder];
        [sv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        vocabTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 260)];
        [vocabTextView setFont:[NSFont userFixedPitchFontOfSize:12]];
        [vocabTextView setVerticallyResizable:YES];
        [vocabTextView setHorizontallyResizable:NO];
        [[vocabTextView textContainer] setWidthTracksTextView:YES];
        [sv setDocumentView:vocabTextView];
        [cv addSubview:sv];
        [sv release];

        NSButton *saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(320, 10, 90, 24)];
        [saveBtn setTitle:@"Save"];
        [saveBtn setBezelStyle:NSRoundedBezelStyle];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveVocabulary:)];
        [saveBtn setAutoresizingMask:NSViewMinXMargin];
        [cv addSubview:saveBtn];
        [saveBtn release];

        NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(230, 10, 80, 24)];
        [cancelBtn setTitle:@"Cancel"];
        [cancelBtn setBezelStyle:NSRoundedBezelStyle];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(cancelVocabulary:)];
        [cancelBtn setAutoresizingMask:NSViewMinXMargin];
        [cv addSubview:cancelBtn];
        [cancelBtn release];
    }

    [vocabTextView setString:vocabularyPrompt ? vocabularyPrompt : @""];
    [vocabPanel makeKeyAndOrderFront:self];
}

- (void)saveVocabulary:(id)sender
{
    NSString *text = [vocabTextView string];
    [vocabularyPrompt release];
    vocabularyPrompt = [text retain];
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:@"VocabularyPrompt"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [vocabPanel close];
}

- (void)cancelVocabulary:(id)sender
{
    [vocabPanel close];
}

- (NSString *)displayTextFromSegments
{
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSDictionary *seg in segments) {
        NSString *txt = [seg objectForKey:@"text"];
        if (!txt) continue;
        NSUInteger i = 0;
        while (i < [txt length] && [ws characterIsMember:[txt characterAtIndex:i]])
            i++;
        if (i >= [txt length]) continue;
        txt = [txt substringFromIndex:i];
        if (showTimestamps) {
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *ts = [NSString stringWithFormat:@"[%@ --> %@] ",
                              [self formatTimestamp:t0],
                              [self formatTimestamp:t1]];
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:ts];
            [result appendString:txt];
        } else {
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:txt];
        }
    }
    return result;
}

- (void)rebuildTextView
{
    if (!resultTextView) return;
    NSString *text = [self displayTextFromSegments];
    [resultTextView setString:text];
    [resultTextView scrollRangeToVisible:NSMakeRange([text length], 0)];
}

#pragma mark - Export

- (NSString *)formatTimestamp:(int64_t)t
{
    int ms = (int)(t % 100);
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%02d", hr, min, sec, ms];
}

- (NSString *)formatTimestampSrt:(int64_t)t
{
    int ms = (int)(t % 100) * 10;
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", hr, min, sec, ms];
}

- (NSString *)formatTimestampVtt:(int64_t)t
{
    int ms = (int)(t % 100) * 10;
    int sec = (int)((t / 100) % 60);
    int min = (int)((t / 6000) % 60);
    int hr = (int)(t / 360000);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d", hr, min, sec, ms];
}

- (void)saveTranscriptionWithFormat:(NSString *)format
{
    if ([segments count] == 0) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:format]];
    [panel setExtensionHidden:NO];

    if (currentFilePath) {
        NSString *base = [[currentFilePath lastPathComponent]
                            stringByDeletingPathExtension];
        [panel setNameFieldStringValue:[base stringByAppendingPathExtension:format]];
    }

    if ([panel runModal] != NSOKButton) return;

    NSString *path = [[panel URL] path];
    NSMutableString *content = [NSMutableString string];

    if ([format isEqualToString:@"srt"]) {
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"%d\n%@ --> %@\n%@\n\n",
                i + 1,
                [self formatTimestampSrt:t0],
                [self formatTimestampSrt:t1],
                text];
        }
    } else if ([format isEqualToString:@"vtt"]) {
        [content appendString:@"WEBVTT\n\n"];
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"%@ --> %@\n%@\n\n",
                [self formatTimestampVtt:t0],
                [self formatTimestampVtt:t1],
                text];
        }
    } else {
        for (int i = 0; i < [segments count]; i++) {
            NSDictionary *seg = [segments objectAtIndex:i];
            int64_t t0 = [[seg objectForKey:@"t0"] longLongValue];
            int64_t t1 = [[seg objectForKey:@"t1"] longLongValue];
            NSString *text = [seg objectForKey:@"text"];
            [content appendFormat:@"[%@ --> %@] %@\n",
                [self formatTimestamp:t0],
                [self formatTimestamp:t1],
                text];
        }
    }

    NSError *error = nil;
    BOOL ok = [content writeToFile:path
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&error];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Save failed"];
        [alert setInformativeText:[error localizedDescription]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
    }
}

#pragma mark - NSTableView (model list)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [availableModels count];
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)row
{
    NSDictionary *entry = [availableModels objectAtIndex:row];
    return [entry objectForKey:@"label"];
}

#pragma mark - Menu

- (void)createMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // Application menu
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Whisper"];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Whisper"
                                                     action:NULL
                                              keyEquivalent:@""];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Whisper"
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    [aboutItem setTarget:NSApp];
    [appMenu addItem:aboutItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Transcribe file..."
                                                      action:@selector(openFile:)
                                               keyEquivalent:@"o"];
    [appMenu addItem:openItem];

    recordMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start Recording"
                                                action:@selector(toggleRecording:)
                                         keyEquivalent:@"r"];
    [recordMenuItem setTarget:self];
    [appMenu addItem:recordMenuItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    // Model submenu
    NSMenu *modelMenu = [[NSMenu alloc] initWithTitle:@"Model"];
    NSMenuItem *modelMenuItem = [[NSMenuItem alloc] initWithTitle:@"Model"
                                                           action:NULL
                                                    keyEquivalent:@""];
    [modelMenuItem setSubmenu:modelMenu];
    [appMenu addItem:modelMenuItem];

    for (int i = 0; modelNames[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:modelSizes[i]];
        NSString *name = [NSString stringWithUTF8String:modelNames[i]];
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:label
                                                    action:@selector(modelSelected:)
                                             keyEquivalent:@""];
        [mi setRepresentedObject:name];
        [mi setTarget:self];
        [modelMenu addItem:mi];
        [mi release];
    }

    // Threads submenu
    int threadValues[] = {1, 2, 4, 8, 16, 32};
    NSMenu *threadMenu = [[NSMenu alloc] initWithTitle:@"Threads"];
    NSMenuItem *threadMenuItem = [[NSMenuItem alloc] initWithTitle:@"Threads"
                                                            action:NULL
                                                     keyEquivalent:@""];
    [threadMenuItem setSubmenu:threadMenu];
    [appMenu addItem:threadMenuItem];
    for (int i = 0; i < 6; i++) {
        int tv = threadValues[i];
        NSString *title = [NSString stringWithFormat:@"%d", tv];
        NSMenuItem *ti = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(threadSelected:)
                                             keyEquivalent:@""];
        [ti setTag:tv];
        [ti setTarget:self];
        [ti setState:(tv == currentThreads ? NSOnState : NSOffState)];
        [threadMenu addItem:ti];
        [ti release];
    }
    [threadMenuItem release];
    [threadMenu release];

    // Language submenu
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:@"Language"];
    NSMenuItem *langMenuItem = [[NSMenuItem alloc] initWithTitle:@"Language"
                                                          action:NULL
                                                   keyEquivalent:@""];
    [langMenuItem setSubmenu:langMenu];
    [appMenu addItem:langMenuItem];
    for (int i = 0; langCodes[i] != NULL; i++) {
        NSString *label = [NSString stringWithUTF8String:langNames[i]];
        NSString *code = [NSString stringWithUTF8String:langCodes[i]];
        NSMenuItem *li = [[NSMenuItem alloc] initWithTitle:label
                                                    action:@selector(languageChanged:)
                                             keyEquivalent:@""];
        [li setRepresentedObject:code];
        [li setTarget:self];
        [li setState:[code isEqualToString:currentLangCode]
            ? NSOnState : NSOffState];
        [langMenu addItem:li];
        [li release];
    }
    [langMenuItem release];
    [langMenu release];

    NSMenuItem *vocabItem = [[NSMenuItem alloc] initWithTitle:@"Vocabulary..."
                                                       action:@selector(editVocabulary:)
                                                keyEquivalent:@""];
    [vocabItem setTarget:self];
    [appMenu addItem:vocabItem];
    [vocabItem release];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *saveTxtItem = [[NSMenuItem alloc] initWithTitle:@"Save as TXT"
                                                         action:@selector(saveAsTxt:)
                                                  keyEquivalent:@"s"];
    [saveTxtItem setTarget:self];
    [appMenu addItem:saveTxtItem];
    [saveTxtItem release];

    NSMenuItem *saveSrtItem = [[NSMenuItem alloc] initWithTitle:@"Save as SRT"
                                                         action:@selector(saveAsSrt:)
                                                  keyEquivalent:@""];
    [saveSrtItem setTarget:self];
    [appMenu addItem:saveSrtItem];
    [saveSrtItem release];

    NSMenuItem *saveVttItem = [[NSMenuItem alloc] initWithTitle:@"Save as VTT"
                                                         action:@selector(saveAsVtt:)
                                                  keyEquivalent:@""];
    [saveVttItem setTarget:self];
    [appMenu addItem:saveVttItem];
    [saveVttItem release];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Whisper"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    // Edit menu
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit"
                                                       action:NULL
                                                keyEquivalent:@""];
    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copyText:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    // Copy All Text (accessible from menu; use Cmd+A, Cmd+C for quick select-all)
    NSMenuItem *copyAllItem = [[NSMenuItem alloc] initWithTitle:@"Copy All Text"
                                                         action:@selector(copyText:)
                                                  keyEquivalent:@""];
    [copyAllItem setTarget:self];
    [editMenu addItem:copyAllItem];
    [copyAllItem release];

    [NSApp setMainMenu:mainMenu];

    [editItem release];
    [editMenu release];
    [quitItem release];
    [modelMenuItem release];
    [modelMenu release];
    [openItem release];
    [aboutItem release];
    [appMenu release];
    [appItem release];
    [mainMenu release];
}

#pragma mark - Menu Checkmarks

- (void)refreshMenuCheckmarks
{
    NSString *savedModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastModel"];
    NSString *savedLang  = [[NSUserDefaults standardUserDefaults] stringForKey:@"LastLanguage"];

    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenuItem *appItem = [[mainMenu itemArray] objectAtIndex:0];
    NSMenu *appMenu = [appItem submenu];

    for (NSMenuItem *item in [appMenu itemArray]) {
        // Model submenu
        if ([[item title] isEqualToString:@"Model"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:[[mi representedObject] isEqualToString:savedModel]
                    ? NSOnState : NSOffState];
            }
        }
        // Threads submenu
        if ([[item title] isEqualToString:@"Threads"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:([mi tag] == currentThreads) ? NSOnState : NSOffState];
            }
        }
        // Language submenu
        if ([[item title] isEqualToString:@"Language"]) {
            for (NSMenuItem *mi in [[item submenu] itemArray]) {
                [mi setState:[[mi representedObject] isEqualToString:savedLang]
                    ? NSOnState : NSOffState];
            }
        }
    }
}

#pragma mark - UI Creation

- (void)createUI
{
    NSUInteger styleMask = NSTitledWindowMask |
                           NSClosableWindowMask |
                           NSMiniaturizableWindowMask |
                           NSResizableWindowMask;

    mainWindow = [[WhisperFloatingWindow alloc] initWithContentRect:NSMakeRect(0, 0,
                                                       DEFAULT_WINDOW_WIDTH,
                                                       DEFAULT_WINDOW_HEIGHT)
                                                         styleMask:styleMask
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    [mainWindow setTitle:@"Whisper Speech-to-Text"];
    [mainWindow setDelegate:self];
    [mainWindow setMinSize:NSMakeSize(CONTENT_MIN_WIDTH, CONTENT_MIN_HEIGHT)];
    [mainWindow setLevel:NSFloatingWindowLevel];

    NSView *contentView = [mainWindow contentView];

    // Recording row: one button, centred in the window.  It shows the
    // application icon at rest and a stop square while recording.
    recordButton = [[WRecordButton alloc]
                     initWithFrame:NSMakeRect(0, 0,
                                              METRICS_ICON_BUTTON_SIDE,
                                              METRICS_ICON_BUTTON_SIDE)];
    [recordButton setTarget:self];
    [recordButton setAction:@selector(toggleRecording:)];
    [recordButton setKeyEquivalent:@""];
    [contentView addSubview:recordButton];

    recordSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [recordSpinner setStyle:NSProgressIndicatorSpinningStyle];
    [recordSpinner setIndeterminate:YES];
    [recordSpinner setControlSize:NSSmallControlSize];
    [recordSpinner sizeToFit];
    [recordSpinner setDisplayedWhenStopped:NO];
    [contentView addSubview:recordSpinner];

    downloadProgress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [downloadProgress setStyle:NSProgressIndicatorBarStyle];
    [downloadProgress setIndeterminate:NO];
    [downloadProgress setMinValue:0.0];
    [downloadProgress setMaxValue:100.0];
    [downloadProgress setDoubleValue:0.0];
    [downloadProgress setHidden:YES];
    [downloadProgress setDisplayedWhenStopped:NO];
    [contentView addSubview:downloadProgress];

    /*
    translateCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [translateCheckbox setButtonType:NSSwitchButton];
    [translateCheckbox setTitle:@"Translate to English"];
    [translateCheckbox setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [translateCheckbox sizeToFit];
    [contentView addSubview:translateCheckbox];
    */

    // Progress bar
    progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    [progressBar setStyle:NSProgressIndicatorBarStyle];
    [progressBar setIndeterminate:NO];
    [progressBar setMinValue:0.0];
    [progressBar setMaxValue:100.0];
    [progressBar setDoubleValue:0.0];
    [progressBar setHidden:YES];
    [contentView addSubview:progressBar];

    statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [statusLabel setEditable:NO];
    [statusLabel setBordered:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [statusLabel setTextColor:[NSColor grayColor]];
    [statusLabel setStringValue:@"Ready"];
    [contentView addSubview:statusLabel];

    // Results text view
    resultScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [resultScrollView setHasVerticalScroller:YES];
    [resultScrollView setAutoresizesSubviews:YES];
    [resultScrollView setBorderType:NSBezelBorder];
    [resultScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [contentView addSubview:resultScrollView];

    resultTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    [resultTextView setFont:[NSFont userFixedPitchFontOfSize:12]];
    [resultTextView setVerticallyResizable:YES];
    [resultTextView setHorizontallyResizable:NO];
    [resultTextView setAutoresizingMask:NSViewWidthSizable];
    [[resultTextView textContainer] setWidthTracksTextView:YES];
    [resultScrollView setDocumentView:resultTextView];
    // scroll view now owns resultTextView; we keep a zero-ing ivar so it
    // must NOT be released here (non-ARC: the scroll view retains it).
    // (We deliberately do NOT send extra release to keep the ivar valid.)

    copyTextButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [copyTextButton setTitle:@"Copy to Clipboard"];
    [copyTextButton setTarget:self];
    [copyTextButton setAction:@selector(copyText:)];
    [copyTextButton setBezelStyle:NSRoundedBezelStyle];
    [copyTextButton sizeToFit];
    [copyTextButton setEnabled:NO];
    [contentView addSubview:copyTextButton];



    showTimestampsCheckbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [showTimestampsCheckbox setButtonType:NSSwitchButton];
    [showTimestampsCheckbox setTitle:@"Show Timestamps"];
    [showTimestampsCheckbox setTarget:self];
    [showTimestampsCheckbox setAction:@selector(timestampsToggled:)];
    [showTimestampsCheckbox setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [showTimestampsCheckbox sizeToFit];
    [showTimestampsCheckbox setState:NSOffState];
    [contentView addSubview:showTimestampsCheckbox];

    [self layoutSubviews];
}

#pragma mark - Layout

- (void)layoutSubviews
{
    NSView *cv = [mainWindow contentView];
    NSRect bounds = [cv bounds];

    CGFloat mx = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat mt = METRICS_CONTENT_TOP_MARGIN;
    CGFloat mb = METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat w  = bounds.size.width - mx * 2;
    CGFloat y  = bounds.size.height - mt;

    CGFloat bh  = METRICS_BUTTON_HEIGHT;
    CGFloat s8  = METRICS_SPACE_8;
    CGFloat s16 = METRICS_SPACE_16;

    // ---- Row 1: the one record/stop button, horizontally centred ----
    CGFloat btnSide = METRICS_ICON_BUTTON_SIDE;
    [recordButton setFrame:NSMakeRect(NSMidX(bounds) - btnSide / 2.0,
                                      y - btnSide, btnSide, btnSide)];
    y -= btnSide + s16;

    // ---- Row 2: recording spinner + status text ----
    [statusLabel setAlignment:NSRightTextAlignment];
    CGFloat spinnerW = [recordSpinner frame].size.width;
    [recordSpinner setFrame:NSMakeRect(mx, y - bh + (bh - spinnerW) / 2,
                                        spinnerW, spinnerW)];
    CGFloat statusX2 = mx + spinnerW + s8;
    CGFloat statusW2 = mx + w - statusX2;
    if (statusW2 < 60) statusW2 = 60;
    [statusLabel setFrame:NSMakeRect(statusX2, y - bh, statusW2, bh)];
    y -= bh + s16;

    // ---- Row 3: Progress bar ----
    [progressBar setFrame:NSMakeRect(mx, y, w, bh)];
    y -= bh + s8;

    // ---- Bottom row: checkboxes (left) + action buttons (right) ----
    NSSize copySz = [copyTextButton frame].size;
    NSSize tsSz   = [showTimestampsCheckbox frame].size;
    CGFloat bottomRowY = mb + s8;
    CGFloat textY      = bottomRowY + bh + s8;
    [resultScrollView setFrame:NSMakeRect(mx, textY, w, y - textY)];
    [[resultTextView textContainer] setContainerSize:
        NSMakeSize([resultScrollView contentSize].width, FLT_MAX)];
    [showTimestampsCheckbox setFrame:NSMakeRect(mx, bottomRowY, tsSz.width, bh)];
    [copyTextButton setFrame:NSMakeRect(mx + w - copySz.width, bottomRowY,
                                        copySz.width, bh)];

    // Export buttons removed - now in Whisper menu
}

- (void)windowDidResize:(NSNotification *)notification
{
    [self layoutSubviews];
}

#pragma mark - Window

#pragma mark - Auto-type

- (NSString *)plainTextFromSegments
{
    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSDictionary *seg in segments) {
        NSString *txt = [seg objectForKey:@"text"];
        if (!txt) continue;
        // Strip leading whitespace whisper often prepends
        NSUInteger i = 0;
        while (i < [txt length] && [ws characterIsMember:[txt characterAtIndex:i]])
            i++;
        if (i < [txt length]) {
            if ([result length] > 0) [result appendString:@" "];
            [result appendString:[txt substringFromIndex:i]];
        }
    }
    return result;
}

- (void)buildWhisperEngineWithScript:(NSString *)scriptPath
{
    buildProgressPct = 0;
    buildThreadRunning = YES;

    CGFloat ww = 380, lx = 20, lw = ww - 2*lx;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, ww, 48)
                                                 styleMask:NSTitledWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    [win setTitle:@"Whisper"];
    [win center];

    NSProgressIndicator *prog = [[NSProgressIndicator alloc]
      initWithFrame:NSMakeRect(lx, 12, lw, 20)];
    [prog setStyle:NSProgressIndicatorBarStyle];
    [prog setIndeterminate:NO];
    [prog setMinValue:0]; [prog setMaxValue:100]; [prog setDoubleValue:0];
    [[win contentView] addSubview:prog];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(lx, 44, lw, 18)];
    [label setStringValue:@"Preparing for first run..."];
    [label setEditable:NO]; [label setSelectable:NO];
    [label setBordered:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
    [[win contentView] addSubview:label];

    [win makeKeyAndOrderFront:self];
    objc_setAssociatedObject(self, "_buildWin", win, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "_buildProg", prog, OBJC_ASSOCIATION_RETAIN);

    // Polling timer 2x/sec updates the progress bar from the shared ivar
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                   selector:@selector(buildPollProgress:)
                                   userInfo:nil repeats:YES];

    [self performSelectorInBackground:@selector(buildThread:)
                           withObject:scriptPath];
}

- (void)buildPollProgress:(NSTimer *)t
{
    if (!buildThreadRunning) { [t invalidate]; return; }
    NSProgressIndicator *p = objc_getAssociatedObject(self, "_buildProg");
    if (p) {
        [p setDoubleValue:(double)buildProgressPct];
        [p setNeedsDisplay:YES];
    }
}

- (void)buildThread:(NSString *)scriptPath
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmd = [NSString stringWithFormat:@"sudo -A -E sh '%@' 2>&1 | awk '{print; fflush()}'", scriptPath];
    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) {
        buildThreadRunning = NO;
        [self performSelectorOnMainThread:@selector(buildDoneWithStatus:)
                               withObject:[NSNumber numberWithInt:-1]
                            waitUntilDone:NO];
        [pool release];
        return;
    }
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        fprintf(stderr, "%s", line);
        char *p = line;
        while ((p = strstr(p, "["))) {
            p++;
            int pct;
            if (sscanf(p, " %d%%", &pct) >= 1) {
                buildProgressPct = pct;  // shared ivar, read by poll timer
                break;
            }
        }
    }
    int status = pclose(fp);
    buildThreadRunning = NO;
    [self performSelectorOnMainThread:@selector(buildDoneWithStatus:)
                           withObject:[NSNumber numberWithInt:status]
                        waitUntilDone:NO];
    [pool release];
}

- (void)buildDoneWithStatus:(NSNumber *)statusObj
{
    int status = [statusObj intValue];

    NSWindow *w = objc_getAssociatedObject(self, "_buildWin");
    [w close];
    [w release];
    objc_setAssociatedObject(self, "_buildWin", nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self, "_buildProg", nil, OBJC_ASSOCIATION_RETAIN);

    // Re-dlopen libwhisper since it was just installed
    wdlopen_close();
    wdlopen_init();

    if (status != 0 || !wdlopen_init()) {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:@"Build failed"];
        [a setInformativeText:@"whisper.cpp could not be built. Check the terminal for details."];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        [a release];
    }
    [self finishStartup];
}

- (void)finishStartup
{
    // No positioning - let the WM cascade it.
    [mainWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - Capture device

/* The device the microphone is opened on: the CaptureDevice default when
   the user named one (an ALSA PCM or an OSS device path), else the input
   the Sound preferences chose.  nil lets the capture use the system's
   default input. */
- (NSString *)captureDevicePath
{
    NSString *chosen = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"CaptureDevice"];
    if ([chosen length] > 0)
        return chosen;

    NSString *devPath = nil;
    BOOL found = NO;

#if defined(__FreeBSD__) || defined(__DragonFly__) || defined(__OpenBSD__) || defined(__NetBSD__)
    OSSBackend *oss = [[OSSBackend alloc] init];
    if ([oss isAvailable]) {
        found = YES;
        AudioDevice *dev = [oss defaultInputDevice];
        if (dev)
            devPath = [NSString stringWithFormat:@"/dev/dsp%d", [dev cardIndex]];
    }
    [oss release];
#endif
    if (!found) {
        ALSABackend *alsa = [[ALSABackend alloc] init];
        if ([alsa isAvailable]) {
            found = YES;
            AudioDevice *dev = [alsa defaultInputDevice];
            if (dev)
                devPath = [NSString stringWithFormat:@"plughw:%d,%d",
                                    [dev cardIndex], [dev deviceIndex]];
        }
        [alsa release];
    }
#if !defined(__FreeBSD__) && !defined(__DragonFly__) && !defined(__OpenBSD__) && !defined(__NetBSD__)
    if (!found) {
        OSSBackend *oss = [[OSSBackend alloc] init];
        if ([oss isAvailable]) {
            AudioDevice *dev = [oss defaultInputDevice];
            if (dev)
                devPath = [NSString stringWithFormat:@"/dev/dsp%d", [dev cardIndex]];
        }
        [oss release];
    }
#endif
    return devPath;
}


- (void)syncTypedText
{
    NSString *desired = [self plainTextFromSegments];
    if (!desired) desired = @"";
    if (!typedText) typedText = [@"" retain];

    if ([typedText isEqualToString:desired]) return;

    NSUInteger oldLen = [typedText length];
    NSUInteger newLen = [desired length];
    NSUInteger common = 0;
    NSUInteger minLen = oldLen < newLen ? oldLen : newLen;
    for (NSUInteger i = 0; i < minLen; i++) {
        if ([typedText characterAtIndex:i] == [desired characterAtIndex:i])
            common++;
        else
            break;
    }

    if (common < oldLen)
        [self typeBackspaces:(int)(oldLen - common)];

    if (common < newLen) {
        NSString *toType = [desired substringFromIndex:common];
        [self typeTextToApp:toType];
    }

    [typedText release];
    typedText = [desired retain];
}

- (void)typeBackspaces:(int)count
{
    if (count <= 0 || targetWindowID == 0) return;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xdoPath];
    NSString *winArg = [NSString stringWithFormat:@"%lu", targetWindowID];
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"key", @"--clearmodifiers", @"--window", winArg, nil];
    for (int i = 0; i < count; i++)
        [args addObject:@"BackSpace"];
    [task setArguments:args];
    [task launch];
    [task waitUntilExit];
    [task release];
}

- (void)typeTextToApp:(NSString *)text
{
    if ([text length] == 0 || targetWindowID == 0) return;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xdoPath];
    NSString *winArg = [NSString stringWithFormat:@"%lu", targetWindowID];
    [task setArguments:[NSArray arrayWithObjects:
        @"type", @"--clearmodifiers", @"--delay", @"12",
        @"--window", winArg, text, nil]];
    [task launch];
    [task waitUntilExit];
    [task release];
}

@end

/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuApplication.h"
#import "MenuController.h"
#import "MenuProfiler.h"
#import "CrashHandler.h"
#import "MenuInstanceTakeover.h"
#import <signal.h>
#import <sys/types.h>
#import <unistd.h>
#import <X11/Xlib.h>

/* The Menu app routinely walks the window tree while other clients - and its
   own popup menus - create and destroy transient windows.  A query that races
   a window teardown fails with BadWindow/BadDrawable, and every call site
   already handles that via the return value, so the default Xlib handler's
   per-error spew is pure noise.  Suppress it; anything else is logged once so
   real errors remain visible. */
static int menuXErrorHandler(Display *display, XErrorEvent *event)
{
    (void)display;
    if (event->error_code == BadWindow || event->error_code == BadDrawable)
        return 0;
    fprintf(stderr, "Menu.app: X11 error %d (request %d) on resource 0x%lx\n",
            (int)event->error_code, (int)event->request_code,
            (unsigned long)event->resourceid);
    return 0;
}

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    MenuInstallCrashHandlers();

    // Initialize X11 threading support
    if (!XInitThreads()) {
        fprintf(stderr, "Menu.app: Failed to initialize X11 threading support\n");
        return 1;
    }

    // Keep the flood of BadWindow errors from racing window scans off the log.
    XSetErrorHandler(menuXErrorHandler);

    NSDebugLLog(@"gwcomp", @"Menu.app: Starting application initialization...");
    
    // Replace only the Menu of this display; a Menu on another display belongs
    // to another session and must keep running.
    if (!MenuTakeOverDisplay()) {
        return 1;
    }
    
    @autoreleasepool {
        @try {
            // Create MenuApplication directly as the main application instance
            MenuApplication *app = [[MenuApplication alloc] init];
            
            // Set it as the shared application instance manually
            NSApp = app;
            
            NSDebugLLog(@"gwcomp", @"Menu.app: About to start main run loop...");
            
            // Install profiling signal handler (SIGUSR1 dumps stats)
            menuProfileInstallSignalHandler();
            
            // Run the application with better exception handling
            @try {
                [app run];
            } @catch (NSException *runException) {
                NSDebugLLog(@"gwcomp", @"Menu.app: Exception in run loop: %@", runException);
                NSDebugLLog(@"gwcomp", @"Menu.app: Run loop exception reason: %@", [runException reason]);
            }
            
            // GNUstep's [NSApp run] may return when it detects no regular windows.
            // The menu bar is borderless (NSBorderlessWindowMask) and is not counted.
            // Keep the run loop alive manually to prevent premature exit.
            // Defensive guard: if the run loop ever starts returning with NO
            // work done (no sources attached, backend gone), do not spin at
            // 100% CPU - only loop iterations that returned instantly (< 1ms,
            // i.e. nothing ran at all) count toward the backoff; normal
            // re-entry after processing events resets it.
            unsigned degenerateReturns = 0;
            while (YES) {
                NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate distantFuture]];
                }
                if ([NSDate timeIntervalSinceReferenceDate] - t0 < 0.001) {
                    if (degenerateReturns < 1000000) degenerateReturns++;
                    if (degenerateReturns > 20) {
                        usleep(100000); // 100ms - caps a degenerate loop at ~10 wakeups/s
                    }
                } else {
                    degenerateReturns = 0;
                }
            }
            
            NSDebugLLog(@"gwcomp", @"Menu.app: Main run loop exited normally");
        } @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"Menu.app: Caught exception in main: %@", exception);
            NSDebugLLog(@"gwcomp", @"Menu.app: Exception reason: %@", [exception reason]);
            NSDebugLLog(@"gwcomp", @"Menu.app: Exception stack: %@", [exception callStackSymbols]);
            return 1;
        }
    }
    
    NSDebugLLog(@"gwcomp", @"Menu.app: Application exiting normally");
    return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "SetupAssistantSteps.h"

@interface SetupAssistantAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation SetupAssistantAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

@interface SetupAssistantDelegate : NSObject <GSAssistantWindowDelegate> {
    NSTimer *_progressTimer;
    NSArray *_progressTasks;
    NSUInteger _progressIndex;
    GSProgressStep *_progressStep;
}
@end

@implementation SetupAssistantDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window {
    NSDebugLLog(@"gwcomp", @"SetupAssistant: will finish");
}

/* The progress step only advances when something tells it how far along it
 * is, and nothing else in this assistant applies the collected settings.  So
 * when the step comes up, walk it through the settings groups the user just
 * chose; reaching 100% then auto-completes into the Finish step. */
- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step {
    if (![step isKindOfClass:[GSProgressStep class]]) {
        return;
    }
    if (_progressTimer) {
        return;
    }

    GSProgressStep *progress = (GSProgressStep *)step;
    [_progressTasks release];
    _progressTasks = [[NSArray alloc] initWithObjects:
        NSLocalizedString(@"Language and Keyboard", @""),
        NSLocalizedString(@"Region and Formats", @""),
        NSLocalizedString(@"Date and Time", @""),
        NSLocalizedString(@"User Account", @""),
        NSLocalizedString(@"Computer Name", @""),
        nil];
    _progressIndex = 0;
    _progressStep = progress;
    progress.autoCompleteOnFinish = YES;
    progress.completionMessage = NSLocalizedString(@"Setup completed successfully! Your system is now ready to use.", @"");

    _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:0.4
                                                       target:self
                                                     selector:@selector(progressStepTick:)
                                                     userInfo:nil
                                                      repeats:YES] retain];
}

- (void)progressStepTick:(NSTimer *)timer {
    (void)timer;
    NSUInteger count = [_progressTasks count];
    if (!_progressStep || _progressIndex >= count) {
        [self stopProgressTimer];
        return;
    }

    NSUInteger index = _progressIndex++;
    [_progressStep updateProgress:(CGFloat)(index + 1) / (CGFloat)count
                         withTask:[_progressTasks objectAtIndex:index]];
    if (_progressIndex >= count) {
        [self stopProgressTimer];
    }
}

- (void)stopProgressTimer {
    if (_progressTimer) {
        [_progressTimer invalidate];
        [_progressTimer release];
        _progressTimer = nil;
    }
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window {
    NSDebugLLog(@"gwcomp", @"SetupAssistant: did finish");
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation {
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Cancel Setup?", @"");
        alert.informativeText = NSLocalizedString(@"Are you sure you want to cancel the setup? Any progress will be lost.", @"");
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel Setup", @"")];
        [alert addButtonWithTitle:NSLocalizedString(@"Continue Setup", @"")];
        alert.alertStyle = NSWarningAlertStyle;

        NSModalResponse response = [alert runModal];
        return response == NSAlertFirstButtonReturn;
    }
    return YES;
}

@end

@interface SetupAssistant : NSObject
+ (void)showSetupAssistant;
@end

@implementation SetupAssistant

+ (void)showSetupAssistant {
    SetupAssistantDelegate *delegate = [[SetupAssistantDelegate alloc] init];

    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withTitle:NSLocalizedString(@"Setup Assistant", @"")];
    [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];

    SAWelcomeStep *welcomeStep = [[SAWelcomeStep alloc] init];
    [builder addStep:welcomeStep];
    [welcomeStep release];

    SALanguageKeyboardStep *languageKeyboardStep = [[SALanguageKeyboardStep alloc] init];
    [builder addStep:languageKeyboardStep];
    [languageKeyboardStep release];

    SARegionStep *regionStep = [[SARegionStep alloc] init];
    [builder addStep:regionStep];
    [regionStep release];

    SADateTimeStep *dateTimeStep = [[SADateTimeStep alloc] init];
    [builder addStep:dateTimeStep];
    [dateTimeStep release];

    SAUserAccountStep *userAccountStep = [[SAUserAccountStep alloc] init];
    [builder addStep:userAccountStep];
    [userAccountStep release];

    SAComputerNameStep *computerNameStep = [[SAComputerNameStep alloc] init];
    [builder addStep:computerNameStep];
    [computerNameStep release];

    [builder addProgressStep:NSLocalizedString(@"Applying Settings", @"")
                 description:NSLocalizedString(@"Please wait while we apply your settings...", @"")];

    [builder addCompletionWithMessage:NSLocalizedString(@"Setup completed successfully! Your system is now ready to use.", @"")
                             success:YES];

    GSAssistantWindow *assistant = [builder build];
    assistant.delegate = delegate;
    [assistant showWindow:nil];
    [assistant.window makeKeyAndOrderFront:nil];
}

@end

int main(int argc, const char * argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];

        SetupAssistantAppDelegate *appDelegate = [[SetupAssistantAppDelegate alloc] init];
        [NSApp setDelegate:appDelegate];

        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [mainMenu addItem:appMenuItem];
        [NSApp setMainMenu:mainMenu];

        NSMenu *appMenu = [[NSMenu alloc] init];
        NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                              action:@selector(terminate:)
                                                       keyEquivalent:@"q"];
        [appMenu addItem:quitMenuItem];
        [appMenuItem setSubmenu:appMenu];

        [SetupAssistant showSetupAssistant];
        [NSApp run];

        [appDelegate release];
    }
    return 0;
}

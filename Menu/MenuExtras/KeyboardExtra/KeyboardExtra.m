/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KeyboardExtra.h"
#import "GSMenuExtraContext.h"
#import "KeyboardBackend.h"

@implementation KeyboardExtra
{
    GSMenuExtraContext *_context;
    /* Read from base.lst once, off the main thread: the file is large and
       -menu runs on the thread that draws every menu bar. */
    NSDictionary *_layoutNames;
    NSDictionary *_variantsByLayout;
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    /* The Keyboard pane runs in another process; this is how its changes
       reach the menu and the title at once. */
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(preferencesDidChange:)
               name:KeyboardBackendPreferencesDidChangeNotification
             object:nil];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *variants = nil;
        NSDictionary *names = [KeyboardBackend availableLayouts:&variants];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_layoutNames = names;
            self->_variantsByLayout = variants;
            [self->_context invalidatePresentation];
        });
    });
}

- (void)preferencesDidChange:(NSNotification *)note
{
    (void)note;
    [_context invalidatePresentation];
}

- (void)menuExtraWillUnload
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    _context = nil;
}

- (BOOL)isCompatibleWithSystem
{
    return [KeyboardBackend findSetxkbmap] != nil;
}

#pragma mark - State

- (NSString *)currentLayout
{
    return [[KeyboardBackend savedPreferences] objectForKey:@"layout"];
}

- (NSString *)currentVariant
{
    return [[KeyboardBackend savedPreferences] objectForKey:@"variant"];
}

- (NSString *)displayNameForLayout:(NSString *)layout variant:(NSString *)variant
{
    NSString *name = [_layoutNames objectForKey:layout];
    if (name == nil) {
        name = layout;
    }
    if (variant.length == 0) {
        return name;
    }
    for (NSDictionary *v in [_variantsByLayout objectForKey:layout]) {
        if ([[v objectForKey:@"code"] isEqualToString:variant]) {
            return [v objectForKey:@"description"];
        }
    }
    return name;
}

#pragma mark - GSMenuExtra

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
    NSString *layout = [self currentLayout];
    return layout != nil ? [layout uppercaseString] : NSLocalizedString(@"Keyboard", @"Keyboard extra: title when no layout is saved");
}

- (NSMenuItem *)itemForLayout:(NSString *)layout variant:(NSString *)variant title:(NSString *)title
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                   action:@selector(selectLayout:)
                                            keyEquivalent:@""];
    [item setTarget:self];
    [item setRepresentedObject:variant.length ? @{@"layout": layout, @"variant": variant}
                                              : @{@"layout": layout}];
    if ([KeyboardBackend menuLayouts:@[[item representedObject]] containLayout:[self currentLayout] variant:[self currentVariant]]) {
        [item setState:NSOnState];
    }
    return item;
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Keyboard"];
    NSArray *chosen = [KeyboardBackend menuLayouts];
    for (NSDictionary *entry in chosen) {
        NSString *layout = [entry objectForKey:@"layout"];
        NSString *variant = [entry objectForKey:@"variant"];
        [m addItem:[self itemForLayout:layout variant:variant
                                  title:[self displayNameForLayout:layout variant:variant]]];
    }
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *customize = [[NSMenuItem alloc] initWithTitle:
        NSLocalizedString(@"Customize...", @"Keyboard extra: opens the Keyboard preferences")
                                                       action:@selector(openKeyboardPrefs:)
                                                keyEquivalent:@""];
    [customize setTarget:self];
    [m addItem:customize];
    return m;
}

- (void)openKeyboardPrefs:(id)sender
{
    (void)sender;
    NSString *appPath = [[NSWorkspace sharedWorkspace] fullPathForApplication:@"SystemPreferences"];
    NSString *execPath = [appPath stringByAppendingPathComponent:@"SystemPreferences"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:execPath]) {
        execPath = [[NSBundle bundleWithPath:appPath] executablePath];
    }
    if (execPath == nil) {
        NSLog(@"KeyboardExtra: SystemPreferences not found");
        return;
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:execPath];
    [task setArguments:@[@"Keyboard"]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        NSLog(@"KeyboardExtra: could not open the Keyboard preferences: %@", e);
    }
}

#pragma mark - Switching

- (void)selectLayout:(NSMenuItem *)sender
{
    NSDictionary *entry = [sender representedObject];
    NSString *layout = [entry objectForKey:@"layout"];
    NSString *variant = [entry objectForKey:@"variant"];
    NSDictionary *saved = [KeyboardBackend savedPreferences];
    NSString *options = [saved objectForKey:@"options"];
    NSString *keyboardType = [saved objectForKey:@"keyboardType"];
    BOOL isApple = [[saved objectForKey:@"isApple"] boolValue];

    /* setxkbmap takes a while; the menu bar must not wait for it. */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *error = nil;
        BOOL ok = [KeyboardBackend applyLayout:layout variant:variant options:options
                                      setxkbmap:[KeyboardBackend findSetxkbmap] error:&error];
        if (ok && [KeyboardBackend needsAppleISOKeySwapForKeyboardType:keyboardType isApple:isApple]) {
            [KeyboardBackend applyAppleISOKeySwap];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSLog(@"KeyboardExtra: could not set layout %@: %@", layout, error);
                NSBeep();
                return;
            }
            [KeyboardBackend persistLayout:layout variant:variant];
            [self->_context invalidatePresentation];
        });
    });
}

@end

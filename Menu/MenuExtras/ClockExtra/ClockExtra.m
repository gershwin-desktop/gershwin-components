/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ClockExtra.h"
#import "GSMenuExtraContext.h"
#import "WorldClockList.h"
#import <time.h>


@implementation ClockExtra
{
    char _timeStr[64];
    NSDateFormatter *_timeFormatter;
    NSDateFormatter *_dateFormatter;
    NSDateFormatter *_worldClockTimeFormatter;
    NSMenuItem *_dateItem;
    NSMenu *_globalSubmenu;
    NSTimer *_globalRefreshTimer;
    GSMenuExtraContext *_context;
    BOOL _running;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Clock"];

    _dateItem = [[NSMenuItem alloc] initWithTitle:[_dateFormatter stringFromDate:[NSDate date]]
                                           action:nil keyEquivalent:@""];
    [_dateItem setEnabled:NO];
    [m addItem:_dateItem];

    [m addItem:[NSMenuItem separatorItem]];

    if (!_globalSubmenu) {
        _globalSubmenu = [[NSMenu alloc] initWithTitle:
            NSLocalizedString(@"Global", @"Clock extra: world clock submenu title")];
        /* Not declared <NSMenuDelegate> in the header: this GNUstep's
           NSMenuDelegate protocol methods are all implicitly required (no
           @optional marker), and this class only needs the three below -
           same workaround MenuExtraManager uses for its own submenus. */
        [_globalSubmenu setDelegate:(id<NSMenuDelegate>)self];
    }
    [self rebuildGlobalSubmenuItems];
    NSMenuItem *globalItem = [[NSMenuItem alloc] initWithTitle:
        NSLocalizedString(@"Global", @"Clock extra: world clock menu item")
                                                          action:NULL
                                                   keyEquivalent:@""];
    [globalItem setSubmenu:_globalSubmenu];
    [m addItem:globalItem];

    return m;
}

#pragma mark - Global submenu (world clock)

/* Rebuilds the Global submenu's rows for "now" - one representative city
   per UTC offset, the user's own zone marked, sorted by how far each is
   from the user (see WorldClockList). Called when the submenu is about to
   be shown and, while it stays open, once a minute - a world clock that
   only knew the time at the moment you opened it would already be stale a
   minute later. */
- (void)rebuildGlobalSubmenuItems
{
    if (!_globalSubmenu) return;

    NSDate *now = [NSDate date];
    NSTimeZone *userZone = [NSTimeZone localTimeZone];
    NSArray<WorldClockEntry *> *entries =
        [WorldClockList worldClockEntriesForDate:now userTimeZone:userZone];

    [_globalSubmenu removeAllItems];
    for (WorldClockEntry *entry in entries) {
        [_worldClockTimeFormatter setTimeZone:[NSTimeZone timeZoneWithName:[entry timeZoneName]]];
        NSString *time = [_worldClockTimeFormatter stringFromDate:now];
        NSString *title = [NSString stringWithFormat:@"%@ (%@) %@",
                            [entry abbreviation], [entry cityName], time];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
        [item setEnabled:NO];
        if ([entry isUserZone]) {
            [item setState:NSOnState];
        }
        [_globalSubmenu addItem:item];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu == _globalSubmenu) {
        [self rebuildGlobalSubmenuItems];
    }
}

- (void)menuWillOpen:(NSMenu *)menu
{
    if (menu != _globalSubmenu) return;
    [self rebuildGlobalSubmenuItems];
    [_globalRefreshTimer invalidate];
    _globalRefreshTimer = [NSTimer timerWithTimeInterval:60.0
                                                    target:self
                                                  selector:@selector(globalSubmenuTick:)
                                                  userInfo:nil
                                                   repeats:YES];
    /* The menu's own tracking loop runs in NSEventTrackingRunLoopMode, which
       a timer scheduled the ordinary way is not in - it would sit silent
       until the submenu closed and only then fire, defeating the point. */
    [[NSRunLoop currentRunLoop] addTimer:_globalRefreshTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:_globalRefreshTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)menuDidClose:(NSMenu *)menu
{
    if (menu != _globalSubmenu) return;
    [_globalRefreshTimer invalidate];
    _globalRefreshTimer = nil;
}

- (void)globalSubmenuTick:(NSTimer *)timer
{
    (void)timer;
    if (!_running) return;
    [self rebuildGlobalSubmenuItems];
}

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
    time_t now = time(NULL);
    struct tm *lt = localtime(&now);
    if (lt) {
        strftime(_timeStr, sizeof(_timeStr), "%H:%M", lt);
    } else {
        strncpy(_timeStr, "??:??", sizeof(_timeStr) - 1);
        _timeStr[sizeof(_timeStr) - 1] = '\0';
    }
    return [NSString stringWithUTF8String:_timeStr];
}

- (CGFloat)preferredWidth
{
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSSize size = [@"88:88" sizeWithAttributes:@{ NSFontAttributeName: font }];
    return (CGFloat)((int)(size.width + 0.999)) + 8.0;
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraWillOpenMenu
{
    [_dateItem setTitle:[_dateFormatter stringFromDate:[NSDate date]]];
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        _timeFormatter = [[NSDateFormatter alloc] init];
        [_timeFormatter setTimeStyle:NSDateFormatterShortStyle];
        [_timeFormatter setDateStyle:NSDateFormatterNoStyle];

        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setTimeStyle:NSDateFormatterNoStyle];
        [_dateFormatter setDateStyle:NSDateFormatterFullStyle];

        /* Fixed 24-hour "HH:mm", independent of locale - a world clock row
           mixes a dozen zones at once, and each already carries its own
           abbreviation for identification, so a consistent format reads
           better than a per-row AM/PM switch. The time zone is set on this
           formatter per row in -rebuildGlobalSubmenuItems. */
        _worldClockTimeFormatter = [[NSDateFormatter alloc] init];
        [_worldClockTimeFormatter setDateFormat:@"HH:mm"];
    } @catch (NSException *e) {
        NSLog(@"ClockExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _timeFormatter = nil;
        _dateFormatter = nil;
        _worldClockTimeFormatter = nil;
        _dateItem = nil;
        _context = nil;
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
    [_globalRefreshTimer invalidate];
    _globalRefreshTimer = nil;
}

- (void)refresh:(NSTimer *)timer
{
    @try {
        if (!_running) return;
        (void)timer;
        [_context invalidatePresentation];
    } @catch (NSException *e) {
        NSLog(@"ClockExtra: exception in refresh:: %@", e);
    }
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    if ([submenu numberOfItems] > 0) {
        NSMenuItem *item = [submenu itemAtIndex:0];
        [item setTitle:[_dateFormatter stringFromDate:[NSDate date]]];
    }
}

@end

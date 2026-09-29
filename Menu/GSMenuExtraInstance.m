/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraInstance.h"
#import "GSMenuExtraContext.h"
#import "MenuExtraManager.h"

@implementation GSMenuExtraInstance
{
    id<GSMenuExtra> _extra;
    NSString *_identifier;
    NSString *_displayName;
    NSInteger _priority;
    BOOL _enabledByDefault;
    GSMenuExtraContext *_context;
}

- (instancetype)initWithExtra:(id<GSMenuExtra>)extra
                   identifier:(NSString *)identifier
                  displayName:(NSString *)displayName
                     priority:(NSInteger)priority
                     manager:(MenuExtraManager *)manager
{
    self = [super init];
    if (self) {
        _extra = extra;
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _priority = priority;
        _cachedWidth = 0;

        @try {
            _enabledByDefault = [_extra respondsToSelector:@selector(enabledByDefault)] &&
                                [_extra enabledByDefault];
        } @catch (NSException *e) {
            NSLog(@"GSMenuExtraInstance: exception in enabledByDefault for %@: %@", _identifier, e);
            _enabledByDefault = NO;
        }

        _context = [[GSMenuExtraContext alloc] initWithManager:manager
                                                    identifier:_identifier];
        if ([_extra respondsToSelector:@selector(setContext:)]) {
            [_extra setContext:_context];
        }
    }
    return self;
}

- (BOOL)enabledByDefault
{
    return _enabledByDefault;
}

- (BOOL)load
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraDidLoad)]) {
            [_extra menuExtraDidLoad];
        }
        return YES;
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in load for %@: %@", _identifier, e);
        return NO;
    }
}

- (void)unload
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraWillUnload)]) {
            [_extra menuExtraWillUnload];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in unload for %@: %@", _identifier, e);
    }
}

- (NSString *)title
{
    @try {
        return [_extra title];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in title for %@: %@", _identifier, e);
        return _identifier;
    }
}

- (NSMenu *)menu
{
    @try {
        return [_extra menu];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menu for %@: %@", _identifier, e);
        return nil;
    }
}

- (NSImage *)icon
{
    @try {
        return [_extra image];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in icon for %@: %@", _identifier, e);
        return nil;
    }
}

/* The width the extra wants, or 0 to be measured from the title.
 *
 * A cached width is only reused while it is positive, so an extra that
 * reports 0 - because it has nothing to show - is measured afresh every
 * time, and the first time it has something again it is measured and kept.
 * That is what lets an extra come and go in the bar: see -invalidateWidth,
 * which is what tells the cached width it is stale. */
- (CGFloat)width
{
    if (_cachedWidth > 0) return _cachedWidth;
    NSString *display = [self title];
    if ([_extra respondsToSelector:@selector(totalWidthInMenuBar)]) {
        /* Stated as the whole item, icon and padding included. */
        CGFloat wanted = [_extra totalWidthInMenuBar];
        _cachedWidth = wanted > 0 ? wanted : 0;
    } else if ([_extra respondsToSelector:@selector(preferredWidth)]) {
        CGFloat wanted = [_extra preferredWidth];
        /* A negative width is not a width; treating it as 0 keeps a broken
           extra from pushing the rest of the bar off the screen. */
        _cachedWidth = wanted > 0 ? wanted : 0;
    } else {
        if (!display || [display length] == 0) display = @"";
        NSFont *font = [NSFont menuBarFontOfSize:0];
        NSSize size = [display sizeWithAttributes:@{ NSFontAttributeName: font }];
        _cachedWidth = (CGFloat)((int)(size.width + 0.999)) + 8.0;
    }
    return _cachedWidth;
}

- (void)invalidateWidth
{
    _cachedWidth = 0;
}

- (BOOL)isIconOnly
{
    NSString *t = [self title];
    return !t || [t length] == 0;
}

/* Whether the extra wants no room in the bar at all right now.
 *
 * An extra that does not implement -isHiddenFromMenuBar is never hidden, so
 * this is a plain NO for every extra that has not opted in. */
- (BOOL)isHiddenFromMenuBar
{
    if (![_extra respondsToSelector:@selector(isHiddenFromMenuBar)]) {
        return NO;
    }
    @try {
        return [_extra isHiddenFromMenuBar];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in isHiddenFromMenuBar for %@: %@",
              _identifier, e);
        return NO;
    }
}

- (void)tick
{
    @try {
        if ([_extra respondsToSelector:@selector(tick)]) {
            [(id)_extra tick];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in tick for %@: %@", _identifier, e);
    }
}

- (void)menuWillOpen
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraWillOpenMenu)]) {
            [_extra menuExtraWillOpenMenu];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menuWillOpen for %@: %@", _identifier, e);
    }
}

- (void)menuDidClose
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraDidCloseMenu)]) {
            [_extra menuExtraDidCloseMenu];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menuDidClose for %@: %@", _identifier, e);
    }
}

- (NSInteger)displayPriority
{
    return _priority;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %@>", [self class], _identifier];
}

@end

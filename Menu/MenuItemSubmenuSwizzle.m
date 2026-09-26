/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Lives in its own file so a test can load the very swizzle Menu runs
   with: it is what turns a menu build that frees one of its own items
   into a crash (a message to the item after the original setSubmenu:
   returns). */

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

/* ── NSMenuItem swizzle: preserve custom action after setSubmenu: ── */

/*
 * GNUstep's -[NSMenuItem setSubmenu:] calls [self setAction:@selector(submenuAction:)]
 * (NSMenuItem.m:244), overwriting any action set before it.  submenuAction: is a
 * no-op (NSMenu.m:851), so our openFolderInWorkspace: was silently lost.
 *
 * We swizzle setSubmenu: to save the action/target before the call and restore
 * them afterwards - but only when a non-nil, non-submenuAction: action was
 * already set.  This allows items with both a submenu and a custom action to
 * work: the submenu opens on hover (handled by NSMenuView's tracking loop,
 * which checks [item submenu], not the action), and the custom action fires
 * on click.
 */

#import <objc/runtime.h>

@interface NSMenuItem (GWSwizzle)
@end

@implementation NSMenuItem (GWSwizzle)

+ (void)load
{
    static BOOL swizzled = NO;
    if (swizzled) return;
    swizzled = YES;

    Method original = class_getInstanceMethod(self, @selector(setSubmenu:));
    Method swizzledM = class_getInstanceMethod(self, @selector(gw_setSubmenu:));
    method_exchangeImplementations(original, swizzledM);
}

- (void)gw_setSubmenu:(NSMenu *)submenu
{
    SEL savedAction = [self action];
    id savedTarget = [self target];

    /* Call the original setSubmenu: (now gw_setSubmenu: after swizzle). */
    [self gw_setSubmenu:submenu];

    /* Restore action/target only if a custom action was explicitly set. */
    if (savedAction && savedAction != @selector(submenuAction:))
    {
        [self setAction:savedAction];
        [self setTarget:savedTarget];
    }
}

@end

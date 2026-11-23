/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MousePane.h"
#import "MouseController.h"
#include <stdlib.h>

@implementation MousePane

/* No xinput check here: a pane that hid itself without xinput could not offer
   to install it.  OnDemand does that when the pane is selected, from the
   Dependencies.plist in this bundle. */
+ (BOOL)isCompatible {
  return YES;
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[MouseController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [controller release];
    [super dealloc];
}

- (NSView *)loadMainView
{
    if (_mainView == nil) {
        _mainView = [[controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil;
}

/* The host also loads the main view without selecting it (to index its
   labels for search), so querying and loading device state must wait until
   the pane is actually shown. */
- (void)didSelect
{
    [super didSelect];
    [controller refreshFromSystem];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end

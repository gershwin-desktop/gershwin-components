/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDIPane.h"
#import "MIDIPaneController.h"

@implementation MIDIPane
{
    MIDIPaneController *_controller;
}

- (id)initWithBundle:(NSBundle *)bundle
{
    if ((self = [super initWithBundle:bundle])) {
        _controller = [[MIDIPaneController alloc] init];
    }
    return self;
}

- (NSString *)mainNibName
{
    return nil;
}

- (NSView *)loadMainView
{
    if (_mainView == nil) {
        _mainView = [_controller createMainView];
        [self mainViewDidLoad];
    }
    return _mainView;
}

/* The backend talks to the daemon only while the pane is on screen, so a
   hidden pane neither polls nor holds a connection. */
- (void)didSelect
{
    [super didSelect];
    [_controller start];
}

- (void)didUnselect
{
    [super didUnselect];
    [_controller stop];
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Preference Pane
 */

#import <PreferencePanes/PreferencePanes.h>

@class NetworkController;

@interface NetworkPane : NSPreferencePane
{
    NetworkController *controller;
}

@end

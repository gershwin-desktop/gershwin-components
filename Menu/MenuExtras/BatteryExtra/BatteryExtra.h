/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "GSMenuExtra.h"
#import "EnergyLidCloseOnce.h"

@interface BatteryExtra : NSObject <GSMenuExtra>

/* Builds the armer behind "Stay awake at lid close"; overridable so a test
 * can hand back one built from fake collaborators instead of the real
 * D-Bus/systemd-inhibit backend (EnergyLidBackend). */
- (EnergyLidCloseOnceArmer *)createLidArmerWithUnsupportedReason:(NSString **)reason;

/* The "Stay awake at lid close" menu item's action; declared here (rather
 * than only in the .m) so a test can invoke it directly on the extra
 * without going through a live NSMenu click. */
- (void)toggleStayAwakeAtLidClose:(id)sender;

@end

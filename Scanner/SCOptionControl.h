/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCOption, SCScanner, SCFormRow;

@protocol SCOptionControlDelegate <NSObject>
- (void) optionControlDidFail: (NSError *)error;
/* After a value was taken; drivers do not always announce what it changes */
- (void) optionControlDidChangeValue;
@end

/*
 * Builds the control for one scanner option and writes the user's changes
 * back to the scanner. A change that makes the driver reload its options
 * posts SCScannerOptionsDidChangeNotification, upon which the owner builds
 * all controls anew; otherwise the control shows the value the driver
 * really took (drivers round).
 */
@interface SCOptionControl : NSObject

@property (nonatomic, weak) id<SCOptionControlDelegate> delegate;

/* nil when the option has no sensible control (inactive, internal) */
+ (instancetype) controlForOption: (SCOption *)option
                          scanner: (SCScanner *)scanner
                    gammaSettings: (NSMutableDictionary *)gammaSettings;

- (SCFormRow *) row;

/* Replaces the driver's title where it is jargon, e.g. "Scan intent" */
- (void) setLabel: (NSString *)label;

@end

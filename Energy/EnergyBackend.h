/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* The hardware side of the Energy preference pane (battery, backlight,
 * display blanking, disk and network power settings), shared with
 * gershwin-apply-settings so what the pane applies live is applied the
 * same way again at login.  The CPU governor has its own backend
 * (CPUGovernorBackend), shared with the Battery menu extra.  Built as
 * libEnergyBackend (Libraries/EnergyBackend) under ARC; objects handed out
 * are autoreleased from the caller's point of view. */
@interface EnergyBackend : NSObject

/* Keys "source" (AC, Battery or Unknown), "percent" (-1 if unknown) and
 * "status". */
+ (NSDictionary *)readBatteryInfo;

+ (int)readBrightnessPercent;
+ (BOOL)setBrightnessPercent:(int)pct;

/* The blanking delays the pane offers, in seconds, in menu order; 0 means
 * never.  The pane stores the index into this list. */
+ (NSArray<NSNumber *> *)screenBlankChoices;
+ (NSString *)titleForScreenBlankSeconds:(int)seconds;
/* The choice a running X server's DPMS standby delay falls into. */
+ (NSUInteger)screenBlankChoiceIndexForSeconds:(int)seconds;
/* DPMS standby delay of the running X server, 0 when DPMS is off. */
+ (int)currentScreenBlankSeconds;
/* Returns whether the X server reports the new delay afterwards. */
+ (BOOL)setScreenBlankSeconds:(int)seconds;

+ (BOOL)readHddSleep;
+ (BOOL)setHddSleep:(BOOL)enable;
+ (BOOL)readWakeNetwork;
+ (BOOL)setWakeNetwork:(BOOL)enable;
+ (BOOL)readPowerFail;
+ (BOOL)setPowerFail:(BOOL)enable;

@end

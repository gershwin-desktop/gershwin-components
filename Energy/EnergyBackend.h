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

/* The level the battery is charged up to, as a percentage.
 *
 * This is the kernel's own charge threshold pair, so it is offered only
 * where the kernel has it: Linux, and a battery whose driver exposes both
 * charge_control_end_threshold and charge_control_start_threshold.  A
 * driver with only the end threshold cannot express "stop at 80, resume at
 * 75", and a platform with no threshold at all cannot stop charging at
 * all, so +chargeLimitAvailable is NO there and the pane greys the slider
 * out rather than offering a setting that cannot happen.
 *
 * Charging resumes below the level it stopped at - the start threshold sits
 * a few points below the end threshold - because a battery whose two
 * thresholds are the same value toggles charging on and off around that one
 * level instead of staying put. */
+ (BOOL)chargeLimitAvailable;
/* The end and start thresholds in force, each -1 when there is none to
 * read. */
+ (int)readChargeLimitPercent;
+ (int)readChargeStartThresholdPercent;
/* Charge no further than percent, resuming at
 * +chargeLimitStartThresholdForEnd: percent.  A value outside the slider's
 * range is clamped to it rather than refused, since these come from a
 * slider and from a defaults file the user may have edited by hand.
 * Writing the thresholds needs privileges; a value already in force is
 * left alone, so an unchanged login asks for none. */
+ (BOOL)setChargeLimitPercent:(int)percent;
/* The two ends of the slider's range. */
+ (int)minimumChargeLimitPercent;
+ (int)maximumChargeLimitPercent;
/* The start threshold that belongs to an end threshold: a few points below
 * it, except at the maximum, which is the kernel's "no limit" and has
 * nothing below it. */
+ (int)chargeLimitStartThresholdForEnd:(int)end;
/* The sysfs writes that move both thresholds to end, from the thresholds
 * currently in force, each write an @[path, value] pair.  Their order is
 * the whole point: the kernel rejects a start that is not below the end
 * still in force, and an end that is not above the start, so which of the
 * two has to be written first depends on whether the limit is going up or
 * down.  Empty when both are already right, which is what makes applying
 * the same limit again a no-op. */
+ (NSArray<NSArray<NSString *> *> *)chargeThresholdWritePlanForEnd:(int)end
                                                        currentEnd:(int)currentEnd
                                                      currentStart:(int)currentStart;

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

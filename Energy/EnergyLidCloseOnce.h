/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* A source of "the lid just closed / just opened" events.  Implementations
 * are platform-specific (EnergyLidBackend); -start/-stop bracket the only
 * window in which the handler may fire, so a source that has to hold a
 * connection or a thread open only does so while something is armed. */
@protocol EnergyLidEventSource <NSObject>
- (void)setLidStateHandler:(void (^)(BOOL closed))handler;
- (void)start;
- (void)stop;
@end

/* The privilege boundary that keeps the machine awake across one lid close:
 * on Linux, a logind "handle-lid-switch" block-mode inhibitor lock, held for
 * as long as -stopInhibiting is not called.  Returning NO from the start
 * method is a hard failure - callers must surface it, never pretend the lid
 * close is covered when it is not. */
@protocol EnergySleepInhibitor <NSObject>
- (BOOL)startInhibitingLidHandlingWhy:(NSString *)why error:(NSError **)error;
- (void)stopInhibiting;
- (BOOL)isInhibiting;
@end

typedef NS_ENUM(NSInteger, EnergyLidArmState) {
    EnergyLidArmStateUnarmed = 0,
    EnergyLidArmStateArmed,
    EnergyLidArmStateConsumed
};

/* One-shot state machine: armed -> lid closed -> consumed -> unarmed.
 * Arming starts the inhibitor immediately (it must already be held by the
 * time the lid-close event reaches logind/the kernel, or the machine
 * suspends before this class ever hears about it) and starts observing the
 * lid source; the first "closed" event after that releases the inhibitor
 * and disarms.  A lid "open" event, or any event while unarmed, is a no-op:
 * this only ever covers the next close, once. */
@interface EnergyLidCloseOnceArmer : NSObject

- (instancetype)initWithLidEventSource:(id<EnergyLidEventSource>)lidEventSource
                              inhibitor:(id<EnergySleepInhibitor>)inhibitor;

/* NO + error means nothing was armed: the inhibitor could not be taken, so
 * the caller must not show the feature as active. */
- (BOOL)armWithError:(NSError **)error;

/* User-initiated cancel before the lid ever closes. Harmless when unarmed. */
- (void)disarm;

- (BOOL)isArmed;

/* Exposed for tests, which drive/observe the internal transitions directly
 * rather than through timing. */
- (EnergyLidArmState)state;

@end

extern NSString *const EnergyLidCloseOnceErrorDomain;

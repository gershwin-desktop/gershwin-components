/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */

#import "EnergyLidCloseOnce.h"

NSString *const EnergyLidCloseOnceErrorDomain = @"EnergyLidCloseOnceErrorDomain";

@implementation EnergyLidCloseOnceArmer
{
    id<EnergyLidEventSource> _lidEventSource;
    id<EnergySleepInhibitor> _inhibitor;
    EnergyLidArmState _state;
}

- (instancetype)initWithLidEventSource:(id<EnergyLidEventSource>)lidEventSource
                              inhibitor:(id<EnergySleepInhibitor>)inhibitor
{
    self = [super init];
    if (self) {
        _lidEventSource = lidEventSource;
        _inhibitor = inhibitor;
        _state = EnergyLidArmStateUnarmed;

        /* The source only ever calls back while we told it to -start, i.e.
         * while armed, so there is no race with a handler surviving past
         * -disarm/-dealloc that this class did not itself arrange for. */
        __weak EnergyLidCloseOnceArmer *weakSelf = self;
        [_lidEventSource setLidStateHandler:^(BOOL closed) {
            [weakSelf handleLidStateChanged:closed];
        }];
    }
    return self;
}

- (BOOL)armWithError:(NSError **)error
{
    if (_state == EnergyLidArmStateArmed) {
        return YES;
    }

    /* The lock must exist before the lid can possibly close, or logind may
     * already have acted on the close before this call returns. */
    if (![_inhibitor startInhibitingLidHandlingWhy:@"Stay awake at lid close (Battery menu)"
                                              error:error]) {
        return NO;
    }

    _state = EnergyLidArmStateArmed;
    [_lidEventSource start];
    return YES;
}

- (void)disarm
{
    if (_state != EnergyLidArmStateArmed) {
        return;
    }
    [_lidEventSource stop];
    [_inhibitor stopInhibiting];
    _state = EnergyLidArmStateUnarmed;
}

/* A safety net, not the primary release path (the caller disarming on
 * unload is): whoever holds this object dropping it while still armed must
 * not leave a lock and a background watcher behind it with nothing left to
 * release either. */
- (void)dealloc
{
    if (_state == EnergyLidArmStateArmed) {
        [_lidEventSource stop];
        [_inhibitor stopInhibiting];
    }
}

- (BOOL)isArmed
{
    return _state == EnergyLidArmStateArmed;
}

- (EnergyLidArmState)state
{
    return _state;
}

/* The one event this class cares about: the lid closing while armed.  An
 * "opened" event, or any event while not armed, changes nothing - there is
 * nothing left to consume. */
- (void)handleLidStateChanged:(BOOL)closed
{
    if (_state != EnergyLidArmStateArmed || !closed) {
        return;
    }

    _state = EnergyLidArmStateConsumed;

    /* The close this was armed for has now reached us, which means logind
     * (or the platform equivalent) has already made its one decision for
     * this event while the lock was held; releasing it now does not un-do
     * that decision, and holding it any longer would cover lid closes this
     * menu item was never asked to cover. */
    [_lidEventSource stop];
    [_inhibitor stopInhibiting];
    _state = EnergyLidArmStateUnarmed;
}

@end

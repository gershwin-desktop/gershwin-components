/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkControl.h"
#import "MIDINetworkBackend.h"
#include <unistd.h>

NSString * const MIDINetworkDaemonToolName = @"gwmidid";

NSString * const MIDINetworkReplyKeyError = @"error";
NSString * const MIDINetworkReplyKeyChanges = @"changes";
NSString * const MIDINetworkErrorKeyCode = @"code";
NSString * const MIDINetworkErrorKeyMessage = @"message";

NSString *MIDINetworkDaemonServiceName(void)
{
    /* The uid keeps the name unique even if a name server were ever
       shared between users; message ports are per user already. */
    return [NSString stringWithFormat:@"io.github.gershwin-desktop.gwmidid.%lu", (unsigned long)getuid()];
}

NSDictionary *MIDINetworkReplyWithError(NSError *error)
{
    NSInteger code = [[error domain] isEqual:MIDINetworkErrorDomain] ? [error code]
                                                                     : MIDINetworkErrorInvalidArgument;
    return @{ MIDINetworkReplyKeyError: @{ MIDINetworkErrorKeyCode: @(code),
                                           MIDINetworkErrorKeyMessage: [error localizedDescription] ?: @"" } };
}

NSDictionary *MIDINetworkReplyWithChanges(NSDictionary *changes)
{
    return changes ? @{ MIDINetworkReplyKeyChanges: changes } : @{};
}

NSError *MIDINetworkErrorFromReply(id reply)
{
    if (![reply isKindOfClass:[NSDictionary class]]) {
        return MIDINetworkMakeError(MIDINetworkErrorInvalidArgument,
                                    @"The network MIDI service sent an answer that is not understood.");
    }
    id error = [reply objectForKey:MIDINetworkReplyKeyError];
    if (error == nil) {
        return nil;
    }
    id code = [error isKindOfClass:[NSDictionary class]] ? [error objectForKey:MIDINetworkErrorKeyCode] : nil;
    id message = [error isKindOfClass:[NSDictionary class]] ? [error objectForKey:MIDINetworkErrorKeyMessage] : nil;
    if (![code isKindOfClass:[NSNumber class]] || ![message isKindOfClass:[NSString class]]) {
        return MIDINetworkMakeError(MIDINetworkErrorInvalidArgument,
                                    @"The network MIDI service sent an answer that is not understood.");
    }
    return MIDINetworkMakeError((MIDINetworkErrorCode)[code integerValue], message);
}

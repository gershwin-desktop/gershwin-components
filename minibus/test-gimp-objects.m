/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Test decoding the exact a{oa{sa{sv}}} body GIMP's
 * GetManagedObjects reply carries, which minibus previously
 * failed to parse (empty body re-serialized).
 */

#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Raw GIMP GetManagedObjects reply (136 bytes), captured from
        // /tmp/minibus-test-gimp.log on 2026-09-10.
        uint8_t raw[] = {
            0x6c, 0x02, 0x01, 0x01, 0x48, 0x00, 0x00, 0x00,
            0x1d, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00,
            0x3a, 0x31, 0x2e, 0x33, 0x30, 0x00, 0x00, 0x00,
            0x08, 0x01, 0x67, 0x00, 0x0d, 0x61, 0x7b, 0x6f,
            0x61, 0x7b, 0x73, 0x61, 0x7b, 0x73, 0x76, 0x7d,
            0x7d, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x11, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67,
            0x2f, 0x67, 0x69, 0x6d, 0x70, 0x2f, 0x47, 0x49,
            0x4d, 0x50, 0x2f, 0x55, 0x49, 0x00, 0x00, 0x00,
            0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x10, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e,
            0x67, 0x69, 0x6d, 0x70, 0x2e, 0x47, 0x49, 0x4d,
            0x50, 0x2e, 0x55, 0x49, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        };

        NSData *data = [NSData dataWithBytes:raw length:sizeof(raw)];
        NSUInteger offset = 0;
        MBMessage *msg = [MBMessage messageFromData:data offset:&offset];

        if (!msg) {
            NSLog(@"FAIL: could not parse message");
            return 1;
        }

        NSLog(@"PASS: parsed message type=%u sig='%@' dest='%@'", 
              (unsigned)msg.type, msg.signature, msg.destination);
        NSLog(@"      arguments count=%lu", (unsigned long)[msg.arguments count]);
        if ([msg.arguments count] != 1) {
            NSLog(@"FAIL: expected 1 argument, got %lu", (unsigned long)[msg.arguments count]);
            return 1;
        }
        id arg = msg.arguments[0];
        NSLog(@"      argument class=%@", NSStringFromClass([arg class]));
        NSLog(@"      argument=%@", arg);

        // Round-trip: reserialize and ensure body length is preserved
        NSData *reserialized = [msg serialize];
        if (!reserialized) {
            NSLog(@"FAIL: reserialization returned nil");
            return 1;
        }
        NSLog(@"PASS: reserialized message is %lu bytes (original %lu)", 
              (unsigned long)[reserialized length], (unsigned long)[data length]);

        // Parse the reserialized message again
        NSUInteger offset2 = 0;
        MBMessage *msg2 = [MBMessage messageFromData:reserialized offset:&offset2];
        if (!msg2) {
            NSLog(@"FAIL: could not re-parse reserialized message");
            return 1;
        }
        NSLog(@"PASS: re-parsed message, arguments count=%lu", (unsigned long)[msg2.arguments count]);
        if ([msg2.arguments count] == 1) {
            NSLog(@"PASS: round-trip preserved the a{oa{sa{sv}}} argument");
            return 0;
        }
        NSLog(@"FAIL: round-trip LOST the argument (count=%lu)", (unsigned long)[msg2.arguments count]);
        return 1;
    }
}
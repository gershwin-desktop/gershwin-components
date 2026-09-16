/*
 * Capture the raw a(uuaa{sv}) reply from GIMP's org.gtk.Menus.Start
 * and test the round-trip decode/encode fidelity.
 */

#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"
#import "MBVariant.h"

static void hexDump(NSData *data, const char *label, unsigned max) {
    unsigned len = (unsigned)[data length];
    printf("%s (%u bytes", label, len);
    if (len > max) printf(", showing first %u", max);
    printf("): ");
    const uint8_t *p = (const uint8_t *)[data bytes];
    unsigned show = len > max ? max : len;
    for (unsigned i = 0; i < show; i++) printf("%02x ", p[i]);
    printf("\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        const char *socketPath = "/tmp/minibus-test-gimp.socket";
        if (argc > 1) socketPath = argv[1];

        MBClient *client = [[MBClient alloc] init];
        if (![client connectToPath:[NSString stringWithUTF8String:socketPath]]) {
            NSLog(@"FAIL: cannot connect");
            return 1;
        }
        NSLog(@"Connected as %@", client.uniqueName);

        /* Manually construct org.gtk.Menus.Start(au [0]) call with correct signature.
         * GNUstep NSNumber always reports objCType='i' even for unsigned, so
         * signatureForArguments infers (ai) instead of (au). We override it. */
        NSNumber *groupId = [NSNumber numberWithInt:0];
        NSArray *groupIds = @[groupId];
        MBMessage *startMsg = [MBMessage methodCallWithDestination:@":1.1"
                                                             path:@"/org/appmenu/gtk/window/0"
                                                        interface:@"org.gtk.Menus"
                                                           member:@"Start"
                                                        arguments:@[groupIds]];
        startMsg.signature = @"au";
        startMsg.serial = 42;

        NSLog(@"Sending Start(au [0])...");
        NSLog(@"  sig='%@' args=%lu", startMsg.signature, (unsigned long)[startMsg.arguments count]);

        if (![client sendMessage:startMsg]) {
            NSLog(@"FAIL: could not send message");
            return 1;
        }

        /* Wait for reply */
        NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
        while ([NSDate timeIntervalSinceReferenceDate] - startTime < 10.0) {
            NSArray *messages = [client processMessages];
            for (MBMessage *reply in messages) {
                if (reply.replySerial == startMsg.serial) {
                    NSLog(@"Got reply: type=%u sig='%@' args=%lu",
                          (unsigned)reply.type, reply.signature,
                          (unsigned long)[reply.arguments count]);

                    if (reply.type == MBMessageTypeError) {
                        NSLog(@"ERROR: %@", reply.errorName);
                        for (id arg in reply.arguments) {
                            NSLog(@"  error arg: %@", arg);
                        }
                        [client disconnect];
                        return 1;
                    }

                    /* Dump the full serialized reply */
                    NSData *serialized = [reply serialize];
                    hexDump(serialized, "FULL REPLY", 2000);

                    NSLog(@"\n=== ROUND-TRIP TEST ===");
                    NSLog(@"Original sig='%@' args=%lu", reply.signature,
                          (unsigned long)[reply.arguments count]);

                    /* Re-serialize */
                    NSData *reserialized = [reply serialize];
                    NSLog(@"Reserialized to %lu bytes", (unsigned long)[reserialized length]);
                    hexDump(reserialized, "RE-SERIALIZED", 2000);

                    /* Re-parse */
                    NSUInteger offset2 = 0;
                    MBMessage *roundTrip = [MBMessage messageFromData:reserialized offset:&offset2];
                    if (!roundTrip) {
                        NSLog(@"FAIL: could not re-parse reserialized message");
                        [client disconnect];
                        return 1;
                    }

                    NSLog(@"Re-parsed: sig='%@' args=%lu", roundTrip.signature,
                          (unsigned long)[roundTrip.arguments count]);

                    if ([roundTrip.arguments count] == [reply.arguments count]) {
                        NSLog(@"PASS: round-trip preserved %lu arguments",
                              (unsigned long)[roundTrip.arguments count]);
                    } else {
                        NSLog(@"FAIL: original %lu args vs reserialized %lu",
                              (unsigned long)[reply.arguments count],
                              (unsigned long)[roundTrip.arguments count]);
                    }

                    /* Compare byte-for-byte */
                    NSData *reserialized3 = [roundTrip serialize];
                    if ([serialized length] == [reserialized3 length] &&
                        memcmp([serialized bytes], [reserialized3 bytes], [serialized length]) == 0) {
                        NSLog(@"PASS: serialized content identical (%lu bytes)",
                              (unsigned long)[serialized length]);
                    } else {
                        NSLog(@"FAIL: serialized sizes differ %lu vs %lu",
                              (unsigned long)[serialized length],
                              (unsigned long)[reserialized3 length]);
                        hexDump(reserialized3, "RE-SERIALIZED AGAIN", 200);
                    }

                    [client disconnect];
                    return ([roundTrip.arguments count] == [reply.arguments count]) ? 0 : 1;
                }
            }
            usleep(10000);
        }

        NSLog(@"FAIL: timeout waiting for reply");
        [client disconnect];
        return 1;
    }
}

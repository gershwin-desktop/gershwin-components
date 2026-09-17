/*
 * Test round-trip of the a(uuaa{sv}) menu-body type used by GIMP's
 * org.gtk.Menus.Start reply. Uses MBMessage's own encoder to build the
 * body (so we know the bytes are spec-correct), then verifies the decoder
 * parses it back and the re-encode preserves byte-identical output.
 */

#import <Foundation/Foundation.h>
#import "MBMessage.h"
#import "MBVariant.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        /* Build the argument structure a(uuaa{sv}):
         *   one struct (u, u, aa{sv})
         *     u1 = group id = 1
         *     u2 = action id = 2
         *     aa{sv} = one inner a{sv}
         *       a{sv} = one dict entry {"label": "File"}
         */
        NSDictionary *dict = @{ @"label": [MBVariant variantWithSignature:@"s" value:@"File"] };
        NSArray *aSvOuter = @[dict];
        NSNumber *u1 = [NSNumber numberWithInt:1];
        NSNumber *u2 = [NSNumber numberWithInt:2];
        NSArray *structVal = @[u1, u2, aSvOuter];
        NSArray *menu = @[structVal];

        NSString *sig = [MBMessage signatureForValue:menu];
        NSLog(@"Inferred signature: '%@'", sig);
        /* GNUstep cannot distinguish i from u; note it but don't fail the
         * round-trip test on it. */

        /* Create a message carrying this argument and serialize it.
         * GNUstep NSNumber cannot distinguish int from unsigned, so force the
         * signature to the exact 'u' form GIMP emits. encodeValue treats 'i'
         * and 'u' identically (both 4-byte), so byte output is unaffected. */
        MBMessage *msg = [MBMessage methodReturnWithReplySerial:1 arguments:@[menu]];
        msg.signature = @"a(uuaa{sv})";
        NSData *serialized = [msg serialize];

        /* Parse it back */
        NSUInteger offset = 0;
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:&offset];
        if (!parsed) {
            NSLog(@"FAIL: could not parse message");
            return 1;
        }
        NSLog(@"Parsed sig='%@' args=%lu", parsed.signature,
              (unsigned long)[parsed.arguments count]);

        if ([parsed.arguments count] != 1) {
            NSLog(@"FAIL: expected 1 argument, got %lu", (unsigned long)[parsed.arguments count]);
            return 1;
        }

        NSLog(@"arg0=%@", parsed.arguments[0]);

        /* Re-serialize and compare byte-for-byte */
        NSData *reserialized = [parsed serialize];
        NSLog(@"Original %lu bytes, re-serialized %lu bytes",
              (unsigned long)[serialized length], (unsigned long)[reserialized length]);
        BOOL identical = ([serialized length] == [reserialized length] &&
                          memcmp([serialized bytes], [reserialized bytes], [serialized length]) == 0);
        NSLog(identical ? @"PASS: round-trip byte-identical" : @"FAIL: bytes differ");

        if (!identical) {
            const uint8_t *a = [serialized bytes];
            const uint8_t *b = [reserialized bytes];
            NSUInteger n = MIN([serialized length], [reserialized length]);
            for (NSUInteger i = 0; i < n; i++) {
                if (a[i] != b[i]) {
                    NSLog(@"First difference at byte %lu: orig=%02x new=%02x", (unsigned long)i, a[i], b[i]);
                    break;
                }
            }
            printf("ORIG: ");
            for (NSUInteger i = 0; i < [serialized length]; i++) printf("%02x ", a[i]);
            printf("\nNEW:  ");
            for (NSUInteger i = 0; i < [reserialized length]; i++) printf("%02x ", b[i]);
            printf("\n");
            return 1;
        }

        NSLog(@"ALL TESTS PASSED");
        return 0;
    }
}
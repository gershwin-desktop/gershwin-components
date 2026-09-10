#import <Foundation/Foundation.h>
#import "MBMessage.h"
#import "MBVariant.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSData *raw = [NSData dataWithContentsOfFile:@"/tmp/start-reply.bin"];
        if (!raw) {
            NSLog(@"FAIL: cannot read /tmp/start-reply.bin");
            return 1;
        }
        uint16_t hdrLen = 0;
        [raw getBytes:&hdrLen range:NSMakeRange(12, 4)];
        hdrLen = 0;
        uint32_t fieldsLen = 0;
        [raw getBytes:&fieldsLen range:NSMakeRange(12, 4)];
        NSData *body = [raw subdataWithRange:NSMakeRange(16 + fieldsLen,
                                                          [raw length] - 16 - fieldsLen)];
        NSLog(@"body %lu bytes", (unsigned long)[body length]);

        NSArray *args = [MBMessage parseArgumentsFromBodyData:body
                                                    signature:@"a(uuaa{sv})"
                                                   endianness:0x6c];
        if (!args) {
            NSLog(@"FAIL: null args");
            return 1;
        }
        NSLog(@"Parsed args count: %lu", (unsigned long)[args count]);
        for (id a in args) {
            NSLog(@"arg: %@", a);
        }
        if ([args count] != 1) {
            NSLog(@"FAIL: expected 1 argument");
            return 1;
        }
        NSLog(@"ALL TESTS PASSED");
        return 0;
    }
}
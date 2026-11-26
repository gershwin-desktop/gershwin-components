/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Names for DNS-SD service types as the type meta browse
 * ("_services._dns-sd._udp") reports them: the name is the first label
 * ("_kdeconnect"), the protocol label is carried in the service type
 * ("_udp." or "_tcp."). Foundation only so it can be unit tested. */
@interface ServiceTypeName : NSObject

/* "tcp" or "udp" for a label such as "_udp.", "_tcp" or "_udp.local.";
 * nil for anything else, because DNS-SD knows no other protocol. */
+ (NSString *)protocolForLabel:(NSString *)label;

/* "_ssh._tcp" from the name "_ssh" and the label "_tcp."; nil if the name
 * is empty or the protocol is neither TCP nor UDP. */
+ (NSString *)fullTypeForName:(NSString *)name protocolLabel:(NSString *)label;

/* "_ssh (TCP)": what the type list shows, so TCP and UDP variants of one
 * name can be told apart. nil when fullTypeForName:protocolLabel: is nil. */
+ (NSString *)titleForName:(NSString *)name protocolLabel:(NSString *)label;

/* NO for UDP services and nil: a web browser speaks TCP only, so the open
 * action makes no sense there. YES for every TCP type. */
+ (BOOL)typeCanOpenInBrowser:(NSString *)fullType;

@end

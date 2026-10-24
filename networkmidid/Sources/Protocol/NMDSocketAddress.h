/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Socket addresses travel as NSData holding a struct sockaddr_in or
 * sockaddr_in6, the form NSNetService hands out too. */

uint16_t NMDAddressPort(NSData *address);
NSData *NMDAddressWithPort(NSData *address, uint16_t port);
/* Numeric host part, no port */
NSString *NMDAddressHost(NSData *address);
/* "host:port" for logs and the control interface */
NSString *NMDAddressDescription(NSData *address);
BOOL NMDAddressHostsEqual(NSData *a, NSData *b);
/* Numeric IPv4 or IPv6 literal only; names are resolved elsewhere so that
 * nothing here can block. */
NSData *NMDAddressFromNumericHost(NSString *host, uint16_t port);

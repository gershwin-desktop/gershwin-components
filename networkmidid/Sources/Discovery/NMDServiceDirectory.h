/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

@class NMDServiceDirectory;

/* A session another host announces on the local network. */
@interface NMDDiscoveredService : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *hostName;
/* IPv4 control port addresses, empty until resolved */
@property (nonatomic, readonly, copy) NSArray *addresses;
@property (nonatomic, readonly) uint16_t port;
@end

@protocol NMDServiceDirectoryDelegate <NSObject>
- (void) serviceDirectoryDidChange: (NMDServiceDirectory *)directory;
@end

/* Announces our sessions and lists the others via NSNetService, so it
 * works with either libs-base zeroconf backend (mDNSResponder or Avahi). */
@interface NMDServiceDirectory : NSObject

@property (nonatomic, weak) id<NMDServiceDirectoryDelegate> delegate;

- (void) startBrowsing;
- (void) stopBrowsing;

/* Name -> service, resolved or not, excluding our own announcements. */
- (NSArray *) services;
- (NMDDiscoveredService *) serviceNamed: (NSString *)name;

- (void) announceSessionNamed: (NSString *)name port: (uint16_t)port;
- (void) withdrawSessionNamed: (NSString *)name;
- (void) withdrawAll;

@end

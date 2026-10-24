/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

@class GMServiceDirectory;

/* A session another host announces on the local network. */
@interface GMDiscoveredService : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *hostName;
/* IPv4 control port addresses, empty until resolved */
@property (nonatomic, readonly, copy) NSArray *addresses;
@property (nonatomic, readonly) uint16_t port;
@end

@protocol GMServiceDirectoryDelegate <NSObject>
- (void) serviceDirectoryDidChange: (GMServiceDirectory *)directory;
@end

/* Announces our sessions and lists the others via NSNetService, so it
 * works with either libs-base zeroconf backend (mDNSResponder or Avahi). */
@interface GMServiceDirectory : NSObject

@property (nonatomic, weak) id<GMServiceDirectoryDelegate> delegate;

- (void) startBrowsing;
- (void) stopBrowsing;

/* Name -> service, resolved or not, excluding our own announcements. */
- (NSArray *) services;
- (GMDiscoveredService *) serviceNamed: (NSString *)name;

- (void) announceSessionNamed: (NSString *)name port: (uint16_t)port;
- (void) withdrawSessionNamed: (NSString *)name;
- (void) withdrawAll;

@end

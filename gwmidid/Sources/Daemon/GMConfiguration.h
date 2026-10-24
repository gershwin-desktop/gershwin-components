/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "GMLocalSession.h"

/* The user's defaults domain; also the DO name and the notification name
 * prefix, so all three are found under one reverse-DNS name. */
extern NSString * const GMDefaultsDomain;
extern NSString * const GMStatusDidChangeNotification;

/* Keys of the defaults domain and of the dictionaries the control
 * interface exchanges */
extern NSString * const GMKeySessions;
extern NSString * const GMKeyDirectory;
extern NSString * const GMKeyConnections;
extern NSString * const GMKeyName;
extern NSString * const GMKeyPort;
extern NSString * const GMKeyEnabled;
extern NSString * const GMKeyPolicy;
extern NSString * const GMKeyAnnounce;
extern NSString * const GMKeyHost;
extern NSString * const GMKeySession;
extern NSString * const GMKeyService;

/* The first session's port when the user has configured none */
#define GM_DEFAULT_PORT 5004

@interface GMSessionConfiguration : NSObject <NSCopying>
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint16_t port;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL announce;
@property (nonatomic) GMConnectionPolicy policy;

/* nil and an error message for anything that is not a valid session; no
 * field is guessed. */
+ (instancetype) configurationWithDictionary: (NSDictionary *)d
                                       error: (NSString **)error;
- (NSDictionary *) dictionary;
@end

/* A host the user listed: it may join sessions with the directory policy
 * and can be connected to by name. */
@interface GMDirectoryEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *host;   /* numeric address */
@property (nonatomic) uint16_t port;
+ (instancetype) entryWithDictionary: (NSDictionary *)d error: (NSString **)error;
- (NSDictionary *) dictionary;
@end

/* A connection made at start: to a directory entry or announced service
 * by name, or to a numeric host and port. */
@interface GMConnectionConfiguration : NSObject
@property (nonatomic, copy) NSString *session;
@property (nonatomic, copy) NSString *service;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) uint16_t port;
+ (instancetype) connectionWithDictionary: (NSDictionary *)d error: (NSString **)error;
- (NSDictionary *) dictionary;
@end

@interface GMConfiguration : NSObject
@property (nonatomic, copy) NSArray *sessions;      /* GMSessionConfiguration */
@property (nonatomic, copy) NSArray *directory;     /* GMDirectoryEntry */
@property (nonatomic, copy) NSArray *connections;   /* GMConnectionConfiguration */
@property (nonatomic, copy) NSArray *errors;        /* entries that were refused */

/* domain: the persistent defaults domain, nil when the user has none */
+ (instancetype) configurationWithDomain: (NSDictionary *)domain
                             defaultName: (NSString *)defaultName;
- (NSDictionary *) domain;
@end

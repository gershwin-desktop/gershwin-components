/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// One entry of an item's `links` array. The feed stores GitHub links as an
// "owner/repo" path rather than a URL, so every URL this class hands out is
// resolved here and nowhere else.
@interface AGLink : NSObject

@property (nonatomic, copy, readonly) NSString *type;      // "GitHub", "Download", "Install"
@property (nonatomic, copy, readonly) NSString *URLString; // exactly what the feed said
// Absolute http(s) address to open, nil when the value is not one.
@property (nonatomic, strong, readonly) NSURL *url;

- (instancetype)initWithType:(NSString *)type URLString:(NSString *)URLString;

// "owner/repo" when the feed's GitHub value is a repository path, else nil.
// The feed never gives a GitHub URL, and a path is the only shape we trust
// for building one.
+ (NSString *)repoPathInURLString:(NSString *)string;

// "owner/repo" when the value is a repository releases page, else nil. Used
// to recover the repository of items that linked only a download.
+ (NSString *)releaseRepoPathInURLString:(NSString *)string;

@end

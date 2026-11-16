/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGAuthor;
@class AGLink;

// One catalog item: an immutable value object. Every field is derived once
// from the feed dictionary here, so no view ever has to re-derive or guess.
@interface AGApp : NSObject

@property (nonatomic, copy, readonly) NSString *name;      // "Apache_NetBeans", the identifier
@property (nonatomic, copy, readonly) NSString *displayName; // underscores as spaces
@property (nonatomic, copy, readonly) NSString *summary;    // card-length line, nil without a description
@property (nonatomic, copy, readonly) NSString *descriptionText;
@property (nonatomic, copy, readonly) NSArray<NSString *> *categories; // nulls dropped, never nil
@property (nonatomic, copy, readonly) NSArray<AGAuthor *> *authors;    // never nil
@property (nonatomic, copy, readonly) NSString *license;    // raw feed value, nil when absent
@property (nonatomic, copy, readonly) NSArray<AGLink *> *links;        // never nil
@property (nonatomic, strong, readonly) NSURL *iconURL;     // nil when absent or not a bitmap
@property (nonatomic, strong, readonly) NSURL *screenshotURL;
@property (nonatomic, strong, readonly) NSURL *githubURL;
@property (nonatomic, copy, readonly) NSString *githubRepo; // "owner/repo" or nil
@property (nonatomic, strong, readonly) NSURL *downloadPageURL;
@property (nonatomic, strong, readonly) NSURL *catalogPageURL;
@property (nonatomic, readonly) BOOL selfContained;
// Only set when the feed carried the key, so the detail page leaves the row
// out instead of printing "No" for an app that never said anything.
@property (nonatomic, readonly) BOOL selfContainedPresent;
@property (nonatomic, copy, readonly) NSString *glibcRequired;

// Returns nil for an item that has no usable name, which the parser counts
// as skipped instead of failing the whole feed.
- (instancetype)initWithFeedItem:(NSDictionary *)item;

@end

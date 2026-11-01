/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef RadioBrowser_h
#define RadioBrowser_h

#import <Foundation/Foundation.h>

@class RadioStation;

/**
 * RadioBrowser
 *
 * API client for the TuneIn radio directory service.
 * Provides methods for browsing local stations and searching.
 *
 * The user default PlayerRadioDirectoryURL replaces the directory's base
 * URL; with a file:// URL each endpoint (Browse.ashx, Search.ashx) is a
 * file in that directory holding one answer (query parameters ignored).
 */
@interface RadioBrowser : NSObject

/// Shared singleton instance
+ (instancetype)sharedBrowser;

/// Check whether the API is reachable
- (void)checkStatusWithCompletion:(void(^)(BOOL available))completion;

/// Fetch stations local to the user's region
- (void)localStationsWithCompletion:(void(^)(NSArray *stations, NSError *error))completion;

/// Search stations by query string
- (void)searchStations:(NSString *)query
           completion:(void(^)(NSArray *stations, NSError *error))completion;

@end

#endif /* RadioBrowser_h */

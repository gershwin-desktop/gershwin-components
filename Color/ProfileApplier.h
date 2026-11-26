/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Loads ICC display profiles into the X server's video card gamma tables.
 * Shared with gershwin-apply-settings through libColorProfileBackend
 * (Libraries/ColorProfileBackend) so the profiles the user chose are loaded
 * again at login, because the gamma tables do not survive an X restart. */
@interface ProfileApplier : NSObject

/* Loads the profile without recording it as active, for callers that only
 * restore what the pane recorded already. */
+ (BOOL)loadProfile:(NSString *)profilePath forOutput:(NSString *)displayName;

- (BOOL)applyProfile:(NSString *)profilePath forDisplay:(NSString *)displayName;
- (BOOL)revertForDisplay:(NSString *)displayName;
- (NSString *)activeProfileForDisplay:(NSString *)displayName;

@end

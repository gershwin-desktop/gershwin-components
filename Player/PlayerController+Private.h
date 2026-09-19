/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerController_Private_h
#define PlayerController_Private_h

#import "PlayerController.h"

extern NSString *const PlayerDefaultsMode;
extern NSString *const PlayerDefaultsRadioSearch;
extern NSString *const PlayerDefaultsRadioStation;
extern NSString *const PlayerDefaultsRadioPlaying;

/// Shared between PlayerController.m and its Radio category
@interface PlayerController (Private)
- (void)rememberRadioPlaying:(BOOL)playing;
- (void)placeRadioSpinner;
- (void)putControlsInPanel:(BOOL)inPanel;
- (NSTextField *)labelWithFont:(NSFont *)font;
- (void)layoutSubviews;
- (void)updateWindowShape;
- (void)setViews:(NSArray *)views hidden:(BOOL)hidden;
- (NSArray *)trackInfoViews;
- (NSArray *)positionViews;
- (NSArray *)transportViews;
- (NSArray *)volumeViews;
- (void)layoutTransportCenteredAt:(CGFloat)midX y:(CGFloat)y;
- (void)layoutVolumeCenteredAt:(CGFloat)midX y:(CGFloat)y;
- (void)setPictureFrame:(NSRect)frame;
- (void)exitFullscreen;
- (void)showCoverArt;
- (void)playlistDidChange;
- (void)updateControls;
- (void)revalidateMenu;
- (void)updateTrackInfo;
- (void)updateWindowTitle;
- (float)volume;
@end

#endif /* PlayerController_Private_h */

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
extern NSString *const PlayerDefaultsPodcastSearch;
extern NSString *const PlayerDefaultsPodcastShow;
extern NSString *const PlayerDefaultsPodcastEpisode;
extern NSString *const PlayerDefaultsPodcastPosition;
extern NSString *const PlayerDefaultsPodcastPlaying;

/// Shared between PlayerController.m and its Radio/Podcast categories
@interface PlayerController (Private)
- (void)rememberRadioPlaying:(BOOL)playing;
- (void)setRadioStatus:(NSString *)status;
- (void)placeRadioSpinner;
- (void)prepareRadioIconsAround:(NSUInteger)index;
- (NSTextField *)labelWithFont:(NSFont *)font;
- (NSButton *)iconButtonWithImage:(NSImage *)image title:(NSString *)title action:(SEL)action;
- (void)layoutSubviews;
- (void)updateWindowShape;
- (void)setViews:(NSArray *)views hidden:(BOOL)hidden;
- (NSArray *)trackInfoViews;
- (NSArray *)positionViews;
- (NSArray *)transportViews;
- (NSArray *)volumeViews;
- (void)layoutTransportCenteredAt:(CGFloat)midX y:(CGFloat)y;
- (void)layoutVolumeCenteredAt:(CGFloat)midX y:(CGFloat)y;
- (void)layoutTimelineRowFrom:(CGFloat)left to:(CGFloat)right y:(CGFloat)y;
- (NSString *)formatTime:(NSTimeInterval)seconds;
- (void)setPictureFrame:(NSRect)frame;
- (void)exitFullscreen;
- (void)showCoverArt;
- (void)playlistDidChange;
- (void)updateControls;
- (BOOL)radioTuning;
- (void)revalidateMenu;
- (void)updateTrackInfo;
- (void)updateWindowTitle;
- (float)volume;
@end

#endif /* PlayerController_Private_h */

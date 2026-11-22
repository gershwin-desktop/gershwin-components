/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "SCImageWriter.h"

extern NSString * const SCSaveDirectoryKey;
extern NSString * const SCFileNamePatternKey;
extern NSString * const SCFileFormatKey;
extern NSString * const SCJPEGQualityKey;
extern NSString * const SCPreviewResolutionKey;
extern NSString * const SCInvertColorsKey;
extern NSString * const SCThresholdKey;
extern NSString * const SCRecognizeTextKey;
extern NSString * const SCDeclinedLanguagesKey;
extern NSString * const SCOfferedTextRecognitionKey;
extern NSString * const SCPanelScanningKey;
extern NSString * const SCDeviceSettingsKey;
extern NSString * const SCLastDeviceKey;

@interface SCPreferences : NSWindowController

+ (void) registerDefaults;
+ (NSString *) saveDirectory;
+ (SCFileFormat) fileFormat;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sane/sane.h>

@class SCImage, SCOption, SCScanner;

@interface SCDeviceInfo : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *vendor;
@property (nonatomic, readonly) NSString *model;
@property (nonatomic, readonly) NSString *kind;
- (instancetype) initWithName: (NSString *)name vendor: (NSString *)vendor
                        model: (NSString *)model kind: (NSString *)kind;
- (NSString *) displayName;

/*
 * Names the same scanner across sessions. airscan names carry a discovery
 * index ("airscan:w0:..." one day, "airscan:w1:..." the next), so it is
 * left out; other names are stable as they are.
 */
- (NSString *) persistentIdentifier;

- (NSDictionary *) propertyList;
+ (instancetype) deviceWithPropertyList: (NSDictionary *)plist;
@end

NSString *SCPersistentDeviceIdentifier(NSString *deviceName);

/*
 * Other names the same airscan device may have now: airscan numbers
 * devices in the order it discovers them ("airscan:w0:..." one day,
 * "airscan:w1:..." the next) and names them by protocol (e for eSCL, w for
 * WSD). Same protocol first; empty for names of other drivers.
 */
NSArray *SCAirscanAlternativeNames(NSString *deviceName);

/* All delegate messages arrive on the main thread */
@protocol SCScannerDelegate <NSObject>
- (void) scanner: (SCScanner *)scanner didScanImage: (SCImage *)image;
- (void) scanner: (SCScanner *)scanner progress: (double)fraction;
/* error is nil on success; cancelled is YES when -cancel ended the scan */
- (void) scannerDidFinish: (SCScanner *)scanner cancelled: (BOOL)cancelled
                    error: (NSError *)error;
@end

/*
 * Supplies user name and password for a SANE resource. Called on the thread
 * that opened the device; return NO when the user cancels.
 */
typedef BOOL (^SCAuthenticationHandler)(NSString *resource,
                                        NSString **user,
                                        NSString **password);

extern NSString * const SCScannerOptionsDidChangeNotification;

/*
 * One open SANE device. Option access happens on the main thread; a scan
 * runs on a worker thread, during which only -cancel may be called, because
 * SANE drivers do not expect concurrent calls on one handle.
 */
@interface SCScanner : NSObject

@property (nonatomic, weak) id<SCScannerDelegate> delegate;
@property (nonatomic, readonly) SCDeviceInfo *device;
@property (nonatomic, readonly) NSArray *options;
@property (nonatomic, readonly, getter=isScanning) BOOL scanning;

+ (BOOL) initializeSANEWithError: (NSError **)error;
+ (void) exitSANE;
+ (void) setAuthenticationHandler: (SCAuthenticationHandler)handler;

/*
 * YES once a running scan was cancelled. SANE's thread helper (used by the
 * test, pixma, avision and other drivers) cancels its reader thread
 * asynchronously, which can leave glibc's locale lock taken; a later exit()
 * then hangs forever in library destructors. A process for which this
 * returns YES must leave with _exit() after saving its state.
 */
+ (BOOL) mustSkipExitHandlers;

/* Blocking; network discovery can take seconds, call it off the main thread */
+ (NSArray *) devicesWithError: (NSError **)error;

/* Blocking for the same reason */
- (instancetype) initWithDevice: (SCDeviceInfo *)device error: (NSError **)error;

/*
 * Opens the device, and when that fails, the same airscan device under its
 * other possible names. Once airscan has looked for devices for the first
 * attempt, the others are answered at once, so this is much faster than a
 * full search. Blocking.
 */
+ (instancetype) scannerOpeningDevice: (SCDeviceInfo *)device error: (NSError **)error;
- (void) close;

- (SCOption *) optionNamed: (NSString *)name;
- (BOOL) setValue: (id)value forOption: (SCOption *)option error: (NSError **)error;
- (BOOL) setAutomaticForOption: (SCOption *)option error: (NSError **)error;
- (BOOL) pressButton: (SCOption *)option error: (NSError **)error;
- (void) reloadOptions;

/* Settable values keyed by option name, to restore a device's setup later */
- (NSDictionary *) savedValues;
- (void) restoreValues: (NSDictionary *)values;

- (double) resolution;

/* Scan area as fractions of the full area, origin top left */
- (BOOL) hasScanArea;
- (NSRect) normalizedScanArea;
- (BOOL) setNormalizedScanArea: (NSRect)area error: (NSError **)error;
/* Full area in mm, or NSZeroSize when the driver does not use mm */
- (NSSize) scanAreaSizeInMillimeters;

/* YES when the selected source feeds sheets, so a scan continues until it is empty */
- (BOOL) sourceFeedsMultiplePages;

- (void) startScanAllowingMultiplePages: (BOOL)multiplePages;
- (void) cancel;

@end

/* Maps a fraction of [minimum, maximum] to the value the option allows */
double SCOptionValueForFraction(SCOption *option, double fraction);
double SCFractionForOptionValue(SCOption *option, double value);

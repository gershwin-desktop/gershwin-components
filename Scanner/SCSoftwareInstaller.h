/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Installs what Scanner needs only once it is used, with the PackageManager
 * framework, Gershwin's on-demand installer: scanner support (SANE and its
 * network scanner driver) and text recognition (tesseract and its language
 * data). Asks the user, then installs with the system's package manager
 * while the framework's progress window shows what happens.
 *
 * Package names were checked against each system's package index
 * (packages.debian.org, archlinux.org, freshports.org, OpenBSD ports).
 */
@interface SCSoftwareInstaller : NSObject

/*
 * Package names for tesseract codes ("deu", "chi_sim"), plus tesseract
 * itself when withTesseract is set, for a package manager family as
 * GWOSDetector names them; nil for a family we do not know the names for
 */
+ (NSArray *) packagesForLanguages: (NSArray *)codes
                     withTesseract: (BOOL)withTesseract
                            family: (NSString *)family;

/* The same for the system this runs on */
+ (NSArray *) packagesForLanguages: (NSArray *)codes
                     withTesseract: (BOOL)withTesseract;

/* SANE with its drivers, and the network scanner driver where it is packaged */
+ (NSArray *) scannerSupportPackagesForFamily: (NSString *)family;
+ (NSArray *) scannerSupportPackages;

/* ipp-usb, which lets sane-airscan scan from printers connected by USB; nil where not packaged */
+ (NSArray *) usbScanningPackagesForFamily: (NSString *)family;
+ (NSArray *) usbScanningPackages;

/*
 * Asks whether to install `what` ("German text recognition"), explaining
 * why with `reason`, and installs `packages`. The completion runs on the
 * main thread with YES when they were installed; NO when the user declined
 * or the install failed (a failure is shown to the user before).
 */
+ (void) offerPackages: (NSArray *)packages
                  what: (NSString *)what
                reason: (NSString *)reason
            completion: (void (^)(BOOL installed))completion;

/* Text recognition through -offerPackages:... */
+ (void) offerLanguages: (NSArray *)codes
          withTesseract: (BOOL)withTesseract
                   what: (NSString *)what
             completion: (void (^)(BOOL installed))completion;

@end

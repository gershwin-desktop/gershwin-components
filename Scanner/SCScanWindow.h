/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCScanner;

/*
 * The main window for one open scanner: its options on the left, the
 * preview with the areas to scan on the right, Preview and Scan below.
 */
@interface SCScanWindow : NSWindowController

- (instancetype) initWithScanner: (SCScanner *)scanner;
- (SCScanner *) scanner;
- (BOOL) isScanning;

/* Stops listing this computer on the printer's panel; before closing the scanner */
- (void) stopPanelScanning;

/* Writes the scanner's settings to the defaults, to restore them next time */
- (void) saveDeviceSettings;

- (void) preview: (id)sender;
- (void) scan: (id)sender;
- (void) cancelScan: (id)sender;
- (void) savePages: (id)sender;
- (void) discardPages: (id)sender;
- (void) deletePage: (id)sender;
- (void) movePageUp: (id)sender;
- (void) movePageDown: (id)sender;
- (void) showSavedFile: (id)sender;
- (void) installTextRecognition: (id)sender;

/* On the very first launch, offers text recognition when it is missing */
- (void) offerTextRecognitionOnFirstLaunch;

/* NO when the user keeps the window open to deal with collected pages first */
- (BOOL) mayCloseWithCollectedPages;

- (void) zoomIn: (id)sender;
- (void) zoomOut: (id)sender;
- (void) zoomToFit: (id)sender;
- (void) autoSelect: (id)sender;
- (void) removeAllSelections: (id)sender;

@end

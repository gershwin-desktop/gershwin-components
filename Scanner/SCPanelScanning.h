/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCImage, SCWSDScanTicket;

@protocol SCPanelScanningDelegate <NSObject>
/* How to scan what was started at the panel: Scanner's current settings */
- (SCWSDScanTicket *) panelScanTicketForSource: (NSString *)inputSource;
/* name: how the printer's panel lists this computer, nil when it no longer does */
- (void) panelScanningDidChangeStatus: (NSString *)name;
- (void) panelScanDidStart;
- (void) panelScanDidDeliverPage: (SCImage *)page;
- (void) panelScanDidFinishWithError: (NSError *)error;
@end

/*
 * While Scanner runs, lists this computer as a scan destination on the
 * panel of the open network scanner (WSD) and fetches what is scanned there.
 * Everything runs in Scanner's own threads; when Scanner quits, the
 * registration is withdrawn and the printer stops listing the computer.
 */
@interface SCPanelScanning : NSObject

@property (nonatomic, weak) id<SCPanelScanningDelegate> delegate;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

/* host: the printer's IP address; name: how the panel lists this computer */
- (instancetype) initWithHost: (NSString *)host displayName: (NSString *)name;
- (void) start;
/* Withdraws the registration; waits a few seconds at most, for quitting */
- (void) stop;

/* The computer's name as panels list it: the host name without its domain */
+ (NSString *) defaultDisplayName;

@end

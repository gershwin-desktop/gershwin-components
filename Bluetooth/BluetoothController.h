/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface BluetoothController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSView *controlsView;
    NSTextField *unavailableLabel;

    NSButton *powerCheckbox;
    NSButton *discoverableCheckbox;

    NSTableView *devicesTable;
    NSScrollView *devicesScrollView;
    NSArray *pairedDevices;
    NSArray *discoveredDevices;

    NSTextField *deviceInfoLabel;
    NSTextField *detailType;
    NSTextField *detailAddress;
    NSTextField *detailPaired;
    NSTextField *detailConnected;
    NSTextField *detailTrusted;
    NSButton *pairButton;
    NSButton *connectButton;
    NSButton *disconnectButton;
    NSButton *trustButton;
    NSButton *removeButton;
    NSButton *scanButton;
    NSProgressIndicator *scanSpinner;

    NSTextField *statusLabel;

    BOOL isRefreshing;
    NSMutableDictionary *deviceInfoCache;
}

- (NSView *)createMainView;
- (void)refreshFromSystem;
- (void)pollDevices;
- (IBAction)settingChanged:(id)sender;

@end

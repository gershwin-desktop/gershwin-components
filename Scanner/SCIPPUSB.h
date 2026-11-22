/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Most printers with a scanner made in the last decade (HP, Canon, Epson,
 * Brother, ...) scan over USB the way they do over the network, through
 * IPP-over-USB. The ipp-usb service makes them look like network devices,
 * which sane-airscan then drives without any vendor driver. This finds such
 * devices, so Scanner can offer ipp-usb when one is connected but missing.
 */
@interface SCIPPUSB : NSObject

/*
 * Names ("HP OfficeJet 3830") of the devices under a sysfs root
 * (/sys/bus/usb/devices) that have an IPP-over-USB interface: USB class 7
 * (printer), subclass 1, protocol 4, or HP's own variant of it (vendor
 * 03f0, class 255, subclass 9, protocol 1), as ipp-usb's udev rules match
 */
+ (NSArray *) deviceNamesInSysfs: (NSString *)root;

/* The connected IPP-over-USB devices; only Linux can list them without root */
+ (NSArray *) connectedDeviceNames;

/* The installed ipp-usb program, or nil */
+ (NSString *) programPath;

/* YES while an ipp-usb process runs (Linux); NO where that cannot be told */
+ (BOOL) isRunning;

/* The same for a /proc root, for tests */
+ (BOOL) isRunningInProc: (NSString *)proc;

/*
 * Runs ipp-usb for the connected devices, as root through sudo's password
 * prompt. "udev" mode serves what is connected and ends by itself once the
 * last device is unplugged, so nothing is left running for nothing, and no
 * service has to be added to the system's startup (Debian starts ipp-usb
 * only through systemd, which Devuan and Artix do not have). The
 * completion runs on the main thread once it serves devices or failed.
 */
+ (void) startWithCompletion: (void (^)(BOOL running))completion;

@end

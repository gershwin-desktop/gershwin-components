/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Explains why a USB scanner cannot be used when the reason is device
 * permissions, which SANE itself only reports as "not found" or "access
 * denied". The checks differ per system: Linux grants scanners to a group
 * through udev, the BSDs set owner and mode of /dev/ugen* nodes.
 */
@interface SCPermissionCheck : NSObject

/*
 * A connected USB scanner that this user cannot open, with what to do
 * about it; nil when there is none. Only Linux can tell scanners from other
 * USB devices (udev marks the ones SANE knows), so this is nil elsewhere.
 */
+ (NSString *) problemWithConnectedScanners;

/*
 * For when no scanner was found or opening one failed: whether this user
 * can open USB devices at all, and what to do; nil when nothing is wrong
 * or nothing can be said.
 */
+ (NSString *) problemWithUSBAccess;

/* The parts below are separate so they can be tested with made-up data */

/* Device nodes (/dev/bus/usb/BBB/DDD) of USB devices udev marked for SANE */
+ (NSArray *) linuxScannerNodesInUdevData: (NSString *)udevDataDir
                                  devRoot: (NSString *)devRoot;

/* What to do about a missing membership in `group`; nil when the session has it */
+ (NSString *) adviceForGroup: (NSString *)group
                     userName: (NSString *)user
                inSessionGIDs: (NSArray *)sessionGroupNames
            inGroupDatabase: (BOOL)listedInGroupDatabase;

@end

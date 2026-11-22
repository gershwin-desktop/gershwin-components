/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_IPPUSB - finding IPP-over-USB devices in a made-up sysfs tree. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCIPPUSB.h"

static void
Write(NSString *dir, NSString *name, NSString *value)
{
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
                            withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  [[value stringByAppendingString: @"\n"]
    writeToFile: [dir stringByAppendingPathComponent: name]
     atomically: NO encoding: NSUTF8StringEncoding error: NULL];
}

static void
Interface(NSString *root, NSString *name, NSString *c, NSString *s, NSString *p)
{
  NSString *dir = [root stringByAppendingPathComponent: name];

  Write(dir, @"bInterfaceClass", c);
  Write(dir, @"bInterfaceSubClass", s);
  Write(dir, @"bInterfaceProtocol", p);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_IPPUSB-%d", getpid()]];
  NSArray *names;

  [fm removeItemAtPath: root error: NULL];
  /* An HP multifunction device: a vendor interface and two IPP-over-USB ones */
  Write([root stringByAppendingPathComponent: @"1-2"], @"manufacturer", @"HP");
  Write([root stringByAppendingPathComponent: @"1-2"], @"product", @"OfficeJet 3830");
  Interface(root, @"1-2:1.0", @"ff", @"cc", @"00");
  Interface(root, @"1-2:1.1", @"07", @"01", @"04");
  Interface(root, @"1-2:1.2", @"07", @"01", @"04");
  /* An old printer that only speaks plain USB printing (protocol 2) */
  Write([root stringByAppendingPathComponent: @"1-3"], @"product", @"LaserJet 1018");
  Interface(root, @"1-3:1.0", @"07", @"01", @"02");
  /* A product name that already starts with the maker */
  Write([root stringByAppendingPathComponent: @"2-1"], @"manufacturer", @"Canon");
  Write([root stringByAppendingPathComponent: @"2-1"], @"product", @"Canon PIXMA G3010");
  Interface(root, @"2-1:1.3", @"07", @"01", @"04");

  names = [SCIPPUSB deviceNamesInSysfs: root];
  PASS([names count] == 2, "each IPP-over-USB device once, plain USB printers left out");
  PASS([names containsObject: @"HP OfficeJet 3830"], "maker and product make the name");
  PASS([names containsObject: @"Canon PIXMA G3010"], "the maker is not repeated");
  PASS([[SCIPPUSB deviceNamesInSysfs: @"/nonexistent"] count] == 0,
       "no sysfs, no devices");

  /* HP's own variant of the interface counts only on HP devices */
  Write([root stringByAppendingPathComponent: @"3-1"], @"idVendor", @"03f0");
  Write([root stringByAppendingPathComponent: @"3-1"], @"product", @"HP LaserJet MFP M28w");
  Interface(root, @"3-1:1.1", @"ff", @"09", @"01");
  Write([root stringByAppendingPathComponent: @"3-2"], @"idVendor", @"04a9");
  Write([root stringByAppendingPathComponent: @"3-2"], @"product", @"Other Device");
  Interface(root, @"3-2:1.0", @"ff", @"09", @"01");
  names = [SCIPPUSB deviceNamesInSysfs: root];
  PASS([names containsObject: @"HP LaserJet MFP M28w"]
       && ![names containsObject: @"Other Device"],
       "HP's vendor interface counts for HP, not for others");

  {
    NSString *proc = [root stringByAppendingPathComponent: @"proc"];

    Write([proc stringByAppendingPathComponent: @"1"], @"comm", @"init");
    Write([proc stringByAppendingPathComponent: @"812"], @"comm", @"sudo");
    PASS(![SCIPPUSB isRunningInProc: proc], "sudo waiting for a password is not ipp-usb");
    Write([proc stringByAppendingPathComponent: @"813"], @"comm", @"ipp-usb");
    PASS([SCIPPUSB isRunningInProc: proc], "a running ipp-usb is found");
  }

  [fm removeItemAtPath: root error: NULL];
  [arp release];
  return 0;
}

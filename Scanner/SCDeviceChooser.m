/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCDeviceChooser.h"
#import "SCScanner.h"
#import "SCMetrics.h"
#import "SCPermissionCheck.h"

/* Room for a permission problem with its fix, which takes a few lines */
static const CGFloat SCStatusHeight = 84;

@interface SCDeviceChooser () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SCDeviceChooser
{
  NSTableView *_table;
  NSTextField *_status;
  NSProgressIndicator *_spinner;
  NSButton *_rescan;
  NSButton *_open;
  NSArray *_devices;
  BOOL _searching;
  BOOL _busy;
}

- (instancetype) init
{
  NSRect frame = NSMakeRect(0, 0, 520, 380);
  NSWindow *window = [[NSWindow alloc]
                       initWithContentRect: frame
                                 styleMask: NSTitledWindowMask | NSResizableWindowMask
                                   backing: NSBackingStoreBuffered
                                     defer: YES];

  self = [super initWithWindow: window];
  if (self)
    {
      [window setTitle: @"Choose a Scanner"];
      /* Closed when a scanner opens and shown again by "Choose Scanner..." */
      [window setReleasedWhenClosed: NO];
      [window setMinSize: NSMakeSize(360, 220)];
      [self buildContent];
      [window center];
    }
  return self;
}

- (NSButton *) buttonWithTitle: (NSString *)title action: (SEL)action x: (CGFloat)x
{
  NSButton *b = [[NSButton alloc]
                  initWithFrame: NSMakeRect(x, METRICS_CONTENT_BOTTOM_MARGIN,
                                            METRICS_BUTTON_MIN_WIDTH,
                                            METRICS_BUTTON_HEIGHT)];

  [b setTitle: title];
  [b setBezelStyle: NSRoundedBezelStyle];
  [b setTarget: self];
  [b setAction: action];
  [b setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [[[self window] contentView] addSubview: b];
  return b;
}

- (void) buildContent
{
  NSView *content = [[self window] contentView];
  NSRect bounds = [content bounds];
  CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
  CGFloat buttonsTop = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT;
  CGFloat statusY = buttonsTop + METRICS_BUTTON_VERT_INTERSPACE;
  CGFloat tableY = statusY + SCStatusHeight + METRICS_SPACE_8;
  NSScrollView *scroll;
  NSTableColumn *column;

  scroll = [[NSScrollView alloc]
             initWithFrame: NSMakeRect(side, tableY, NSWidth(bounds) - 2 * side,
                                       NSHeight(bounds) - tableY
                                       - METRICS_CONTENT_TOP_MARGIN)];
  [scroll setHasVerticalScroller: YES];
  [scroll setBorderType: NSBezelBorder];
  [scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _table = [[NSTableView alloc] initWithFrame: [[scroll contentView] bounds]];
  column = [[NSTableColumn alloc] initWithIdentifier: @"name"];
  [[column headerCell] setStringValue: @"Scanner"];
  [column setResizingMask: NSTableColumnAutoresizingMask];
  [_table addTableColumn: column];
  [_table setColumnAutoresizingStyle: NSTableViewUniformColumnAutoresizingStyle];
  [_table setDataSource: self];
  [_table setDelegate: self];
  [_table setTarget: self];
  [_table setDoubleAction: @selector(open:)];
  [scroll setDocumentView: _table];
  [column setWidth: NSWidth([[scroll contentView] bounds])];
  [content addSubview: scroll];

  _spinner = [[NSProgressIndicator alloc]
               initWithFrame: NSMakeRect(side, statusY + SCStatusHeight - 16, 16, 16)];
  [_spinner setStyle: NSProgressIndicatorSpinningStyle];
  [_spinner setDisplayedWhenStopped: NO];
  [_spinner setAutoresizingMask: NSViewMaxYMargin];
  [content addSubview: _spinner];

  _status = [[NSTextField alloc]
              initWithFrame: NSMakeRect(side + 16 + METRICS_SPACE_8, statusY,
                                        NSWidth(bounds) - 2 * side - 24,
                                        SCStatusHeight)];
  [_status setEditable: NO];
  /* Selectable, so the command to fix permissions can be copied */
  [_status setSelectable: YES];
  [[_status cell] setWraps: YES];
  [[_status cell] setLineBreakMode: NSLineBreakByWordWrapping];
  [_status setBezeled: NO];
  [_status setDrawsBackground: NO];
  [_status setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
  [content addSubview: _status];

  _open = [self buttonWithTitle: @"Open"
                         action: @selector(open:)
                              x: NSWidth(bounds) - side - METRICS_BUTTON_MIN_WIDTH];
  [_open setKeyEquivalent: @"\r"];
  _rescan = [self buttonWithTitle: @"Search Again"
                           action: @selector(rescan:)
                                x: NSMinX([_open frame])
                                   - METRICS_BUTTON_HORIZ_INTERSPACE
                                   - METRICS_BUTTON_MIN_WIDTH];
  [self updateButtons];
}

- (void) updateButtons
{
  [_open setEnabled: !_searching && !_busy && [_table selectedRow] >= 0];
  [_rescan setEnabled: !_searching && !_busy];
}

- (void) setBusy: (BOOL)busy message: (NSString *)message
{
  _busy = busy;
  [_status setStringValue: message ? message : @""];
  if (busy)
    {
      [_spinner startAnimation: nil];
    }
  else
    {
      [_spinner stopAnimation: nil];
    }
  [self updateButtons];
}

- (void) showAndSearch
{
  [self showWindow: nil];
  [self rescan: nil];
}

- (void) rescan: (id)sender
{
  if (_searching || ![_delegate deviceChooserShouldSearch: self])
    {
      return;
    }
  _searching = YES;
  _devices = nil;
  [_table reloadData];
  [self setBusy: NO message: @"Looking for scanners..."];
  [_spinner startAnimation: nil];
  [NSThread detachNewThreadSelector: @selector(searchThread:)
                           toTarget: self withObject: nil];
}

- (void) searchThread: (id)unused
{
  @autoreleasepool
    {
      NSError *error = nil;
      NSArray *devices = [SCScanner devicesWithError: &error];
      NSDictionary *result = devices ? @{@"devices": devices}
                                     : @{@"error": error};

      [self performSelectorOnMainThread: @selector(searchFinished:)
                             withObject: result waitUntilDone: NO];
    }
}

- (void) searchFinished: (NSDictionary *)result
{
  NSError *error = [result objectForKey: @"error"];
  SCDeviceInfo *automatic;

  _searching = NO;
  _devices = [result objectForKey: @"devices"];
  [_spinner stopAnimation: nil];
  [_table reloadData];
  if (error != nil)
    {
      [_status setStringValue: [error localizedDescription]];
    }
  else if ([_devices count] == 0)
    {
      NSString *usb = [SCPermissionCheck problemWithUSBAccess];

      [_status setStringValue: usb
        ? [@"No scanners found. If yours is connected by USB: " stringByAppendingString: usb]
        : @"No scanners found. Check that the scanner is switched on and connected."];
    }
  else
    {
      /* A USB scanner the user cannot open does not show up in the list at all */
      NSString *blocked = [SCPermissionCheck problemWithConnectedScanners];
      NSString *found = [_devices count] == 1 ? @"1 scanner found."
        : [NSString stringWithFormat: @"%lu scanners found.",
                    (unsigned long)[_devices count]];

      [_status setStringValue: blocked
        ? [NSString stringWithFormat: @"%@ %@", found, blocked] : found];
      [_table selectRowIndexes: [NSIndexSet indexSetWithIndex: 0]
          byExtendingSelection: NO];
    }
  [self updateButtons];

  [_delegate deviceChooser: self didFindDevices: _devices];
  automatic = [_delegate deviceChooser: self deviceToOpenAutomaticallyFrom: _devices];
  if (automatic != nil)
    {
      [_delegate deviceChooser: self didChooseDevice: automatic];
    }
}

- (void) open: (id)sender
{
  NSInteger row = [_table selectedRow];

  if (row < 0 || _searching || _busy)
    {
      return;
    }
  [_delegate deviceChooser: self didChooseDevice: [_devices objectAtIndex: row]];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)table
{
  return [_devices count];
}

- (id) tableView: (NSTableView *)table objectValueForTableColumn: (NSTableColumn *)column
             row: (NSInteger)row
{
  SCDeviceInfo *d = [_devices objectAtIndex: row];

  return [NSString stringWithFormat: @"%@ (%@)", [d displayName], [d name]];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
  [self updateButtons];
}

@end

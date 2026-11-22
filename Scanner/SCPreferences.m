/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPreferences.h"
#import "SCFormView.h"
#import "SCMetrics.h"

NSString * const SCSaveDirectoryKey = @"SaveDirectory";
NSString * const SCFileNamePatternKey = @"FileNamePattern";
NSString * const SCFileFormatKey = @"FileFormat";
NSString * const SCJPEGQualityKey = @"JPEGQuality";
NSString * const SCPreviewResolutionKey = @"PreviewResolution";
NSString * const SCInvertColorsKey = @"InvertColors";
NSString * const SCThresholdKey = @"BlackAndWhiteThreshold";
NSString * const SCRecognizeTextKey = @"RecognizeTextInPDFs";
NSString * const SCDeclinedLanguagesKey = @"DeclinedTextRecognitionLanguages";
NSString * const SCOfferedTextRecognitionKey = @"OfferedTextRecognition";
NSString * const SCPanelScanningKey = @"ScanFromPrinterPanel";
NSString * const SCDeviceSettingsKey = @"DeviceSettings";
NSString * const SCLastDeviceKey = @"LastDevice";

@implementation SCPreferences
{
  NSTextField *_directory;
  NSTextField *_pattern;
  NSSlider *_quality;
  NSPopUpButton *_previewResolution;
  NSButton *_panelScanning;
}

+ (void) registerDefaults
{
  NSArray *pictures = NSSearchPathForDirectoriesInDomains(NSPicturesDirectory,
                                                          NSUserDomainMask, YES);

  [[NSUserDefaults standardUserDefaults] registerDefaults: @{
    SCSaveDirectoryKey: [pictures count] ? [pictures objectAtIndex: 0]
                                         : NSHomeDirectory(),
    SCFileNamePatternKey: @"Scan-####",
    SCFileFormatKey: @"PDF",
    SCJPEGQualityKey: @0.9,
    SCPreviewResolutionKey: @100,
    SCInvertColorsKey: @NO,
    SCThresholdKey: @128,
    SCRecognizeTextKey: @NO,
    SCPanelScanningKey: @YES,
  }];
}

+ (NSString *) saveDirectory
{
  return [[[NSUserDefaults standardUserDefaults] stringForKey: SCSaveDirectoryKey]
           stringByExpandingTildeInPath];
}

+ (SCFileFormat) fileFormat
{
  NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey: SCFileFormatKey];
  NSUInteger i = [[SCImageWriter formatNames] indexOfObject: name];

  return (i == NSNotFound) ? SCFileFormatPNG : (SCFileFormat)i;
}

- (instancetype) init
{
  NSWindow *window = [[NSWindow alloc]
                       initWithContentRect: NSMakeRect(0, 0, 520, 300)
                                 styleMask: NSTitledWindowMask | NSClosableWindowMask
                                   backing: NSBackingStoreBuffered
                                     defer: YES];

  self = [super initWithWindow: window];
  if (self)
    {
      [window setTitle: @"Scanner Preferences"];
      [self buildContent];
      [self load];
      [window center];
    }
  return self;
}

- (NSTextField *) fieldWithAction: (SEL)action
{
  NSTextField *f = [[NSTextField alloc]
                     initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)];

  [f setTarget: self];
  [f setAction: action];
  [f setDelegate: (id)self];
  return f;
}

- (void) buildContent
{
  NSView *content = [[self window] contentView];
  CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
  CGFloat width = NSWidth([content bounds]) - 2 * side;
  SCFormView *form = [[SCFormView alloc] initWithFrame: NSMakeRect(side, 0, width, 10)];
  NSView *folderRow = [[NSView alloc]
                        initWithFrame: NSMakeRect(0, 0, 200, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
  NSButton *choose = [[NSButton alloc]
                       initWithFrame: NSMakeRect(0, 1, METRICS_BUTTON_MIN_WIDTH,
                                                 METRICS_BUTTON_HEIGHT)];
  NSTextField *hint;
  NSRect f;

  [form setLabelWidth: 150];
  _directory = [self fieldWithAction: @selector(changed:)];
  [_directory setAutoresizingMask: NSViewWidthSizable];
  [choose setTitle: @"Choose..."];
  [choose setBezelStyle: NSRoundedBezelStyle];
  [choose setTarget: self];
  [choose setAction: @selector(chooseDirectory:)];
  [choose setAutoresizingMask: NSViewMinXMargin];
  [folderRow addSubview: _directory];
  [folderRow addSubview: choose];
  [folderRow setAutoresizesSubviews: YES];
  /* The form gives the row its width; field and button follow by autoresizing */
  [_directory setFrame: NSMakeRect(0, 0, 200 - METRICS_BUTTON_MIN_WIDTH - METRICS_SPACE_8,
                                   METRICS_TEXT_INPUT_FIELD_HEIGHT)];
  [choose setFrameOrigin: NSMakePoint(200 - METRICS_BUTTON_MIN_WIDTH, 1)];

  _pattern = [self fieldWithAction: @selector(changed:)];

  hint = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 100, 18)];
  [hint setStringValue: @"#### becomes the number of the scan."];
  [hint setEditable: NO];
  [hint setSelectable: NO];
  [hint setBezeled: NO];
  [hint setDrawsBackground: NO];
  [hint setFont: [NSFont systemFontOfSize: 11]];


  _quality = [[NSSlider alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [_quality setMinValue: 0.1];
  [_quality setMaxValue: 1.0];
  [_quality setTarget: self];
  [_quality setAction: @selector(changed:)];

  _previewResolution = [[NSPopUpButton alloc]
                         initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)
                             pullsDown: NO];
  for (NSNumber *dpi in @[@50, @75, @100, @150, @200])
    {
      [_previewResolution addItemWithTitle:
        [NSString stringWithFormat: @"%@ dpi", dpi]];
      [[_previewResolution lastItem] setRepresentedObject: dpi];
    }
  [_previewResolution setTarget: self];
  [_previewResolution setAction: @selector(changed:)];


  _panelScanning = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [_panelScanning setButtonType: NSSwitchButton];
  [_panelScanning setTitle: @"Scan from the printer's panel"];
  [_panelScanning setToolTip: @"While Scanner is open, network scanners list this "
                  @"computer on their panel, so scanning can be started there. "
                  @"Takes effect when a scanner is opened next."];
  [_panelScanning setTarget: self];
  [_panelScanning setAction: @selector(changed:)];

  [form setRows: @[
    [SCFormRow rowWithLabel: @"Save in:" control: folderRow],
    [SCFormRow rowWithLabel: @"File name:" control: _pattern],
    [SCFormRow rowWithLabel: @"" control: hint],
    [SCFormRow rowWithLabel: @"JPEG quality:" control: _quality],
    [SCFormRow rowWithLabel: @"Preview resolution:" control: _previewResolution],
    [SCFormRow rowWithLabel: @"" control: _panelScanning],
  ]];

  /* Size the window to the form so the margins stay symmetric */
  f = [form frame];
  [[self window] setContentSize: NSMakeSize(NSWidth([content bounds]),
                                            NSHeight(f) + METRICS_CONTENT_TOP_MARGIN
                                            + METRICS_CONTENT_BOTTOM_MARGIN)];
  [form setFrameOrigin: NSMakePoint(side, METRICS_CONTENT_BOTTOM_MARGIN)];
  [form setAutoresizingMask: NSViewWidthSizable];
  [content addSubview: form];
  /* SCFormView is flipped and lays out top-down; re-run now that it is placed */
  [form layoutRows];
}

- (void) load
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSInteger i;

  [_directory setStringValue: [SCPreferences saveDirectory]];
  [_pattern setStringValue: [d stringForKey: SCFileNamePatternKey]];
  [_quality setDoubleValue: [d doubleForKey: SCJPEGQualityKey]];
  [_panelScanning setState: [d boolForKey: SCPanelScanningKey] ? NSOnState : NSOffState];
  for (i = 0; i < [_previewResolution numberOfItems]; i++)
    {
      if ([[[_previewResolution itemAtIndex: i] representedObject] integerValue]
          == [d integerForKey: SCPreviewResolutionKey])
        {
          [_previewResolution selectItemAtIndex: i];
        }
    }
}

- (void) changed: (id)sender
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSString *pattern = [[_pattern stringValue]
                        stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];

  [d setObject: [[_directory stringValue] stringByAbbreviatingWithTildeInPath]
        forKey: SCSaveDirectoryKey];
  /* A slash would put scans into another folder than the one shown above */
  if ([pattern length] > 0 && [pattern rangeOfString: @"/"].location == NSNotFound)
    {
      [d setObject: pattern forKey: SCFileNamePatternKey];
    }
  [d setDouble: [_quality doubleValue] forKey: SCJPEGQualityKey];
  [d setObject: [[_previewResolution selectedItem] representedObject]
        forKey: SCPreviewResolutionKey];
  [d setBool: [_panelScanning state] == NSOnState forKey: SCPanelScanningKey];
  [self load];
}

- (void) controlTextDidEndEditing: (NSNotification *)n
{
  [self changed: [n object]];
}

- (void) chooseDirectory: (id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];

  [panel setCanChooseDirectories: YES];
  [panel setCanChooseFiles: NO];
  [panel setCanCreateDirectories: YES];
  [panel setAllowsMultipleSelection: NO];
  [panel setDirectoryURL: [NSURL fileURLWithPath: [SCPreferences saveDirectory]]];
  if ([panel runModal] == NSModalResponseOK)
    {
      [_directory setStringValue: [[panel URL] path]];
      [self changed: sender];
    }
}

@end

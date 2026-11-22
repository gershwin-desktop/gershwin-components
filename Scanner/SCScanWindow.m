/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCScanWindow.h"
#import "SCScanner.h"
#import "SCOption.h"
#import "SCImage.h"
#import "SCImageWriter.h"
#import "SCImageAnalysis.h"
#import "SCFormView.h"
#import "SCOptionControl.h"
#import "SCPreviewView.h"
#import "SCPreferences.h"
#import "SCPageListView.h"
#import "SCSaver.h"
#import "SCTextRecognizer.h"
#import "SCSoftwareInstaller.h"
#import "SCLanguageGuess.h"
#import "SCMetrics.h"
#include <sane/saneopts.h>

static const CGFloat SCOptionsWidth = 340;
/* Fits a portrait thumbnail big enough to recognize a page by */
static const CGFloat SCPagesWidth = 170;

typedef NS_ENUM(NSInteger, SCScanMode)
{
  SCScanModeIdle,
  SCScanModePreview,
  SCScanModeScan
};

/* Options most people change for every scan; everything else is "Advanced" */
/* airscan's name; other drivers have no such option */
static NSString * const SCScanIntentName = @"scan-intent";

static NSArray *
SCBasicOptionNames(void)
{
  return @[SCScanIntentName, @SANE_NAME_SCAN_SOURCE, @SANE_NAME_SCAN_MODE,
           @SANE_NAME_BIT_DEPTH,
           @SANE_NAME_SCAN_RESOLUTION, @SANE_NAME_SCAN_X_RESOLUTION,
           @SANE_NAME_SCAN_Y_RESOLUTION, @SANE_NAME_BRIGHTNESS,
           @SANE_NAME_CONTRAST];
}

/* Driven by the preview and the page size menu instead of by number fields */
static NSArray *
SCHiddenOptionNames(void)
{
  return @[@SANE_NAME_SCAN_TL_X, @SANE_NAME_SCAN_TL_Y, @SANE_NAME_SCAN_BR_X,
           @SANE_NAME_SCAN_BR_Y, @SANE_NAME_PREVIEW];
}

/* Paper sizes in mm, offered when they fit on the bed */
static NSArray *
SCPageSizes(void)
{
  return @[@[@"A4", @210.0, @297.0], @[@"A5", @148.0, @210.0],
           @[@"A6", @105.0, @148.0], @[@"Letter", @215.9, @279.4],
           @[@"Legal", @215.9, @355.6], @[@"Photo 10 x 15 cm", @100.0, @150.0],
           @[@"Photo 13 x 18 cm", @130.0, @180.0],
           @[@"Business Card", @85.0, @55.0]];
}

@interface SCScanWindow () <SCScannerDelegate, SCPreviewViewDelegate,
                            SCOptionControlDelegate, SCPageListViewDelegate,
                            NSWindowDelegate>
@end

@implementation SCScanWindow
{
  SCScanner *_scanner;
  NSTabView *_tabs;
  NSScrollView *_basicScroll;
  NSScrollView *_advancedScroll;
  SCFormView *_basicForm;
  SCFormView *_advancedForm;
  NSArray *_controls;
  NSMutableDictionary *_gammaSettings;
  NSPopUpButton *_pageSize;
  NSButton *_invert;
  /* Black and white made from gray scans, for scanners without line art */
  BOOL _ownBlackAndWhite;
  NSPopUpButton *_modePopUp;
  NSSlider *_threshold;
  NSButton *_recognizeText;
  /* Scanned pages waiting to be saved, in page order */
  NSMutableArray *_pages;
  SCPageListView *_pageList;
  NSScrollView *_pageView;
  NSImageView *_pageImageView;
  NSPopUpButton *_formatPopUp;
  NSButton *_saveButton;
  NSButton *_discardButton;
  BOOL _saving;
  /* Languages already suggested in this session, and whether one is being offered */
  NSMutableSet *_suggestedLanguages;
  BOOL _suggestingLanguage;
  /* Shown in the file viewer by "Show Saved File" */
  NSString *_lastSavedPath;
  NSScrollView *_previewScroll;
  SCPreviewView *_preview;
  NSTextField *_status;
  NSProgressIndicator *_progress;
  NSButton *_previewButton;
  NSButton *_scanButton;
  NSButton *_cancelButton;

  SCScanMode _mode;
  NSDictionary *_valuesBeforePreview;
  SCImage *_previewImage;
  NSMutableArray *_pendingAreas;
  BOOL _rebuildScheduled;
}

- (instancetype) initWithScanner: (SCScanner *)scanner
{
  NSRect screen = [[NSScreen mainScreen] visibleFrame];
  NSRect frame = NSMakeRect(0, 0, MIN(1000, NSWidth(screen) - 60),
                            MIN(680, NSHeight(screen) - 60));
  NSWindow *window = [[NSWindow alloc]
                       initWithContentRect: frame
                                 styleMask: NSTitledWindowMask | NSClosableWindowMask
                                            | NSResizableWindowMask
                                            | NSMiniaturizableWindowMask
                                   backing: NSBackingStoreBuffered
                                     defer: YES];

  self = [super initWithWindow: window];
  if (self)
    {
      _scanner = scanner;
      [_scanner setDelegate: self];
      _gammaSettings = [NSMutableDictionary dictionary];
      [window setTitle: [[scanner device] displayName]];
      [window setMinSize: NSMakeSize(720, 480)];
      [window setDelegate: self];
      /* Centered first; the autosaved frame, when there is one, wins */
      [window center];
      [window setFrameAutosaveName: @"ScanWindow"];
      [self buildContent];
      [self restoreDeviceSettings];
      [self rebuildOptions];
      [self updateButtons];
      [[NSNotificationCenter defaultCenter]
        addObserver: self selector: @selector(optionsDidChange:)
               name: SCScannerOptionsDidChangeNotification object: scanner];
      [[NSNotificationCenter defaultCenter]
        addObserver: self selector: @selector(recognitionDidFinish:)
               name: SCTextRecognizerDidFinishPageNotification object: nil];
      /* Languages may have been installed outside Scanner meanwhile */
      [[NSNotificationCenter defaultCenter]
        addObserver: self selector: @selector(applicationDidBecomeActive:)
               name: NSApplicationDidBecomeActiveNotification object: nil];
      /* Every save reports where it went in the status line */
      [[NSNotificationCenter defaultCenter]
        addObserver: self selector: @selector(didSave:)
               name: SCSaverDidSaveNotification object: nil];
      /* The file format in the preferences decides whether OCR applies */
      [[NSNotificationCenter defaultCenter]
        addObserver: self selector: @selector(defaultsDidChange:)
               name: NSUserDefaultsDidChangeNotification object: nil];
    }
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
}

- (SCScanner *) scanner
{
  return _scanner;
}

- (BOOL) isScanning
{
  return _mode != SCScanModeIdle;
}

#pragma mark Building the window

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

- (NSScrollView *) formScrollWithForm: (SCFormView *)form
{
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: [_tabs contentRect]];

  [scroll setHasVerticalScroller: YES];
  [scroll setAutohidesScrollers: YES];
  [scroll setBorderType: NSNoBorder];
  [scroll setDrawsBackground: NO];
  [scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [scroll setDocumentView: form];
  [[scroll contentView] setPostsFrameChangedNotifications: YES];
  [[NSNotificationCenter defaultCenter]
    addObserver: self selector: @selector(formClipDidResize:)
           name: NSViewFrameDidChangeNotification object: [scroll contentView]];
  return scroll;
}

- (void) buildContent
{
  NSView *content = [[self window] contentView];
  NSRect bounds = [content bounds];
  CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
  CGFloat upperY = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT
    + METRICS_BUTTON_VERT_INTERSPACE;
  CGFloat upperH = NSHeight(bounds) - upperY - METRICS_CONTENT_TOP_MARGIN;
  CGFloat previewX = side + SCOptionsWidth + METRICS_SPACE_16;
  NSTabViewItem *item;
  CGFloat x, pagesX;

  _tabs = [[NSTabView alloc] initWithFrame: NSMakeRect(side, upperY,
                                                       SCOptionsWidth, upperH)];
  [_tabs setAutoresizingMask: NSViewHeightSizable];
  [content addSubview: _tabs];

  _basicForm = [[SCFormView alloc] initWithFrame: NSMakeRect(0, 0, 100, 10)];
  _advancedForm = [[SCFormView alloc] initWithFrame: NSMakeRect(0, 0, 100, 10)];
  _basicScroll = [self formScrollWithForm: _basicForm];
  _advancedScroll = [self formScrollWithForm: _advancedForm];
  item = [[NSTabViewItem alloc] initWithIdentifier: @"basic"];
  [item setLabel: @"Basic"];
  [item setView: _basicScroll];
  [_tabs addTabViewItem: item];
  item = [[NSTabViewItem alloc] initWithIdentifier: @"advanced"];
  [item setLabel: @"Advanced"];
  [item setView: _advancedScroll];
  [_tabs addTabViewItem: item];

  pagesX = NSWidth(bounds) - side - SCPagesWidth;
  _previewScroll = [[NSScrollView alloc]
                     initWithFrame: NSMakeRect(previewX, upperY,
                                               pagesX - METRICS_SPACE_16 - previewX,
                                               upperH)];
  [_previewScroll setHasVerticalScroller: YES];
  [_previewScroll setHasHorizontalScroller: YES];
  [_previewScroll setAutohidesScrollers: YES];
  [_previewScroll setBorderType: NSBezelBorder];
  [_previewScroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _preview = [[SCPreviewView alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)];
  [_preview setDelegate: self];
  [_previewScroll setDocumentView: _preview];
  [[_previewScroll contentView] setPostsFrameChangedNotifications: YES];
  [[NSNotificationCenter defaultCenter]
    addObserver: self selector: @selector(previewClipDidResize:)
           name: NSViewFrameDidChangeNotification
         object: [_previewScroll contentView]];
  [content addSubview: _previewScroll];
  [_preview setBedAspect: [self bedAspect]];

  /* A scanned page, shown large in place of the preview when picked in the list */
  _pageView = [[NSScrollView alloc] initWithFrame: [_previewScroll frame]];
  [_pageView setBorderType: NSBezelBorder];
  [_pageView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _pageImageView = [[NSImageView alloc] initWithFrame: [[_pageView contentView] bounds]];
  [_pageImageView setImageScaling: NSImageScaleProportionallyDown];
  [_pageImageView setEditable: NO];
  [_pageImageView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  [_pageView setDocumentView: _pageImageView];
  [_pageView setHidden: YES];
  [content addSubview: _pageView];

  [self buildPageColumnAtX: pagesX y: upperY height: upperH];

  x = NSWidth(bounds) - side - METRICS_BUTTON_MIN_WIDTH;
  _scanButton = [self buttonWithTitle: @"Scan" action: @selector(scan:) x: x];
  [_scanButton setKeyEquivalent: @"\r"];
  x -= METRICS_BUTTON_MIN_WIDTH + METRICS_BUTTON_HORIZ_INTERSPACE;
  _previewButton = [self buttonWithTitle: @"Preview" action: @selector(preview:) x: x];
  x -= METRICS_BUTTON_MIN_WIDTH + METRICS_BUTTON_HORIZ_INTERSPACE;
  _cancelButton = [self buttonWithTitle: @"Cancel" action: @selector(cancelScan:) x: x];
  [_cancelButton setKeyEquivalent: @"\e"];

  x -= METRICS_BUTTON_HORIZ_INTERSPACE + 160;
  _progress = [[NSProgressIndicator alloc]
                initWithFrame: NSMakeRect(x, METRICS_CONTENT_BOTTOM_MARGIN + 2,
                                          160, 16)];
  [_progress setIndeterminate: NO];
  [_progress setMinValue: 0];
  [_progress setMaxValue: 1];
  [_progress setHidden: YES];
  [_progress setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [content addSubview: _progress];

  _status = [[NSTextField alloc]
              initWithFrame: NSMakeRect(side, METRICS_CONTENT_BOTTOM_MARGIN + 1,
                                        x - side - METRICS_SPACE_8, 18)];
  [_status setEditable: NO];
  [_status setSelectable: NO];
  [_status setBezeled: NO];
  [_status setDrawsBackground: NO];
  [[_status cell] setLineBreakMode: NSLineBreakByTruncatingTail];
  [_status setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
  [content addSubview: _status];
}

/* The pages, then "Save as" right above Save and Discard: the column is the document */
- (void) buildPageColumnAtX: (CGFloat)x y: (CGFloat)y height: (CGFloat)h
{
  NSView *content = [[self window] contentView];
  CGFloat top = y + h;
  CGFloat buttonsTop = y + 2 * METRICS_BUTTON_HEIGHT + METRICS_SPACE_8;
  CGFloat formatY = buttonsTop + METRICS_SPACE_8;
  NSTextField *label;
  NSScrollView *scroll;
  NSUInteger i;

  label = [[NSTextField alloc] initWithFrame:
             NSMakeRect(x, formatY + 2, 56, 18)];
  [label setStringValue: @"Save as:"];
  [label setEditable: NO];
  [label setSelectable: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  [label setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [content addSubview: label];

  _formatPopUp = [[NSPopUpButton alloc]
                   initWithFrame: NSMakeRect(x + 60, formatY,
                                             SCPagesWidth - 60,
                                             METRICS_TEXT_INPUT_FIELD_HEIGHT)
                       pullsDown: NO];
  [_formatPopUp addItemsWithTitles: [SCImageWriter formatNames]];
  for (i = 0; i < [[SCImageWriter formatNames] count]; i++)
    {
      [[_formatPopUp itemAtIndex: i] setTag: i];
    }
  [_formatPopUp selectItemWithTag: [SCPreferences fileFormat]];
  [_formatPopUp setToolTip: @"PDF puts all pages into one file; the other "
                @"formats save one file per page."];
  [_formatPopUp setTarget: self];
  [_formatPopUp setAction: @selector(formatChanged:)];
  [_formatPopUp setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [content addSubview: _formatPopUp];

  scroll = [[NSScrollView alloc]
             initWithFrame: NSMakeRect(x, formatY + METRICS_TEXT_INPUT_FIELD_HEIGHT
                                          + METRICS_SPACE_12, SCPagesWidth,
                                       top - formatY - METRICS_TEXT_INPUT_FIELD_HEIGHT
                                       - METRICS_SPACE_12)];
  [scroll setHasVerticalScroller: YES];
  /* Always shown: a scroller appearing later would cover the thumbnails' edge */
  [scroll setAutohidesScrollers: NO];
  [scroll setBorderType: NSBezelBorder];
  [scroll setAutoresizingMask: NSViewMinXMargin | NSViewHeightSizable];
  _pageList = [[SCPageListView alloc] initWithFrame: [[scroll contentView] bounds]];
  [_pageList setAutoresizingMask: NSViewWidthSizable];
  [_pageList setDelegate: self];
  [scroll setDocumentView: _pageList];
  [content addSubview: scroll];
  _pages = [NSMutableArray array];
  [_pageList reload];

  _saveButton = [[NSButton alloc]
                  initWithFrame: NSMakeRect(x, y + METRICS_BUTTON_HEIGHT + METRICS_SPACE_8,
                                            SCPagesWidth, METRICS_BUTTON_HEIGHT)];
  [_saveButton setTitle: @"Save"];
  [_saveButton setBezelStyle: NSRoundedBezelStyle];
  [_saveButton setTarget: self];
  [_saveButton setAction: @selector(savePages:)];
  [_saveButton setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [content addSubview: _saveButton];

  _discardButton = [[NSButton alloc]
                     initWithFrame: NSMakeRect(x, y, SCPagesWidth, METRICS_BUTTON_HEIGHT)];
  [_discardButton setTitle: @"Discard Pages"];
  [_discardButton setBezelStyle: NSRoundedBezelStyle];
  [_discardButton setTarget: self];
  [_discardButton setAction: @selector(discardPages:)];
  [_discardButton setAutoresizingMask: NSViewMinXMargin | NSViewMaxYMargin];
  [content addSubview: _discardButton];
}

- (NSSize) bedAspect
{
  NSSize mm = [_scanner scanAreaSizeInMillimeters];
  SCOption *brx = [_scanner optionNamed: @SANE_NAME_SCAN_BR_X];
  SCOption *bry = [_scanner optionNamed: @SANE_NAME_SCAN_BR_Y];

  if (mm.width > 0 && mm.height > 0)
    {
      return mm;
    }
  if ([_scanner hasScanArea] && [brx maximum] > 0 && [bry maximum] > 0)
    {
      return NSMakeSize([brx maximum], [bry maximum]);
    }
  return NSMakeSize(210, 297);
}

#pragma mark Options

- (void) optionsDidChange: (NSNotification *)n
{
  /*
   * Deferred: the notification arrives inside the action of a control
   * that the rebuild would free while its method is still running.
   */
  if (!_rebuildScheduled && _mode == SCScanModeIdle)
    {
      _rebuildScheduled = YES;
      [self performSelector: @selector(rebuildOptions) withObject: nil afterDelay: 0];
    }
}

- (NSPopUpButton *) pageSizePopUp
{
  NSSize bed = [_scanner scanAreaSizeInMillimeters];
  NSPopUpButton *popup;

  if (bed.width <= 0 || bed.height <= 0)
    {
      return nil;
    }
  popup = [[NSPopUpButton alloc]
            initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)
                pullsDown: NO];
  [popup addItemWithTitle: @"Custom"];
  [popup addItemWithTitle: @"Whole Bed"];
  [[popup lastItem] setRepresentedObject:
    [NSValue valueWithSize: bed]];
  for (NSArray *size in SCPageSizes())
    {
      double w = [[size objectAtIndex: 1] doubleValue];
      double h = [[size objectAtIndex: 2] doubleValue];

      /* A little tolerance: Letter is 215.9 mm and many beds are 215.9 or 216 */
      if (w <= bed.width + 0.5 && h <= bed.height + 0.5)
        {
          [popup addItemWithTitle: [size objectAtIndex: 0]];
          [[popup lastItem] setRepresentedObject:
            [NSValue valueWithSize: NSMakeSize(w, h)]];
        }
    }
  [popup setTarget: self];
  [popup setAction: @selector(pageSizeChanged:)];
  return popup;
}

- (void) rebuildOptions
{
  NSArray *basicNames = SCBasicOptionNames();
  NSArray *hidden = SCHiddenOptionNames();
  NSMutableArray *controls = [NSMutableArray array];
  NSMutableArray *basicRows = [NSMutableArray array];
  NSMutableArray *advancedRows = [NSMutableArray array];
  NSString *group = nil;
  BOOL hasResolution = [_scanner optionNamed: @SANE_NAME_SCAN_RESOLUTION] != nil;
  BOOL pageSizeAdded;

  _rebuildScheduled = NO;

  _pageSize = [self pageSizePopUp];
  _modePopUp = nil;
  pageSizeAdded = (_pageSize == nil);

  /* Basic rows in the order of SCBasicOptionNames, not the driver's order */
  for (NSString *name in basicNames)
    {
      SCOption *option = [_scanner optionNamed: name];
      SCOptionControl *c;

      /* The page size belongs right after what kind of original it is */
      if (!pageSizeAdded && ![name isEqualToString: SCScanIntentName])
        {
          [basicRows addObject: [SCFormRow rowWithLabel: @"Page Size:"
                                                control: _pageSize]];
          pageSizeAdded = YES;
        }
      if ([name isEqualToString: @SANE_NAME_SCAN_MODE] && [option isActive])
        {
          _modePopUp = [self modePopUp: option];
          [basicRows addObject: [SCFormRow rowWithLabel:
                                   [[option title] stringByAppendingString: @":"]
                                                control: _modePopUp]];
          continue;
        }

      /* Separate x/y resolutions only matter when there is no common one */
      if (hasResolution && ([name isEqualToString: @SANE_NAME_SCAN_X_RESOLUTION]
                            || [name isEqualToString: @SANE_NAME_SCAN_Y_RESOLUTION]))
        {
          continue;
        }
      c = option ? [SCOptionControl controlForOption: option scanner: _scanner
                                       gammaSettings: _gammaSettings] : nil;
      if (c != nil)
        {
          if ([name isEqualToString: SCScanIntentName])
            {
              [c setLabel: @"Document type:"];
            }
          [c setDelegate: self];
          [controls addObject: c];
          [basicRows addObject: [c row]];
        }
    }

  _invert = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [_invert setButtonType: NSSwitchButton];
  [_invert setTitle: @"Invert colors"];
  [_invert setToolTip: @"Turns negatives into positives and white text on black into black on white."];
  [_invert setState: [[NSUserDefaults standardUserDefaults] boolForKey: SCInvertColorsKey]
             ? NSOnState : NSOffState];
  [_invert setTarget: self];
  [_invert setAction: @selector(invertChanged:)];
  [basicRows addObject: [SCFormRow rowWithLabel: @"" control: _invert]];

  _threshold = [[NSSlider alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [_threshold setMinValue: 1];
  [_threshold setMaxValue: 254];
  [_threshold setDoubleValue: [[NSUserDefaults standardUserDefaults]
                                integerForKey: SCThresholdKey]];
  [_threshold setToolTip: @"Move right if thin lines get lost, left if the paper turns gray or spotty."];
  /* Continuous, so the preview shows the effect while dragging */
  [_threshold setContinuous: YES];
  [_threshold setTarget: self];
  [_threshold setAction: @selector(thresholdChanged:)];
  if ([self usesOwnBlackAndWhite])
    {
      [basicRows addObject: [SCFormRow rowWithLabel: @"Threshold:" control: _threshold]];
    }

  _recognizeText = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [_recognizeText setButtonType: NSSwitchButton];
  [_recognizeText setTitle: @"Searchable text (OCR)"];
  [_recognizeText setState: [[NSUserDefaults standardUserDefaults]
                              boolForKey: SCRecognizeTextKey] ? NSOnState : NSOffState];
  [_recognizeText setTarget: self];
  [_recognizeText setAction: @selector(recognizeTextChanged:)];
  [basicRows addObject: [SCFormRow rowWithLabel: @"" control: _recognizeText]];
  [self updateRecognizeText];

  for (SCOption *option in [_scanner options])
    {
      SCOptionControl *c;

      if ([basicNames containsObject: [option name]]
          || [hidden containsObject: [option name]])
        {
          continue;
        }
      c = [SCOptionControl controlForOption: option scanner: _scanner
                              gammaSettings: _gammaSettings];
      if (c == nil)
        {
          continue;
        }
      if (![[option groupTitle] isEqualToString: group])
        {
          group = [option groupTitle];
          if ([group length] > 0)
            {
              [advancedRows addObject: [SCFormRow headingWithTitle: group]];
            }
        }
      [c setDelegate: self];
      [controls addObject: c];
      [advancedRows addObject: [c row]];
    }

  _controls = controls;
  [self sizeForm: _basicForm inScroll: _basicScroll];
  [self sizeForm: _advancedForm inScroll: _advancedScroll];
  [_basicForm setRows: basicRows];
  [_advancedForm setRows: advancedRows];
  [self updatePageSizeSelection];
  [_preview setBedAspect: [self bedAspect]];
  [self updateButtons];
}

- (void) sizeForm: (SCFormView *)form inScroll: (NSScrollView *)scroll
{
  NSSize size = [scroll contentSize];

  /* Inset like a tab view's content, the labels must not touch the tab edge */
  [form setMargin: METRICS_SPACE_12];
  [form setFrame: NSMakeRect(0, 0, size.width, NSHeight([form frame]))];
}

- (void) formClipDidResize: (NSNotification *)n
{
  SCFormView *form = ([n object] == [_basicScroll contentView])
    ? _basicForm : _advancedForm;

  [self sizeForm: form inScroll: [form enclosingScrollView]];
  [form layoutRows];
}

- (void) previewClipDidResize: (NSNotification *)n
{
  [_preview updateSize];
}

- (void) optionControlDidChangeValue
{
  /* E.g. the source: the feeder has no bed, and no preview */
  [self updateButtons];
}

- (void) optionControlDidFail: (NSError *)error
{
  [self showError: error];
}

- (void) invertChanged: (id)sender
{
  [[NSUserDefaults standardUserDefaults] setBool: [_invert state] == NSOnState
                                          forKey: SCInvertColorsKey];
}

/* The driver's own line art mode, if it has one; it beats converting gray */
- (NSString *) nativeLineArtMode
{
  SCOption *mode = [_scanner optionNamed: @SANE_NAME_SCAN_MODE];

  for (id v in [mode listValues])
    {
      NSString *m = [v lowercaseString];

      if ([m rangeOfString: @"lineart"].location != NSNotFound
          || [m rangeOfString: @"binary"].location != NSNotFound
          || [m rangeOfString: @"black"].location != NSNotFound)
        {
          return v;
        }
    }
  return nil;
}

- (BOOL) usesOwnBlackAndWhite
{
  return _ownBlackAndWhite && [self nativeLineArtMode] == nil;
}

/* The driver's modes, plus Black and White made from gray when it has none */
- (NSPopUpButton *) modePopUp: (SCOption *)option
{
  NSPopUpButton *popup = [[NSPopUpButton alloc]
                           initWithFrame: NSMakeRect(0, 0, 100, METRICS_TEXT_INPUT_FIELD_HEIGHT)
                               pullsDown: NO];

  for (id v in [option listValues])
    {
      [popup addItemWithTitle: [v description]];
      [[popup lastItem] setRepresentedObject: v];
    }
  if ([self nativeLineArtMode] == nil && [[option listValues] containsObject: @"Gray"])
    {
      [popup addItemWithTitle: @"Black and White"];
    }
  if ([self usesOwnBlackAndWhite])
    {
      [popup selectItemWithTitle: @"Black and White"];
    }
  else
    {
      [popup selectItemWithTitle: [[option value] description]];
    }
  [popup setToolTip: [option help]];
  [popup setEnabled: [option isSettable]];
  [popup setTarget: self];
  [popup setAction: @selector(modeChanged:)];
  return popup;
}

- (void) modeChanged: (NSPopUpButton *)sender
{
  SCOption *option = [_scanner optionNamed: @SANE_NAME_SCAN_MODE];
  id value = [[sender selectedItem] representedObject];
  NSError *error = nil;

  /* Black and white is scanned in gray and converted with the threshold */
  _ownBlackAndWhite = (value == nil);
  if (value == nil)
    {
      value = @"Gray";
    }
  if (![[option value] isEqual: value]
      && ![_scanner setValue: value forOption: option error: &error])
    {
      [self showError: error];
    }
  [self showPreviewImage];
  /* The threshold row comes and goes with the mode */
  [self optionsDidChange: nil];
}

- (void) thresholdChanged: (id)sender
{
  [[NSUserDefaults standardUserDefaults] setInteger: (NSInteger)[_threshold doubleValue]
                                             forKey: SCThresholdKey];
  [self showPreviewImage];
}

- (void) recognizeTextChanged: (id)sender
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSMutableArray *offer = [NSMutableArray array];

  [d setBool: [_recognizeText state] == NSOnState forKey: SCRecognizeTextKey];
  if ([_recognizeText state] != NSOnState)
    {
      return;
    }
  [self recognizePagesIfNeeded];
  /* The moment OCR is wanted is the moment to mention a missing language */
  for (NSString *identifier in [SCTextRecognizer missingUserLanguages])
    {
      if (![[d arrayForKey: SCDeclinedLanguagesKey]
             containsObject: [SCTextRecognizer codeForLanguage: identifier]])
        {
          [offer addObject: identifier];
        }
    }
  if ([offer count] > 0)
    {
      [self offerTextRecognitionForLanguages: offer];
    }
}

/* Offered only where it can work: with tesseract, and when a PDF is made */
- (void) updateRecognizeText
{
  BOOL available = [SCTextRecognizer isAvailable];
  BOOL pdf = [SCPreferences fileFormat] == SCFileFormatPDF;

  [_recognizeText setEnabled: available && pdf && _mode == SCScanModeIdle];
  if (!available)
    {
      [_recognizeText setToolTip: @"Needs the tesseract text recognition program "
                      @"and a language for it, which are not installed."];
    }
  else if (!pdf)
    {
      [_recognizeText setToolTip: @"Only for PDFs: choose PDF under \"Save as\"."];
    }
  else
    {
      NSArray *missing = [SCTextRecognizer missingUserLanguages];
      NSMutableArray *missingNames = [NSMutableArray array];
      NSString *tip = [NSString stringWithFormat:
        @"Recognizes the text (OCR) and hides it behind the page, so it can be "
        @"searched and copied. Languages: %@. Works best at 300 dpi.",
        [SCTextRecognizer userLanguages]];

      for (NSString *identifier in missing)
        {
          [missingNames addObject: [SCTextRecognizer displayNameForLanguage: identifier]];
        }
      if ([missing count] > 0)
        {
          tip = [tip stringByAppendingFormat:
            @" Not installed for text recognition: %@ (%@).",
            [missingNames componentsJoinedByString: @", "],
            [self tesseractPackagesForLanguages: missing]];
        }
      [_recognizeText setToolTip: tip];
    }
}

/* Package names differ per system; say what to install where we know it */
- (NSString *) tesseractPackagesForLanguages: (NSArray *)identifiers
{
  NSMutableArray *codes = [NSMutableArray array];
  NSArray *packages;

  for (NSString *identifier in identifiers)
    {
      [codes addObject: [SCTextRecognizer codeForLanguage: identifier]];
    }
  packages = [SCSoftwareInstaller packagesForLanguages: codes withTesseract: NO];
  if (packages == nil)
    {
      return [NSString stringWithFormat: @"language data for tesseract: %@",
                       [codes componentsJoinedByString: @", "]];
    }
  return [@"Scan > Install Text Recognition, or packages "
           stringByAppendingString: [packages componentsJoinedByString: @", "]];
}

/* "German text recognition", "German and French text recognition" */
- (NSString *) textRecognitionNameForLanguages: (NSArray *)identifiers
{
  NSMutableArray *names = [NSMutableArray array];

  for (NSString *identifier in identifiers)
    {
      [names addObject: [SCTextRecognizer displayNameForLanguage: identifier]];
    }
  if ([names count] == 0)
    {
      return @"text recognition";
    }
  if ([names count] == 1)
    {
      return [[names lastObject] stringByAppendingString: @" text recognition"];
    }
  return [NSString stringWithFormat: @"%@ and %@ text recognition",
                   [[names subarrayWithRange: NSMakeRange(0, [names count] - 1)]
                     componentsJoinedByString: @", "], [names lastObject]];
}

/* Missing languages, and tesseract itself, offered for installation */
- (void) offerTextRecognitionForLanguages: (NSArray *)identifiers
{
  BOOL withTesseract = [SCTextRecognizer tesseractPath] == nil;
  NSMutableArray *codes = [NSMutableArray array];
  NSString *what = [self textRecognitionNameForLanguages: identifiers];

  for (NSString *identifier in identifiers)
    {
      [codes addObject: [SCTextRecognizer codeForLanguage: identifier]];
    }
  [SCSoftwareInstaller offerLanguages: codes withTesseract: withTesseract what: what
                           completion: ^(BOOL installed) {
      NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
      NSMutableArray *declined = [[d arrayForKey: SCDeclinedLanguagesKey] mutableCopy];

      if (declined == nil)
        {
          declined = [NSMutableArray array];
        }
      [SCTextRecognizer reloadInstallation];
      [_pageList setNeedsDisplay: YES];
      /* Asked once: a language left out is not offered again by the checkbox */
      for (NSString *code in codes)
        {
          if (![[SCTextRecognizer installedLanguages] containsObject: code]
              && ![declined containsObject: code])
            {
              [declined addObject: code];
            }
        }
      [d setObject: declined forKey: SCDeclinedLanguagesKey];
      [self updateRecognizeText];
      if (installed)
        {
          [_status setStringValue: [NSString stringWithFormat: @"%@ is installed.",
                                             [what capitalizedString]]];
        }
    }];
}

- (void) offerTextRecognitionOnFirstLaunch
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSArray *missing = [SCTextRecognizer missingUserLanguages];

  if ([d boolForKey: SCOfferedTextRecognitionKey])
    {
      return;
    }
  /* Asked once; the Scan menu offers it any time later */
  [d setBool: YES forKey: SCOfferedTextRecognitionKey];
  if ([SCTextRecognizer tesseractPath] != nil && [missing count] == 0)
    {
      return;
    }
  [self offerTextRecognitionForLanguages: missing];
}

- (void) installTextRecognition: (id)sender
{
  [self offerTextRecognitionForLanguages: [SCTextRecognizer missingUserLanguages]];
}

- (void) applicationDidBecomeActive: (NSNotification *)n
{
  if ([SCTextRecognizer reloadInstallation])
    {
      [self updateRecognizeText];
      [_pageList setNeedsDisplay: YES];
    }
}

- (void) defaultsDidChange: (NSNotification *)n
{
  if ([_formatPopUp selectedTag] != [SCPreferences fileFormat])
    {
      [_formatPopUp selectItemWithTag: [SCPreferences fileFormat]];
    }
  [self updateRecognizeText];
}

- (void) formatChanged: (id)sender
{
  [[NSUserDefaults standardUserDefaults]
    setObject: [_formatPopUp titleOfSelectedItem] forKey: SCFileFormatKey];
  [self updateRecognizeText];
  /* Pages scanned before OCR applied get it now, so saving does not wait as long */
  [self recognizePagesIfNeeded];
}

- (void) recognizePagesIfNeeded
{
  if (![self recognizesText])
    {
      return;
    }
  for (SCImage *page in _pages)
    {
      if ([SCTextRecognizer stateForImage: page] == SCRecognitionNone)
        {
          [SCTextRecognizer startRecognizingImage: page];
        }
    }
}

- (void) setControlsEnabled: (BOOL)enabled inView: (NSView *)view
{
  if ([view isKindOfClass: [NSControl class]])
    {
      [(NSControl *)view setEnabled: enabled];
    }
  for (NSView *sub in [view subviews])
    {
      [self setControlsEnabled: enabled inView: sub];
    }
}

#pragma mark Device settings

- (void) restoreDeviceSettings
{
  NSDictionary *all = [[NSUserDefaults standardUserDefaults]
                        dictionaryForKey: SCDeviceSettingsKey];
  NSString *identifier = [[_scanner device] persistentIdentifier];
  NSDictionary *mine = nil;

  /* Keys written before identifiers were stable still name the same scanner */
  for (NSString *key in all)
    {
      if ([SCPersistentDeviceIdentifier(key) isEqualToString: identifier])
        {
          mine = [all objectForKey: key];
          if ([key isEqualToString: identifier])
            {
              break;
            }
        }
    }

  if ([mine isKindOfClass: [NSDictionary class]])
    {
      NSDictionary *gamma = [mine objectForKey: @"Gamma"];

      [_scanner restoreValues: [mine objectForKey: @"Options"]];
      if ([gamma isKindOfClass: [NSDictionary class]])
        {
          [_gammaSettings addEntriesFromDictionary: gamma];
        }
      _ownBlackAndWhite = [[mine objectForKey: @"BlackAndWhite"] boolValue];
      [self restoreSelections: [mine objectForKey: @"Selections"]];
    }
  [self chooseAutomaticIntent];
}

/* The areas to scan, so a page size like A4 is still chosen next time */
- (NSArray *) savedSelections
{
  NSMutableArray *list = [NSMutableArray array];

  for (NSValue *v in [_preview selections])
    {
      [list addObject: NSStringFromRect([v rectValue])];
    }
  return list;
}

- (void) restoreSelections: (NSArray *)list
{
  NSMutableArray *selections = [NSMutableArray array];

  if (![list isKindOfClass: [NSArray class]])
    {
      return;
    }
  for (NSString *s in list)
    {
      NSRect r = [s isKindOfClass: [NSString class]] ? NSRectFromString(s) : NSZeroRect;

      /* Fractions of the bed; anything else was not written by this app */
      if (!NSIsEmptyRect(r)
          && NSContainsRect(NSInsetRect(NSMakeRect(0, 0, 1, 1), -0.001, -0.001), r))
        {
          [selections addObject: [NSValue valueWithRect: r]];
        }
    }
  [_preview setSelections: selections];
}

/*
 * airscan starts with "*unset*", which sends the scanner no intent at all.
 * Auto leaves the choice to the scanner too, but is a real choice the menu
 * can show, so the menu never has to offer "*unset*".
 */
- (void) chooseAutomaticIntent
{
  SCOption *intent = [_scanner optionNamed: SCScanIntentName];

  if ([[intent value] isEqual: @"*unset*"] && [intent isSettable]
      && [[intent listValues] containsObject: @"Auto"])
    {
      [_scanner setValue: @"Auto" forOption: intent error: NULL];
    }
}

- (void) saveDeviceSettings
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *all = [[d dictionaryForKey: SCDeviceSettingsKey] mutableCopy];

  if (_mode != SCScanModeIdle)
    {
      /* Mid-preview the values are the temporary preview ones */
      return;
    }
  if (all == nil)
    {
      all = [NSMutableDictionary dictionary];
    }
  for (NSString *key in [all allKeys])
    {
      if ([SCPersistentDeviceIdentifier(key)
            isEqualToString: [[_scanner device] persistentIdentifier]])
        {
          [all removeObjectForKey: key];
        }
    }
  [all setObject: @{@"Options": [_scanner savedValues], @"Gamma": _gammaSettings,
                     @"BlackAndWhite": @(_ownBlackAndWhite),
                     @"Selections": [self savedSelections]}
          forKey: [[_scanner device] persistentIdentifier]];
  [d setObject: all forKey: SCDeviceSettingsKey];
}

#pragma mark Selections

- (void) previewViewSelectionsDidChange: (SCPreviewView *)view
{
  [self updatePageSizeSelection];
  [self updateButtons];
}

- (void) updatePageSizeSelection
{
  NSInteger active = [_preview activeSelection];
  NSSize bed = [_scanner scanAreaSizeInMillimeters];
  NSRect r;
  NSInteger i;

  [_pageSize selectItemAtIndex: 0];
  if (_pageSize == nil || active < 0 || bed.width <= 0)
    {
      return;
    }
  r = [[[_preview selections] objectAtIndex: active] rectValue];
  for (i = 1; i < [_pageSize numberOfItems]; i++)
    {
      NSSize s = [[[_pageSize itemAtIndex: i] representedObject] sizeValue];

      if (NSMinX(r) == 0 && NSMinY(r) == 0
          && fabs(NSWidth(r) * bed.width - MIN(s.width, bed.width)) < 0.5
          && fabs(NSHeight(r) * bed.height - MIN(s.height, bed.height)) < 0.5)
        {
          [_pageSize selectItemAtIndex: i];
          return;
        }
    }
}

- (void) pageSizeChanged: (NSPopUpButton *)sender
{
  NSSize bed = [_scanner scanAreaSizeInMillimeters];
  NSSize s;

  if ([sender indexOfSelectedItem] <= 0)
    {
      return;
    }
  s = [[[sender selectedItem] representedObject] sizeValue];
  /* Pages lie in the corner the scanner's origin is in */
  [_preview setActiveSelectionRect:
    NSMakeRect(0, 0, MIN(1, s.width / bed.width), MIN(1, s.height / bed.height))];
}

- (void) autoSelect: (id)sender
{
  NSRect r;

  if (_previewImage == nil)
    {
      [_status setStringValue: @"Make a preview first, so the document can be found."];
      return;
    }
  r = SCContentRectOfImage(_previewImage);
  if (NSIsEmptyRect(r))
    {
      [_status setStringValue: @"No document found on the preview."];
      return;
    }
  /* A small margin, the edge of the document must not be cut off */
  r = NSIntersectionRect(NSInsetRect(r, -0.01, -0.01), NSMakeRect(0, 0, 1, 1));
  [_preview setActiveSelectionRect: r];
  [_status setStringValue: @""];
}

- (void) removeAllSelections: (id)sender
{
  [_preview removeAllSelections];
}

- (void) zoomIn: (id)sender
{
  [_preview zoomIn];
}

- (void) zoomOut: (id)sender
{
  [_preview zoomOut];
}

- (void) zoomToFit: (id)sender
{
  [_preview zoomToFit];
}

#pragma mark Scanning

- (void) updateButtons
{
  BOOL idle = (_mode == SCScanModeIdle);
  BOOL feeder = [_scanner sourceFeedsMultiplePages];

  /* A preview from the feeder would use up the first sheet */
  [_previewButton setEnabled: idle && !feeder && [_scanner hasScanArea]];
  [_scanButton setEnabled: idle];
  [_cancelButton setEnabled: !idle];
  if ([_pageList showsBed] == feeder)
    {
      [_pageList setShowsBed: !feeder];
      [self showPageAtIndex: [_pageList selectedIndex]];
      [self showPageCountStatus];
    }
  [_saveButton setEnabled: [_pages count] > 0 && !_saving];
  [_discardButton setEnabled: [_pages count] > 0 && !_saving];
  [_saveButton setTitle: [_pages count] > 1
    ? [NSString stringWithFormat: @"Save %lu Pages", (unsigned long)[_pages count]]
    : @"Save"];
  [_progress setHidden: idle];
}

- (void) showError: (NSError *)error
{
  NSAlert *alert = [NSAlert alertWithError: error];

  [alert beginSheetModalForWindow: [self window] modalDelegate: nil
                   didEndSelector: NULL contextInfo: NULL];
}

- (void) startScanWithMode: (SCScanMode)mode multiplePages: (BOOL)multi
{
  _mode = mode;
  [_progress setDoubleValue: 0];
  [self updateButtons];
  [self setControlsEnabled: NO inView: _tabs];
  [_scanner startScanAllowingMultiplePages: multi];
}

- (void) setResolutionForPreview: (double)dpi
{
  for (NSString *name in @[@SANE_NAME_SCAN_RESOLUTION, @SANE_NAME_SCAN_X_RESOLUTION,
                           @SANE_NAME_SCAN_Y_RESOLUTION])
    {
      SCOption *option = [_scanner optionNamed: name];

      if (option != nil && [option isActive] && [option isSettable])
        {
          NSNumber *v = ([option type] == SCOptionTypeInt)
            ? [NSNumber numberWithInt: (int)[option constrainedNumber: dpi]]
            : [NSNumber numberWithDouble: [option constrainedNumber: dpi]];

          [_scanner setValue: v forOption: option error: NULL];
        }
    }
}

/* A value typed but not yet confirmed counts for this scan */
- (void) commitTypedValues
{
  [[self window] makeFirstResponder: [self window]];
}

- (void) preview: (id)sender
{
  SCOption *previewOption;
  NSError *error = nil;

  if (_mode != SCScanModeIdle || ![_scanner hasScanArea])
    {
      return;
    }
  [self commitTypedValues];
  [self showPageAtIndex: 0];
  _valuesBeforePreview = [_scanner savedValues];
  if (![_scanner setNormalizedScanArea: NSMakeRect(0, 0, 1, 1) error: &error])
    {
      [self showError: error];
      return;
    }
  /* Drivers with a preview option pick their own fast mode for it */
  previewOption = [_scanner optionNamed: @SANE_NAME_PREVIEW];
  if ([previewOption isActive] && [previewOption isSettable])
    {
      [_scanner setValue: @YES forOption: previewOption error: NULL];
    }
  [self setResolutionForPreview: [[NSUserDefaults standardUserDefaults]
                                   doubleForKey: SCPreviewResolutionKey]];
  [_status setStringValue: @"Making a preview..."];
  [self startScanWithMode: SCScanModePreview multiplePages: NO];
}

- (void) scan: (id)sender
{
  NSArray *selections = [_preview selections];

  if (_mode != SCScanModeIdle)
    {
      return;
    }
  [self commitTypedValues];
  _pendingAreas = [NSMutableArray array];
  if (![_scanner hasScanArea])
    {
      [_pendingAreas addObject: [NSNull null]];
    }
  else if ([_scanner sourceFeedsMultiplePages])
    {
      /*
       * Areas drawn on a flatbed preview mean nothing for sheets from the
       * feeder; only a chosen page size does
       */
      NSInteger active = [_preview activeSelection];

      [_pendingAreas addObject: ([_pageSize indexOfSelectedItem] > 0 && active >= 0)
        ? [selections objectAtIndex: active]
        : [NSValue valueWithRect: NSMakeRect(0, 0, 1, 1)]];
    }
  else if ([selections count] == 0)
    {
      [_pendingAreas addObject: [NSValue valueWithRect: NSMakeRect(0, 0, 1, 1)]];
    }
  else
    {
      [_pendingAreas addObjectsFromArray: selections];
    }
  [self scanNextArea];
}

- (void) scanNextArea
{
  id area = [_pendingAreas objectAtIndex: 0];
  NSError *error = nil;

  [_pendingAreas removeObjectAtIndex: 0];
  if ([area isKindOfClass: [NSValue class]]
      && ![_scanner setNormalizedScanArea: [area rectValue] error: &error])
    {
      _mode = SCScanModeIdle;
      [self updateButtons];
      [self rebuildOptions];
      [self showError: error];
      return;
    }
  /* Below 300 dpi tesseract misreads small print and accents */
  [_status setStringValue: ([self recognizesText] && [_scanner resolution] > 0
                            && [_scanner resolution] < 300)
    ? @"Scanning... Text recognition works best at 300 dpi."
    : @"Scanning..."];
  [self startScanWithMode: SCScanModeScan
            multiplePages: [_scanner sourceFeedsMultiplePages]];
}

/* YES when the pages of the next save get text recognition */
- (BOOL) recognizesText
{
  return [SCSaver recognizesTextForFormat: [SCPreferences fileFormat]];
}

/*
 * What the user asked to be done to every scan. Text recognition starts
 * right away, on the page before it becomes black and white, because
 * tesseract separates text from paper better than one threshold does.
 */
- (SCImage *) processedImage: (SCImage *)image
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  SCImage *page;

  if ([d boolForKey: SCInvertColorsKey])
    {
      image = [image invertedImage];
    }
  page = [self usesOwnBlackAndWhite]
    ? [image blackAndWhiteImageWithThreshold: [d integerForKey: SCThresholdKey]]
    : image;
  if ([self recognizesText])
    {
      [SCTextRecognizer startRecognizingImage: page fromImage: image];
    }
  return page;
}

- (void) didSave: (NSNotification *)n
{
  NSArray *paths = [[n userInfo] objectForKey: @"paths"];
  NSString *folder = [[[paths lastObject] stringByDeletingLastPathComponent]
                       stringByAbbreviatingWithTildeInPath];

  if ([paths count] == 0)
    {
      return;
    }
  _lastSavedPath = [paths lastObject];
  [_status setStringValue: ([paths count] == 1)
    ? [NSString stringWithFormat: @"Saved %@ in %@.",
                [_lastSavedPath lastPathComponent], folder]
    : [NSString stringWithFormat: @"Saved %lu files in %@.",
                (unsigned long)[paths count], folder]];
}

- (void) showSavedFile: (id)sender
{
  if (_lastSavedPath != nil)
    {
      [[NSWorkspace sharedWorkspace] selectFile: _lastSavedPath
                       inFileViewerRootedAtPath: @""];
    }
}

/* The preview shows black and white as it will be saved, to judge the threshold */
- (void) showPreviewImage
{
  SCImage *image;
  NSImage *ns;
  NSBitmapImageRep *rep;

  if (_previewImage == nil)
    {
      return;
    }
  image = [_previewImage eightBitImage];
  if ([self usesOwnBlackAndWhite])
    {
      image = [[image blackAndWhiteImageWithThreshold:
                        [[NSUserDefaults standardUserDefaults]
                          integerForKey: SCThresholdKey]] eightBitImage];
    }
  ns = [[NSImage alloc] initWithSize: NSMakeSize([image width], [image height])];
  rep = [SCImageWriter bitmapForImage: image];
  [rep setSize: NSMakeSize([image width], [image height])];
  [ns addRepresentation: rep];
  [_preview setImage: ns];
  [_pageList setBedImage: ns];
}

- (void) scanner: (SCScanner *)scanner progress: (double)fraction
{
  [_progress setDoubleValue: fraction];
}

- (void) scanner: (SCScanner *)scanner didScanImage: (SCImage *)image
{
  if (_mode == SCScanModePreview)
    {
      _previewImage = image;
      [self showPreviewImage];
      return;
    }
  /* Each page appears as soon as it is there, as it will be saved */
  [_pages addObject: [self processedImage: image]];
  [_pageList setPages: _pages];
  [self showPageAtIndex: [_pages count]];
  [self updateButtons];
  [_status setStringValue: [NSString stringWithFormat: @"Scanned page %lu.",
                                     (unsigned long)[_pages count]]];
}

- (void) scannerDidFinish: (SCScanner *)scanner cancelled: (BOOL)cancelled
                    error: (NSError *)error
{
  SCScanMode mode = _mode;

  if (mode == SCScanModePreview)
    {
      SCOption *previewOption = [_scanner optionNamed: @SANE_NAME_PREVIEW];

      if ([previewOption isActive] && [previewOption isSettable])
        {
          [_scanner setValue: @NO forOption: previewOption error: NULL];
        }
      [_scanner restoreValues: _valuesBeforePreview];
      _valuesBeforePreview = nil;
    }

  if (mode == SCScanModeScan && error == nil && !cancelled && [_pendingAreas count] > 0)
    {
      [self scanNextArea];
      return;
    }

  _mode = SCScanModeIdle;
  [self updateButtons];
  /* Rebuilt rather than re-enabled, which would also enable options the driver locks */
  [self rebuildOptions];
  if (cancelled)
    {
      [_status setStringValue: @"Cancelled."];
      return;
    }
  if (error != nil)
    {
      [_status setStringValue: @""];
      [self showError: error];
      return;
    }
  if (mode == SCScanModePreview)
    {
      [self showPageAtIndex: 0];
      [_status setStringValue: @"Drag over the preview to choose what to scan."];
      return;
    }
  [self showPageCountStatus];
}

#pragma mark Pages

- (void) showPageCountStatus
{
  NSUInteger n = [_pages count];

  if (n == 0 && [_scanner sourceFeedsMultiplePages])
    {
      [_status setStringValue: @"Put the pages into the document feeder, then choose Scan."];
      return;
    }
  [_status setStringValue: n == 0 ? @"" : [NSString stringWithFormat:
    @"%lu %@ to save. Scan more, or choose Save.", (unsigned long)n,
    n == 1 ? @"page" : @"pages"]];
}

/* 0 shows the scanner bed for choosing the area, the others a scanned page */
- (void) showPageAtIndex: (NSInteger)index
{
  BOOL bed = (index <= 0 || index > (NSInteger)[_pages count]);
  BOOL feeder = [_scanner sourceFeedsMultiplePages];

  /* The feeder has no bed to show: its last page, or an empty page instead */
  if (bed && feeder)
    {
      if ([_pages count] > 0)
        {
          index = [_pages count];
          bed = NO;
        }
      else
        {
          [_pageList setSelectedIndex: -1];
          [_previewScroll setHidden: YES];
          [_pageImageView setImage: nil];
          [_pageView setHidden: NO];
          return;
        }
    }
  [_pageList setSelectedIndex: bed ? 0 : index];
  [_previewScroll setHidden: !bed];
  [_pageView setHidden: bed];
  if (!bed)
    {
      SCImage *page = [_pages objectAtIndex: index - 1];
      NSImage *ns = [[NSImage alloc] initWithSize:
                       NSMakeSize([page width], [page height])];
      NSBitmapImageRep *rep = [SCImageWriter bitmapForImage: [page eightBitImage]];

      /* In pixels: the physical size would make 600 dpi scans tiny */
      [rep setSize: NSMakeSize([page width], [page height])];
      [ns addRepresentation: rep];
      [_pageImageView setImage: ns];
    }
}

- (void) pageList: (SCPageListView *)list didSelectIndex: (NSInteger)index
{
  [self showPageAtIndex: index];
}

- (NSString *) pageList: (SCPageListView *)list noteForPage: (SCImage *)page
{
  switch ([SCTextRecognizer stateForImage: page])
    {
      case SCRecognitionPending: return @"Reading text...";
      case SCRecognitionDone:    return @"Text recognized";
      case SCRecognitionFailed:  return @"Text not recognized";
      default:                   return nil;
    }
}

- (void) recognitionDidFinish: (NSNotification *)n
{
  [_pageList setNeedsDisplay: YES];
  if ([_pages indexOfObjectIdenticalTo: [n object]] != NSNotFound)
    {
      [self suggestLanguageForPage: [n object]];
    }
}

/*
 * Offers the language a page seems to be in when it is not installed: by
 * its script when that is not Latin, else by its most common words. Each
 * language once per session, and never again once declined.
 */
- (void) suggestLanguageForPage: (SCImage *)page
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSArray *installed = [SCTextRecognizer installedLanguages];
  NSString *script = [SCTextRecognizer scriptForImage: page];
  NSString *code = nil;
  NSString *name, *reason;
  BOOL scriptCovered = NO;

  if (_suggestingLanguage)
    {
      return;
    }
  if (script != nil && ![script isEqualToString: @"Latin"])
    {
      for (NSString *c in installed)
        {
          scriptCovered = scriptCovered || [SCScriptForLanguage(c) isEqualToString: script];
        }
      code = scriptCovered ? nil : SCLanguageForScript(script);
    }
  else
    {
      NSArray *words = [SCTextRecognizer wordsForImage: page error: NULL];

      code = SCGuessLanguageFromWords([words valueForKey: @"text"]);
    }
  if (code == nil || [installed containsObject: code]
      || [_suggestedLanguages containsObject: code]
      || [[d arrayForKey: SCDeclinedLanguagesKey] containsObject: code])
    {
      return;
    }
  if (_suggestedLanguages == nil)
    {
      _suggestedLanguages = [NSMutableSet set];
    }
  [_suggestedLanguages addObject: code];

  name = [SCTextRecognizer displayNameForCode: code];
  reason = [NSString stringWithFormat:
    @"This page looks like %@ text, which is not recognized well yet. With "
    @"%@ text recognition installed, its words can be searched and copied "
    @"correctly.", name, name];
  _suggestingLanguage = YES;
  [SCSoftwareInstaller offerPackages: [SCSoftwareInstaller packagesForLanguages: @[code]
                                                                 withTesseract: NO]
                                what: [NSString stringWithFormat: @"%@ text recognition", name]
                              reason: reason
                          completion: ^(BOOL installed) {
      _suggestingLanguage = NO;
      if (installed)
        {
          [SCTextRecognizer reloadInstallation];
          [self updateRecognizeText];
          [_pageList setNeedsDisplay: YES];
        }
      else
        {
          NSMutableArray *declined = [[d arrayForKey: SCDeclinedLanguagesKey] mutableCopy];

          if (declined == nil)
            {
              declined = [NSMutableArray array];
            }
          [declined addObject: code];
          [d setObject: declined forKey: SCDeclinedLanguagesKey];
        }
    }];
}

- (void) pageListDeleteSelected: (SCPageListView *)list
{
  [self deletePage: nil];
}

- (void) deletePage: (id)sender
{
  NSInteger index = [_pageList selectedIndex];

  if (index <= 0 || index > (NSInteger)[_pages count] || _saving)
    {
      return;
    }
  [SCTextRecognizer forgetImages: @[[_pages objectAtIndex: index - 1]]];
  [_pages removeObjectAtIndex: index - 1];
  [_pageList setPages: _pages];
  [self showPageAtIndex: MIN(index, (NSInteger)[_pages count])];
  [self updateButtons];
  [self showPageCountStatus];
}

- (void) movePageBy: (NSInteger)delta
{
  NSInteger index = [_pageList selectedIndex];
  NSInteger target = index + delta;
  SCImage *page;

  if (index <= 0 || target <= 0 || target > (NSInteger)[_pages count] || _saving)
    {
      return;
    }
  page = [_pages objectAtIndex: index - 1];
  [_pages removeObjectAtIndex: index - 1];
  [_pages insertObject: page atIndex: target - 1];
  [_pageList setPages: _pages];
  [self showPageAtIndex: target];
}

- (void) movePageUp: (id)sender
{
  [self movePageBy: -1];
}

- (void) movePageDown: (id)sender
{
  [self movePageBy: 1];
}

- (void) savePages: (id)sender
{
  NSArray *pages = [_pages copy];
  SCFileFormat format = [SCPreferences fileFormat];

  if ([pages count] == 0 || _saving)
    {
      return;
    }
  _saving = YES;
  [self updateButtons];
  [_status setStringValue: [SCSaver recognizesTextForFormat: format]
    ? @"Saving, with the recognized text..." : @"Saving..."];
  [SCSaver saveImages: pages format: format
           completion: ^(NSArray *paths, NSError *error) {
      _saving = NO;
      if (paths == nil)
        {
          [self updateButtons];
          [self showPageCountStatus];
          [self showError: error];
          return;
        }
      /* Pages scanned while this was saving stay for the next save */
      [_pages removeObjectsInArray: pages];
      [SCTextRecognizer forgetImages: pages];
      [_pageList setPages: _pages];
      [self showPageAtIndex: 0];
      [self updateButtons];
      /* The status line itself is set by -didSave: */
    }];
}

- (void) discardPages: (id)sender
{
  if ([_pages count] == 0 || _saving)
    {
      return;
    }
  if (NSRunAlertPanel(@"Discard the scanned pages?",
                      @"%lu pages have not been saved and will be lost.",
                      @"Discard", @"Cancel", nil,
                      (unsigned long)[_pages count]) != NSAlertDefaultReturn)
    {
      return;
    }
  [SCTextRecognizer forgetImages: _pages];
  [_pages removeAllObjects];
  [_pageList setPages: _pages];
  [self showPageAtIndex: 0];
  [self updateButtons];
  [self showPageCountStatus];
}

- (BOOL) mayCloseWithCollectedPages
{
  NSInteger choice;

  if (_saving)
    {
      /* Closing would throw the pages away while they are being written */
      NSBeep();
      return NO;
    }
  if ([_pages count] == 0)
    {
      return YES;
    }
  choice = NSRunAlertPanel(@"Save the scanned pages?",
    @"%lu scanned pages have not been saved yet.", @"Save",
    @"Cancel", @"Discard", (unsigned long)[_pages count]);
  if (choice == NSAlertAlternateReturn)
    {
      return NO;
    }
  if (choice == NSAlertDefaultReturn)
    {
      /* Saving finishes asynchronously; the window stays until it is done */
      [self savePages: nil];
      return NO;
    }
  [SCTextRecognizer forgetImages: _pages];
  [_pages removeAllObjects];
  return YES;
}

- (void) cancelScan: (id)sender
{
  if (_mode != SCScanModeIdle)
    {
      [_pendingAreas removeAllObjects];
      [_status setStringValue: @"Cancelling..."];
      [_scanner cancel];
    }
}

- (BOOL) windowShouldClose: (id)sender
{
  /* The handle cannot close under a running scan */
  return _mode == SCScanModeIdle && [self mayCloseWithCollectedPages];
}

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
  SEL a = [item action];

  if (a == @selector(preview:))
    {
      return [_previewButton isEnabled];
    }
  if (a == @selector(scan:))
    {
      return [_scanButton isEnabled];
    }
  if (a == @selector(installTextRecognition:))
    {
      return [SCTextRecognizer tesseractPath] == nil
        || [[SCTextRecognizer missingUserLanguages] count] > 0;
    }
  if (a == @selector(showSavedFile:))
    {
      return _lastSavedPath != nil;
    }
  if (a == @selector(savePages:))
    {
      return [_saveButton isEnabled];
    }
  if (a == @selector(deletePage:))
    {
      return [_pageList selectedIndex] > 0 && !_saving;
    }
  if (a == @selector(movePageUp:))
    {
      return [_pageList selectedIndex] > 1 && !_saving;
    }
  if (a == @selector(movePageDown:))
    {
      return [_pageList selectedIndex] > 0
        && [_pageList selectedIndex] < (NSInteger)[_pages count] && !_saving;
    }
  if (a == @selector(cancelScan:))
    {
      return _mode != SCScanModeIdle;
    }
  if (a == @selector(autoSelect:))
    {
      return _previewImage != nil && _mode == SCScanModeIdle;
    }
  if (a == @selector(removeAllSelections:))
    {
      return [[_preview selections] count] > 0 && _mode == SCScanModeIdle;
    }
  return YES;
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGDetailViewController.h"
#import "AGApp.h"
#import "AGAuthor.h"
#import "AGCategoryNames.h"
#import "AGLicenseFormatter.h"
#import "AGImageCache.h"
#import "AGInstaller.h"
#import "AGInstallButton.h"
#import "AGScreenshotView.h"
#import "AGPlaceholderIcon.h"
#import "AGColors.h"
#import "AppearanceMetrics.h"

static const CGFloat kAGDetailSideMargin = 32.0;
static const CGFloat kAGDetailMaxContentWidth = 760.0;
static const CGFloat kAGDetailIconSide = 128.0;
static const CGFloat kAGDetailHeaderGap = 24.0;
static const CGFloat kAGDetailKeyColumnWidth = 140.0;
static const CGFloat kAGDetailRowHeight = 20.0;
static const CGFloat kAGDetailSectionGap = 24.0;
static const CGFloat kAGDetailScreenshotGap = 32.0;
static const CGFloat kAGDetailLineHeightFactor = 1.3;
/* The brief asks for 4 points between the name and the author line; the
   metrics header has no constant that small. */
static const CGFloat kAGDetailTightGap = 4.0;

#pragma mark - Link button

/* A borderless button that looks like a web link and opens its URL. One
   class serves the author names, the license, the source and download rows
   and the catalog page link, so every link on the page behaves the same. */
@interface AGLinkButton : NSButton
@property (nonatomic, strong) NSURL *url;
- (instancetype)initWithTitle:(NSString *)title url:(NSURL *)url font:(NSFont *)font;
@end

@implementation AGLinkButton

- (instancetype)initWithTitle:(NSString *)title url:(NSURL *)url font:(NSFont *)font
{
  self = [super initWithFrame:NSZeroRect];
  if (self != nil)
    {
      _url = url;
      [self setBordered:NO];
      [self setBezelStyle:NSRegularSquareBezelStyle];
      [[self cell] setHighlightsBy:NSContentsCellMask];
      [self setImagePosition:NSNoImage];
      [self setAlignment:NSLeftTextAlignment];
      NSDictionary *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : AGAccentColor(),
      };
      [self setAttributedTitle:[[NSAttributedString alloc] initWithString:title
                                                                 attributes:attributes]];
      [self setTarget:self];
      [self setAction:@selector(openLink:)];
      [self setToolTip:[url absoluteString]];
      [self sizeToFit];
    }
  return self;
}

- (void)openLink:(id)sender
{
  (void)sender;
  [[NSWorkspace sharedWorkspace] openURL:_url];
}

- (void)resetCursorRects
{
  [self addCursorRect:[self bounds] cursor:[NSCursor pointingHandCursor]];
}

@end

#pragma mark - Content view

@class AGDetailContentView;

@protocol AGDetailContentViewLayoutOwner <NSObject>
- (void)layoutDetailContentView:(AGDetailContentView *)view;
@end

/* Flipped so the page reads top to bottom in code; the controller lays it
   out again whenever the scroll view hands it a new width. */
@interface AGDetailContentView : NSView
@property (nonatomic, weak) id<AGDetailContentViewLayoutOwner> layoutOwner;
@end

@implementation AGDetailContentView

- (BOOL)isFlipped
{
  return YES;
}

- (void)setFrame:(NSRect)frame
{
  BOOL widthChanged = (NSWidth(frame) != NSWidth([self frame]));
  [super setFrame:frame];
  if (widthChanged)
    [_layoutOwner layoutDetailContentView:self];
}

- (void)setFrameSize:(NSSize)size
{
  BOOL widthChanged = (size.width != NSWidth([self frame]));
  [super setFrameSize:size];
  if (widthChanged)
    [_layoutOwner layoutDetailContentView:self];
}

@end

#pragma mark - Controller

@interface AGDetailViewController () <AGDetailContentViewLayoutOwner>
@end

@implementation AGDetailViewController
{
  AGImageCache *_imageCache;
  AGInstaller *_installer;
  AGDetailContentView *_contentView;
  BOOL _layingOut;

  NSImageView *_iconView;
  NSTextField *_nameLabel;
  NSArray<NSView *> *_authorViews;      /* AGLinkButton or NSTextField, comma labels between */
  NSArray<NSView *> *_metaViews;        /* category label, separator, license label or link */
  AGInstallButton *_installButton;
  NSButton *_removeButton;
  AGLinkButton *_catalogPageButton;
  AGScreenshotView *_screenshotView;
  NSTextField *_descriptionHeading;
  NSTextView *_descriptionView;
  NSTextField *_informationHeading;
  NSArray<NSArray<NSView *> *> *_informationRows; /* {key label, value view} */
}

@synthesize app = _app;
@synthesize pageTitle = _pageTitle;

- (instancetype)initWithApp:(AGApp *)app
                 imageCache:(AGImageCache *)imageCache
                  installer:(AGInstaller *)installer
{
  self = [super initWithNibName:nil bundle:nil];
  if (self != nil)
    {
      _app = app;
      _imageCache = imageCache;
      _installer = installer;
      _pageTitle = [[app displayName] copy];
    }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_imageCache cancelRequestsForURL:[_app iconURL]];
  [_imageCache cancelRequestsForURL:[_app screenshotURL]];
}

#pragma mark - Building

- (NSTextField *)labelWithString:(NSString *)string font:(NSFont *)font color:(NSColor *)color
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
  [label setEditable:NO];
  [label setSelectable:NO];
  [label setBordered:NO];
  [label setBezeled:NO];
  [label setDrawsBackground:NO];
  [label setFont:font];
  [label setTextColor:color];
  [label setStringValue:(string != nil) ? string : @""];
  [[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
  [label sizeToFit];
  [_contentView addSubview:label];
  return label;
}

- (AGLinkButton *)linkWithTitle:(NSString *)title url:(NSURL *)url font:(NSFont *)font
{
  AGLinkButton *link = [[AGLinkButton alloc] initWithTitle:title url:url font:font];
  [_contentView addSubview:link];
  return link;
}

- (void)loadView
{
  NSRect frame = NSMakeRect(0.0, 0.0, 800.0, 600.0);
  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
  [scrollView setHasVerticalScroller:YES];
  [scrollView setHasHorizontalScroller:NO];
  [scrollView setAutohidesScrollers:YES];
  [scrollView setBorderType:NSNoBorder];
  [scrollView setBackgroundColor:[NSColor windowBackgroundColor]];
  [scrollView setDrawsBackground:YES];
  [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  _contentView = [[AGDetailContentView alloc] initWithFrame:[[scrollView contentView] bounds]];
  [_contentView setAutoresizingMask:NSViewWidthSizable];
  [self buildContent];
  _contentView.layoutOwner = self;
  [scrollView setDocumentView:_contentView];
  [self setView:scrollView];

  [self layoutDetailContentView:_contentView];
  [self requestImages];
}

- (void)buildContent
{
  AGApp *app = _app;
  NSColor *gray = [NSColor disabledControlTextColor];

  _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0.0, 0.0, kAGDetailIconSide, kAGDetailIconSide)];
  [_iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
  [_iconView setImageFrameStyle:NSImageFrameNone];
  [_iconView setEditable:NO];
  [_iconView setImage:[AGPlaceholderIcon placeholderIconForDisplayName:[app displayName]
                                                                   size:kAGDetailIconSide]];
  [_contentView addSubview:_iconView];

  _nameLabel = [self labelWithString:[app displayName]
                                font:[NSFont boldSystemFontOfSize:26.0]
                               color:[NSColor textColor]];

  NSMutableArray *authorViews = [NSMutableArray array];
  NSUInteger authorIndex = 0;
  for (AGAuthor *author in [app authors])
    {
      if (authorIndex > 0)
        [authorViews addObject:[self labelWithString:@", " font:METRICS_FONT_SYSTEM_REGULAR_13 color:gray]];
      if ([author url] != nil)
        [authorViews addObject:[self linkWithTitle:[author name] url:[author url]
                                              font:METRICS_FONT_SYSTEM_REGULAR_13]];
      else
        [authorViews addObject:[self labelWithString:[author name]
                                                font:METRICS_FONT_SYSTEM_REGULAR_13
                                               color:[NSColor textColor]]];
      authorIndex++;
    }
  _authorViews = authorViews;

  NSMutableArray *metaViews = [NSMutableArray array];
  NSString *category = [self firstVisibleCategoryDisplayName];
  if (category != nil)
    {
      [metaViews addObject:[self labelWithString:category font:METRICS_FONT_SYSTEM_REGULAR_11 color:gray]];
      [metaViews addObject:[self labelWithString:@"  ·  " font:METRICS_FONT_SYSTEM_REGULAR_11 color:gray]];
    }
  NSString *license = [AGLicenseFormatter displayStringForLicense:[app license]];
  NSURL *licenseURL = [AGLicenseFormatter licenseURLForLicense:[app license]];
  if (licenseURL != nil)
    [metaViews addObject:[self linkWithTitle:license url:licenseURL font:METRICS_FONT_SYSTEM_REGULAR_11]];
  else
    [metaViews addObject:[self labelWithString:license font:METRICS_FONT_SYSTEM_REGULAR_11 color:gray]];
  _metaViews = metaViews;

  NSSize buttonSize = [AGInstallButton sizeForStyle:AGInstallButtonStyleDetail];
  _installButton = [[AGInstallButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, buttonSize.width, buttonSize.height)
                                                    style:AGInstallButtonStyleDetail
                                                installer:_installer];
  [_installButton setApp:app];
  [_contentView addSubview:_installButton];

  _removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, buttonSize.width, buttonSize.height)];
  [_removeButton setBezelStyle:NSRoundedBezelStyle];
  [_removeButton setTitle:NSLocalizedString(@"Remove", @"")];
  [_removeButton setFont:METRICS_FONT_SYSTEM_REGULAR_13];
  [_removeButton setTarget:self];
  [_removeButton setAction:@selector(removeClicked:)];
  [_contentView addSubview:_removeButton];

  _catalogPageButton = [self linkWithTitle:NSLocalizedString(@"View on appimage.github.io", @"")
                                       url:[app catalogPageURL]
                                      font:METRICS_FONT_SYSTEM_REGULAR_13];

  if ([app screenshotURL] != nil)
    {
      _screenshotView = [[AGScreenshotView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 225.0)];
      [_contentView addSubview:_screenshotView];
    }

  _descriptionHeading = [self labelWithString:NSLocalizedString(@"Description", @"")
                                         font:[NSFont boldSystemFontOfSize:15.0]
                                        color:[NSColor textColor]];
  _descriptionView = [self buildDescriptionView];

  _informationHeading = [self labelWithString:NSLocalizedString(@"Information", @"")
                                         font:[NSFont boldSystemFontOfSize:15.0]
                                        color:[NSColor textColor]];
  _informationRows = [self buildInformationRows];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(installedSetDidChange:)
                                               name:AGInstallerInstalledSetDidChangeNotification
                                             object:nil];
  [self updateRemoveButton];
}

- (NSString *)firstVisibleCategoryDisplayName
{
  for (NSString *raw in [_app categories])
    {
      if (![AGCategoryNames isHiddenCategory:raw])
        return [AGCategoryNames displayNameForCategory:raw];
    }
  return nil;
}

- (NSString *)visibleCategoryDisplayNames
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *raw in [_app categories])
    {
      if (![AGCategoryNames isHiddenCategory:raw])
        [names addObject:[AGCategoryNames displayNameForCategory:raw]];
    }
  return ([names count] > 0) ? [names componentsJoinedByString:@", "] : nil;
}

- (NSTextView *)buildDescriptionView
{
  NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 100.0)];
  [textView setEditable:NO];
  [textView setSelectable:YES];
  [textView setDrawsBackground:NO];
  [textView setRichText:NO];
  [textView setHorizontallyResizable:NO];
  [textView setVerticallyResizable:NO];
  [textView setTextContainerInset:NSZeroSize];
  [[textView textContainer] setLineFragmentPadding:0.0];
  [[textView textContainer] setWidthTracksTextView:YES];

  NSString *text = [_app descriptionText];
  NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
  [paragraph setLineHeightMultiple:kAGDetailLineHeightFactor];
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  [attributes setObject:paragraph forKey:NSParagraphStyleAttributeName];
  if (text != nil)
    {
      [attributes setObject:METRICS_FONT_SYSTEM_REGULAR_13 forKey:NSFontAttributeName];
      [attributes setObject:[NSColor textColor] forKey:NSForegroundColorAttributeName];
    }
  else
    {
      text = NSLocalizedString(@"The publisher did not provide a description.", @"");
      NSFont *italic = [[NSFontManager sharedFontManager]
          convertFont:METRICS_FONT_SYSTEM_REGULAR_13 toHaveTrait:NSItalicFontMask];
      [attributes setObject:italic forKey:NSFontAttributeName];
      [attributes setObject:[NSColor disabledControlTextColor] forKey:NSForegroundColorAttributeName];
    }
  [[textView textStorage] setAttributedString:
      [[NSAttributedString alloc] initWithString:text attributes:attributes]];
  [_contentView addSubview:textView];
  return textView;
}

- (NSArray<NSArray<NSView *> *> *)buildInformationRows
{
  AGApp *app = _app;
  NSMutableArray *rows = [NSMutableArray array];
  NSColor *gray = [NSColor disabledControlTextColor];
  NSFont *font = METRICS_FONT_SYSTEM_REGULAR_13;

  void (^addRow)(NSString *, NSView *) = ^(NSString *key, NSView *value) {
    if (value == nil)
      return;
    NSTextField *keyLabel = [self labelWithString:key font:font color:gray];
    [keyLabel setAlignment:NSRightTextAlignment];
    [rows addObject:@[ keyLabel, value ]];
  };
  NSView *(^text)(NSString *) = ^NSView *(NSString *value) {
    if (value == nil)
      return nil;
    return [self labelWithString:value font:font color:[NSColor textColor]];
  };

  NSMutableArray *authorNames = [NSMutableArray array];
  for (AGAuthor *author in [app authors])
    [authorNames addObject:[author name]];
  addRow(NSLocalizedString(@"Developer", @""),
         text(([authorNames count] > 0) ? [authorNames componentsJoinedByString:@", "] : nil));
  addRow(NSLocalizedString(@"Category", @""), text([self visibleCategoryDisplayNames]));
  addRow(NSLocalizedString(@"License", @""),
         text([AGLicenseFormatter displayStringForLicense:[app license]]));
  if ([app githubURL] != nil)
    addRow(NSLocalizedString(@"Source", @""),
           [self linkWithTitle:[app githubRepo] url:[app githubURL] font:font]);
  if ([app downloadPageURL] != nil && [[app downloadPageURL] host] != nil)
    addRow(NSLocalizedString(@"Download page", @""),
           [self linkWithTitle:[[app downloadPageURL] host] url:[app downloadPageURL] font:font]);
  if ([app selfContainedPresent])
    addRow(NSLocalizedString(@"Self-contained", @""),
           text([app selfContained] ? NSLocalizedString(@"Yes", @"") : NSLocalizedString(@"No", @"")));
  addRow(NSLocalizedString(@"Requires glibc", @""), text([app glibcRequired]));
  return rows;
}

#pragma mark - Images

- (void)requestImages
{
  AGApp *app = _app;
  __weak AGDetailViewController *weakSelf = self;
  if ([app iconURL] != nil)
    {
      [_imageCache imageForURL:[app iconURL]
              maximumPixelSize:AGImageCacheIconPixelSize
                    completion:^(NSImage *image, NSError *error) {
        (void)error;
        AGDetailViewController *strongSelf = weakSelf;
        if (strongSelf != nil && image != nil)
          [strongSelf->_iconView setImage:image];
      }];
    }
  if (_screenshotView != nil)
    {
      [_imageCache imageForURL:[app screenshotURL] completion:^(NSImage *image, NSError *error) {
        (void)error;
        AGDetailViewController *strongSelf = weakSelf;
        if (strongSelf == nil)
          return;
        if (image != nil)
          {
            [strongSelf->_screenshotView setImage:image];
            [strongSelf->_screenshotView setState:AGScreenshotStateLoaded];
          }
        else
          [strongSelf->_screenshotView setState:AGScreenshotStateFailed];
      }];
    }
}

#pragma mark - Removing

- (void)installedSetDidChange:(NSNotification *)note
{
  (void)note;
  [self updateRemoveButton];
  [self layoutDetailContentView:_contentView];
}

- (void)updateRemoveButton
{
  BOOL installed = ([_installer stateForApp:_app] == AGInstallStateInstalled);
  [_removeButton setHidden:!installed];
}

- (void)removeClicked:(id)sender
{
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:
      NSLocalizedString(@"Remove %@?", @""), [_app displayName]]];
  [alert setInformativeText:NSLocalizedString(@"The application file is deleted from your Applications folder.", @"")];
  [alert addButtonWithTitle:NSLocalizedString(@"Remove", @"")];
  [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
  if ([alert runModal] != NSAlertFirstButtonReturn)
    return;

  NSError *error = nil;
  if (![_installer removeApp:_app error:&error])
    {
      NSAlert *failure = [[NSAlert alloc] init];
      [failure setMessageText:NSLocalizedString(@"Could Not Remove the Application", @"")];
      [failure setInformativeText:[error localizedDescription]];
      [failure addButtonWithTitle:NSLocalizedString(@"OK", @"")];
      [failure runModal];
    }
}

#pragma mark - Layout

- (CGFloat)placeInlineViews:(NSArray<NSView *> *)views atX:(CGFloat)x y:(CGFloat)y maxX:(CGFloat)maxX
{
  CGFloat cursor = x;
  CGFloat rowHeight = 0.0;
  for (NSView *view in views)
    {
      NSSize size = [view frame].size;
      if (cursor + size.width > maxX && cursor > x)
        {
          cursor = x;
          y += rowHeight;
          rowHeight = 0.0;
        }
      CGFloat width = MIN(size.width, maxX - cursor);
      [view setFrame:NSMakeRect(cursor, y, width, size.height)];
      cursor += width;
      rowHeight = MAX(rowHeight, size.height);
    }
  return y + rowHeight;
}

- (CGFloat)fittedHeightOfDescriptionForWidth:(CGFloat)width
{
  [_descriptionView setFrameSize:NSMakeSize(width, NSHeight([_descriptionView frame]))];
  [[_descriptionView textContainer] setContainerSize:NSMakeSize(width, 1.0e7)];
  NSLayoutManager *layoutManager = [_descriptionView layoutManager];
  [layoutManager ensureLayoutForTextContainer:[_descriptionView textContainer]];
  NSRect used = [layoutManager usedRectForTextContainer:[_descriptionView textContainer]];
  return ceil(NSHeight(used));
}

- (void)layoutDetailContentView:(AGDetailContentView *)view
{
  if (_layingOut || view == nil)
    return;
  _layingOut = YES;

  CGFloat pageWidth = NSWidth([view frame]);
  CGFloat contentWidth = MIN(kAGDetailMaxContentWidth, pageWidth - 2.0 * kAGDetailSideMargin);
  if (contentWidth < 200.0)
    contentWidth = 200.0;
  CGFloat left = floor((pageWidth - contentWidth) / 2.0);
  CGFloat right = left + contentWidth;
  CGFloat y = kAGDetailSideMargin;

  [_iconView setFrame:NSMakeRect(left, y, kAGDetailIconSide, kAGDetailIconSide)];

  CGFloat textLeft = left + kAGDetailIconSide + kAGDetailHeaderGap;
  CGFloat textY = y;
  [_nameLabel setFrame:NSMakeRect(textLeft, textY, right - textLeft, NSHeight([_nameLabel frame]))];
  textY += NSHeight([_nameLabel frame]) + kAGDetailTightGap;
  if ([_authorViews count] > 0)
    textY = [self placeInlineViews:_authorViews atX:textLeft y:textY maxX:right] + kAGDetailTightGap;
  textY = [self placeInlineViews:_metaViews atX:textLeft y:textY maxX:right] + METRICS_SPACE_16;

  NSSize buttonSize = [_installButton frame].size;
  [_installButton setFrame:NSMakeRect(textLeft, textY, buttonSize.width, buttonSize.height)];
  CGFloat afterButton = textLeft + buttonSize.width + METRICS_SPACE_12;
  if (![_removeButton isHidden])
    {
      [_removeButton setFrame:NSMakeRect(afterButton, textY, NSWidth([_removeButton frame]), buttonSize.height)];
      afterButton += NSWidth([_removeButton frame]) + METRICS_SPACE_12;
    }
  NSSize linkSize = [_catalogPageButton frame].size;
  [_catalogPageButton setFrame:NSMakeRect(afterButton,
                                          textY + floor((buttonSize.height - linkSize.height) / 2.0),
                                          MIN(linkSize.width, MAX(0.0, right - afterButton)),
                                          linkSize.height)];
  textY += buttonSize.height;

  y = MAX(y + kAGDetailIconSide, textY);

  if (_screenshotView != nil)
    {
      y += kAGDetailScreenshotGap;
      CGFloat height = [AGScreenshotView heightForWidth:contentWidth];
      [_screenshotView setFrame:NSMakeRect(left, y, contentWidth, height)];
      y += height;
    }

  y += kAGDetailSectionGap;
  [_descriptionHeading setFrame:NSMakeRect(left, y, contentWidth, NSHeight([_descriptionHeading frame]))];
  y += NSHeight([_descriptionHeading frame]) + METRICS_SPACE_8;
  CGFloat descriptionHeight = [self fittedHeightOfDescriptionForWidth:contentWidth];
  [_descriptionView setFrame:NSMakeRect(left, y, contentWidth, descriptionHeight)];
  y += descriptionHeight;

  y += kAGDetailSectionGap;
  [_informationHeading setFrame:NSMakeRect(left, y, contentWidth, NSHeight([_informationHeading frame]))];
  y += NSHeight([_informationHeading frame]) + METRICS_SPACE_8;
  CGFloat valueLeft = left + kAGDetailKeyColumnWidth + METRICS_SPACE_12;
  for (NSArray<NSView *> *row in _informationRows)
    {
      NSView *key = [row objectAtIndex:0];
      NSView *value = [row objectAtIndex:1];
      CGFloat keyHeight = NSHeight([key frame]);
      CGFloat valueHeight = NSHeight([value frame]);
      [key setFrame:NSMakeRect(left, y + floor((kAGDetailRowHeight - keyHeight) / 2.0),
                               kAGDetailKeyColumnWidth, keyHeight)];
      [value setFrame:NSMakeRect(valueLeft, y + floor((kAGDetailRowHeight - valueHeight) / 2.0),
                                 MIN(NSWidth([value frame]), right - valueLeft), valueHeight)];
      y += kAGDetailRowHeight;
    }

  y += kAGDetailSideMargin;

  /* The scroll view only scrolls what the document claims; the visible
   * height is the floor so a short page still fills the clip view. */
  CGFloat visibleHeight = NSHeight([[view superview] bounds]);
  [view setFrameSize:NSMakeSize(pageWidth, MAX(y, visibleHeight))];
  [view setNeedsDisplay:YES];
  _layingOut = NO;
}

@end

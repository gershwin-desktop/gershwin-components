/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGMainWindowController.h"
#import "AGSidebarController.h"
#import "AGGridViewController.h"
#import "AGDetailViewController.h"
#import "AGStatusBannerController.h"
#import "AGPage.h"
#import "AGAppGridView.h"
#import "AGFeedLoader.h"
#import "AGImageCache.h"
#import "AGInstaller.h"
#import "AGCatalog.h"
#import "AGApp.h"
#import "AGSearchIndex.h"
#import "AGCategoryNames.h"
#import "AGDiscoverOrder.h"
#import "AGColors.h"
#import "AppearanceMetrics.h"

/* Not the first name this was saved under: windows saved at the old, wider
 * default would otherwise keep that width and the new default would never be
 * seen. */
static NSString *const kAGWindowFrameAutosaveName = @"AGMainWindowNarrow";
static NSString *const kAGShowToolkitCategoriesKey = @"AGShowToolkitCategories";

/* Three columns of cards: 24 + 3 * 200 + 2 * 16 + 24 points beside the
 * 200 point sidebar. */
static const CGFloat kAGInitialWidth = 920.0;
static const CGFloat kAGInitialHeight = 680.0;
static const CGFloat kAGMinimumWidth = 760.0;
static const CGFloat kAGMinimumHeight = 480.0;
static const CGFloat kAGSidebarWidth = 200.0;
static const CGFloat kAGTopBarHeight = 52.0;
static const CGFloat kAGSearchFieldWidth = 240.0;
/* An image-only button is a square, not the 100 points a titled button
   wants: the chevron is 16 points like every other glyph in the app, and
   the face around it is a little wider so the arrow is not crowded. */
static const CGFloat kAGBackGlyphSide = 16.0;
static const CGFloat kAGBackButtonSide = 24.0;

/* The back arrow is a bundled glyph like the sidebar ones, so it belongs
   to the same iconography and needs no theme image that may be absent. The
   button falls back to its titled face if it is missing, because the
   chevron is the only way back out of a detail page. */
static NSImage *AGBackArrowImage(void)
{
  static NSImage *arrow = nil;
  if (arrow == nil)
    {
      NSString *path = [[NSBundle mainBundle] pathForResource:@"back" ofType:@"tiff"];
      NSImage *loaded = [[NSImage alloc] initWithContentsOfFile:path];
      if (loaded != nil)
        {
          [loaded setSize:NSMakeSize(kAGBackGlyphSide, kAGBackGlyphSide)];
          arrow = loaded;
        }
    }
  return arrow;
}

#pragma mark - Field editor

/* Up and Down in the search field leave the field and move the focus into
   the grid, the way Build's catalog does; a single-line field has no
   cursor line to move anyway. */
@interface AGSearchFieldEditor : NSTextView
@property (nonatomic, weak) AGAppGridView *gridView;
@end

@implementation AGSearchFieldEditor

- (void)moveUp:(id)sender
{
  (void)sender;
  [_gridView exitSearchFieldIntoResultsWithDelta:-1];
}

- (void)moveDown:(id)sender
{
  (void)sender;
  [_gridView exitSearchFieldIntoResultsWithDelta:1];
}

/* Tab goes the same way: the key-view chain from a search field does not
 * reach a plain view under this AppKit and the text system never calls
 * -insertTab: on a field editor here, so the key itself is intercepted. */
- (void)keyDown:(NSEvent *)event
{
  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] == 1 && [characters characterAtIndex:0] == '\t'
      && ([event modifierFlags] & NSShiftKeyMask) == 0)
    {
      [_gridView exitSearchFieldIntoResultsWithDelta:1];
      return;
    }
  [super keyDown:event];
}

@end

#pragma mark - Top bar and page container

/* A subtle vertical gradient (lighter at the top, so it reads as a surface
   the window's frame continues into rather than a stripe painted on the
   content), with a one-point separator at the bottom edge. Same treatment
   as FMRackNew's FMBarView and Player's PlayerBarView. */
@interface AGTopBarView : NSView
@end

@implementation AGTopBarView

- (BOOL)isOpaque
{
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
  (void)dirtyRect;
  NSRect b = [self bounds];
  NSGradient *g = [[NSGradient alloc]
      initWithStartingColor:AGTopBarGradientBottomColor()
                endingColor:AGTopBarGradientTopColor()];
  [g drawInRect:b angle:90.0];

  [[NSColor gridColor] set];
  NSRectFill(NSMakeRect(0.0, 0.0, NSWidth(b), 1.0));
}

@end

/* Escape anywhere in the page area pops the navigation stack. The page views
   do not know about the stack, so the container turns the key into an
   action for the window controller. */
@interface AGPageContainerView : NSView
@property (nonatomic, weak) id escapeTarget;
@end

@implementation AGPageContainerView

/* A detail page has no view that takes the keyboard, so the container
 * holds it while one is shown; otherwise Escape would reach nothing. */
- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (void)keyDown:(NSEvent *)event
{
  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] == 1 && [characters characterAtIndex:0] == 0x1b
      && [_escapeTarget respondsToSelector:@selector(goBack:)])
    {
      [_escapeTarget performSelector:@selector(goBack:) withObject:self];
      return;
    }
  [super keyDown:event];
}

@end

#pragma mark - Error page

/* What the page area shows when the very first fetch failed and there is no
   cache behind it: the error and one Retry, and nothing else, because there
   is no catalog to draw a grid from. */
@interface AGCatalogErrorView : NSView
@property (nonatomic, copy) NSString *message;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
@end

@implementation AGCatalogErrorView
{
  NSTextField *_label;
  NSButton *_retryButton;
}

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _label = [[NSTextField alloc] initWithFrame:NSZeroRect];
      [_label setEditable:NO];
      [_label setSelectable:NO];
      [_label setBordered:NO];
      [_label setBezeled:NO];
      [_label setDrawsBackground:NO];
      [_label setAlignment:NSTextAlignmentCenter];
      [_label setFont:METRICS_FONT_SYSTEM_REGULAR_13];
      [_label setTextColor:[NSColor textColor]];
      [[_label cell] setLineBreakMode:NSLineBreakByWordWrapping];
      [self addSubview:_label];

      _retryButton = [[NSButton alloc] initWithFrame:NSZeroRect];
      [_retryButton setBezelStyle:NSRoundedBezelStyle];
      [_retryButton setTitle:NSLocalizedString(@"Retry", @"")];
      [_retryButton setFont:METRICS_FONT_SYSTEM_REGULAR_13];
      [self addSubview:_retryButton];

      [self layoutErrorView];
    }
  return self;
}

- (void)setMessage:(NSString *)message
{
  _message = [message copy];
  [self layoutErrorView];
  [self setNeedsDisplay:YES];
}

- (void)setTarget:(id)target
{
  _target = target;
  [_retryButton setTarget:target];
}

- (void)setAction:(SEL)action
{
  _action = action;
  [_retryButton setAction:action];
}

- (void)setFrame:(NSRect)frame
{
  BOOL widthChanged = (NSWidth(frame) != NSWidth([self frame]));
  [super setFrame:frame];
  if (widthChanged)
    [self layoutErrorView];
}

- (void)setFrameSize:(NSSize)size
{
  BOOL widthChanged = (size.width != NSWidth([self frame]));
  [super setFrameSize:size];
  if (widthChanged)
    [self layoutErrorView];
}

/* Both the message and the button are centered as one block, so the two
   relayout triggers above have to be enough on their own. */
- (void)layoutErrorView
{
  NSRect bounds = [self bounds];
  if (NSWidth(bounds) <= 0.0)
    return;

  CGFloat width = MIN(560.0, NSWidth(bounds) - 2.0 * METRICS_SPACE_24);
  if (width < 200.0)
    width = MAX(1.0, NSWidth(bounds) - 2.0 * METRICS_SPACE_12);

  NSString *text = (_message != nil) ? _message : @"";
  NSDictionary *attributes = @{ NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_13 };
  NSRect textRect = [text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                                       options:(NSStringDrawingUsesLineFragmentOrigin
                                                | NSStringDrawingUsesFontLeading)
                                    attributes:attributes];
  CGFloat textHeight = ceil(NSHeight(textRect));

  [_retryButton sizeToFit];
  NSRect buttonFrame = [_retryButton frame];
  CGFloat totalHeight = textHeight + METRICS_SPACE_12 + NSHeight(buttonFrame);
  CGFloat top = floor((NSHeight(bounds) - totalHeight) / 2.0);
  if (top < METRICS_SPACE_24)
    top = METRICS_SPACE_24;

  [_label setFrame:NSMakeRect(floor((NSWidth(bounds) - width) / 2.0), top,
                              width, textHeight)];
  [_label setStringValue:text];

  buttonFrame.origin.x = floor((NSWidth(bounds) - NSWidth(buttonFrame)) / 2.0);
  buttonFrame.origin.y = top + textHeight + METRICS_SPACE_12;
  [_retryButton setFrame:buttonFrame];
}

@end

/* The page protocol for that view: the window controller keeps pages on its
   stack, so the error has to be one of them rather than an extra subview. */
@interface AGCatalogErrorPage : NSViewController <AGPage>
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;
- (instancetype)initWithMessage:(NSString *)message;
@end

@implementation AGCatalogErrorPage
{
  AGCatalogErrorView *_errorView;
  NSString *_pendingMessage;
}

- (instancetype)initWithMessage:(NSString *)message
{
  self = [super initWithNibName:nil bundle:nil];
  if (self != nil)
    _pendingMessage = [message copy];
  return self;
}

- (void)loadView
{
  _errorView = [[AGCatalogErrorView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 800.0, 600.0)];
  [_errorView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [_errorView setMessage:_pendingMessage];
  /* The window controller hands over its target before the view exists, so
     the stored copy is applied here as well. */
  [_errorView setTarget:_target];
  [_errorView setAction:_action];
  [self setView:_errorView];
}

- (void)setTarget:(id)target
{
  _target = target;
  [_errorView setTarget:target];
}

- (void)setAction:(SEL)action
{
  _action = action;
  [_errorView setAction:action];
}

@end

#pragma mark - Controller

@interface AGMainWindowController () <NSWindowDelegate, NSSplitViewDelegate,
                                      AGGridViewControllerDelegate>
@end

@implementation AGMainWindowController
{
  AGFeedLoader *_feedLoader;
  AGImageCache *_imageCache;
  AGInstaller *_installer;
  AGCatalog *_catalog;
  AGSearchIndex *_searchIndex;

  AGSidebarController *_sidebar;
  AGStatusBannerController *_banner;
  BOOL _bannerVisible;
  NSSplitView *_splitView;
  NSView *_contentArea;
  AGTopBarView *_topBar;
  NSButton *_backButton;
  NSSearchField *_searchField;
  AGSearchFieldEditor *_searchFieldEditor;
  AGPageContainerView *_pageContainer;

  NSMutableArray<NSViewController<AGPage> *> *_navigationStack;
  AGGridViewController *_rootGridPage;
  /* The catalog in the order Discover shows it, shuffled once when the
     catalog arrives rather than on every repopulate. */
  NSArray<AGApp *> *_discoverApps;
  BOOL _hasCatalogOnce;
  BOOL _toolkitCategoriesShown;
}

- (instancetype)initWithFeedLoader:(AGFeedLoader *)feedLoader
                        imageCache:(AGImageCache *)imageCache
                         installer:(AGInstaller *)installer
{
  NSRect frame = NSMakeRect(0.0, 0.0, kAGInitialWidth, kAGInitialHeight);
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                           | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self = [super initWithWindow:window];
  if (self != nil)
    {
      _feedLoader = feedLoader;
      _imageCache = imageCache;
      _installer = installer;
      _navigationStack = [[NSMutableArray alloc] init];
      _toolkitCategoriesShown = [self showsToolkitCategories];

      [window setTitle:NSLocalizedString(@"AppGarden", @"")];
      [window setMinSize:NSMakeSize(kAGMinimumWidth, kAGMinimumHeight)];
      [window setReleasedWhenClosed:NO];
      [window setDelegate:self];
      [window center];
      [window setFrameAutosaveName:kAGWindowFrameAutosaveName];

      [self buildContent];
      [self showRootPage];

      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(userDefaultsDidChange:)
                                                   name:NSUserDefaultsDidChangeNotification
                                                 object:nil];
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(installedSetDidChange:)
                                                   name:AGInstallerInstalledSetDidChangeNotification
                                                 object:nil];
    }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Building

- (void)buildContent
{
  NSView *contentView = [[self window] contentView];
  NSRect bounds = [contentView bounds];

  _splitView = [[NSSplitView alloc] initWithFrame:bounds];
  [_splitView setVertical:YES];
  [_splitView setDividerStyle:NSSplitViewDividerStyleThin];
  [_splitView setDelegate:self];
  [_splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  _sidebar = [[AGSidebarController alloc] init];
  [_sidebar setTarget:self];
  [_sidebar setAction:@selector(sidebarSelectionChanged:)];
  NSView *sidebarView = [_sidebar view];
  [sidebarView setFrame:NSMakeRect(0.0, 0.0, kAGSidebarWidth, NSHeight(bounds))];
  [_splitView addSubview:sidebarView];

  _contentArea = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0,
                                                          NSWidth(bounds) - kAGSidebarWidth,
                                                          NSHeight(bounds))];
  [_contentArea setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [_splitView addSubview:_contentArea];
  [_splitView adjustSubviews];
  [contentView addSubview:_splitView];

  [self buildTopBar];

  _banner = [[AGStatusBannerController alloc] init];
  [_banner setTarget:self];
  [_banner setAction:@selector(reloadCatalog:)];

  _pageContainer = [[AGPageContainerView alloc] initWithFrame:NSZeroRect];
  [_pageContainer setEscapeTarget:self];
  [_pageContainer setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [_contentArea addSubview:_pageContainer];

  [self layoutContentArea];
}

- (void)buildTopBar
{
  NSRect areaBounds = [_contentArea bounds];
  _topBar = [[AGTopBarView alloc] initWithFrame:NSMakeRect(0.0, NSHeight(areaBounds) - kAGTopBarHeight,
                                                           NSWidth(areaBounds), kAGTopBarHeight)];
  [_topBar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
  [_contentArea addSubview:_topBar];

  CGFloat buttonY = floor((kAGTopBarHeight - kAGBackButtonSide) / 2.0);
  _backButton = [[NSButton alloc] initWithFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, buttonY,
                                                           kAGBackButtonSide, kAGBackButtonSide)];
  [_backButton setBezelStyle:NSRoundedBezelStyle];
  /* The arrow is the whole control, so nothing is drawn but the arrow. The
     title stays on the button for the tooltip and for the test and the
     menu item that name it "Back", and the font follows it for that. */
  NSImage *arrow = AGBackArrowImage();
  if (arrow != nil)
    {
      [_backButton setImage:arrow];
      [_backButton setImagePosition:NSImageOnly];
    }
  [_backButton setTitle:NSLocalizedString(@"Back", @"")];
  [_backButton setToolTip:NSLocalizedString(@"Back", @"")];
  [_backButton setFont:METRICS_FONT_SYSTEM_REGULAR_13];
  [_backButton setTarget:self];
  [_backButton setAction:@selector(goBack:)];
  /* A button in a bar is not in the Tab loop: the search field is, and
     Tab from there goes into the grid. */
  [_backButton setRefusesFirstResponder:YES];
  [_backButton setAutoresizingMask:NSViewMaxXMargin];
  [_topBar addSubview:_backButton];

  CGFloat fieldY = floor((kAGTopBarHeight - METRICS_TEXT_INPUT_FIELD_HEIGHT) / 2.0);
  NSRect fieldFrame = NSMakeRect(NSWidth(areaBounds) - METRICS_CONTENT_SIDE_MARGIN - kAGSearchFieldWidth,
                                 fieldY, kAGSearchFieldWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT);
  /* The Eau theme draws NSSearchField with its own magnifier and clear
   * button; without that theme hook a plain rounded text field is the
   * closest look, as Build's catalog does. */
  BOOL themeSearch = [NSSearchFieldCell instancesRespondToSelector:
      @selector(EAUsearchButtonRectForBounds:)];
  if (themeSearch)
    _searchField = [[NSSearchField alloc] initWithFrame:fieldFrame];
  else
    {
      NSTextField *field = [[NSTextField alloc] initWithFrame:fieldFrame];
      [field setBezeled:YES];
      [field setBezelStyle:NSTextFieldRoundedBezel];
      [field setEditable:YES];
      [field setSelectable:YES];
      _searchField = (NSSearchField *)field;
    }
  [[_searchField cell] setPlaceholderString:NSLocalizedString(@"Search", @"")];
  [_searchField setFont:METRICS_FONT_SYSTEM_REGULAR_13];
  [_searchField setTarget:self];
  [_searchField setAction:@selector(searchChanged:)];
  [_searchField setAutoresizingMask:NSViewMinXMargin];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(searchChanged:)
                                               name:NSControlTextDidChangeNotification
                                             object:_searchField];
  [_topBar addSubview:_searchField];
}

- (void)layoutContentArea
{
  NSRect bounds = [_contentArea bounds];
  CGFloat top = NSHeight(bounds) - kAGTopBarHeight;
  NSView *bannerView = [_banner view];
  if (_bannerVisible)
    {
      CGFloat bannerHeight = [AGStatusBannerController height];
      [bannerView setFrame:NSMakeRect(0.0, top - bannerHeight, NSWidth(bounds), bannerHeight)];
      [bannerView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
      if ([bannerView superview] == nil)
        [_contentArea addSubview:bannerView];
      top -= bannerHeight;
    }
  else if ([bannerView superview] != nil)
    [bannerView removeFromSuperview];

  [_pageContainer setFrame:NSMakeRect(0.0, 0.0, NSWidth(bounds), top)];
  NSView *pageView = [[_navigationStack lastObject] view];
  [pageView setFrame:[_pageContainer bounds]];
}

#pragma mark - NSSplitViewDelegate

/* The sidebar is fixed at 200 points: the design does not need a resizable
 * one and a fixed width keeps every page layout predictable. */
- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimum
               ofSubviewAt:(NSInteger)dividerIndex
{
  (void)splitView; (void)proposedMinimum; (void)dividerIndex;
  return kAGSidebarWidth;
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximum
               ofSubviewAt:(NSInteger)dividerIndex
{
  (void)splitView; (void)proposedMaximum; (void)dividerIndex;
  return kAGSidebarWidth;
}

- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize
{
  (void)oldSize;
  NSRect bounds = [splitView bounds];
  CGFloat divider = [splitView dividerThickness];
  [[_sidebar view] setFrame:NSMakeRect(0.0, 0.0, kAGSidebarWidth, NSHeight(bounds))];
  [_contentArea setFrame:NSMakeRect(kAGSidebarWidth + divider, 0.0,
                                    NSWidth(bounds) - kAGSidebarWidth - divider, NSHeight(bounds))];
  [self layoutContentArea];
}

#pragma mark - NSWindowDelegate

- (id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)client
{
  (void)sender;
  if (client != _searchField)
    return nil;
  if (_searchFieldEditor == nil)
    {
      _searchFieldEditor = [[AGSearchFieldEditor alloc] init];
      [_searchFieldEditor setFieldEditor:YES];
    }
  [_searchFieldEditor setGridView:[self currentGridView]];
  return _searchFieldEditor;
}

#pragma mark - Catalog

- (void)loadCatalog
{
  [self setLoading:YES];
  __weak AGMainWindowController *weakSelf = self;
  [_feedLoader loadWithCompletion:^(AGCatalog *catalog, BOOL fromCache, NSError *error) {
    [weakSelf catalogDidLoad:catalog fromCache:fromCache error:error];
  }];
}

- (void)reloadCatalog:(id)sender
{
  (void)sender;
  if ([_feedLoader isLoading])
    return;
  [self setLoading:YES];
  __weak AGMainWindowController *weakSelf = self;
  [_feedLoader reloadIgnoringCacheWithCompletion:^(AGCatalog *catalog, BOOL fromCache, NSError *error) {
    [weakSelf catalogDidLoad:catalog fromCache:fromCache error:error];
  }];
}

- (void)setLoading:(BOOL)loading
{
  /* Only the very first load shows the spinner: a reload with a catalog on
   * screen keeps the grid browsable until the new one arrives. */
  if (!_hasCatalogOnce)
    [_rootGridPage setLoading:loading];
}

- (void)catalogDidLoad:(AGCatalog *)catalog fromCache:(BOOL)fromCache error:(NSError *)error
{
  (void)fromCache;
  [self setLoading:NO];
  if (catalog != nil)
    {
      _catalog = catalog;
      /* Discover gets its order here, once per catalog: re-shuffling on
         every repopulate would move the cards under the user, throw away
         the scroll offset and drop the focused card. */
      _discoverApps = [AGDiscoverOrder shuffled:[catalog apps]];
      _searchIndex = [[AGSearchIndex alloc] initWithCatalog:catalog];
      _hasCatalogOnce = YES;
      _toolkitCategoriesShown = [self showsToolkitCategories];
      [_sidebar reloadWithCatalog:catalog showToolkitCategories:_toolkitCategoriesShown];
      [self showRootPage];
    }

  if (error == nil)
    [self hideBanner];
  else if (catalog != nil)
    /* An older catalog is on screen behind a failed fetch, so the banner says
       how old it is; that is the only case the brief names for it. */
    [self showBannerWithMessage:[self staleCatalogMessageForDate:[catalog fetchDate]
                                                           error:error]];
  else if (_catalog != nil)
    /* A reload failed but the previous catalog still fills the page: keep it
       browsable and report the failure in the banner rather than dropping it. */
    [self showBannerWithMessage:[error localizedDescription]];
  else
    /* Nothing was ever loaded, so there is no grid to fall back on and the
       page area shows the error alone. */
    [self showErrorPageWithMessage:[error localizedDescription]];
}

- (NSString *)staleCatalogMessageForDate:(NSDate *)date error:(NSError *)error
{
  NSString *when = nil;
  if (date != nil)
    when = [NSDateFormatter localizedStringFromDate:date
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
  if (when == nil)
    return [error localizedDescription];
  return [NSString stringWithFormat:
      NSLocalizedString(@"Showing the catalog from %@. Could not reach appimage.github.io: %@", @""),
      when, [error localizedDescription]];
}

- (void)showErrorPageWithMessage:(NSString *)message
{
  AGCatalogErrorPage *page = [[AGCatalogErrorPage alloc] initWithMessage:message];
  [page setTarget:self];
  [page setAction:@selector(reloadCatalog:)];
  /* The message lives in the page itself now, so a banner over it would say
     the same thing twice. */
  [self hideBanner];
  [self replaceStackWithPage:page];
}

- (void)showBannerWithMessage:(NSString *)message
{
  [_banner setMessage:message];
  _bannerVisible = YES;
  [self layoutContentArea];
}

- (void)hideBanner
{
  if (!_bannerVisible)
    return;
  _bannerVisible = NO;
  [self layoutContentArea];
}

- (BOOL)showsToolkitCategories
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:kAGShowToolkitCategoriesKey];
}

- (void)userDefaultsDidChange:(NSNotification *)note
{
  (void)note;
  if (_catalog == nil)
    return;
  BOOL toolkit = [self showsToolkitCategories];
  if (toolkit == _toolkitCategoriesShown)
    return;                 /* every other default is read on the next load */
  _toolkitCategoriesShown = toolkit;

  AGSidebarSection section = [_sidebar selectedSection];
  NSString *rawCategory = [_sidebar selectedRawCategory];
  [_sidebar reloadWithCatalog:_catalog showToolkitCategories:toolkit];

  /* Dropping the row the user was on moves the selection back to Discover, and
     the page behind the sidebar has to follow or the two would disagree. */
  NSString *nowRawCategory = [_sidebar selectedRawCategory];
  BOOL sameSelection = ([_sidebar selectedSection] == section)
      && (rawCategory == nowRawCategory
          || (rawCategory != nil && [rawCategory isEqualToString:nowRawCategory]));
  if (!sameSelection)
    [self showRootPage];
}

- (void)installedSetDidChange:(NSNotification *)note
{
  (void)note;
  /* The Installed page is a fixed list, so it is the one page whose content
   * changes when something is installed or removed. */
  if ([_sidebar selectedSection] == AGSidebarSectionInstalled
      && [_navigationStack firstObject] == _rootGridPage)
    [self populateRootGridPage];
}

#pragma mark - Pages

- (AGGridViewController *)newGridPage
{
  AGGridViewController *page = [[AGGridViewController alloc] initWithImageCache:_imageCache
                                                                      installer:_installer];
  [page setDelegate:self];
  return page;
}

- (AGAppGridView *)currentGridView
{
  NSViewController *top = [_navigationStack lastObject];
  if ([top isKindOfClass:[AGGridViewController class]])
    return [(AGGridViewController *)top gridView];
  return nil;
}

- (NSString *)currentScopeCategory
{
  if ([_sidebar selectedSection] == AGSidebarSectionCategory)
    return [_sidebar selectedRawCategory];
  return nil;
}

- (NSArray<AGApp *> *)appsForCurrentScope
{
  switch ([_sidebar selectedSection])
    {
      case AGSidebarSectionInstalled:
        return [_installer installedAppsFromCatalog:_catalog];
      case AGSidebarSectionCategory:
        return [_catalog appsInCategory:[_sidebar selectedRawCategory]];
      case AGSidebarSectionDiscover:
      default:
        /* Nil until the first catalog lands, which is the state the root
           page is built in; the grid reads nil as an empty list. */
        return _discoverApps;
    }
}

- (void)populateRootGridPage
{
  NSString *query = [[_searchField stringValue]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSArray<AGApp *> *apps;
  NSString *emptyMessage;
  if ([query length] > 0 && _searchIndex != nil)
    {
      NSArray<AGApp *> *matches = [_searchIndex appsMatchingQuery:query
                                                       inCategory:[self currentScopeCategory]];
      if ([_sidebar selectedSection] == AGSidebarSectionInstalled)
        {
          NSSet *installed = [NSSet setWithArray:[_installer installedAppsFromCatalog:_catalog]];
          NSMutableArray *filtered = [NSMutableArray array];
          for (AGApp *app in matches)
            if ([installed containsObject:app])
              [filtered addObject:app];
          matches = filtered;
        }
      apps = matches;
      emptyMessage = [AGAppGridView emptyMessageForSearchQuery:query];
    }
  else
    {
      apps = [self appsForCurrentScope];
      emptyMessage = ([_sidebar selectedSection] == AGSidebarSectionInstalled)
                         ? [AGAppGridView installedEmptyMessage] : @"";
    }
  [_rootGridPage setEmptyMessage:emptyMessage];
  [_rootGridPage setApps:apps];
  [self updateTopBar];
}

- (void)showRootPage
{
  if (_rootGridPage == nil)
    _rootGridPage = [self newGridPage];
  [self replaceStackWithPage:_rootGridPage];
  [self populateRootGridPage];
  if (!_hasCatalogOnce)
    [_rootGridPage setLoading:YES];
}

- (void)replaceStackWithPage:(NSViewController<AGPage> *)page
{
  for (NSViewController *entry in _navigationStack)
    [[entry view] removeFromSuperview];
  [_navigationStack removeAllObjects];
  [self pushPage:page];
}

- (void)pushPage:(NSViewController<AGPage> *)page
{
  NSViewController *previous = [_navigationStack lastObject];
  [[previous view] removeFromSuperview];
  [_navigationStack addObject:page];
  [self presentTopPage];
}

- (void)presentTopPage
{
  NSViewController *top = [_navigationStack lastObject];
  NSView *pageView = [top view];
  [pageView setFrame:[_pageContainer bounds]];
  [pageView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [_pageContainer addSubview:pageView];
  [_searchField setNextKeyView:[self currentGridView]];
  if ([self currentGridView] == nil)
    [[self window] makeFirstResponder:_pageContainer];
  [self updateTopBar];
}

- (void)updateTopBar
{
  /* Nothing names the page in the bar any more: the sidebar selection says
     which scope is open and the window title says which app this is, so a
     third copy of the name between the back arrow and the search field
     was saying the same thing twice. */
  [_backButton setHidden:([_navigationStack count] <= 1)];
  [self revalidateMenus];
}

/* The global menu bar shows the enabled state it was last told about and
 * drops clicks on items it believes disabled, so every navigation change
 * has to push the new state into the menus rather than wait for the next
 * validation pass. */
- (void)revalidateMenus
{
  for (NSMenuItem *item in [[NSApp mainMenu] itemArray])
    [[item submenu] update];
}

#pragma mark - Actions

- (void)sidebarSelectionChanged:(id)sender
{
  (void)sender;
  /* With no catalog there is no scope to show, and leaving the error page is
     the one way to lose sight of why the page is empty. */
  if (_catalog == nil)
    return;
  [_searchField setStringValue:@""];
  [self showRootPage];
}

- (void)searchChanged:(id)sender
{
  (void)sender;
  if (_catalog == nil)
    return;
  if ([_navigationStack firstObject] != _rootGridPage || [_navigationStack count] > 1)
    [self replaceStackWithPage:_rootGridPage];
  [self populateRootGridPage];
}

- (void)showDiscover:(id)sender
{
  (void)sender;
  [_sidebar selectSection:AGSidebarSectionDiscover rawCategory:nil];
  [self sidebarSelectionChanged:sender];
}

- (void)showInstalled:(id)sender
{
  (void)sender;
  [_sidebar selectSection:AGSidebarSectionInstalled rawCategory:nil];
  [self sidebarSelectionChanged:sender];
}

- (void)goBack:(id)sender
{
  (void)sender;
  if ([_navigationStack count] <= 1)
    return;
  NSViewController *top = [_navigationStack lastObject];
  [[top view] removeFromSuperview];
  [_navigationStack removeLastObject];
  [self presentTopPage];
  [[self window] makeFirstResponder:[self currentGridView]];
}

- (void)focusSearchField:(id)sender
{
  (void)sender;
  [[self window] makeFirstResponder:_searchField];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
  SEL action = [item action];
  if (action == @selector(goBack:))
    return [_navigationStack count] > 1;
  if (action == @selector(reloadCatalog:))
    return ![_feedLoader isLoading];
  return YES;
}

#pragma mark - AGGridViewControllerDelegate

- (void)gridViewController:(AGGridViewController *)controller didSelectApp:(AGApp *)app
{
  (void)controller;
  AGDetailViewController *detail = [[AGDetailViewController alloc] initWithApp:app
                                                                    imageCache:_imageCache
                                                                     installer:_installer];
  [self pushPage:detail];
}

@end

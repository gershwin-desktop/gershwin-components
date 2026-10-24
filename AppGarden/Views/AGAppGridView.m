/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGAppGridView.h"
#import "AGAppCardView.h"
#import "AGInstallButton.h"
#import "AppearanceMetrics.h"
#import "AGApp.h"
#import "AGGridLayout.h"
#import "AGImageCache.h"
#import "AGInstaller.h"

/* Points of content laid out below the viewport, so a fast scroll lands on
 * cards that already exist instead of on the pool being filled. */
static const CGFloat kAGGridLookAhead = 200.0;
static const CGFloat kAGSpinnerSide = 32.0;
/* Side margin of the centered status text; the grid's own card inset is the
 * same 24 points, so the empty state lines up with the first card. */
static const CGFloat kAGStatusTextInset = 24.0;

/* One shared style for both status lines: centered, 13 pt, the theme's grey. */
static NSDictionary *AGStatusAttributes(void)
{
  static NSDictionary *attributes = nil;
  if (attributes == nil)
    {
      NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
      [style setAlignment:NSCenterTextAlignment];
      attributes = @{
        NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_13,
        NSForegroundColorAttributeName : [NSColor disabledControlTextColor],
        NSParagraphStyleAttributeName : style
      };
    }
  return attributes;
}

/* The grid answers a card click itself instead of forwarding it: a card is
 * the grid's row, so selecting one is the grid's own job. */
@interface AGAppGridView () <AGAppCardViewDelegate>
@end

@implementation AGAppGridView
{
  AGImageCache *_imageCache;
  AGInstaller *_installer;
  AGGridLayout *_layout;
  /* Index in the page to the card drawn for it. A card outside this
   * dictionary does not exist, which is the whole recycling rule. */
  NSMutableDictionary<NSNumber *, AGAppCardView *> *_cardsByIndex;
  NSMutableArray<AGAppCardView *> *_pool;
  /* URL strings already asked of the cache, so a scroll does not re-ask for
   * what is still on screen. Cleared when the URL leaves the wanted set. */
  NSMutableSet<NSString *> *_requestedIcons;
  NSProgressIndicator *_spinner;
  NSInteger _focusedIndex;
  BOOL _layingOut;
}

#pragma mark - Setup

- (instancetype)initWithFrame:(NSRect)frame
                   imageCache:(AGImageCache *)imageCache
                    installer:(AGInstaller *)installer
{
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _imageCache = imageCache;
      _installer = installer;
      _apps = @[];
      _focusedIndex = NSNotFound;
      _cardsByIndex = [[NSMutableDictionary alloc] init];
      _pool = [[NSMutableArray alloc] init];
      _requestedIcons = [[NSMutableSet alloc] init];
      _layout = [[AGGridLayout alloc] initWithCardSize:[AGAppCardView cardSize]
                                           minimumGap:METRICS_SPACE_16
                                            sideInset:METRICS_CONTENT_SIDE_MARGIN];
      /* The clip view resizes its document view's width through this mask;
       * the height stays ours to set from the content. */
      [self setAutoresizingMask:NSViewWidthSizable];

      _spinner = [[NSProgressIndicator alloc]
          initWithFrame:NSMakeRect(0.0, 0.0, kAGSpinnerSide, kAGSpinnerSide)];
      [_spinner setStyle:NSProgressIndicatorSpinningStyle];
      [_spinner setIndeterminate:YES];
      [_spinner setHidden:YES];
      [self addSubview:_spinner];
      [self layoutStatusViews];

      [self updateScrollObservation];
    }
  return self;
}

- (instancetype)initWithFrame:(NSRect)frame
{
  return [self initWithFrame:frame imageCache:nil installer:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  (void)coder;
  return [self initWithFrame:NSZeroRect imageCache:nil installer:nil];
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  for (NSString *key in _requestedIcons)
    [_imageCache cancelRequestsForURL:[NSURL URLWithString:key]];
}

- (BOOL)isFlipped
{
  return YES;
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

#pragma mark - Scroll tracking

/*
 * The document view's own bounds never move while the page scrolls: the clip
 * view's bounds origin does. Observing anything on self would therefore never
 * fire during a scroll, and the pooled cards would run out one row in.
 */
- (void)updateScrollObservation
{
  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center removeObserver:self name:NSViewBoundsDidChangeNotification object:nil];

  NSView *superview = [self superview];
  if (superview == nil || ![superview isKindOfClass:[NSClipView class]])
    return;
  [superview setPostsBoundsChangedNotifications:YES];
  [center addObserver:self
             selector:@selector(clipDidScroll:)
                 name:NSViewBoundsDidChangeNotification
               object:superview];
}

- (void)clipDidScroll:(NSNotification *)note
{
  (void)note;
  [self relayout];
}

- (void)viewDidMoveToSuperview
{
  [super viewDidMoveToSuperview];
  [self updateScrollObservation];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self updateScrollObservation];
  [self updateSpinnerAnimation];
}

#pragma mark - State

- (void)setApps:(NSArray<AGApp *> *)apps
{
  NSArray<AGApp *> *next = (apps != nil) ? [apps copy] : @[];
  if ([next isEqualToArray:_apps])
    return;
  _apps = next;

  if (_focusedIndex != NSNotFound && _focusedIndex >= (NSInteger)[_apps count])
    _focusedIndex = NSNotFound;

  /* Every card may now stand for a different item than the index it holds,
   * so none of them may survive the swap. */
  [self recycleAllCards];
  /* A new list starts at its top: keeping the offset of the previous list
   * showed the last row of a search result after a long scroll through
   * Discover. */
  [self scrollPoint:NSZeroPoint];
  [self setNeedsDisplay:YES];
  [self relayout];
}

- (void)setLoading:(BOOL)loading
{
  if (_loading == loading)
    return;
  _loading = loading;
  [_spinner setHidden:!loading];
  [self updateSpinnerAnimation];
  [self setNeedsDisplay:YES];
  [self relayout];
}

- (void)setEmptyMessage:(NSString *)emptyMessage
{
  if ((_emptyMessage == emptyMessage) || [_emptyMessage isEqualToString:emptyMessage])
    return;
  _emptyMessage = [emptyMessage copy];
  [self setNeedsDisplay:YES];
}

+ (NSString *)emptyMessageForSearchQuery:(NSString *)query
{
  NSString *format = NSLocalizedString(@"No applications match \"%@\".", @"");
  return [NSString stringWithFormat:format,
                                    (query != nil) ? query : @""];
}

+ (NSString *)installedEmptyMessage
{
  return NSLocalizedString(
      @"You have not downloaded anything yet. Apps you get from AppGarden appear here.",
      @"");
}

- (void)updateSpinnerAnimation
{
  if (_loading && [self window] != nil)
    [_spinner startAnimation:self];
  else
    [_spinner stopAnimation:self];
}

#pragma mark - Layout

- (void)setFrameSize:(NSSize)size
{
  [super setFrameSize:size];
  [self relayout];
}

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self relayout];
}

/* Height the page has to cover: the content, or the viewport when there is
 * less content than screen, so the background always reaches the bottom. */
- (CGFloat)viewportHeight
{
  NSView *superview = [self superview];
  if (superview != nil && [superview isKindOfClass:[NSClipView class]])
    return NSHeight([superview bounds]);
  return NSHeight([self bounds]);
}

- (void)relayout
{
  if (_layingOut)
    return;
  _layingOut = YES;

  NSRect bounds = [self bounds];
  CGFloat width = NSWidth(bounds);
  CGFloat height = [self viewportHeight];
  NSUInteger count = [_apps count];

  if (count > 0 && width > 8.0)
    height = MAX(height, [_layout heightForCount:count width:width]);

  if (fabs(NSHeight(bounds) - height) > 0.01 || NSWidth(bounds) < 8.0)
    {
      [self setFrameSize:NSMakeSize(width, height)];
      [self setNeedsDisplay:YES];
    }

  /* Centering the status group depends on the height settled above, and
   * -layout is never reached on its own in this stack, so both exits of this
   * pass position it here. */
  [self layoutStatusViews];

  if (count == 0 || width <= 8.0)
    {
      [self recycleAllCards];
      [self updateFocusDisplay];
      _layingOut = NO;
      return;
    }

  NSRange range = [self visibleIndexRangeForWidth:width count:count];
  [self bindCardsInRange:range width:width];
  [self updateIconRequestsInRange:range];
  [self updateFocusDisplay];

  _layingOut = NO;
}

/*
 * The first and last card the user can reach without the pool being filled
 * first: the visible rect plus a fixed look-ahead below it.
 *
 * Both ends are binary searches over AGGridLayout rather than a walk, and
 * over the layout rather than a copy of its row arithmetic, so a change to
 * the model cannot leave this function describing a different grid than the
 * one that is drawn.
 */
- (NSRange)visibleIndexRangeForWidth:(CGFloat)width count:(NSUInteger)count
{
  NSRect visible = [self visibleRect];
  if (NSHeight(visible) <= 0.0)
    visible = [self bounds];
  CGFloat firstY = NSMinY(visible);
  CGFloat lastY = NSMaxY(visible) + kAGGridLookAhead;

  NSUInteger low = 0;
  NSUInteger high = count;
  while (low < high)
    {
      NSUInteger mid = low + (high - low) / 2;
      if (NSMaxY([_layout frameForIndex:mid width:width]) >= firstY)
        high = mid;
      else
        low = mid + 1;
    }
  NSUInteger start = low;

  low = start;
  high = count;
  while (low < high)
    {
      NSUInteger mid = low + (high - low) / 2;
      if (NSMinY([_layout frameForIndex:mid width:width]) >= lastY)
        high = mid;
      else
        low = mid + 1;
    }
  NSUInteger end = low;

  /* A viewport that has not been measured yet would otherwise produce an
   * empty range and an empty page. */
  if (end <= start && start < count)
    end = start + 1;
  if (end > count)
    end = count;
  if (start > end)
    start = end;
  return NSMakeRange(start, end - start);
}

- (void)bindCardsInRange:(NSRange)range width:(CGFloat)width
{
  for (NSNumber *key in [[_cardsByIndex allKeys] copy])
    {
      NSUInteger index = [key unsignedIntegerValue];
      if (index >= range.location && index < NSMaxRange(range))
        continue;
      AGAppCardView *card = [_cardsByIndex objectForKey:key];
      [card removeFromSuperview];
      [card setDelegate:nil];
      [card setFocused:NO];
      [_pool addObject:card];
      [_cardsByIndex removeObjectForKey:key];
    }

  for (NSUInteger i = range.location; i < NSMaxRange(range); i++)
    {
      NSNumber *key = [NSNumber numberWithUnsignedInteger:i];
      AGAppCardView *card = [_cardsByIndex objectForKey:key];
      BOOL fresh = (card == nil);
      if (fresh)
        {
          card = [self dequeueCard];
          [_cardsByIndex setObject:card forKey:key];
          [self addSubview:card];
        }
      [card setFrame:[_layout frameForIndex:i width:width]];
      if (fresh)
        {
          [self bindCard:card toIndex:i];
          [card setNeedsDisplay:YES];
        }
    }
}

- (AGAppCardView *)dequeueCard
{
  AGAppCardView *card = nil;
  if ([_pool count] > 0)
    {
      card = [_pool lastObject];
      [_pool removeLastObject];
    }
  else
    {
      card = [[AGAppCardView alloc] initWithFrame:NSZeroRect installer:_installer];
    }
  [card setDelegate:self];
  return card;
}

- (void)bindCard:(AGAppCardView *)card toIndex:(NSUInteger)index
{
  AGApp *app = (index < [_apps count]) ? [_apps objectAtIndex:index] : nil;
  [card setApp:app];

  /* Asked synchronously first: the card was just created, so without a hit
   * here every scroll step would flash the placeholder for a frame. */
  NSURL *url = [app iconURL];
  if (url != nil)
    [card setIcon:[_imageCache cachedImageForURL:url]];
}

- (void)recycleAllCards
{
  for (AGAppCardView *card in [_cardsByIndex allValues])
    {
      [card removeFromSuperview];
      [card setDelegate:nil];
      [card setFocused:NO];
      [_pool addObject:card];
    }
  [_cardsByIndex removeAllObjects];
}

#pragma mark - Icons

- (void)updateIconRequestsInRange:(NSRange)range
{
  if (_imageCache == nil)
    return;

  NSMutableSet<NSString *> *wanted = [[NSMutableSet alloc] init];
  for (NSUInteger i = range.location; i < NSMaxRange(range); i++)
    {
      NSURL *url = [[_apps objectAtIndex:i] iconURL];
      if (url != nil)
        [wanted addObject:[url absoluteString]];
    }

  for (NSString *key in [[_requestedIcons allObjects] copy])
    {
      if ([wanted containsObject:key])
        continue;
      /* Off screen: stop the transfer instead of letting a fast scroll queue
       * one for every row the user has already passed. */
      [_imageCache cancelRequestsForURL:[NSURL URLWithString:key]];
      [_requestedIcons removeObject:key];
    }

  for (NSString *key in wanted)
    {
      if ([_requestedIcons containsObject:key])
        continue;
      [_requestedIcons addObject:key];
      NSURL *url = [NSURL URLWithString:key];
      __weak AGAppGridView *weakSelf = self;
      [_imageCache imageForURL:url
              maximumPixelSize:AGImageCacheIconPixelSize
                    completion:^(NSImage *image, NSError *error) {
                      (void)error;
                      [weakSelf deliverIcon:image forURLString:key];
                    }];
    }
}

- (void)deliverIcon:(NSImage *)image forURLString:(NSString *)urlString
{
  if (image == nil || urlString == nil)
    return;
  for (NSNumber *key in _cardsByIndex)
    {
      AGAppCardView *card = [_cardsByIndex objectForKey:key];
      NSURL *iconURL = [[card app] iconURL];
      if (iconURL != nil && [[iconURL absoluteString] isEqualToString:urlString])
        [card setIcon:image];
    }
}

#pragma mark - Status

- (BOOL)showsEmptyMessage
{
  return (!_loading && [_apps count] == 0 && [_emptyMessage length] > 0);
}

- (CGFloat)statusTextWidth
{
  CGFloat width = NSWidth([self bounds]) - 2.0 * kAGStatusTextInset;
  return (width > 40.0) ? width : 40.0;
}

- (void)layoutStatusViews
{
  if (_spinner == nil)
    return;

  NSDictionary *attributes = AGStatusAttributes();
  CGFloat lineHeight = ceil([@"Ag" sizeWithAttributes:attributes].height);
  CGFloat groupHeight = kAGSpinnerSide + METRICS_SPACE_8 + lineHeight;
  CGFloat originY = floor((NSHeight([self bounds]) - groupHeight) / 2.0);
  if (originY < 0.0)
    originY = 0.0;

  CGFloat width = NSWidth([self bounds]);
  [_spinner setFrame:NSMakeRect(floor((width - kAGSpinnerSide) / 2.0),
                               originY, kAGSpinnerSide, kAGSpinnerSide)];
}

- (void)drawRect:(NSRect)dirtyRect
{
  (void)dirtyRect;

  NSRect bounds = [self bounds];
  if (NSIsEmptyRect(bounds))
    return;
  [[NSColor windowBackgroundColor] setFill];
  NSRectFill(bounds);

  NSDictionary *attributes = AGStatusAttributes();
  CGFloat width = [self statusTextWidth];
  CGFloat inset = kAGStatusTextInset;

  if ([self showsEmptyMessage])
    {
      NSSize needed = [_emptyMessage
          boundingRectWithSize:NSMakeSize(width, 10000.0)
                       options:NSStringDrawingUsesLineFragmentOrigin
                    attributes:attributes].size;
      CGFloat originY = floor((NSHeight(bounds) - ceil(needed.height)) / 2.0);
      [_emptyMessage drawInRect:NSMakeRect(inset, originY, width,
                                           ceil(needed.height))
                 withAttributes:attributes];
      return;
    }

  if (!_loading)
    return;

  NSString *text = NSLocalizedString(@"Loading catalog...", @"");
  CGFloat lineHeight = ceil([text sizeWithAttributes:attributes].height);
  CGFloat originY = NSMaxY([_spinner frame]) + METRICS_SPACE_8;
  [text drawInRect:NSMakeRect(inset, originY, width, lineHeight)
     withAttributes:attributes];
}

- (void)layout
{
  [super layout];
  [self layoutStatusViews];
}

#pragma mark - Focus and keyboard

- (BOOL)showsKeyboardFocus
{
  return ([[self window] firstResponder] == self);
}

- (void)updateFocusDisplay
{
  BOOL shows = [self showsKeyboardFocus];
  for (NSNumber *key in _cardsByIndex)
    {
      NSInteger index = (NSInteger)[key unsignedIntegerValue];
      [[_cardsByIndex objectForKey:key] setFocused:(shows && index == _focusedIndex)];
    }
}

- (AGAppCardView *)cardAtIndex:(NSInteger)index
{
  if (index < 0)
    return nil;
  return [_cardsByIndex objectForKey:[NSNumber numberWithUnsignedInteger:(NSUInteger)index]];
}

- (AGApp *)appAtIndex:(NSInteger)index
{
  if (index < 0 || index >= (NSInteger)[_apps count])
    return nil;
  return [_apps objectAtIndex:(NSUInteger)index];
}

- (void)scrollToFocusedCard
{
  if (_focusedIndex < 0 || _focusedIndex >= (NSInteger)[_apps count])
    return;
  [self scrollRectToVisible:[_layout frameForIndex:(NSUInteger)_focusedIndex
                                             width:NSWidth([self bounds])]];
}

- (void)focusCardAtIndex:(NSInteger)index
{
  _focusedIndex = index;
  [self scrollToFocusedCard];
  [self updateFocusDisplay];
}

- (BOOL)becomeFirstResponder
{
  BOOL ok = [super becomeFirstResponder];
  if (ok)
    {
      /* Tab into an untouched grid lands on the first card so the border the
       * user is about to move actually appears somewhere. */
      if (_focusedIndex == NSNotFound && [_apps count] > 0)
        _focusedIndex = 0;
      [self updateFocusDisplay];
    }
  return ok;
}

- (BOOL)resignFirstResponder
{
  BOOL ok = [super resignFirstResponder];
  if (ok)
    [self updateFocusDisplay];
  return ok;
}

- (void)exitSearchFieldIntoResultsWithDelta:(NSInteger)delta
{
  NSInteger count = (NSInteger)[_apps count];
  if (count == 0)
    return;

  BOOL hadFocus = (_focusedIndex != NSNotFound);
  [[self window] makeFirstResponder:self];
  if (hadFocus)
    {
      [self moveFocusBy:delta];
      return;
    }
  /* First entry steps onto the end of the grid that the direction names
   * rather than jumping to row zero, so the first arrow press always moves
   * the border instead of landing on the card that was already there. */
  [self focusCardAtIndex:(delta >= 0) ? 0 : count - 1];
}

- (void)moveFocusBy:(NSInteger)delta
{
  NSInteger count = (NSInteger)[_apps count];
  if (count == 0)
    return;

  NSInteger next;
  if (_focusedIndex == NSNotFound)
    next = (delta >= 0) ? 0 : count - 1;
  else
    next = _focusedIndex + delta;
  if (next < 0)
    next = 0;
  if (next >= count)
    next = count - 1;
  [self focusCardAtIndex:next];
}

- (void)keyDown:(NSEvent *)event
{
  if ([_apps count] == 0)
    {
      [super keyDown:event];
      return;
    }

  NSString *characters = [event charactersIgnoringModifiers];
  unichar character = ([characters length] > 0) ? [characters characterAtIndex:0] : 0;
  NSUInteger keyCode = [event keyCode];

  NSInteger columns = (NSInteger)[_layout columnsForWidth:NSWidth([self bounds])];
  if (columns < 1)
    columns = 1;

  NSInteger delta = 0;
  BOOL open = NO;
  BOOL toggle = NO;

  if (keyCode == 126 || character == NSUpArrowFunctionKey)
    delta = -columns;
  else if (keyCode == 125 || character == NSDownArrowFunctionKey)
    delta = columns;
  else if (keyCode == 123 || character == NSLeftArrowFunctionKey)
    delta = -1;
  else if (keyCode == 124 || character == NSRightArrowFunctionKey)
    delta = 1;
  else if (character == '\r' || character == '\n' || keyCode == 36 || keyCode == 76)
    open = YES;
  else if (character == ' ' || keyCode == 49)
    toggle = YES;
  else
    {
      [super keyDown:event];
      return;
    }

  if (open)
    {
      AGApp *app = [self appAtIndex:_focusedIndex];
      if (app != nil)
        [self.delegate appGridView:self didSelectApp:app];
      return;
    }

  if (toggle)
    {
      /* Space presses the same control a mouse click would, so the label the
       * user reads and the action they get cannot drift apart. */
      [[[self cardAtIndex:_focusedIndex] installButton] performClick];
      return;
    }

  [self moveFocusBy:delta];
}

#pragma mark - AGAppCardViewDelegate

- (void)appCardViewWasClicked:(AGAppCardView *)cardView
{
  NSInteger found = -1;
  for (NSNumber *key in _cardsByIndex)
    {
      if ([_cardsByIndex objectForKey:key] == cardView)
        {
          found = (NSInteger)[key unsignedIntegerValue];
          break;
        }
    }
  if (found < 0)
    return;

  /* The border follows the click only if the grid already has the keyboard;
   * taking first responder away from a search field mid-thought would be
   * rude, and the controller replaces this page anyway. */
  _focusedIndex = found;
  [self updateFocusDisplay];

  AGApp *app = [self appAtIndex:found];
  if (app != nil)
    [self.delegate appGridView:self didSelectApp:app];
}

@end

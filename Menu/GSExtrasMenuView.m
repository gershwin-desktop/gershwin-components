/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSExtrasMenuView.h"
#import <GNUstepGUI/GSTheme.h>
#import <math.h>

/* A damped spring, the kind a thing on a rail settles with: it overshoots
 * its place by a few pixels once and comes to rest.  The ratio is under
 * critical so the overshoot is there at all (the eye reads a critically
 * damped slide as a fade), the rate is chosen so the motion is over in
 * kSlideDuration; past that the remaining fraction is below a pixel and
 * the items are snapped to rest. */
static const NSTimeInterval kSlideDuration = 0.45;
static const double kSlideDampingRatio = 0.72;
static const double kSlideRate = 14.0;         /* undamped angular rate, 1/s */
static const NSTimeInterval kSlideFrame = 1.0 / 60.0;

/* The fraction of the start offset still to go at time t. */
static CGFloat GSSlideRemaining(NSTimeInterval t)
{
  if (t <= 0.0) return 1.0;
  if (t >= kSlideDuration) return 0.0;
  double decay = kSlideDampingRatio * kSlideRate;
  double dampedRate = kSlideRate * sqrt(1.0 - kSlideDampingRatio * kSlideDampingRatio);
  return (CGFloat)(exp(-decay * t)
                   * (cos(dampedRate * t) + (decay / dampedRate) * sin(dampedRate * t)));
}

@interface GSExtrasMenuView ()
- (void)rememberRestingPlaces;
- (void)keepRightEdge;
- (BOOL)cellsMatchItems;
- (NSMapTable *)currentOffsets;
- (void)startSlideFrom:(NSMapTable *)before reached:(NSMapTable *)reached;
- (void)stopSlide;
@end

@implementation GSExtrasMenuView

- (id)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self) {
    _measuringIndex = -1;
    _restingX = [NSMapTable mapTableWithKeyOptions:NSMapTableObjectPointerPersonality
                                      valueOptions:NSMapTableStrongMemory];
    _slideStart = [NSMapTable mapTableWithKeyOptions:NSMapTableObjectPointerPersonality
                                        valueOptions:NSMapTableStrongMemory];
  }
  return self;
}

- (void)dealloc
{
  [_slideTimer invalidate];
}

- (NSMenuItemCell *)menuItemCellForItemAtIndex:(NSInteger)index
{
  _measuringIndex = index;
  return [super menuItemCellForItemAtIndex:index];
}

- (NSInteger)measuringItemIndex
{
  return _measuringIndex;
}

- (void)setWidthProvider:(id<GSExtrasMenuViewWidthProvider>)provider
{
  _widthProvider = provider;
}

- (id<GSExtrasMenuViewWidthProvider>)widthProvider
{
  return _widthProvider;
}

/* The rect NSMenuView laid the item out at, moved right by the reach: while
 * the frame reaches out to the left for a sliding item, every item's place
 * in the view moves right by as much so nothing moves on screen.  Asking
 * for a rect the view has no cell for raises: its list of cells can lag the
 * menu's list of items by one notification. */
- (NSRect)restingRectOfItemAtIndex:(NSInteger)index
{
  NSRect rect = [super rectOfItemAtIndex:index];
  rect.origin.x += _slideLeftReach;
  return rect;
}

/* Whether the view's cells are the menu's items right now.  Between an
 * item's insertion or removal and the notification that tells the view, the
 * two lists differ, and a layout pass run in that gap lays out the wrong
 * list: its rects, and anything taken from them, describe nothing that will
 * be on screen. */
- (BOOL)cellsMatchItems
{
  NSUInteger cells = [_itemCells count];
  NSUInteger items = [[[self menu] itemArray] count];
  if (cells != items && !_reportedMismatch) {
    /* Said once: nothing here can put it right, and the menu's owner needs
       to know its view is laying out cells that belong to no item. */
    NSLog(@"GSExtrasMenuView: %lu cells for %lu items, layout passes skipped until they agree",
          (unsigned long)cells, (unsigned long)items);
    _reportedMismatch = YES;
  } else if (cells == items) {
    _reportedMismatch = NO;
  }
  return cells == items;
}

- (CGFloat)itemsWidth
{
  if (![self cellsMatchItems]) {
    return _restingWidth;
  }
  CGFloat width = 0.0;
  NSInteger count = (NSInteger)[[[self menu] itemArray] count];
  for (NSInteger i = 0; i < count; i++) {
    CGFloat right = NSMaxX([super rectOfItemAtIndex:i]);
    if (right > width) width = right;
  }
  _restingWidth = width;
  return width;
}

- (BOOL)isSliding
{
  return _slideTimer != nil;
}

#pragma mark - Anchor

/* Sizes the frame to the items and puts its right edge on the anchor.  While
 * items slide in from further left than the group now starts, the frame is
 * kept that much wider to the left so they are not clipped on the way.  The
 * area the view leaves behind is the superview's to repaint: a frame change
 * marks only the view itself. */
- (void)keepRightEdge
{
  if (!_anchored) {
    return;
  }
  CGFloat width = [self itemsWidth] + _slideLeftReach;
  NSRect old = [self frame];
  NSRect wanted = NSMakeRect(_anchoredRightEdge - width, NSMinY(old), width, NSHeight(old));
  if (NSEqualRects(old, wanted)) {
    return;
  }
  [super setFrame:wanted];
  NSView *superview = [self superview];
  if (superview) {
    [superview setNeedsDisplayInRect:NSUnionRect(old, wanted)];
  }
}

/* Placing the group - the anchor set or changed, a frame given by whoever
   lays the bar out - is not something the items slide through: it is where
   they are from now on, so the resting places are taken afresh. */
- (void)setAnchoredRightEdge:(CGFloat)x
{
  _anchored = YES;
  _anchoredRightEdge = x;
  [self keepRightEdge];
  [self rememberRestingPlaces];
}

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self keepRightEdge];
  [self rememberRestingPlaces];
}

#pragma mark - Slide

/* The x of an item's resting rect in the superview, or NAN when the view
 * cannot answer for it yet. */
- (CGFloat)superviewXOfItemAtIndex:(NSInteger)index
{
  @try {
    return NSMinX([self restingRectOfItemAtIndex:index]) + NSMinX([self frame]);
  } @catch (NSException *e) {
    return NAN;
  }
}

- (void)rememberRestingPlaces
{
  if (![self cellsMatchItems]) {
    return;
  }
  [_restingX removeAllObjects];
  NSArray *items = [[self menu] itemArray];
  for (NSUInteger i = 0; i < [items count]; i++) {
    CGFloat x = [self superviewXOfItemAtIndex:(NSInteger)i];
    if (!isnan(x)) {
      [_restingX setObject:[NSNumber numberWithDouble:x] forKey:[items objectAtIndex:i]];
    }
  }
}

/* Every layout pass ends here, the ones NSMenuView runs by itself after an
 * item changed included: the group goes back on its anchor before anything
 * is drawn, and every item that the pass moved on screen starts its slide
 * from where it was. */
- (void)sizeToFit
{
  BOOL consistent = [self cellsMatchItems];
  NSMapTable *before = [_restingX copy];
  [super sizeToFit];
  if (!consistent) {
    /* Laid out a list that is not the menu's: the group stays where it is
       and remembers what it knew, the pass after the notification puts
       everything right. */
    return;
  }
  /* Items that moved between two passes of one slide keep the offset they
     have reached: a pass in the middle of a slide (a title ticked over)
     must not start it again from the far end. */
  NSMapTable *reached = [self currentOffsets];
  [self keepRightEdge];
  [self startSlideFrom:before reached:reached];
}

/* Where each sliding item currently is relative to its new resting place,
 * before this pass moved anything. */
- (NSMapTable *)currentOffsets
{
  NSMapTable *offsets = [NSMapTable mapTableWithKeyOptions:NSMapTableObjectPointerPersonality
                                              valueOptions:NSMapTableStrongMemory];
  if (_slideTimer == nil) {
    return offsets;
  }
  CGFloat remaining = GSSlideRemaining(-[_slideBegan timeIntervalSinceNow]);
  NSEnumerator *keys = [_slideStart keyEnumerator];
  id item;
  while ((item = [keys nextObject]) != nil) {
    CGFloat start = [[_slideStart objectForKey:item] doubleValue];
    [offsets setObject:[NSNumber numberWithDouble:start * remaining] forKey:item];
  }
  return offsets;
}

- (void)startSlideFrom:(NSMapTable *)before reached:(NSMapTable *)reached
{
  NSArray *items = [[self menu] itemArray];
  NSMapTable *starts = [NSMapTable mapTableWithKeyOptions:NSMapTableObjectPointerPersonality
                                             valueOptions:NSMapTableStrongMemory];
  CGFloat leftReach = 0.0;
  BOOL moved = NO;
  for (NSUInteger i = 0; i < [items count]; i++) {
    id item = [items objectAtIndex:i];
    NSNumber *was = [before objectForKey:item];
    if (was == nil) {
      continue;                   /* new in the bar: appears in place */
    }
    CGFloat now = [self superviewXOfItemAtIndex:(NSInteger)i];
    if (isnan(now)) {
      continue;
    }
    /* From where the item is on screen right now - its old resting place,
       plus whatever slide it had not finished - to its new resting place. */
    CGFloat delta = [was doubleValue] - now;
    if (fabs(delta) >= 0.5) {
      moved = YES;
    }
    CGFloat offset = delta;
    NSNumber *partway = [reached objectForKey:item];
    if (partway != nil) {
      offset += [partway doubleValue];
    }
    if (fabs(offset) < 0.5) {
      continue;
    }
    [starts setObject:[NSNumber numberWithDouble:offset] forKey:item];
    /* How far left of the group's start the item is drawn when it sets off:
       its place in the items, plus the offset. */
    CGFloat reach = -(NSMinX([super rectOfItemAtIndex:(NSInteger)i]) + offset);
    if (reach > leftReach) leftReach = reach;
  }
  [self rememberRestingPlaces];
  /* A pass that moved nothing (a title ticked over, a measuring pass) leaves
     a running slide exactly as it is; restarting it from where the items
     have got to would set the spring back to rest there and stutter. */
  if (!moved || [starts count] == 0) {
    return;
  }
  [_slideStart removeAllObjects];
  NSEnumerator *keys = [starts keyEnumerator];
  id item;
  while ((item = [keys nextObject]) != nil) {
    [_slideStart setObject:[starts objectForKey:item] forKey:item];
  }
  _slideBegan = [NSDate date];
  _slideLeftReach = leftReach;
  [self keepRightEdge];
  if (_slideTimer == nil) {
    _slideTimer = [NSTimer timerWithTimeInterval:kSlideFrame
                                          target:self
                                        selector:@selector(slideTick:)
                                        userInfo:nil
                                         repeats:YES];
    /* The bar keeps sliding while a menu is open or a drag is tracked. */
    NSRunLoop *loop = [NSRunLoop currentRunLoop];
    [loop addTimer:_slideTimer forMode:NSDefaultRunLoopMode];
    [loop addTimer:_slideTimer forMode:NSModalPanelRunLoopMode];
    [loop addTimer:_slideTimer forMode:NSEventTrackingRunLoopMode];
  }
  [self setNeedsDisplay:YES];
}

- (void)slideTick:(NSTimer *)timer
{
  if (-[_slideBegan timeIntervalSinceNow] >= kSlideDuration) {
    [self stopSlide];
  }
  [self setNeedsDisplay:YES];
}

- (void)stopSlide
{
  [_slideTimer invalidate];
  _slideTimer = nil;
  [_slideStart removeAllObjects];
  _slideLeftReach = 0.0;
  [self keepRightEdge];
}

/* The rect drawing, highlighting and hit-testing see: the resting rect,
 * displaced by what is left of the item's slide. */
- (NSRect)rectOfItemAtIndex:(NSInteger)index
{
  NSRect rect = [self restingRectOfItemAtIndex:index];
  if (_slideTimer == nil) {
    return rect;
  }
  NSArray *items = [[self menu] itemArray];
  if (index < 0 || (NSUInteger)index >= [items count]) {
    return rect;
  }
  NSNumber *start = [_slideStart objectForKey:[items objectAtIndex:(NSUInteger)index]];
  if (start == nil) {
    return rect;
  }
  rect.origin.x += [start doubleValue] * GSSlideRemaining(-[_slideBegan timeIntervalSinceNow]);
  return rect;
}

@end

/* Horizontal menus only: the hook is reached for every menu view the theme
 * lays out, and the app menus and the dropdowns keep the width the theme
 * measured. */
@interface GSTheme (ExtrasMenuViewWidths)
@end

@implementation GSTheme (ExtrasMenuViewWidths)

- (CGFloat)proposedTitleWidth:(CGFloat)proposedWidth forMenuView:(NSMenuView *)aMenuView
{
  if (![aMenuView isKindOfClass:[GSExtrasMenuView class]]) {
    return proposedWidth;
  }
  GSExtrasMenuView *view = (GSExtrasMenuView *)aMenuView;
  id<GSExtrasMenuViewWidthProvider> provider = [view widthProvider];
  NSInteger index = [view measuringItemIndex];
  if (provider == nil || index < 0 || index >= (NSInteger)[[[view menu] itemArray] count]) {
    return proposedWidth;
  }
  return [provider extrasMenuView:view proposedTitleWidth:proposedWidth forItemAtIndex:index];
}

@end

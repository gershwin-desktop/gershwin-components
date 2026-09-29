/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Every extra is laid out at the width IT asked for, on every layout pass,
   including the passes NSMenuView runs on its own after an item was added or
   removed - the passes nobody resets a counter before.  The bug this pins:
   after the Media extra came back into the bar, the RAM percentage was drawn
   at the check mark's width and the check mark at the RAM item's, the
   highlight rectangles sat beside their icons and the clock was pushed off
   the screen, until a later pass happened to line up again.

   And the group is anchored by its right edge: when an item comes or goes,
   the view's own re-layout leaves the right edge where it was, so the
   extras to the right of that item never move - they used to jump left and
   back every time the player started or quit.

   Needs a display (NSMenuView lays out with real fonts): skipped without
   $DISPLAY, run it under xvfb-run. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "../../GSExtrasMenuView.h"

/* Widths per item title: the provider stands in for the manager and its
   extras, each item wants a width of its own so a permutation shows. */
@interface FixedWidths : NSObject <GSExtrasMenuViewWidthProvider>
{
  NSDictionary *_widths;
}
- (id)initWithWidths:(NSDictionary *)widths;
@end

@implementation FixedWidths
- (id)initWithWidths:(NSDictionary *)widths
{
  self = [super init];
  if (self) _widths = [widths retain];
  return self;
}
- (void)dealloc
{
  [_widths release];
  [super dealloc];
}
- (CGFloat)extrasMenuView:(GSExtrasMenuView *)view
       proposedTitleWidth:(CGFloat)proposedWidth
           forItemAtIndex:(NSInteger)index
{
  NSString *title = [[[[view menu] itemArray] objectAtIndex:index] title];
  NSNumber *w = [_widths objectForKey:title];
  return w ? [w doubleValue] : proposedWidth;
}
@end

/* The title width the view laid the item out with: its rect minus the
   padding NSMenuView adds on both sides (no icons here). */
static CGFloat TitleWidthAt(NSMenuView *view, NSInteger index)
{
  return NSWidth([view rectOfItemAtIndex:index]) - 2.0 * [view horizontalEdgePadding];
}

static BOOL AllItemsAtTheirWidth(GSExtrasMenuView *view, NSDictionary *widths)
{
  NSArray *items = [[view menu] itemArray];
  for (NSUInteger i = 0; i < [items count]; i++)
    {
      CGFloat want = [[widths objectForKey:[[items objectAtIndex:i] title]] doubleValue];
      if (fabs(TitleWidthAt(view, (NSInteger)i) - want) > 0.5)
        {
          NSLog(@"item %lu '%@' laid out at %g, wants %g", (unsigned long)i,
                [[items objectAtIndex:i] title], TitleWidthAt(view, (NSInteger)i), want);
          return NO;
        }
    }
  return YES;
}

int main(void)
{
  NSAutoreleasePool *arp = [[NSAutoreleasePool alloc] init];
  START_SET("extras menu view widths")
  if (getenv("DISPLAY") == NULL)
    SKIP("no DISPLAY: NSMenuView needs fonts, run under xvfb-run")
  /* The default theme: the Eau theme hangs an AppKit tool on a private
     display, and the layout under test is NSMenuView's own. */
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary *args = [[[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] autorelease];
  if (args == nil) args = [NSMutableDictionary dictionary];
  [args setObject:@"GNUstep" forKey:@"GSTheme"];
  [defaults removeVolatileDomainForName:NSArgumentDomain];
  [defaults setVolatileDomain:args forName:NSArgumentDomain];
  [NSApplication sharedApplication];

  NSDictionary *widths = [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithDouble:40.0], @"CPU",
    [NSNumber numberWithDouble:55.0], @"RAM",
    [NSNumber numberWithDouble:12.0], @"Check",
    [NSNumber numberWithDouble:70.0], @"Clock",
    [NSNumber numberWithDouble:20.0], @"Media", nil];
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Extras"];
  NSArray *titles = [NSArray arrayWithObjects:@"CPU", @"RAM", @"Check", @"Clock", nil];
  for (NSString *t in titles)
    [menu addItemWithTitle:t action:NULL keyEquivalent:@""];
  GSExtrasMenuView *view = [[GSExtrasMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, 22)];
  [view setHorizontal:YES];
  FixedWidths *provider = [[FixedWidths alloc] initWithWidths:widths];
  [view setWidthProvider:provider];
  [view setMenu:menu];
  [view sizeToFit];
  PASS(AllItemsAtTheirWidth(view, widths), "first pass lays every item out at its own width");

  /* An extra comes back: the item count grows, and the view lays itself out
     again on its own (the notification path, no reset from anyone). */
  [menu insertItemWithTitle:@"Media" action:NULL keyEquivalent:@"" atIndex:2];
  [view update];
  PASS(AllItemsAtTheirWidth(view, widths), "after an item was added, every item still has its own width");

  /* And goes again. */
  [menu removeItemAtIndex:2];
  [view update];
  PASS(AllItemsAtTheirWidth(view, widths), "after an item was removed, every item still has its own width");

  /* Two passes in a row over the same items, as a title change causes. */
  [view sizeToFit];
  [view sizeToFit];
  PASS(AllItemsAtTheirWidth(view, widths), "repeated passes keep every item at its own width");

  /* Anchored by its right edge: an item coming or going changes the width,
     and the view's own re-layout must leave the right edge where it was,
     so the extras to the right of the item never move. */
  NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 22)];
  [bar addSubview:view];
  [view setAnchoredRightEdge:592.0];
  [view sizeToFit];
  PASS(fabs(NSMaxX([view frame]) - 592.0) < 0.5, "anchored: the right edge sits on the anchor");
  CGFloat leftBefore = NSMinX([view frame]);
  [menu insertItemWithTitle:@"Media" action:NULL keyEquivalent:@"" atIndex:2];
  /* NSMenuView lays itself out again lazily, the first time a rect is
     wanted after the change - drawing asks the same way. */
  [view rectOfItemAtIndex:0];
  PASS(fabs(NSMaxX([view frame]) - 592.0) < 0.5,
       "anchored: after the view's own re-layout for an added item the right edge has not moved");
  PASS(NSMinX([view frame]) < leftBefore - 19.0, "anchored: the added item grew the group to the left");
  [menu removeItemAtIndex:2];
  [view rectOfItemAtIndex:0];
  PASS(fabs(NSMaxX([view frame]) - 592.0) < 0.5 && fabs(NSMinX([view frame]) - leftBefore) < 0.5,
       "anchored: after the item left, the group is back where it was, right edge untouched");

  /* The app menus are not touched: a plain menu view keeps the theme's width. */
  NSMenuView *plain = [[NSMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, 22)];
  [plain setHorizontal:YES];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"App"];
  [appMenu addItemWithTitle:@"CPU" action:NULL keyEquivalent:@""];
  [plain setMenu:appMenu];
  [plain sizeToFit];
  PASS(fabs(TitleWidthAt(plain, 0) - 40.0) > 0.5,
       "a menu view that is not the extras view is laid out from its titles");
  END_SET("extras menu view widths")
  [arp release];
  return 0;
}

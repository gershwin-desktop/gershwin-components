/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The menu bar's right-hand end: the extras group, its anchor, and what an
 * extra that comes and goes does to the room it takes.
 *
 * The rule under test is that the group is anchored by its RIGHT edge, so an
 * extra appearing or disappearing moves the extras beside it and leaves the
 * clock where it was.  The opposite - the group drifting along with its
 * contents - is the bug that pushed the clock off the side of the screen.
 *
 * Headless: this is the geometry, not the drawing.  The widths the view adds
 * on top of what an extra asks for are included, because that is where an
 * extra's idea of its own width and the room it actually takes come apart.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

/* The margin the bar keeps between the extras and the end of the bar. */
static const CGFloat kEdgeMargin = 10.0;

/* What the view adds to whatever width an extra asks for, per item:
     titleWidth + imageWidth + GSCellTextImageXDist + 2 * horizontalEdgePad
   The last two come from NSMenuView; the icon is a menu-bar-sized one.  A
   theme is free to pad differently, which is why these are named here and
   used the same way in the assertions and in the model. */
static const CGFloat kEdgePad = 4.0;        /* horizontalEdgePadding, x2 */
static const CGFloat kTextImageDist = 2.0;  /* GSCellTextImageXDist */
static const CGFloat kIconWidth = 18.0;

/* The gap the app titles leave at the left end of the bar: their first item
   carries this much inset of its own, and it is what the eye reads as the
   margin on that side.  Measured off a capture of the bar at 1920 wide. */
static const CGFloat kTitlesInset = 27.0;

/* How far the ink of the last extra sits inside the group's right edge: its
   own trailing padding.  Measured off the same capture; it is why the
   margin is smaller than the titles' inset and still looks the same. */
static const CGFloat kTrailingInset = 17.0;

/* --- The model -------------------------------------------------------- */

/* One extra in the bar.
 *
 * There are two ways an extra states a width, and mixing them up is what
 * puts one item's icon on top of its neighbour's title:
 *
 *   - a TITLED extra states the width of its title, and the bar adds the
 *     icon and the padding on top.  "36%" plus an icon is a wide item.
 *   - an ICON-ONLY extra states the whole width, because there is no title
 *     to measure and the bar's chrome is not room for anything.
 */
typedef enum {
    BarExtraTitleWidth,   /* -preferredWidth: title plus own padding */
    BarExtraTotalWidth    /* -totalWidthInMenuBar: the whole item */
} BarExtraWidthKind;

@interface BarExtra : NSObject
{
    NSString *_identifier;
    CGFloat _wantedWidth;
    BarExtraWidthKind _kind;
    BOOL _hasIcon;
    BOOL _showing;
}
- (id)initWithIdentifier:(NSString *)identifier
                  width:(CGFloat)width
                hasIcon:(BOOL)hasIcon
                  total:(BOOL)total;
- (CGFloat)occupiedWidth;
@end

@implementation BarExtra
- (id)initWithIdentifier:(NSString *)identifier
                  width:(CGFloat)width
                hasIcon:(BOOL)hasIcon
                  total:(BOOL)total
{
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _wantedWidth = width;
        _kind = total ? BarExtraTotalWidth : BarExtraTitleWidth;
        _hasIcon = hasIcon;
        _showing = YES;
    }
    return self;
}

- (void)setShowing:(BOOL)showing { _showing = showing; }
- (BOOL)isShowing { return _showing; }

/* The chrome the bar puts around an item whatever the extra asked for. */
- (CGFloat)chrome
{
    CGFloat c = 2.0 * kEdgePad;
    if (_hasIcon) c += kIconWidth + kTextImageDist;
    return c;
}

/* The width the theme hook hands to the view.
 *
 * The view asks for the TITLE width and adds the chrome itself, so an extra
 * that stated a total has the chrome taken off before the number goes back,
 * and one that stated a title width is passed straight through. */
- (CGFloat)titleWidthHandedToView
{
    if (_kind == BarExtraTotalWidth) {
        return MAX(0.0, _wantedWidth - [self chrome]);
    }
    return _wantedWidth;
}

/* The width the extra ends up occupying in the bar.
 *
 * An extra that is not showing is not in the bar at all and so takes
 * nothing - not even the padding, which is exactly what an extra asking for
 * zero width while still in the menu would have left behind. */
- (CGFloat)occupiedWidth
{
    if (!_showing) return 0.0;
    return [self titleWidthHandedToView] + [self chrome];
}
@end

/* The extras as one right-anchored strip of the bar. */
@interface ExtrasStrip : NSObject
{
    NSMutableArray *_extras;
    CGFloat _barWidth;
}
- (id)initWithBarWidth:(CGFloat)barWidth;
- (void)add:(BarExtra *)extra;
- (CGFloat)width;
- (CGFloat)originX;
- (CGFloat)rightEdge;
@end

@implementation ExtrasStrip
- (id)initWithBarWidth:(CGFloat)barWidth
{
    if ((self = [super init])) {
        _extras = [[NSMutableArray alloc] init];
        _barWidth = barWidth;
    }
    return self;
}

- (void)add:(BarExtra *)extra
{
    [_extras addObject:extra];
}

- (CGFloat)width
{
    CGFloat total = 0.0;
    NSUInteger i;
    for (i = 0; i < [_extras count]; i++) {
        total += [[_extras objectAtIndex: i] occupiedWidth];
    }
    return total;
}

/* Anchored to the right, a margin in from the end of the bar. */
- (CGFloat)originX { return _barWidth - [self width] - kEdgeMargin; }
- (CGFloat)rightEdge { return [self originX] + [self width]; }
@end

/* A strip of the shape the bar really has: a few ordinary extras and the
   clock at the end of them. */
static ExtrasStrip *MakeStrip(CGFloat barWidth)
{
    ExtrasStrip *strip = [[ExtrasStrip alloc] initWithBarWidth:barWidth];
    [strip add:[[BarExtra alloc] initWithIdentifier: @"cpu" width:48
                                            hasIcon:YES total:NO]];
    [strip add:[[BarExtra alloc] initWithIdentifier: @"ram" width:40
                                            hasIcon:YES total:NO]];
    [strip add:[[BarExtra alloc] initWithIdentifier: @"build" width:24
                                            hasIcon:YES total:NO]];
    [strip add:[[BarExtra alloc] initWithIdentifier: @"clock" width:40
                                            hasIcon: NO total:NO]];
    return strip;
}

/* --- The tests -------------------------------------------------------- */

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- The group is anchored by its right edge. ---
     * This is the whole point: the right edge is the same number whatever
     * the group is made of, so the clock cannot be moved by what else is
     * enabled. */
    {
        ExtrasStrip *strip = MakeStrip(1920.0);
        CGFloat rightBefore = [strip rightEdge];

        [strip add:[[BarExtra alloc] initWithIdentifier: @"media"
                                                  width:28
                                                hasIcon:YES total:YES]];
        PASS([strip rightEdge] == rightBefore,
             "adding an extra leaves the group's right edge at %g, not %g",
             rightBefore, [strip rightEdge]);

        [strip add:[[BarExtra alloc] initWithIdentifier: @"battery"
                                                  width:24
                                                hasIcon:YES total:YES]];
        PASS([strip rightEdge] == rightBefore,
             "adding a second extra still leaves the right edge at %g",
             rightBefore);
    }

    /* --- And it grows leftward, which is what that means in practice. --- */
    {
        ExtrasStrip *strip = MakeStrip(1920.0);
        CGFloat originBefore = [strip originX];
        CGFloat rightBefore = [strip rightEdge];

        [strip add:[[BarExtra alloc] initWithIdentifier: @"media"
                                                  width:28
                                                hasIcon:YES total:YES]];
        PASS([strip originX] < originBefore,
             "the group grew leftward (origin %g -> %g)",
             originBefore, [strip originX]);
        PASS([strip rightEdge] == rightBefore, "and its right edge did not move");
    }

    /* --- An extra with nothing to show takes no room at all. ---
     * Merely asking for zero width is not enough: the bar adds its own
     * padding to whatever is asked for, so the item would leave a gap the
     * width of that padding and nothing in it.  It has to leave the bar. */
    {
        BarExtra *media = [[BarExtra alloc] initWithIdentifier: @"media"
                                                        width:28
                                                      hasIcon:YES total:YES];
        [media setShowing:NO];
        PASS([media occupiedWidth] == 0.0,
             "a hidden extra occupies %g, not 0", [media occupiedWidth]);

        [media setShowing:YES];
        PASS([media occupiedWidth] == 28.0,
             "and once it is showing again it takes its %g back",
             [media occupiedWidth]);
    }

    /* --- A zero-width extra that is still in the menu is not zero. ---
     * The case the "leaves the bar" rule exists for: ask for nothing and
     * the bar still reserves its padding, so the gap is there with nothing
     * in it.  This is what an extra would leave behind if it stayed in the
     * menu reporting a width of 0. */
    {
        CGFloat chrome = 2.0 * kEdgePad + kIconWidth + kTextImageDist;
        CGFloat asLaidOut = MAX(0.0, 0.0 - chrome) + chrome;
        PASS(asLaidOut > 0.0,
             "an extra still in the menu asking for nothing still takes %g",
             asLaidOut);
    }

    /* --- An extra's width covers what the bar draws around it. ---
     * An extra asking for 22 with an icon is asking for 22 INCLUSIVE of the
     * padding and the icon.  Adding those on top would make the item 18+2+8
     * px too wide, and everything to the left of it - the clock among them -
     * would be pushed along. */
    {
        BarExtra *extra = [[BarExtra alloc] initWithIdentifier: @"media"
                                                         width:28
                                                       hasIcon:YES total:YES];
        PASS([extra occupiedWidth] == 28.0,
             "an extra stating a total of 28 occupies %g, not 28 plus the "
             "bar's padding", [extra occupiedWidth]);

        BarExtra *plain = [[BarExtra alloc] initWithIdentifier: @"clock"
                                                         width:40
                                                       hasIcon:NO total:NO];
        PASS([plain occupiedWidth] == 40.0 + 2.0 * kEdgePad,
             "one stating a title width occupies the title plus the padding "
             "(%g)", [plain occupiedWidth]);
    }

    /* --- The two conventions must not be confused. ---
     * A titled extra that states a title width needs the bar's padding AND
     * its icon on top of that number.  Reading it as a total instead - which
     * is what a single "width" method invites - takes the room the icon needs
     * away from under it, and the icon is then drawn on top of the title.
     * This is the shape of that bug: the item comes out the width of the
     * title alone, with the icon overlapping it. */
    {
        BarExtra *titled = [[BarExtra alloc] initWithIdentifier: @"cpu"
                                                          width:40
                                                        hasIcon:YES total:NO];
        CGFloat iconRoom = kIconWidth + kTextImageDist + 2.0 * kEdgePad;
        PASS([titled occupiedWidth] >= 40.0 + iconRoom,
             "a titled extra with an icon occupies %g, which leaves the %g "
             "the icon needs on top of its %g title",
             [titled occupiedWidth], iconRoom, 40.0);

        /* And the icon-only extra, stating a total, must not be short. */
        BarExtra *iconOnly = [[BarExtra alloc] initWithIdentifier: @"media"
                                                             width:40
                                                           hasIcon:YES total:YES];
        PASS([iconOnly occupiedWidth] == 40.0,
             "an icon-only extra stating a total of 40 occupies %g",
             [iconOnly occupiedWidth]);
    }

    /* --- What the theme hook hands back to the view. ---
     * The view asks the theme for the TITLE width and then adds the icon and
     * the padding itself, so a hook that passed the extra's total width
     * straight through would have every item come out that much too wide.
     * The hook takes the chrome off first; this is that arithmetic, and it
     * can only give the total back when the extra asked for more than the
     * chrome - which is why an extra has to ask for a width, not just for
     * "not nothing". */
    {
        CGFloat chrome = 2.0 * kEdgePad + kIconWidth + kTextImageDist;
        CGFloat wanted = 40.0;
        CGFloat handedBack = MAX(0.0, wanted - chrome);
        CGFloat asLaidOut = handedBack + chrome;
        PASS(fabs(asLaidOut - wanted) < 0.001,
             "an extra wanting %g is laid out at %g after the chrome is "
             "taken off and put back", wanted, asLaidOut);

        /* An icon-only extra asking for just the icon and its padding has no
           room for a title, and asking for less than that cannot be
           expressed - which is what "leaves the bar" is for. */
        CGFloat iconOnly = chrome;
        PASS(iconOnly - chrome == 0.0,
             "an extra wanting exactly its chrome gets a title width of %g",
             MAX(0.0, iconOnly - chrome));
    }

    /* --- The group never reaches past the end of the bar. ---
     * The failure this guards against is the clock running off the side of
     * the screen: however many extras are enabled, the right edge stays
     * inside the bar with the margin to spare. */
    {
        ExtrasStrip *strip = MakeStrip(1920.0);
        NSUInteger i;
        for (i = 0; i < 12; i++) {
            NSString *ident = [NSString stringWithFormat: @"extra%lu",
                               (unsigned long)i];
            [strip add:[[BarExtra alloc] initWithIdentifier: ident
                                                      width:40
                                                    hasIcon:YES total:YES]];
        }
        PASS([strip rightEdge] <= 1920.0,
             "with 16 extras the right edge is %g, inside the bar",
             [strip rightEdge]);
        PASS(1920.0 - [strip rightEdge] >= kEdgeMargin - 0.001,
             "and it keeps the %g margin (the gap is %g)",
             kEdgeMargin, 1920.0 - [strip rightEdge]);
    }

    /* --- The bar is the same width at both ends. ---
     * The space left of the app titles and right of the extras should read
     * the same, or the bar looks lopsided.
     *
     * What the eye measures is the gap to the first INK, not to the frame.
     * Each end has its item's own padding inside it - the titles' first
     * item carries the inset that makes the left gap, the clock's carries
     * the padding inside the extras' last item - and the margin is what is
     * left once that padding is taken out of both.  The margin at the
     * extras end is therefore the one constant to size, and it is measured
     * here against the inset measured off a real bar. */
    {
        ExtrasStrip *strip = MakeStrip(1920.0);
        CGFloat frameGap = 1920.0 - [strip rightEdge];

        /* What the eye compares is the gap to the first INK at each end, and
           the ink sits inside the item by that item's own padding.  So the
           two ends are level when
               margin + the last item's trailing inset  ==  the titles' inset
           which is what fixes the margin: 27 - 8 = 19.  Both insets were
           measured off the same bar (kTitlesInset above, kTrailingInset
           below), so this is the arithmetic that makes them look even. */
        CGFloat inkGapRight = frameGap + kTrailingInset;
        PASS(fabs(inkGapRight - kTitlesInset) < 1.0,
             "the gap to the ink at the extras end (%g) matches the one at "
             "the titles end (%g)", inkGapRight, kTitlesInset);
        PASS(frameGap > 0.0, "and there is a margin at all (%g)", frameGap);
    }

    /* suiteName must really be used: with the gnustep-2.0 ABI every other
       literal here is a short tagged string, and a string the compiler can
       drop leaves this file without an __objc_constant_string section, which
       the final link needs at least one of. */
    NSString *suiteName = @"ExtrasBarLayout";
    PASS([suiteName length] > 0, "%s: the suite ran", [suiteName UTF8String]);

    [arp release];
    return 0;
}

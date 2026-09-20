/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRFlameGraphView.h"
#import "PRAppearance.h"
#import "PRLegendView.h"
#import "PRCallNode.h"
#import "PRSymbol.h"

/* One drawn bar. */
@interface PRFlameBox : NSObject
{
@public
    PRCallNode *node;
    NSRect rect;
    BOOL matches;
}
@end

@implementation PRFlameBox
@end

@implementation PRFlameGraphView

@synthesize costUnit = _costUnit;
@synthesize frequency = _frequency;
@synthesize zoomNode = _zoomNode;
@synthesize matchedWeight = _matchedWeight;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil)
        return nil;
    _boxes = [[NSMutableArray alloc] init];
    _rowHeight = 18.0;
    _frequency = 999;
    _boxesAreStale = YES;
    return self;
}

/* Drawing from the top down keeps the outermost frame in sight while the
   user scrolls through deep stacks. */
- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [[self window] setAcceptsMouseMovedEvents:YES];
}

- (void)setRoot:(PRCallNode *)root
{
    _root = root;
    _zoomNode = root;
    _hoverNode = nil;
    _boxesAreStale = YES;
    [self setNeedsDisplay:YES];
}

- (NSString *)searchString
{
    return _searchString;
}

- (void)setSearchString:(NSString *)searchString
{
    _searchString = [searchString copy];
    _boxesAreStale = YES;
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    _boxesAreStale = YES;
}

- (void)zoomToNode:(PRCallNode *)node
{
    if (node == nil || node == _zoomNode)
        return;
    _zoomNode = node;
    _boxesAreStale = YES;
    [self setNeedsDisplay:YES];
    if ([[self delegate] respondsToSelector:@selector(flameGraphView:didZoomToNode:)])
        [[self delegate] flameGraphView:self didZoomToNode:node];
}

- (void)zoomOut
{
    if (_zoomNode != nil && [_zoomNode parent] != nil)
        [self zoomToNode:[_zoomNode parent]];
}

- (void)resetZoom
{
    [self zoomToNode:_root];
}

- (NSUInteger)levelCount
{
    [self layoutBoxes];
    NSUInteger levels = 0;
    for (PRFlameBox *box in _boxes) {
        NSUInteger level = (NSUInteger)(box->rect.origin.y / _rowHeight) + 1;
        if (level > levels)
            levels = level;
    }
    return levels;
}

- (CGFloat)requiredHeight
{
    return (CGFloat)[self levelCount] * _rowHeight;
}

- (BOOL)node:(PRCallNode *)node matchesSearch:(NSString *)search
{
    if ([search length] == 0)
        return NO;
    PRSymbol *symbol = [node symbol];
    if (symbol == nil)
        return NO;
    return [[symbol displayName] rangeOfString:search
                                       options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [[symbol moduleName] rangeOfString:search
                                      options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (void)addBoxesForNode:(PRCallNode *)node
                      x:(CGFloat)x
                  width:(CGFloat)width
                  level:(NSUInteger)level
             insideMatch:(BOOL)insideMatch
{
    if (width < 0.4)
        return;

    PRFlameBox *box = [[PRFlameBox alloc] init];
    box->node = node;
    box->rect = NSMakeRect(x, (CGFloat)level * _rowHeight, width, _rowHeight);
    box->matches = [self node:node matchesSearch:_searchString];
    [_boxes addObject:box];
    /* Everything below a matching frame is part of that match already, so
       only the outermost match of a branch counts towards the total. */
    if (box->matches && !insideMatch)
        _matchedWeight += [node totalWeight];

    double total = [node totalWeight];
    if (total <= 0)
        return;

    CGFloat childX = x;
    for (PRCallNode *child in [node children]) {
        CGFloat childWidth = width * ([child totalWeight] / total);
        [self addBoxesForNode:child
                            x:childX
                        width:childWidth
                        level:level + 1
                  insideMatch:insideMatch || box->matches];
        childX += childWidth;
    }
}

- (void)layoutBoxes
{
    if (!_boxesAreStale)
        return;
    _boxesAreStale = NO;
    [_boxes removeAllObjects];
    _matchedWeight = 0;

    if (_zoomNode == nil)
        return;

    CGFloat width = NSWidth([self bounds]);

    /* The frames the zoomed one was reached through stay visible above it,
       each taking the full width, so the context is never lost. */
    NSMutableArray *ancestors = [NSMutableArray array];
    for (PRCallNode *node = [_zoomNode parent]; node != nil; node = [node parent])
        [ancestors insertObject:node atIndex:0];

    NSUInteger level = 0;
    for (PRCallNode *ancestor in ancestors) {
        PRFlameBox *box = [[PRFlameBox alloc] init];
        box->node = ancestor;
        box->rect = NSMakeRect(0, (CGFloat)level * _rowHeight, width, _rowHeight);
        box->matches = [self node:ancestor matchesSearch:_searchString];
        [_boxes addObject:box];
        level++;
    }

    [self addBoxesForNode:_zoomNode x:0 width:width level:level insideMatch:NO];
}

- (PRFlameBox *)boxAtPoint:(NSPoint)point
{
    for (PRFlameBox *box in _boxes)
        if (NSPointInRect(point, box->rect))
            return box;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self layoutBoxes];

    [[NSColor colorWithCalibratedWhite:0.98 alpha:1.0] set];
    NSRectFill(dirtyRect);

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    NSDictionary *textAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1.0],
        NSParagraphStyleAttributeName: style
    };
    BOOL searching = [_searchString length] > 0;

    for (PRFlameBox *box in _boxes) {
        if (!NSIntersectsRect(box->rect, dirtyRect))
            continue;

        NSRect rect = NSInsetRect(box->rect, 0.5, 0.5);
        if (rect.size.width < 0.5)
            continue;

        PRSymbol *symbol = [box->node symbol];
        NSColor *color;
        if (searching && !box->matches)
            color = [PRAppearance dimmedColorForSymbol:symbol];
        else
            color = [PRAppearance colorForSymbol:symbol
                                     highlighted:(box->node == _hoverNode ||
                                                  (searching && box->matches))];
        [color set];
        NSRectFill(rect);

        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.9] set];
        NSFrameRectWithWidth(rect, 0.5);

        if (rect.size.width > 26) {
            NSString *title = symbol ? [symbol displayName] : [box->node label];
            NSRect textRect = NSInsetRect(rect, 4, 2);
            [title drawInRect:textRect withAttributes:textAttributes];
        }
    }

    if ([_boxes count] == 0) {
        NSString *message = @"No profile loaded. Record one to see where the "
                            @"time goes.";
        NSDictionary *attributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor darkGrayColor]
        };
        [message drawAtPoint:NSMakePoint(16, 16) withAttributes:attributes];
    }
}

/* The legend is built from the bars themselves: which binaries a profile
   shows differs from recording to recording, so a fixed key would name
   colours that are not on screen. */
- (NSArray *)legendEntries
{
    [self layoutBoxes];

    NSMutableDictionary *weights = [NSMutableDictionary dictionary];
    double kernelWeight = 0;
    double unknownWeight = 0;
    BOOL namesNoBinaries = NO;

    for (PRFlameBox *box in _boxes) {
        PRSymbol *symbol = [box->node symbol];
        if (symbol == nil)
            continue;
        double weight = [box->node selfWeight];

        if ([symbol isUnknown]) {
            unknownWeight += weight;
        } else if ([symbol isKernel]) {
            kernelWeight += weight;
        } else if ([[symbol moduleName] isEqualToString:@"[unknown]"]) {
            namesNoBinaries = YES;
        } else {
            NSString *module = [symbol moduleName];
            NSNumber *previous = [weights objectForKey:module];
            [weights setObject:[NSNumber numberWithDouble:
                                [previous doubleValue] + weight]
                        forKey:module];
        }
    }

    NSArray *modules = [[weights allKeys] sortedArrayUsingComparator:
                        ^NSComparisonResult(NSString *a, NSString *b) {
        double left = [[weights objectForKey:a] doubleValue];
        double right = [[weights objectForKey:b] doubleValue];
        if (left > right) return NSOrderedAscending;
        if (left < right) return NSOrderedDescending;
        return [a localizedCaseInsensitiveCompare:b];
    }];

    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *module in modules)
        [entries addObject:
         [PRLegendEntry entryWithLabel:module
                                 color:[PRAppearance colorForModuleName:module]]];

    if (kernelWeight > 0)
        [entries addObject:
         [PRLegendEntry entryWithLabel:@"Kernel and drivers"
                                 color:[PRAppearance kernelColor]]];
    if (unknownWeight > 0)
        [entries addObject:
         [PRLegendEntry entryWithLabel:@"Code that could not be named"
                                 color:[PRAppearance unknownColor]]];
    if ([_searchString length] > 0)
        [entries addObject:
         [PRLegendEntry entryWithLabel:@"Does not match the search"
                                 color:[PRAppearance dimmedColor]]];

    /* A file of folded stacks says which functions ran but not which binary
       they came from, so there is nothing the hues could stand for. */
    if (namesNoBinaries)
        [entries addObject:
         [PRLegendEntry entryWithLabel:@"One colour per function - this "
                                        @"recording names no binaries"
                                 color:nil]];

    return entries;
}

- (NSString *)describeNode:(PRCallNode *)node
{
    if (node == nil)
        return @"";

    PRSymbol *symbol = [node symbol];
    double total = [_root totalWeight];
    NSString *cost = [PRAppearance stringForWeight:[node totalWeight]
                                              unit:_costUnit
                                         frequency:_frequency];
    NSString *selfCost = [PRAppearance stringForWeight:[node selfWeight]
                                                  unit:_costUnit
                                             frequency:_frequency];

    if (symbol == nil)
        return [NSString stringWithFormat:@"%@ - %@ in total",
                [node label], cost];

    return [NSString stringWithFormat:@"%@  -  %@ (%@) inclusive, %@ self  -  %@",
            [symbol displayName], cost,
            [PRAppearance percentOf:[node totalWeight] total:total],
            selfCost, [symbol moduleName]];
}

- (void)mouseMoved:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    PRFlameBox *box = [self boxAtPoint:point];
    PRCallNode *node = box ? box->node : nil;
    if (node == _hoverNode)
        return;

    _hoverNode = node;
    [self setNeedsDisplay:YES];
    if ([[self delegate] respondsToSelector:@selector(flameGraphView:didHoverNode:)])
        [[self delegate] flameGraphView:self didHoverNode:node];
}

- (void)mouseExited:(NSEvent *)event
{
    (void)event;
    _hoverNode = nil;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    PRFlameBox *box = [self boxAtPoint:point];
    if (box == nil)
        return;

    if ([event clickCount] >= 2)
        [self resetZoom];
    else
        [self zoomToNode:box->node];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [self zoomOut];
    (void)event;
}

- (void)keyDown:(NSEvent *)event
{
    NSString *characters = [event charactersIgnoringModifiers];
    if ([characters length] == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [characters characterAtIndex:0];
    if (key == 27) {            /* Escape */
        [self resetZoom];
    } else if (key == NSDeleteCharacter || key == NSBackspaceCharacter ||
               key == NSLeftArrowFunctionKey) {
        [self zoomOut];
    } else {
        [super keyDown:event];
    }
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    PRFlameBox *box = [self boxAtPoint:point];
    if (box == nil)
        return nil;

    _hoverNode = box->node;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Frame"];
    [[menu addItemWithTitle:@"Zoom to This Frame"
                     action:@selector(zoomToHoveredFrame:)
              keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Zoom Out"
                     action:@selector(zoomOutFromMenu:)
              keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Show the Whole Profile"
                     action:@selector(resetZoomFromMenu:)
              keyEquivalent:@""] setTarget:self];
    [menu addItem:[NSMenuItem separatorItem]];
    [[menu addItemWithTitle:@"Copy Function Name"
                     action:@selector(copyHoveredName:)
              keyEquivalent:@""] setTarget:self];
    return menu;
}

- (void)zoomToHoveredFrame:(id)sender
{
    (void)sender;
    [self zoomToNode:_hoverNode];
}

- (void)zoomOutFromMenu:(id)sender
{
    (void)sender;
    [self zoomOut];
}

- (void)resetZoomFromMenu:(id)sender
{
    (void)sender;
    [self resetZoom];
}

- (void)copyHoveredName:(id)sender
{
    (void)sender;
    PRSymbol *symbol = [_hoverNode symbol];
    if (symbol == nil)
        return;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:@[NSStringPboardType] owner:nil];
    [pasteboard setString:[symbol displayName] forType:NSStringPboardType];
}

@end

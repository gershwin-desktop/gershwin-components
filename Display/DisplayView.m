/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayView.h"
#import "DisplayController.h"
#import "DisplayLayout.h"

@implementation DisplayRectView

@synthesize output, label, showsMenuBar, isSelected, isDraggingMenuBar, isMenuBarDropTarget;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        isDragging = NO;
        didMove = NO;
        isDraggingMenuBar = NO;
        showsMenuBar = NO;
        isSelected = NO;
    }
    return self;
}

- (void)dealloc
{
    [output release];
    [label release];
    [super dealloc];
}

- (DisplayView *)arrangementView
{
    NSView *parent = [self superview];
    return [parent isKindOfClass:[DisplayView class]] ? (DisplayView *)parent : nil;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = [self bounds];
    BOOL on = [output enabled];

    /* An output that is connected but off is drawn gray, so it is clear it
     * exists and can be switched on from the resolution pop-up. */
    NSColor *start = on ? [NSColor colorWithCalibratedRed:0.4 green:0.7 blue:0.95 alpha:1.0]
                        : [NSColor colorWithCalibratedWhite:0.75 alpha:1.0];
    NSColor *end = on ? [NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.6 alpha:1.0]
                      : [NSColor colorWithCalibratedWhite:0.55 alpha:1.0];
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:start endingColor:end];
    [gradient drawInRect:bounds angle:45];
    [gradient release];

    if (isSelected) {
        [[NSColor blackColor] setStroke];
        NSBezierPath *selectionBorder = [NSBezierPath bezierPathWithRect:NSInsetRect(bounds, 2.5, 2.5)];
        [selectionBorder setLineWidth:5.0];
        [selectionBorder stroke];
    }

    [[NSColor blackColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:bounds];
    [border setLineWidth:2.0];
    [border stroke];

    if (output) {
        NSString *text = label ? label
                               : ([output monitorName] ? [output monitorName] : [output name]);
        if (!on) text = [text stringByAppendingString:@" (Off)"];
        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSFont systemFontOfSize:12], NSFontAttributeName,
            [NSColor whiteColor], NSForegroundColorAttributeName, nil];
        NSSize textSize = [text sizeWithAttributes:attrs];
        [text drawAtPoint:NSMakePoint((bounds.size.width - textSize.width) / 2,
                                       (bounds.size.height - textSize.height) / 2)
            withAttributes:attrs];
    }

    if ((showsMenuBar && !isDraggingMenuBar) || isMenuBarDropTarget) {
        float menuBarHeight = MIN(18, bounds.size.height * 0.25);
        NSRect menuBarRect = NSMakeRect(2, bounds.size.height - menuBarHeight - 2,
                                        bounds.size.width - 4, menuBarHeight);
        float alpha = isMenuBarDropTarget ? 1.0 : 0.8;
        [[NSColor colorWithCalibratedWhite:0.9 alpha:alpha] setFill];
        [NSBezierPath fillRect:menuBarRect];

        [[NSColor blackColor] setStroke];
        NSBezierPath *menuBarBorder = [NSBezierPath bezierPathWithRect:menuBarRect];
        [menuBarBorder setLineWidth:isMenuBarDropTarget ? 2.0 : 1.0];
        [menuBarBorder stroke];
    }
}

- (void)mouseDown:(NSEvent *)theEvent
{
    NSPoint localPoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    dragOffset = localPoint;
    didMove = NO;
    isDraggingMenuBar = NO;

    /* The top third of the primary is the handle for dragging the menu bar
     * to another display, generous so it is easy to grab. */
    if (showsMenuBar) {
        NSRect bounds = [self bounds];
        float hitHeight = bounds.size.height / 3.0;
        NSRect hitRect = NSMakeRect(0, bounds.size.height - hitHeight, bounds.size.width, hitHeight);
        if ([self mouse:localPoint inRect:hitRect]) isDraggingMenuBar = YES;
    }

    [[[self arrangementView] controller] selectOutput:[output name]];
    isDragging = YES;
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    DisplayView *parent = [self arrangementView];
    if (!isDragging || !output || !parent) return;

    NSPoint parentPoint = [parent convertPoint:[theEvent locationInWindow] fromView:nil];

    if (isDraggingMenuBar) {
        for (DisplayRectView *rect in [parent displayRects]) {
            BOOL over = (rect != self && [[rect output] enabled]
                         && [parent mouse:parentPoint inRect:[rect frame]]);
            if ([rect isMenuBarDropTarget] != over) {
                [rect setIsMenuBarDropTarget:over];
                [rect setNeedsDisplay:YES];
            }
        }
        [self setNeedsDisplay:YES];
        return;
    }

    /* A display that is off has no place in the arrangement yet. */
    if (![output enabled]) return;

    NSRect superBounds = [parent bounds];
    NSRect frame = [self frame];
    NSPoint newOrigin = NSMakePoint(parentPoint.x - dragOffset.x, parentPoint.y - dragOffset.y);
    float margin = 10.0;
    newOrigin.x = MAX(-frame.size.width + margin, MIN(newOrigin.x, superBounds.size.width - margin));
    newOrigin.y = MAX(-frame.size.height + margin, MIN(newOrigin.y, superBounds.size.height - margin));

    /* Only the view moves while dragging; the layout changes on drop. */
    [self setFrameOrigin:newOrigin];
    didMove = YES;
    [parent setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (!isDragging) return;
    BOOL wasDraggingMenuBar = isDraggingMenuBar;
    isDragging = NO;
    isDraggingMenuBar = NO;

    DisplayView *parent = [self arrangementView];
    if (!parent) return;
    DisplayController *controller = [parent controller];

    if (wasDraggingMenuBar) {
        NSPoint parentPoint = [parent convertPoint:[theEvent locationInWindow] fromView:nil];
        DisplayRectView *target = nil;
        for (DisplayRectView *rect in [parent displayRects]) {
            if ([rect isMenuBarDropTarget]) {
                [rect setIsMenuBarDropTarget:NO];
                [rect setNeedsDisplay:YES];
            }
            if (rect != self && [[rect output] enabled]
                && [parent mouse:parentPoint inRect:[rect frame]]) {
                target = rect;
            }
        }
        [self setNeedsDisplay:YES];
        if (target) [controller setPrimaryOutput:[[target output] name]];
    } else if (didMove) {
        [controller moveOutput:[output name] toViewRect:[self frame]];
    }
    [parent setNeedsDisplay:YES];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Display Options"];
    NSMenuItem *makePrimaryItem = [[NSMenuItem alloc] initWithTitle:@"Use as Main Display"
                                                             action:@selector(makePrimary:)
                                                      keyEquivalent:@""];
    [makePrimaryItem setTarget:self];
    if ([output primary]) [makePrimaryItem setTitle:@"Main Display"];
    [contextMenu addItem:makePrimaryItem];
    [makePrimaryItem release];

    [NSMenu popUpContextMenu:contextMenu withEvent:theEvent forView:self];
    [contextMenu release];
}

/* The menu auto-enables its items through this. */
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    return [output enabled] && ![output primary];
}

- (void)makePrimary:(id)sender
{
    [[[self arrangementView] controller] setPrimaryOutput:[output name]];
}

@end

@implementation DisplayView

@synthesize controller;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        displayRects = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [displayRects release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
    [NSBezierPath fillRect:[self bounds]];

    [[NSColor grayColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:[self bounds]];
    [border setLineWidth:1.0];
    [border stroke];
}

- (void)setFrameSize:(NSSize)newSize
{
    BOOL changed = !NSEqualSizes(newSize, [self frame].size);
    [super setFrameSize:newSize];
    /* The mapping depends on the view size. */
    if (changed && [displayRects count] > 0) [self updateDisplayRects];
}

- (DisplayViewMapping)mapping
{
    return mapping;
}

- (void)updateDisplayRects
{
    for (DisplayRectView *rectView in displayRects) {
        [rectView removeFromSuperview];
    }
    [displayRects removeAllObjects];

    DisplayLayout *layout = [controller layout];
    if ([[layout outputs] count] == 0) return;

    /* Outputs that are off have no place on the screen; show them in a row
     * right of the arrangement at their native size. */
    NSRect arrangement = [layout boundingRect];
    NSMutableDictionary *modelRects = [NSMutableDictionary dictionary];
    CGFloat offX = NSMaxX(arrangement);
    for (DisplayOutput *o in [layout outputs]) {
        NSRect r;
        if ([o enabled]) {
            r = [o frame];
        } else {
            DisplayMode *pm = [o preferredMode];
            r = NSMakeRect(offX, NSMinY(arrangement), [pm width], [pm height]);
            offX += [pm width];
        }
        [modelRects setObject:[NSValue valueWithRect:r] forKey:[o name]];
    }
    NSRect modelBounds = NSZeroRect;
    for (NSValue *v in [modelRects allValues]) {
        modelBounds = NSIsEmptyRect(modelBounds) ? [v rectValue]
                                                 : NSUnionRect(modelBounds, [v rectValue]);
    }
    mapping = DisplayViewMappingMake(modelBounds, [self bounds], 10.0, 0.25);

    /* Mirrored outputs cover the same rectangle: the primary goes on top,
     * carrying the names of all of them. */
    BOOL mirrored = [layout isMirrored];
    NSMutableArray *order = [NSMutableArray arrayWithArray:[layout outputs]];
    NSString *mirrorLabel = nil;
    if (mirrored && [layout primaryOutput]) {
        [order removeObject:[layout primaryOutput]];
        [order addObject:[layout primaryOutput]];
        NSMutableArray *names = [NSMutableArray array];
        for (DisplayOutput *o in [layout enabledOutputs]) {
            [names addObject:[o monitorName] ? [o monitorName] : [o name]];
        }
        mirrorLabel = [names componentsJoinedByString:@" + "];
    }

    NSString *selected = [controller selectedOutputName];
    for (DisplayOutput *o in order) {
        NSRect viewRect = DisplayViewRectForModelRect(
            [[modelRects objectForKey:[o name]] rectValue], mapping);
        DisplayRectView *rectView = [[DisplayRectView alloc] initWithFrame:viewRect];
        [rectView setOutput:o];
        if (mirrored && [o primary]) [rectView setLabel:mirrorLabel];
        [rectView setShowsMenuBar:[o primary]];
        [rectView setIsSelected:[[o name] isEqualToString:selected]];
        [self addSubview:rectView];
        [displayRects addObject:rectView];
        [rectView release];
    }
    [self setNeedsDisplay:YES];
}

- (NSArray *)displayRects
{
    return displayRects;
}

@end

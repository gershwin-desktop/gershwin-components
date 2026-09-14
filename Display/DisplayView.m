/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayView.h"
#import "DisplayController.h"

@implementation DisplayRectView

@synthesize displayInfo, showsMenuBar, isSelected, isDraggingMenuBar, isMenuBarDropTarget, menuBarDragPoint;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        isDragging = NO;
        isDraggingMenuBar = NO;
        showsMenuBar = NO;
        isSelected = NO;
    }
    return self;
}

- (void)dealloc
{
    [displayInfo release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw the display rectangle
    NSRect bounds = [self bounds];
    
    // Background color
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.4 green:0.7 blue:0.95 alpha:1.0]
                                                         endingColor:[NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.6 alpha:1.0]];
    [gradient drawInRect:bounds angle:45];
    [gradient release];
    
    // Selection border (thick black border when selected)
    if (isSelected) {
        [[NSColor blackColor] setStroke];
        NSBezierPath *selectionBorder = [NSBezierPath bezierPathWithRect:NSInsetRect(bounds, 2.5, 2.5)];
        [selectionBorder setLineWidth:5.0];
        [selectionBorder stroke];
    }
    
    // Regular border
    [[NSColor blackColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:bounds];
    [border setLineWidth:2.0];
    [border stroke];
    
    // Display name
    if (displayInfo) {
        NSString *displayName = [displayInfo name];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        
        NSSize textSize = [displayName sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint((bounds.size.width - textSize.width) / 2,
                                       (bounds.size.height - textSize.height) / 2);
        [displayName drawAtPoint:textPoint withAttributes:attrs];
    }
    
    // Menu bar representation (hide while being dragged)
    if ((showsMenuBar && !isDraggingMenuBar) || isMenuBarDropTarget) {
        float menuBarHeight = MIN(18, bounds.size.height * 0.25);
        NSRect menuBarRect = NSMakeRect(2, bounds.size.height - menuBarHeight - 2, bounds.size.width - 4, menuBarHeight);
        // Brighter highlight when this is the drop target
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
    isDragging = NO;
    isDraggingMenuBar = NO;

    // Check if the click is on the top portion of this (primary) display.
    // Use a generous hit area (top third) so the menu bar is easy to grab.
    if (showsMenuBar) {
        NSRect bounds = [self bounds];
        float hitHeight = bounds.size.height / 3.0;
        NSRect hitRect = NSMakeRect(0, bounds.size.height - hitHeight, bounds.size.width, hitHeight);
        if (NSPointInRect(localPoint, hitRect)) {
            isDraggingMenuBar = YES;
        }
    }

    // Notify the parent view (DisplayView) that this display was clicked
    NSView *parentView = [self superview];
    if ([parentView isKindOfClass:[DisplayView class]]) {
        DisplayView *displayView = (DisplayView *)parentView;
        DisplayController *controller = [displayView controller];

        if (controller && [controller respondsToSelector:@selector(selectDisplay:)] && displayInfo) {
            // Select this display
            [controller selectDisplay:displayInfo];

            // Update all display rect views to show/hide selection
            NSArray *allRectViews = [displayView displayRects];
            for (DisplayRectView *rectView in allRectViews) {
                [rectView setIsSelected:(rectView == self)];
                [rectView setNeedsDisplay:YES];
            }
        }
    }

    // Set up for potential dragging on next mouse move
    isDragging = YES;
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    if (!isDragging || !displayInfo) return;

    NSPoint windowPoint = [theEvent locationInWindow];
    if (![[self superview] respondsToSelector:@selector(convertPoint:fromView:)]) {
        return;
    }

    NSPoint parentPoint = [[self superview] convertPoint:windowPoint fromView:nil];

    // When dragging the menu bar, don't move the display rect -
    // highlight whichever display the cursor is over as the drop target.
    if (isDraggingMenuBar) {
        menuBarDragPoint = parentPoint;
        NSView *parent = [self superview];
        if (parent && [parent isKindOfClass:[DisplayView class]]) {
            NSArray *siblings = [(DisplayView *)parent displayRects];
            for (DisplayRectView *rect in siblings) {
                BOOL over = (rect != self && NSPointInRect(parentPoint, [rect frame]));
                if ([rect isMenuBarDropTarget] != over) {
                    [rect setIsMenuBarDropTarget:over];
                    [rect setNeedsDisplay:YES];
                }
            }
        }
        [self setNeedsDisplay:YES];
        return;
    }

    NSPoint newOrigin = NSMakePoint(parentPoint.x - dragOffset.x, parentPoint.y - dragOffset.y);

    // Keep within superview bounds with safety margins
    NSView *superview = [self superview];
    if (!superview) return;

    NSRect superBounds = [superview bounds];
    NSRect frame = [self frame];

    // Add safety margins to prevent going completely off-screen
    float margin = 10.0;
    newOrigin.x = MAX(-frame.size.width + margin, MIN(newOrigin.x, superBounds.size.width - margin));
    newOrigin.y = MAX(-frame.size.height + margin, MIN(newOrigin.y, superBounds.size.height - margin));

    [self setFrameOrigin:newOrigin];

    // Update the display info with scaled coordinates
    NSRect newFrame = [displayInfo frame];
    newFrame.origin = newOrigin;
    [displayInfo setFrame:newFrame];

    // Mark superview as needing redisplay
    [superview setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (!isDragging) return;

    BOOL wasDraggingMenuBar = isDraggingMenuBar;
    isDragging = NO;
    isDraggingMenuBar = NO;

    NSView *parentView = [self superview];
    if (!parentView || ![parentView isKindOfClass:[DisplayView class]]) {
        return;
    }

    DisplayView *displayView = (DisplayView *)parentView;

    if (wasDraggingMenuBar) {
        // Menu bar drag: find which display the cursor is over (excluding self)
        NSPoint windowPoint = [theEvent locationInWindow];
        NSPoint parentPoint = [parentView convertPoint:windowPoint fromView:nil];

        // Clear all drop target highlights
        NSArray *allRectViews = [displayView displayRects];
        for (DisplayRectView *rectView in allRectViews) {
            if ([rectView isMenuBarDropTarget]) {
                [rectView setIsMenuBarDropTarget:NO];
                [rectView setNeedsDisplay:YES];
            }
        }

        DisplayRectView *targetView = nil;
        for (DisplayRectView *rectView in allRectViews) {
            if (rectView != self && NSPointInRect(parentPoint, [rectView frame])) {
                targetView = rectView;
                break;
            }
        }

        if (targetView && [targetView displayInfo] && displayInfo) {
            // Transfer primary status (menu bar) to the target display
            [self setShowsMenuBar:NO];
            [targetView setShowsMenuBar:YES];

            // Update display info
            [displayInfo setIsPrimary:NO];
            [[targetView displayInfo] setIsPrimary:YES];

            // Apply changes via controller (setPrimaryDisplay runs xrandr --primary,
            // applyDisplayConfiguration applies the full layout including --primary,
            // and updateSaveButtonState enables the Save Settings button)
            DisplayController *controller = [displayView controller];
            if (controller) {
                if ([controller respondsToSelector:@selector(setPrimaryDisplay:)]) {
                    [controller setPrimaryDisplay:[targetView displayInfo]];
                }
                if ([controller respondsToSelector:@selector(applyDisplayConfiguration)]) {
                    [controller applyDisplayConfiguration];
                }
                if ([controller respondsToSelector:@selector(updateSaveButtonState)]) {
                    [controller updateSaveButtonState];
                }
            }
        }
    } else {
        // Display arrangement drag: apply the new position
        DisplayController *controller = [displayView controller];
        if (controller) {
            if ([controller respondsToSelector:@selector(applyDisplayConfiguration)]) {
                [controller applyDisplayConfiguration];
            }
            if ([controller respondsToSelector:@selector(updateSaveButtonState)]) {
                [controller updateSaveButtonState];
            }
        }
    }

    [parentView setNeedsDisplay:YES];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
    // Create and show context menu for the display
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Display Options"];
    
    // Add "Use as Main Display" option (matches macOS terminology)
    NSMenuItem *makePrimaryItem = [[NSMenuItem alloc] initWithTitle:@"Use as Main Display" 
                                                             action:@selector(makePrimary:) 
                                                      keyEquivalent:@""];
    [makePrimaryItem setTarget:self];
    [makePrimaryItem setRepresentedObject:displayInfo];
    
    // Disable the option if this display is already primary
    if (displayInfo && [displayInfo isPrimary]) {
        [makePrimaryItem setEnabled:NO];
        [makePrimaryItem setTitle:@"Main Display"]; // Show current status
    }
    
    [contextMenu addItem:makePrimaryItem];
    [makePrimaryItem release];
    
    // Show the context menu
    [NSMenu popUpContextMenu:contextMenu withEvent:theEvent forView:self];
    [contextMenu release];
}

- (void)makePrimary:(id)sender
{
    NSMenuItem *item = (NSMenuItem *)sender;
    DisplayInfo *targetDisplay = [item representedObject];
    
    if (!targetDisplay) return;
    
    NSDebugLog(@"DisplayRectView: Making display %@ primary via context menu", [targetDisplay name]);
    
    // Find the parent view and controller
    NSView *parentView = [self superview];
    if (parentView && [parentView isKindOfClass:[DisplayView class]]) {
        DisplayView *displayView = (DisplayView *)parentView;
        DisplayController *controller = [displayView controller];
        
        if (controller) {
            if ([controller respondsToSelector:@selector(setPrimaryDisplay:)]) {
                [controller setPrimaryDisplay:targetDisplay];
            }
            if ([controller respondsToSelector:@selector(applyDisplayConfiguration)]) {
                [controller applyDisplayConfiguration];
            }
            if ([controller respondsToSelector:@selector(updateSaveButtonState)]) {
                [controller updateSaveButtonState];
            }

            // Update the visual state of all display rectangles
            NSArray *allRectViews = [displayView displayRects];
            for (DisplayRectView *rectView in allRectViews) {
                [rectView setShowsMenuBar:([rectView displayInfo] == targetDisplay)];
                [rectView setNeedsDisplay:YES];
            }
        }
    }
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
    // Draw background
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
    [NSBezierPath fillRect:[self bounds]];

    // Draw border
    [[NSColor grayColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:[self bounds]];
    [border setLineWidth:1.0];
    [border stroke];
}

- (void)updateDisplayRects
{
    // Remove existing display rect views
    for (DisplayRectView *rectView in displayRects) {
        [rectView removeFromSuperview];
    }
    [displayRects removeAllObjects];
    
    if (!controller) {
        NSDebugLog(@"DisplayView: No controller available for updateDisplayRects");
        return;
    }
    
    NSArray *displays = nil;
    if ([controller respondsToSelector:@selector(displays)]) {
        displays = [controller displays];
    }
    
    if (!displays || [displays count] == 0) {
        NSDebugLog(@"DisplayView: No displays available");
        return;
    }
    
    NSDebugLog(@"DisplayView: Updating display rects for %lu displays", (unsigned long)[displays count]);
    
    // Ensure at least one display is primary
    BOOL hasPrimary = NO;
    for (DisplayInfo *display in displays) {
        if ([display isPrimary]) {
            hasPrimary = YES;
            break;
        }
    }
    
    // If no primary display, make the first one primary
    if (!hasPrimary && [displays count] > 0) {
        DisplayInfo *firstDisplay = [displays objectAtIndex:0];
        [firstDisplay setIsPrimary:YES];
        NSDebugLog(@"DisplayView: Auto-setting first display as primary: %@", [firstDisplay name]);
    }
    
    // Calculate scaling factor to fit displays in view
    NSRect bounds = [self bounds];
    NSRect totalBounds = NSZeroRect;
    
    NSDebugLog(@"DisplayView: View bounds: %@", NSStringFromRect(bounds));
    
    for (DisplayInfo *display in displays) {
        NSRect displayFrame = [display frame];
        NSDebugLog(@"DisplayView: Display %@ frame: %@", [display name], NSStringFromRect(displayFrame));
        
        if (NSIsEmptyRect(totalBounds)) {
            totalBounds = displayFrame;
        } else {
            totalBounds = NSUnionRect(totalBounds, displayFrame);
        }
    }
    
    NSDebugLog(@"DisplayView: Total bounds: %@", NSStringFromRect(totalBounds));
    
    if (NSIsEmptyRect(totalBounds) || totalBounds.size.width <= 0 || totalBounds.size.height <= 0) {
        NSDebugLog(@"DisplayView: Invalid total bounds, using default single display layout");
        // Handle single display or invalid bounds case
        if ([displays count] == 1) {
            DisplayInfo *display = [displays objectAtIndex:0];
            // Give it a reasonable default size if it doesn't have one
            if ([display frame].size.width <= 0 || [display frame].size.height <= 0) {
                [display setFrame:NSMakeRect(0, 0, 1920, 1080)];
                [display setResolution:NSMakeSize(1920, 1080)];
                NSDebugLog(@"DisplayView: Set default frame for display %@", [display name]);
            }
            totalBounds = [display frame];
        } else {
            NSDebugLog(@"DisplayView: Cannot display - no valid bounds");
            return;
        }
    }
    
    // Use smaller margins for the compact layout
    float margin = 10.0;
    float availableWidth = bounds.size.width - (2 * margin);
    float availableHeight = bounds.size.height - (2 * margin);
    
    // Ensure we have positive available space
    if (availableWidth <= 0) availableWidth = bounds.size.width * 0.8;
    if (availableHeight <= 0) availableHeight = bounds.size.height * 0.8;
    
    // Calculate scale to fit all displays with margin
    float scaleX = availableWidth / totalBounds.size.width;
    float scaleY = availableHeight / totalBounds.size.height;
    float scale = MIN(scaleX, scaleY);
    
    // For the smaller display area, use tighter scale bounds
    scale = MIN(scale, 0.25); // Smaller maximum scale for compact view
    scale = MAX(scale, 0.05); // Ensure they're still visible
    
    NSDebugLog(@"DisplayView: Scaling displays by factor: %f (bounds: %@, totalBounds: %@)", 
          scale, NSStringFromRect(bounds), NSStringFromRect(totalBounds));
    
    DisplayInfo *selectedDisplayInfo = nil;
    if ([controller respondsToSelector:@selector(selectedDisplay)]) {
        selectedDisplayInfo = [controller selectedDisplay];
        NSDebugLog(@"DisplayView: Current selected display: %@", selectedDisplayInfo ? [selectedDisplayInfo name] : @"none");
    }
    
    // Calculate the scaled total bounds for centering
    float scaledTotalWidth = totalBounds.size.width * scale;
    float scaledTotalHeight = totalBounds.size.height * scale;
    
    // Center the display arrangement in the view
    float offsetX = (bounds.size.width - scaledTotalWidth) / 2.0;
    float offsetY = (bounds.size.height - scaledTotalHeight) / 2.0;
    
    NSDebugLog(@"DisplayView: Centering displays with offset: (%f, %f)", offsetX, offsetY);
    
    // Create display rect views
    for (DisplayInfo *display in displays) {
        NSRect displayFrame = [display frame];
        
        // Scale and position the rectangle relative to total bounds, then center
        float scaledX = (displayFrame.origin.x - totalBounds.origin.x) * scale;
        float scaledY = (displayFrame.origin.y - totalBounds.origin.y) * scale;
        float scaledWidth = displayFrame.size.width * scale;
        float scaledHeight = displayFrame.size.height * scale;
        
        NSRect scaledFrame = NSMakeRect(
            offsetX + scaledX,
            offsetY + scaledY, 
            scaledWidth,
            scaledHeight
        );
        
        // Ensure minimum size for visibility and usability in the compact view
        if (scaledFrame.size.width < 50) {
            float centerX = NSMidX(scaledFrame);
            scaledFrame.size.width = 50;
            scaledFrame.origin.x = centerX - 25;
        }
        if (scaledFrame.size.height < 35) {
            float centerY = NSMidY(scaledFrame);
            scaledFrame.size.height = 35;
            scaledFrame.origin.y = centerY - 17.5;
        }
        
        NSDebugLog(@"DisplayView: Creating display rect for %@ at %@ (original: %@)", 
              [display name], NSStringFromRect(scaledFrame), NSStringFromRect(displayFrame));
        
        // Verify the rectangle is within the bounds
        if (!NSContainsRect(bounds, scaledFrame)) {
            NSDebugLog(@"DisplayView: WARNING - Display rectangle extends outside bounds!");
            NSDebugLog(@"  Bounds: %@", NSStringFromRect(bounds));
            NSDebugLog(@"  Display rect: %@", NSStringFromRect(scaledFrame));
        }
        
        DisplayRectView *rectView = [[DisplayRectView alloc] initWithFrame:scaledFrame];
        [rectView setDisplayInfo:display];
        [rectView setShowsMenuBar:[display isPrimary]]; // Always show menu bar for primary display
        
        // Set selection state - preserve existing selection if possible
        BOOL shouldBeSelected = NO;
        if (selectedDisplayInfo && selectedDisplayInfo == display) {
            // Keep the previously selected display selected
            shouldBeSelected = YES;
            NSDebugLog(@"DisplayView: Preserving selection for display: %@", [display name]);
        } else if (!selectedDisplayInfo && [display isPrimary]) {
            // Default to selecting the primary display only if no selection exists
            shouldBeSelected = YES;
            if (controller && [controller respondsToSelector:@selector(selectDisplay:)]) {
                [controller selectDisplay:display];
                NSDebugLog(@"DisplayView: Auto-selecting primary display: %@", [display name]);
            }
        }
        
        [rectView setIsSelected:shouldBeSelected];
        
        [self addSubview:rectView];
        [displayRects addObject:rectView];
        [rectView release];
    }
}

- (DisplayRectView *)displayRectAtPoint:(NSPoint)point
{
    for (DisplayRectView *rectView in displayRects) {
        if (NSPointInRect(point, [rectView frame])) {
            return rectView;
        }
    }
    return nil;
}

- (void)setNeedsDisplay:(BOOL)flag
{
    [super setNeedsDisplay:flag];
    // Do NOT call updateDisplayRects here - setNeedsDisplay: is called
    // frequently by the view system (adding to window, resizing, etc.)
    // and updateDisplayRects removes/adds subviews which can re-enter
    // this method and crash.  Call updateDisplayRects explicitly when
    // the display data actually changes.
}

- (NSArray *)displayRects
{
    return displayRects;
}

@end

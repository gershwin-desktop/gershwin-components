/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppDelegate.h"

@interface AppDelegate ()
@property (strong) NSWindow *window;
@property (strong) ItemFlowView *flowView;
@property (strong) NSArray *images;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSRect frame = NSMakeRect(100, 100, 800, 500);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    /* Owned by ARC through this reference; if it were also released on
     * close, -close would release it a second time. */
    [self.window setReleasedWhenClosed:NO];
    [self.window setTitle:@"ItemFlow Demo"];
    
    self.flowView = [[ItemFlowView alloc] initWithFrame:[[self.window contentView] bounds]];
    [self.flowView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.flowView setDataSource:self];
    [self.flowView setDelegate:self];
    
    [[self.window contentView] addSubview:self.flowView];
    
    [self generateImages];
    [self.flowView reloadData];
    
    [self.window makeKeyAndOrderFront:nil];
}

- (void)generateImages {
    NSMutableArray *imgs = [NSMutableArray array];
    NSArray *colors = @[[NSColor redColor], [NSColor blueColor], [NSColor greenColor], 
                        [NSColor yellowColor], [NSColor purpleColor], [NSColor orangeColor],
                        [NSColor cyanColor], [NSColor magentaColor], [NSColor brownColor], [NSColor grayColor]];
                        
    for (int i = 0; i < 20; i++) {
        NSColor *color = colors[i % colors.count];
        NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(200, 200)];
        [img lockFocus];
        [color setFill];
        NSRectFill(NSMakeRect(0, 0, 200, 200));
        
        NSDictionary *attrs = @{NSForegroundColorAttributeName: [NSColor whiteColor],
                                NSFontAttributeName: [NSFont boldSystemFontOfSize:48]};
        NSString *str = [NSString stringWithFormat:@"%d", i];
        NSSize strSize = [str sizeWithAttributes:attrs];
        [str drawAtPoint:NSMakePoint((200 - strSize.width)/2, (200 - strSize.height)/2) withAttributes:attrs];
        
        [img unlockFocus];
        [imgs addObject:img];
    }
    self.images = imgs;
}

- (NSUInteger)numberOfItemsInItemFlowView:(ItemFlowView *)view {
    return self.images.count;
}

- (NSImage *)itemFlowView:(ItemFlowView *)view imageAtIndex:(NSUInteger)index {
    return self.images[index];
}

- (void)itemFlowView:(ItemFlowView *)view didSelectItemAtIndex:(NSUInteger)index {
    NSDebugLLog(@"gwcomp", @"Selected index: %lu", (unsigned long)index);
    [self.window setTitle:[NSString stringWithFormat:@"ItemFlow Demo - Selected: %lu", (unsigned long)index]];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

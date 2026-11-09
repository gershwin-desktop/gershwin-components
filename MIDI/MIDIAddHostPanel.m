/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDIAddHostPanel.h"
#import "MIDIPaneViewState.h"
#import "MIDINetworkState.h"
#import "AppearanceMetrics.h"

static const CGFloat kFieldWidth = 220.0;

@implementation MIDIAddHostPanel
{
    NSPanel *_panel;
    NSTextField *_nameField;
    NSTextField *_addressField;
    NSTextField *_portField;
}

static NSTextField *Label(NSString *text)
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setStringValue:text];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setAlignment:NSRightTextAlignment];
    [label sizeToFit];
    return label;
}

- (void)buildPanel
{
    NSArray *titles = @[ MIDIPaneLocalized(@"Name:"), MIDIPaneLocalized(@"Address:"), MIDIPaneLocalized(@"Port:") ];
    NSMutableArray *labels = [NSMutableArray array];
    CGFloat labelW = 0;
    for (NSString *t in titles) {
        NSTextField *l = Label(t);
        labelW = MAX(labelW, NSWidth([l frame]));
        [labels addObject:l];
    }
    CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat contentW = METRICS_CONTENT_SIDE_MARGIN * 2 + labelW + METRICS_SPACE_8 + kFieldWidth;
    CGFloat contentH = METRICS_CONTENT_TOP_MARGIN + 3 * rowH + 2 * METRICS_SPACE_8
                     + METRICS_SPACE_20 + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;

    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, contentW, contentH)
                                        styleMask:NSTitledWindowMask
                                          backing:NSBackingStoreBuffered defer:NO];
    [_panel setTitle:MIDIPaneLocalized(@"Add Host")];
    NSView *content = [_panel contentView];

    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _addressField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _portField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [_portField setStringValue:[NSString stringWithFormat:@"%d", MIDINETWORK_DEFAULT_PORT]];
    NSArray *fields = @[ _nameField, _addressField, _portField ];

    CGFloat y = contentH - METRICS_CONTENT_TOP_MARGIN - rowH;
    NSUInteger i;
    for (i = 0; i < 3; i++) {
        NSTextField *l = [labels objectAtIndex:i];
        NSRect lf = [l frame];
        [l setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, y + floor((rowH - NSHeight(lf)) / 2), labelW, NSHeight(lf))];
        [content addSubview:l];
        NSTextField *f = [fields objectAtIndex:i];
        CGFloat w = (f == _portField) ? 80.0 : kFieldWidth;
        [f setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN + labelW + METRICS_SPACE_8, y, w, rowH)];
        [content addSubview:f];
        y -= rowH + METRICS_SPACE_8;
    }
    [_nameField setNextKeyView:_addressField];
    [_addressField setNextKeyView:_portField];
    [_portField setNextKeyView:_nameField];

    NSButton *add = [self buttonWithTitle:MIDIPaneLocalized(@"Add") action:@selector(add:)];
    NSButton *cancel = [self buttonWithTitle:MIDIPaneLocalized(@"Cancel") action:@selector(cancel:)];
    [add setKeyEquivalent:@"\r"];
    [cancel setKeyEquivalent:@"\e"];
    CGFloat bw = MAX(METRICS_BUTTON_MIN_WIDTH, MAX(NSWidth([add frame]), NSWidth([cancel frame])));
    CGFloat bx = contentW - METRICS_CONTENT_SIDE_MARGIN - bw;
    [add setFrame:NSMakeRect(bx, METRICS_CONTENT_BOTTOM_MARGIN, bw, METRICS_BUTTON_HEIGHT)];
    bx -= METRICS_BUTTON_HORIZ_INTERSPACE + bw;
    [cancel setFrame:NSMakeRect(bx, METRICS_CONTENT_BOTTOM_MARGIN, bw, METRICS_BUTTON_HEIGHT)];
    [content addSubview:add];
    [content addSubview:cancel];
    [_panel setInitialFirstResponder:_nameField];
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    [b setTitle:title];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setTarget:self];
    [b setAction:action];
    [b sizeToFit];
    return b;
}

- (void)add:(id)sender
{
    [NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)cancel:(id)sender
{
    [NSApp stopModalWithCode:NSModalResponseCancel];
}

- (MIDINetworkHost *)runModal
{
    if (_panel == nil) {
        [self buildPanel];
    }
    [_panel center];
    NSInteger result = [NSApp runModalForWindow:_panel];
    [_panel orderOut:nil];
    if (result != NSModalResponseOK) {
        return nil;
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return [MIDINetworkHost manualHostWithName:[[_nameField stringValue] stringByTrimmingCharactersInSet:ws]
                                       address:[[_addressField stringValue] stringByTrimmingCharactersInSet:ws]
                                          port:(NSUInteger)MAX(0, [_portField integerValue])];
}

@end

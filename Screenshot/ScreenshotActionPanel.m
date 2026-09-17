/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenshotActionPanel.h"
#import "AppearanceMetrics.h"

/* Height of a one-line label in the 13pt system font without clipping. */
static const CGFloat kLabelHeight = 17.0;

/* Horizontal room the button bezel needs around its title. */
static const CGFloat kButtonTitlePadding = 24.0;

@implementation ScreenshotActionPanel

- (ScreenshotAction)runModal
{
    [self center];
    [self makeFirstResponder:[self initialFirstResponder]];
    ScreenshotAction action = (ScreenshotAction)[NSApp runModalForWindow:self];
    [self orderOut:nil];
    return action;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(ScreenshotAction)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    [button setTitle:title];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTag:action];
    [button setTarget:self];
    [button setAction:@selector(chooseAction:)];
    return [button autorelease];
}

- (NSTextField *)labelWithString:(NSString *)string font:(NSFont *)font
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setStringValue:string];
    [label setFont:font];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    return [label autorelease];
}

- (id)init
{
    // Right to left, as laid out: default action at the trailing edge
    NSArray *titles = [NSArray arrayWithObjects:
        NSLocalizedString(@"Save to File", @""),
        NSLocalizedString(@"Cancel", @""),
        NSLocalizedString(@"Copy to Clipboard", @""),
        NSLocalizedString(@"Copy Text (OCR)", @""),
        nil];
    const ScreenshotAction actions[] = {
        ScreenshotActionSave, ScreenshotActionCancel,
        ScreenshotActionCopy, ScreenshotActionRecognizeText
    };

    // Equal widths like the theme's alert panels
    NSFont *buttonFont = METRICS_FONT_SYSTEM_REGULAR_13;
    CGFloat buttonWidth = METRICS_BUTTON_MIN_WIDTH;
    for (NSString *title in titles)
        buttonWidth = MAX(buttonWidth, ceil([buttonFont widthOfString:title] + kButtonTitlePadding));
    NSUInteger count = [titles count];
    CGFloat buttonsWidth = count * buttonWidth + (count - 1) * METRICS_BUTTON_HORIZ_INTERSPACE;
    CGFloat width = MAX(METRICS_WIN_MIN_WIDTH, buttonsWidth + 2 * METRICS_CONTENT_SIDE_MARGIN);
    CGFloat buttonArea = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_CONTENT_BOTTOM_MARGIN;
    CGFloat textHeight = METRICS_CONTENT_TOP_MARGIN + kLabelHeight + METRICS_TITLE_MESSAGE_GAP + kLabelHeight;
    CGFloat iconHeight = METRICS_ICON_TOP + METRICS_ICON_SIDE;
    CGFloat height = MAX(textHeight, iconHeight) + buttonArea;

    self = [super initWithContentRect:NSMakeRect(0, 0, width, height)
                            styleMask:NSTitledWindowMask
                              backing:NSBackingStoreBuffered
                                defer:YES];
    if (!self)
        return nil;
    [self setTitle:@""];
    [self setReleasedWhenClosed:NO];
    [self setHidesOnDeactivate:NO];
    NSView *content = [self contentView];

    NSImageView *icon = [[[NSImageView alloc] initWithFrame:
        NSMakeRect(METRICS_ICON_LEFT, height - METRICS_ICON_TOP - METRICS_ICON_SIDE,
                   METRICS_ICON_SIDE, METRICS_ICON_SIDE)] autorelease];
    [icon setImage:[NSApp applicationIconImage]];
    [icon setImageScaling:NSScaleProportionally];
    [icon setEditable:NO];
    [content addSubview:icon];

    CGFloat textWidth = width - METRICS_TEXT_LEFT - METRICS_CONTENT_SIDE_MARGIN;
    CGFloat y = height - METRICS_CONTENT_TOP_MARGIN - kLabelHeight;
    NSTextField *title = [self labelWithString:NSLocalizedString(@"Screenshot Captured", @"")
                                          font:METRICS_FONT_SYSTEM_BOLD_13];
    [title setFrame:NSMakeRect(METRICS_TEXT_LEFT, y, textWidth, kLabelHeight)];
    [content addSubview:title];

    y -= METRICS_TITLE_MESSAGE_GAP + kLabelHeight;
    NSTextField *message = [self labelWithString:NSLocalizedString(@"What would you like to do with the screenshot?", @"")
                                            font:METRICS_FONT_SYSTEM_REGULAR_13];
    [message setFrame:NSMakeRect(METRICS_TEXT_LEFT, y, textWidth, kLabelHeight)];
    [content addSubview:message];

    CGFloat x = width - METRICS_CONTENT_SIDE_MARGIN - buttonWidth;
    for (NSUInteger i = 0; i < count; i++) {
        NSButton *button = [self buttonWithTitle:[titles objectAtIndex:i] action:actions[i]];
        [button setFont:buttonFont];
        [button setFrame:NSMakeRect(x, METRICS_CONTENT_BOTTOM_MARGIN,
                                    buttonWidth, METRICS_BUTTON_HEIGHT)];
        [content addSubview:button];
        x -= buttonWidth + METRICS_BUTTON_HORIZ_INTERSPACE;

        if (actions[i] == ScreenshotActionSave) {
            [button setKeyEquivalent:@"\r"];
            [self setDefaultButtonCell:[button cell]];
            [self setInitialFirstResponder:button];
        } else if (actions[i] == ScreenshotActionCancel) {
            [button setKeyEquivalent:@"\e"];
        }
    }
    return self;
}

- (void)chooseAction:(id)sender
{
    [NSApp stopModalWithCode:[sender tag]];
}

@end

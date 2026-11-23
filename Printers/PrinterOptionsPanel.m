/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PrinterOptionsPanel.h"
#import "PrintersController.h"
#import "PrinterSupplies.h"
#import "AppearanceMetrics.h"
#include <cups/cups.h>
#include <cups/ppd.h>
#include <unistd.h>

static const CGFloat kWindowWidth = 520.0;
static const CGFloat kWindowHeight = 440.0;
static const CGFloat kRowHeight = 22.0;
static const CGFloat kRowGap = 12.0;
static const CGFloat kLabelWidth = 110.0;
static const CGFloat kInset = 16.0;

#pragma mark - Small views

/* Top-down layout is much easier to write in a flipped view. */
@interface POFlippedView : NSView
@end

@implementation POFlippedView
- (BOOL)isFlipped
{
    return YES;
}
@end

/* The color chip in front of a supply. */
@interface POSwatchView : NSView
{
    NSColor *color;
}
- (id)initWithFrame:(NSRect)frame color:(NSColor *)aColor;
@end

@implementation POSwatchView
- (id)initWithFrame:(NSRect)frame color:(NSColor *)aColor
{
    self = [super initWithFrame:frame];
    if (self) {
        color = [aColor retain];
    }
    return self;
}

- (void)dealloc
{
    [color release];
    [super dealloc];
}

- (void)drawRect:(NSRect)rect
{
    NSRect r = NSInsetRect([self bounds], 1.0, 1.0);
    [color set];
    NSRectFill(r);
    [[NSColor grayColor] set];
    NSFrameRect(r);
}
@end

static NSTextField *MakeLabel(NSString *text, NSRect frame, BOOL rightAligned, BOOL small)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [label setStringValue:text ? text : @""];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setAlignment:rightAligned ? NSRightTextAlignment : NSLeftTextAlignment];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    if (small) {
        [label setFont:[NSFont systemFontOfSize:10]];
    }
    return label;
}

static NSColor *ColorFromHex(NSString *hex)
{
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    [scanner scanHexInt:&rgb];
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
}

#pragma mark - CUPS

static NSString *PrinterURI(NSString *name)
{
    char uri[1024];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, "localhost",
                     ippPort(), "/printers/%s", [name UTF8String]);
    return [NSString stringWithUTF8String:uri];
}

static void AddPrinterURI(ipp_t *request, NSString *name)
{
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL,
                 [PrinterURI(name) UTF8String]);
}

static NSArray *Strings(ipp_attribute_t *attribute)
{
    NSMutableArray *list = [NSMutableArray array];
    for (int i = 0; attribute != NULL && i < ippGetCount(attribute); i++) {
        const char *s = ippGetString(attribute, i, NULL);
        [list addObject:s ? [NSString stringWithUTF8String:s] : @""];
    }
    return list;
}

static NSArray *Integers(ipp_attribute_t *attribute)
{
    NSMutableArray *list = [NSMutableArray array];
    for (int i = 0; attribute != NULL && i < ippGetCount(attribute); i++) {
        [list addObject:[NSNumber numberWithInt:ippGetInteger(attribute, i)]];
    }
    return list;
}

static BOOL RequestRefusedForRights(void)
{
    ipp_status_t status = cupsLastError();
    /* A user outside the admin group is asked to authenticate, which fails
       with "authentication canceled" when no password can be given. */
    return status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED
        || status == IPP_STATUS_ERROR_NOT_AUTHENTICATED
        || status == IPP_STATUS_ERROR_CUPS_AUTHENTICATION_CANCELED;
}

@implementation PrinterOptionsPanel

- (id)initWithPrinter:(PrinterInfo *)aPrinter
        privilegeHint:(NSString *)hint
               target:(id)aTarget
        changedAction:(SEL)action
{
    self = [super init];
    if (self) {
        printer = [aPrinter retain];
        privilegeHint = [hint copy];
        target = aTarget;
        changedAction = action;
        optionPopups = [[NSMutableArray alloc] init];
        initialChoices = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [window release];
    [printer release];
    [privilegeHint release];
    [optionPopups release];
    [initialChoices release];
    [super dealloc];
}

- (void)close
{
    [window setDelegate:nil];
    [window orderOut:nil];
}

- (void)show
{
    if (window == nil) {
        [self buildWindow];
    }
    [window center];
    [window makeKeyAndOrderFront:nil];
}

#pragma mark - Window

- (void)buildWindow
{
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWindowWidth, kWindowHeight)
                                         styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    [window setTitle:[NSString stringWithFormat:@"%@ Options", [printer displayName]]];
    [window setReleasedWhenClosed:NO];
    [window setDelegate:self];

    NSView *content = [window contentView];
    const CGFloat side = METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat buttonH = METRICS_BUTTON_HEIGHT;
    const CGFloat buttonW = METRICS_BUTTON_MIN_WIDTH;
    const CGFloat bottom = METRICS_CONTENT_BOTTOM_MARGIN;

    NSButton *ok = [[[NSButton alloc] initWithFrame:
        NSMakeRect(kWindowWidth - side - buttonW, bottom, buttonW, buttonH)] autorelease];
    [ok setTitle:@"OK"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self];
    [ok setAction:@selector(save:)];
    [content addSubview:ok];

    NSButton *cancel = [[[NSButton alloc] initWithFrame:
        NSMakeRect(kWindowWidth - side - 2 * buttonW - METRICS_BUTTON_HORIZ_INTERSPACE,
                   bottom, buttonW, buttonH)] autorelease];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\e"];
    [cancel setTarget:self];
    [cancel setAction:@selector(cancel:)];
    [content addSubview:cancel];

    CGFloat tabsBottom = bottom + buttonH + METRICS_BUTTON_VERT_INTERSPACE;
    NSTabView *tabs = [[[NSTabView alloc] initWithFrame:
        NSMakeRect(side, tabsBottom, kWindowWidth - 2 * side,
                   kWindowHeight - METRICS_CONTENT_TOP_MARGIN - tabsBottom)] autorelease];
    [content addSubview:tabs];

    NSDictionary *attributes = [self printerAttributes];
    NSSize pane = [tabs contentRect].size;

    NSTabViewItem *general = [[[NSTabViewItem alloc] initWithIdentifier:@"general"] autorelease];
    [general setLabel:@"General"];
    [general setView:[self generalViewWithSize:pane attributes:attributes]];
    [tabs addTabViewItem:general];

    NSTabViewItem *options = [[[NSTabViewItem alloc] initWithIdentifier:@"options"] autorelease];
    [options setLabel:@"Options"];
    [options setView:[self optionsViewWithSize:pane]];
    [tabs addTabViewItem:options];

    NSTabViewItem *supplies = [[[NSTabViewItem alloc] initWithIdentifier:@"supplies"] autorelease];
    [supplies setLabel:@"Supplies"];
    [supplies setView:[self suppliesViewWithSize:pane attributes:attributes]];
    [tabs addTabViewItem:supplies];
}

#pragma mark - What the printer reports

- (NSDictionary *)printerAttributes
{
    static const char *wanted[] = {
        "printer-info", "printer-location", "printer-is-shared", "printer-is-accepting-jobs",
        "printer-state", "printer-make-and-model", "device-uri", "printer-more-info",
        "marker-names", "marker-levels", "marker-colors", "marker-types"
    };
    ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
    AddPrinterURI(request, [printer name]);
    ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes",
                  (int)(sizeof(wanted) / sizeof(wanted[0])), NULL, wanted);
    ipp_t *response = cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/");
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (response != NULL) {
        NSArray *info = Strings(ippFindAttribute(response, "printer-info", IPP_TAG_ZERO));
        NSArray *location = Strings(ippFindAttribute(response, "printer-location", IPP_TAG_ZERO));
        NSArray *more = Strings(ippFindAttribute(response, "printer-more-info", IPP_TAG_ZERO));
        if ([info count] > 0) {
            [result setObject:[info objectAtIndex:0] forKey:@"info"];
        }
        if ([location count] > 0) {
            [result setObject:[location objectAtIndex:0] forKey:@"location"];
        }
        if ([more count] > 0) {
            [result setObject:[more objectAtIndex:0] forKey:@"moreInfo"];
        }
        [result setObject:[NSNumber numberWithBool:
            ippFindAttribute(response, "printer-is-shared", IPP_TAG_BOOLEAN) != NULL
            && ippGetBoolean(ippFindAttribute(response, "printer-is-shared", IPP_TAG_BOOLEAN), 0)]
                   forKey:@"shared"];
        [result setObject:[PrinterSupply suppliesFromMarkerNames:
                              Strings(ippFindAttribute(response, "marker-names", IPP_TAG_ZERO))
                                                          levels:
                              Integers(ippFindAttribute(response, "marker-levels", IPP_TAG_ZERO))
                                                          colors:
                              Strings(ippFindAttribute(response, "marker-colors", IPP_TAG_ZERO))
                                                           types:
                              Strings(ippFindAttribute(response, "marker-types", IPP_TAG_ZERO))]
                   forKey:@"supplies"];
        ippDelete(response);
    }
    return result;
}

#pragma mark - General

/* The URI as a person reads it: queue names carry spaces as %20. */
- (NSString *)readableURI:(NSString *)uri
{
    NSString *decoded = [uri stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return decoded ? decoded : (uri ? uri : @"");
}

- (NSView *)generalViewWithSize:(NSSize)size attributes:(NSDictionary *)attributes
{
    NSView *view = [[[POFlippedView alloc] initWithFrame:
        NSMakeRect(0, 0, size.width, size.height)] autorelease];
    CGFloat fieldX = kInset + kLabelWidth + METRICS_BUTTON_HORIZ_INTERSPACE;
    CGFloat fieldW = size.width - fieldX - kInset;
    CGFloat y = kInset;

    NSArray *rows = @[
        @[@"Name:", [printer displayName] ? [printer displayName] : @""],
        @[@"Driver:", [printer makeModel] ? [printer makeModel] : @""],
        @[@"Connection:", [self readableURI:[printer deviceURI]]],
    ];
    for (NSArray *row in rows) {
        [view addSubview:MakeLabel([row objectAtIndex:0],
            NSMakeRect(kInset, y, kLabelWidth, kRowHeight), YES, NO)];
        [view addSubview:MakeLabel([row objectAtIndex:1],
            NSMakeRect(fieldX, y, fieldW, kRowHeight), NO, NO)];
        y += kRowHeight + kRowGap;
    }

    [view addSubview:MakeLabel(@"Description:", NSMakeRect(kInset, y, kLabelWidth, kRowHeight), YES, NO)];
    descriptionField = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(fieldX, y, fieldW, kRowHeight)] autorelease];
    [descriptionField setStringValue:[attributes objectForKey:@"info"]
                                     ? [attributes objectForKey:@"info"] : @""];
    [view addSubview:descriptionField];
    y += kRowHeight + kRowGap;

    [view addSubview:MakeLabel(@"Location:", NSMakeRect(kInset, y, kLabelWidth, kRowHeight), YES, NO)];
    locationField = [[[NSTextField alloc] initWithFrame:
        NSMakeRect(fieldX, y, fieldW, kRowHeight)] autorelease];
    [locationField setStringValue:[attributes objectForKey:@"location"]
                                  ? [attributes objectForKey:@"location"] : @""];
    [view addSubview:locationField];
    y += kRowHeight + kRowGap * 2;

    sharedCheckbox = [self checkboxWithTitle:@"Share this printer on the network"
                                       state:[[attributes objectForKey:@"shared"] boolValue]
                                       frame:NSMakeRect(fieldX, y, fieldW, METRICS_RADIO_BUTTON_LINE_SPACING)];
    [view addSubview:sharedCheckbox];
    y += METRICS_RADIO_BUTTON_LINE_SPACING + kRowGap / 2;

    acceptingCheckbox = [self checkboxWithTitle:@"Accept print jobs"
                                          state:[printer acceptingJobs]
                                          frame:NSMakeRect(fieldX, y, fieldW, METRICS_RADIO_BUTTON_LINE_SPACING)];
    [view addSubview:acceptingCheckbox];
    y += METRICS_RADIO_BUTTON_LINE_SPACING + kRowGap / 2;

    pausedCheckbox = [self checkboxWithTitle:@"Pause printing"
                                       state:[[printer state] isEqualToString:@"Stopped"]
                                       frame:NSMakeRect(fieldX, y, fieldW, METRICS_RADIO_BUTTON_LINE_SPACING)];
    [view addSubview:pausedCheckbox];
    return view;
}

- (NSButton *)checkboxWithTitle:(NSString *)title state:(BOOL)on frame:(NSRect)frame
{
    NSButton *box = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [box setButtonType:NSSwitchButton];
    [box setTitle:title];
    [box setState:on ? NSOnState : NSOffState];
    return box;
}

#pragma mark - Options (from the driver)

- (NSView *)optionsViewWithSize:(NSSize)size
{
    const char *ppdPath = cupsGetPPD([[printer name] UTF8String]);
    ppd_file_t *ppd = ppdPath != NULL ? ppdOpenFile(ppdPath) : NULL;
    if (ppdPath != NULL) {
        unlink(ppdPath);
    }
    if (ppd == NULL) {
        NSView *empty = [[[POFlippedView alloc] initWithFrame:
            NSMakeRect(0, 0, size.width, size.height)] autorelease];
        [empty addSubview:MakeLabel(@"This printer's driver has no settings to change.",
            NSMakeRect(kInset, kInset, size.width - 2 * kInset, kRowHeight), NO, NO)];
        return empty;
    }

    ppdMarkDefaults(ppd);
    cups_dest_t *dests = NULL;
    int destCount = cupsGetDests(&dests);
    cups_dest_t *dest = cupsGetDest([[printer name] UTF8String], NULL, destCount, dests);
    if (dest != NULL) {
        cupsMarkOptions(ppd, dest->num_options, dest->options);
    }

    CGFloat fieldX = kInset + kLabelWidth + METRICS_BUTTON_HORIZ_INTERSPACE;
    CGFloat popupW = size.width - fieldX - kInset - METRICS_SCROLLBAR_WIDTH;
    NSView *list = [[[POFlippedView alloc] initWithFrame:
        NSMakeRect(0, 0, size.width - METRICS_SCROLLBAR_WIDTH, size.height)] autorelease];
    CGFloat y = kInset;

    for (int g = 0; g < ppd->num_groups; g++) {
        ppd_group_t *group = &ppd->groups[g];
        BOOL headerShown = NO;
        for (int o = 0; o < group->num_options; o++) {
            ppd_option_t *option = &group->options[o];
            if ((option->ui != PPD_UI_PICKONE && option->ui != PPD_UI_BOOLEAN)
                || option->num_choices < 2 || strcmp(option->keyword, "PageRegion") == 0) {
                continue;
            }
            if (!headerShown) {
                NSTextField *header = MakeLabel([NSString stringWithUTF8String:group->text],
                    NSMakeRect(kInset, y, size.width - 2 * kInset, kRowHeight), NO, NO);
                [header setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
                [list addSubview:header];
                y += kRowHeight + kRowGap / 2;
                headerShown = YES;
            }
            [list addSubview:MakeLabel([NSString stringWithFormat:@"%s:", option->text],
                NSMakeRect(kInset, y, kLabelWidth, kRowHeight), YES, NO)];

            NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:
                NSMakeRect(fieldX, y, popupW, kRowHeight) pullsDown:NO] autorelease];
            ppd_choice_t *marked = ppdFindMarkedChoice(ppd, option->keyword);
            NSString *markedChoice = marked != NULL ? [NSString stringWithUTF8String:marked->choice] : nil;
            for (int c = 0; c < option->num_choices; c++) {
                /* Added through the menu: addItemWithTitle: would fold choices
                   that share a title into one. */
                NSMenuItem *item = (NSMenuItem *)[[popup menu] addItemWithTitle:
                    [NSString stringWithUTF8String:option->choices[c].text] action:NULL keyEquivalent:@""];
                NSString *choice = [NSString stringWithUTF8String:option->choices[c].choice];
                [item setRepresentedObject:choice];
                if ([choice isEqualToString:markedChoice]) {
                    [popup selectItem:item];
                }
            }
            NSString *keyword = [NSString stringWithUTF8String:option->keyword];
            [popup setIdentifier:keyword];
            [initialChoices setObject:[[popup selectedItem] representedObject]
                               forKey:keyword];
            [optionPopups addObject:popup];
            [list addSubview:popup];
            y += kRowHeight + kRowGap;
        }
        if (headerShown) {
            y += kRowGap / 2;
        }
    }
    ppdClose(ppd);
    cupsFreeDests(destCount, dests);

    [list setFrameSize:NSMakeSize(NSWidth([list frame]), MAX(y + kInset, size.height))];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, 0, size.width, size.height)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:YES];
    [scroll setBorderType:NSNoBorder];
    [scroll setDocumentView:list];
    return scroll;
}

#pragma mark - Supplies

- (NSView *)suppliesViewWithSize:(NSSize)size attributes:(NSDictionary *)attributes
{
    NSView *view = [[[POFlippedView alloc] initWithFrame:
        NSMakeRect(0, 0, size.width, size.height)] autorelease];
    NSArray *supplies = [attributes objectForKey:@"supplies"];
    if ([supplies count] == 0) {
        [view addSubview:MakeLabel(@"This printer does not report its supply levels.",
            NSMakeRect(kInset, kInset, size.width - 2 * kInset, kRowHeight), NO, NO)];
    }
    const CGFloat swatch = 14.0;
    const CGFloat percentW = 44.0;
    CGFloat nameW = 150.0;
    CGFloat barX = kInset + swatch + 8.0 + nameW + 8.0;
    CGFloat barW = size.width - barX - percentW - kInset - 8.0;
    CGFloat y = kInset;
    for (PrinterSupply *supply in supplies) {
        NSString *hex = [supply colorHex];
        if (hex != nil) {
            [view addSubview:[[[POSwatchView alloc] initWithFrame:
                NSMakeRect(kInset, y + 4.0, swatch, swatch) color:ColorFromHex(hex)] autorelease]];
        }
        [view addSubview:MakeLabel([supply name],
            NSMakeRect(kInset + swatch + 8.0, y, nameW, kRowHeight), NO, NO)];
        BOOL known = [supply level] != PrinterSupplyLevelUnknown;
        NSProgressIndicator *bar = [[[NSProgressIndicator alloc] initWithFrame:
            NSMakeRect(barX, y + 2.0, barW, 18.0)] autorelease];
        [bar setStyle:NSProgressIndicatorBarStyle];
        [bar setIndeterminate:NO];
        [bar setMinValue:0.0];
        [bar setMaxValue:100.0];
        [bar setDoubleValue:known ? (double)[supply level] : 0.0];
        [view addSubview:bar];
        [view addSubview:MakeLabel(known ? [NSString stringWithFormat:@"%ld%%", (long)[supply level]]
                                         : @"Unknown",
            NSMakeRect(barX + barW + 8.0, y, percentW, kRowHeight), YES, YES)];
        y += kRowHeight + kRowGap;
    }
    NSString *moreInfo = [attributes objectForKey:@"moreInfo"];
    if (moreInfo != nil) {
        NSButton *web = [[[NSButton alloc] initWithFrame:
            NSMakeRect(kInset, size.height - kInset - METRICS_BUTTON_HEIGHT, 160.0,
                       METRICS_BUTTON_HEIGHT)] autorelease];
        [web setTitle:@"Supplies Web Page..."];
        [web setBezelStyle:NSRoundedBezelStyle];
        [web setTarget:self];
        [web setAction:@selector(openMoreInfo:)];
        [web setIdentifier:moreInfo];
        [view addSubview:web];
    }
    return view;
}

- (void)openMoreInfo:(id)sender
{
    NSURL *url = [NSURL URLWithString:[sender identifier]];
    if (url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

#pragma mark - Saving

- (void)showFailure:(NSString *)what
{
    NSString *message;
    if (RequestRefusedForRights()) {
        message = [@"You are not allowed to change printers.\n\n"
                   stringByAppendingString:privilegeHint ? privilegeHint : @""];
    } else {
        message = [NSString stringWithFormat:@"%@\n\n%s", what, cupsLastErrorString()];
    }
    NSRunAlertPanel(@"The Printer Could Not Be Changed", @"%@", @"OK", nil, nil, message);
}

/* One request for everything that changed; NO after telling the user why not. */
- (BOOL)saveSettings
{
    ipp_t *request = ippNewRequest(IPP_OP_CUPS_ADD_MODIFY_PRINTER);
    AddPrinterURI(request, [printer name]);
    ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-info", NULL,
                 [[descriptionField stringValue] UTF8String]);
    ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-location", NULL,
                 [[locationField stringValue] UTF8String]);
    ippAddBoolean(request, IPP_TAG_PRINTER, "printer-is-shared",
                  [sharedCheckbox state] == NSOnState);

    /* A driver setting becomes the printer's "<option>-default" attribute.
       cupsEncodeOptions2 leaves such options out, so they are added by hand. */
    for (NSPopUpButton *popup in optionPopups) {
        NSString *keyword = [popup identifier];
        NSString *choice = [[popup selectedItem] representedObject];
        if (choice != nil && ![choice isEqualToString:[initialChoices objectForKey:keyword]]) {
            ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_NAME,
                         [[keyword stringByAppendingString:@"-default"] UTF8String],
                         NULL, [choice UTF8String]);
        }
    }

    ippDelete(cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/admin/"));
    if (cupsLastError() >= IPP_STATUS_ERROR_BAD_REQUEST) {
        [self showFailure:@"The settings were not saved."];
        return NO;
    }
    return YES;
}

/* Accepting jobs and pausing are separate requests of their own. */
- (BOOL)sendOperation:(ipp_op_t)operation
{
    ipp_t *request = ippNewRequest(operation);
    AddPrinterURI(request, [printer name]);
    ippDelete(cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/admin/"));
    if (cupsLastError() >= IPP_STATUS_ERROR_BAD_REQUEST) {
        [self showFailure:@"The change was not made."];
        return NO;
    }
    return YES;
}

- (void)save:(id)sender
{
    if (![self saveSettings]) {
        return;
    }
    BOOL accepting = [acceptingCheckbox state] == NSOnState;
    if (accepting != [printer acceptingJobs]
        && ![self sendOperation:accepting ? IPP_OP_CUPS_ACCEPT_JOBS : IPP_OP_CUPS_REJECT_JOBS]) {
        return;
    }
    BOOL paused = [pausedCheckbox state] == NSOnState;
    if (paused != [[printer state] isEqualToString:@"Stopped"]
        && ![self sendOperation:paused ? IPP_OP_PAUSE_PRINTER : IPP_OP_RESUME_PRINTER]) {
        return;
    }
    [self close];
    if (target != nil && changedAction != NULL) {
        [target performSelector:changedAction withObject:nil];
    }
}

- (void)cancel:(id)sender
{
    [self close];
}

@end

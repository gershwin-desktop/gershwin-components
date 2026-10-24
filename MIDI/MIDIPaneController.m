/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDIPaneController.h"
#import "MIDIPaneViewState.h"
#import "MIDIAddHostPanel.h"
#import "MIDINetworkBackendFactory.h"
#import "AppearanceMetrics.h"

/* System Preferences shows every pane in the same fixed area; the view is
   built at that size and re-laid out to whatever the host really gives. */
static const CGFloat kPaneWidth = 640.0;
static const CGFloat kPaneHeight = 440.0;

static const CGFloat kSessionListWidth = 170.0;
static const CGFloat kMiniButtonWidth = 28.0;
static const CGFloat kStatusHeight = 20.0;
static const CGFloat kListHeaderHeight = 17.0;
static const CGFloat kListHeaderGap = 4.0;
static const CGFloat kBoxTitleInset = 14.0;
static const CGFloat kCheckColumnWidth = 22.0;
static const CGFloat kAddressColumnWidth = 92.0;
static const CGFloat kLatencyColumnWidth = 78.0;
static const CGFloat kPortFieldWidth = 70.0;

static NSString * const kColumnCheck = @"check";
static NSString * const kColumnTitle = @"title";
static NSString * const kColumnDetail = @"detail";

@interface MIDIPaneMainView : NSView
@property (nonatomic, weak) MIDIPaneController *layoutOwner;
@end

@implementation MIDIPaneMainView

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self.layoutOwner relayoutSubviewsForSize:size];
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    [self.layoutOwner relayoutSubviewsForSize:frame.size];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        /* The host may not size the installed view to its content area,
           and the box content view comes out a few pixels too wide. */
        [self setFrame:[[self superview] bounds]];
    }
}

@end

@implementation MIDIPaneController
{
    id<MIDINetworkBackend> _backend;
    MIDIPaneSelection *_selection;
    NSError *_lastError;
    MIDIPaneViewState *_viewState;
    BOOL _rendering;

    MIDIPaneMainView *_mainView;
    NSTextField *_sessionsHeader;
    NSScrollView *_sessionScroll;
    NSTableView *_sessionTable;
    NSButton *_addSessionButton;
    NSButton *_removeSessionButton;

    NSBox *_sessionBox;
    NSArray *_sessionLabels;
    NSTextField *_localNameField;
    NSTextField *_advertisedNameField;
    NSTextField *_portField;
    NSPopUpButton *_policyPopUp;

    NSTextField *_directoryHeader;
    NSScrollView *_directoryScroll;
    NSTableView *_directoryTable;
    NSButton *_addHostButton;
    NSButton *_removeHostButton;
    NSButton *_connectButton;

    NSTextField *_participantsHeader;
    NSScrollView *_participantScroll;
    NSTableView *_participantTable;
    NSButton *_disconnectButton;

    NSBox *_routingBox;
    NSTextField *_inputLabel;
    NSPopUpButton *_inputPopUp;
    NSTextField *_outputLabel;
    NSPopUpButton *_outputPopUp;

    NSTextField *_statusField;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _backend = MIDINetworkBackendCreateDefault();
        [_backend setDelegate:self];
        _selection = [[MIDIPaneSelection alloc] init];
    }
    return self;
}

- (void)start
{
    [_backend start];
    [self render];
}

- (void)stop
{
    [_backend stop];
}

#pragma mark - Building

static NSTextField *MakeLabel(NSString *text, NSTextAlignment alignment)
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setStringValue:text];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setAlignment:alignment];
    [label sizeToFit];
    return label;
}

- (NSTextField *)makeField
{
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [field setDelegate:self];
    [field setTarget:self];
    [field setAction:@selector(commitSessionDetails:)];
    return field;
}

- (NSPopUpButton *)makePopUpWithAction:(SEL)action
{
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp setTarget:self];
    [popUp setAction:action];
    return popUp;
}

- (NSButton *)makeButton:(NSString *)title action:(SEL)action square:(BOOL)square
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    [button setTitle:title];
    [button setBezelStyle:square ? NSRegularSquareBezelStyle : NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    [button sizeToFit];
    return button;
}

- (NSBox *)makeBoxWithTitle:(NSString *)title
{
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    [box setTitle:title];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setBoxType:NSBoxPrimary];
    return box;
}

/* A borderless-header table in a scroll view; the detail column is left
   out for single-purpose lists. */
- (NSScrollView *)makeTable:(NSTableView * __strong *)tableOut withCheckColumn:(BOOL)check detail:(BOOL)detail
{
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    [scroll setBorderType:NSBezelBorder];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:NO];
    [scroll setAutohidesScrollers:YES];

    NSTableView *table = [[NSTableView alloc] initWithFrame:[[scroll contentView] bounds]];
    [table setHeaderView:nil];
    [table setCornerView:nil];
    [table setAllowsMultipleSelection:NO];
    /* An empty selection must be allowed, or reloadData selects the last
       row by itself; the render pass owns the selection instead. */
    [table setAllowsEmptySelection:YES];
    if (check) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:kColumnCheck];
        NSButtonCell *cell = [[NSButtonCell alloc] init];
        [cell setButtonType:NSSwitchButton];
        [cell setTitle:@""];
        [column setDataCell:cell];
        [column setWidth:kCheckColumnWidth];
        [column setEditable:YES];
        [table addTableColumn:column];
    }
    NSTableColumn *title = [[NSTableColumn alloc] initWithIdentifier:kColumnTitle];
    [title setEditable:NO];
    [table addTableColumn:title];
    if (detail) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:kColumnDetail];
        [column setEditable:NO];
        [table addTableColumn:column];
    }
    [table setDataSource:self];
    [table setDelegate:self];
    [scroll setDocumentView:table];
    *tableOut = table;
    return scroll;
}

- (NSView *)createMainView
{
    _mainView = [[MIDIPaneMainView alloc] initWithFrame:NSMakeRect(0, 0, kPaneWidth, kPaneHeight)];
    [_mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _sessionsHeader = MakeLabel(MIDIPaneLocalized(@"My Sessions:"), NSLeftTextAlignment);
    _sessionScroll = [self makeTable:&_sessionTable withCheckColumn:YES detail:NO];
    _addSessionButton = [self makeButton:@"+" action:@selector(addSession:) square:YES];
    _removeSessionButton = [self makeButton:@"-" action:@selector(removeSession:) square:YES];

    _sessionBox = [self makeBoxWithTitle:MIDIPaneLocalized(@"Session")];
    _sessionLabels = @[ MakeLabel(MIDIPaneLocalized(@"Local Name:"), NSRightTextAlignment),
                        MakeLabel(MIDIPaneLocalized(@"Advertised Name:"), NSRightTextAlignment),
                        MakeLabel(MIDIPaneLocalized(@"Port:"), NSRightTextAlignment),
                        MakeLabel(MIDIPaneLocalized(@"Who may connect to me:"), NSRightTextAlignment) ];
    _localNameField = [self makeField];
    _advertisedNameField = [self makeField];
    _portField = [self makeField];
    _policyPopUp = [self makePopUpWithAction:@selector(commitSessionDetails:)];
    for (NSView *v in _sessionLabels) {
        [[_sessionBox contentView] addSubview:v];
    }
    [[_sessionBox contentView] addSubview:_localNameField];
    [[_sessionBox contentView] addSubview:_advertisedNameField];
    [[_sessionBox contentView] addSubview:_portField];
    [[_sessionBox contentView] addSubview:_policyPopUp];

    _directoryHeader = MakeLabel(MIDIPaneLocalized(@"Directory:"), NSLeftTextAlignment);
    _directoryScroll = [self makeTable:&_directoryTable withCheckColumn:NO detail:YES];
    _addHostButton = [self makeButton:@"+" action:@selector(addHost:) square:YES];
    _removeHostButton = [self makeButton:@"-" action:@selector(removeHost:) square:YES];
    _connectButton = [self makeButton:MIDIPaneLocalized(@"Connect") action:@selector(connect:) square:NO];
    [_directoryTable setDoubleAction:@selector(connect:)];
    [_directoryTable setTarget:self];

    _participantsHeader = MakeLabel(MIDIPaneLocalized(@"Participants:"), NSLeftTextAlignment);
    _participantScroll = [self makeTable:&_participantTable withCheckColumn:NO detail:YES];
    _disconnectButton = [self makeButton:MIDIPaneLocalized(@"Disconnect") action:@selector(disconnect:) square:NO];

    _routingBox = [self makeBoxWithTitle:MIDIPaneLocalized(@"Live Routing")];
    _inputLabel = MakeLabel(MIDIPaneLocalized(@"From:"), NSRightTextAlignment);
    _inputPopUp = [self makePopUpWithAction:@selector(changeRoute:)];
    _outputLabel = MakeLabel(MIDIPaneLocalized(@"To:"), NSRightTextAlignment);
    _outputPopUp = [self makePopUpWithAction:@selector(changeRoute:)];
    [_inputPopUp setToolTip:MIDIPaneLocalized(@"Local MIDI port whose notes are sent to this session")];
    [_outputPopUp setToolTip:MIDIPaneLocalized(@"Local MIDI port that plays what this session receives")];
    [[_routingBox contentView] addSubview:_inputLabel];
    [[_routingBox contentView] addSubview:_inputPopUp];
    [[_routingBox contentView] addSubview:_outputLabel];
    [[_routingBox contentView] addSubview:_outputPopUp];

    _statusField = MakeLabel(@"", NSLeftTextAlignment);

    for (NSView *v in @[ _sessionsHeader, _sessionScroll, _addSessionButton, _removeSessionButton,
                         _sessionBox, _directoryHeader, _directoryScroll, _addHostButton,
                         _removeHostButton, _connectButton, _participantsHeader, _participantScroll,
                         _disconnectButton, _routingBox, _statusField ]) {
        [_mainView addSubview:v];
    }
    _mainView.layoutOwner = self;
    [self relayoutSubviewsForSize:[_mainView bounds].size];
    [self render];
    return _mainView;
}

#pragma mark - Layout

static CGFloat WidestLabel(NSArray *labels)
{
    CGFloat w = 0;
    for (NSTextField *l in labels) {
        w = MAX(w, ceil([[l cell] cellSize].width));
    }
    return w;
}

static void PlaceLabel(NSTextField *label, CGFloat x, CGFloat rowY, CGFloat width)
{
    CGFloat h = ceil([[label cell] cellSize].height);
    [label setFrame:NSMakeRect(x, rowY + floor((METRICS_TEXT_INPUT_FIELD_HEIGHT - h) / 2), width, h)];
}

static CGFloat SessionBoxHeight(void)
{
    return kBoxTitleInset + METRICS_SPACE_16 + 4 * METRICS_TEXT_INPUT_FIELD_HEIGHT + 3 * METRICS_SPACE_8
         + METRICS_SPACE_16;
}

static CGFloat RoutingBoxHeight(void)
{
    return kBoxTitleInset + METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT + METRICS_SPACE_16;
}

/* Widths of the title and detail columns follow the scroll view, so a
   list never needs a horizontal scroller. */
static void FitColumns(NSTableView *table, NSScrollView *scroll, CGFloat detailWidth)
{
    CGFloat clipWidth = NSWidth([[scroll contentView] bounds]);
    NSTableColumn *detail = [table tableColumnWithIdentifier:kColumnDetail];
    NSTableColumn *title = [table tableColumnWithIdentifier:kColumnTitle];
    [detail setWidth:detailWidth];
    /* Take the spacing the table really adds from its own frame rather
       than reproducing its arithmetic. */
    [table tile];
    CGFloat titleWidth = [title width] + clipWidth - NSWidth([table frame]);
    [title setWidth:MAX(20.0, floor(titleWidth))];
    [table tile];
}

- (void)relayoutSubviewsForSize:(NSSize)size
{
    if (_statusField == nil) {
        return;
    }
    const CGFloat margin = METRICS_CONTENT_SIDE_MARGIN;
    const CGFloat W = size.width, H = size.height;
    const CGFloat buttonH = METRICS_BUTTON_HEIGHT;

    CGFloat statusY = METRICS_SPACE_12;
    [_statusField setFrame:NSMakeRect(margin, statusY, W - 2 * margin, kStatusHeight)];
    CGFloat buttonsY = statusY + kStatusHeight + METRICS_SPACE_8;

    /* Left column: the session list fills the height above its +/- row. */
    CGFloat headerY = H - METRICS_CONTENT_TOP_MARGIN - kListHeaderHeight;
    [_sessionsHeader setFrame:NSMakeRect(margin, headerY, kSessionListWidth, kListHeaderHeight)];
    CGFloat listBottom = buttonsY + buttonH;
    [_sessionScroll setFrame:NSMakeRect(margin, listBottom, kSessionListWidth,
                                        headerY - kListHeaderGap - listBottom)];
    [_addSessionButton setFrame:NSMakeRect(margin, buttonsY, kMiniButtonWidth, buttonH)];
    /* -1: the two 1 px outlines coincide instead of forming a double line. */
    [_removeSessionButton setFrame:NSMakeRect(margin + kMiniButtonWidth - 1, buttonsY, kMiniButtonWidth, buttonH)];

    /* Right column, top to bottom: session box, the two lists (the one
       flexible part), the routing box above the status line. */
    CGFloat rx = margin + kSessionListWidth + METRICS_SPACE_16;
    CGFloat rw = W - margin - rx;
    CGFloat sessionBoxH = SessionBoxHeight();
    CGFloat sessionBoxY = H - METRICS_CONTENT_TOP_MARGIN - sessionBoxH;
    [_sessionBox setFrame:NSMakeRect(rx, sessionBoxY, rw, sessionBoxH)];
    [self layoutSessionBox];

    CGFloat routingH = RoutingBoxHeight();
    [_routingBox setFrame:NSMakeRect(rx, buttonsY, rw, routingH)];
    [self layoutRoutingBox];

    CGFloat listsBottom = buttonsY + routingH + METRICS_SPACE_12;
    CGFloat listsTop = sessionBoxY - METRICS_SPACE_12;
    CGFloat halfW = floor((rw - METRICS_SPACE_8) / 2);
    CGFloat px = rx + halfW + METRICS_SPACE_8;
    CGFloat pw = rw - halfW - METRICS_SPACE_8;
    CGFloat listHeaderY = listsTop - kListHeaderHeight;
    CGFloat tableBottom = listsBottom + buttonH;
    CGFloat tableH = MAX(0.0, listHeaderY - kListHeaderGap - tableBottom);

    [_directoryHeader setFrame:NSMakeRect(rx, listHeaderY, halfW, kListHeaderHeight)];
    [_directoryScroll setFrame:NSMakeRect(rx, tableBottom, halfW, tableH)];
    [_addHostButton setFrame:NSMakeRect(rx, listsBottom, kMiniButtonWidth, buttonH)];
    [_removeHostButton setFrame:NSMakeRect(rx + kMiniButtonWidth - 1, listsBottom, kMiniButtonWidth, buttonH)];
    CGFloat connectW = NSWidth([_connectButton frame]);
    [_connectButton setFrame:NSMakeRect(rx + halfW - connectW, listsBottom, connectW, buttonH)];

    [_participantsHeader setFrame:NSMakeRect(px, listHeaderY, pw, kListHeaderHeight)];
    [_participantScroll setFrame:NSMakeRect(px, tableBottom, pw, tableH)];
    CGFloat disconnectW = NSWidth([_disconnectButton frame]);
    [_disconnectButton setFrame:NSMakeRect(px + pw - disconnectW, listsBottom, disconnectW, buttonH)];
    [self fitColumns];
}

/* Also after every reload: whether the scroller shows (and so how wide
   the rows are) depends on the row count. */
- (void)fitColumns
{
    FitColumns(_sessionTable, _sessionScroll, 0);
    FitColumns(_directoryTable, _directoryScroll, kAddressColumnWidth);
    FitColumns(_participantTable, _participantScroll, kLatencyColumnWidth);
}

- (void)layoutSessionBox
{
    NSSize content = [[_sessionBox contentView] bounds].size;
    CGFloat inset = METRICS_SPACE_16;
    CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat rowsH = 4 * rowH + 3 * METRICS_SPACE_8;
    CGFloat labelW = WidestLabel(_sessionLabels);
    CGFloat fieldX = inset + labelW + METRICS_SPACE_8;
    CGFloat fieldW = MAX(40.0, content.width - fieldX - inset);
    CGFloat y = content.height - floor((content.height - rowsH) / 2) - rowH;
    NSArray *controls = @[ _localNameField, _advertisedNameField, _portField, _policyPopUp ];
    NSUInteger i;
    for (i = 0; i < 4; i++) {
        PlaceLabel([_sessionLabels objectAtIndex:i], inset, y, labelW);
        NSView *control = [controls objectAtIndex:i];
        CGFloat w = (control == _portField) ? kPortFieldWidth : fieldW;
        [control setFrame:NSMakeRect(fieldX, y, w, rowH)];
        y -= rowH + METRICS_SPACE_8;
    }
}

- (void)layoutRoutingBox
{
    NSSize content = [[_routingBox contentView] bounds].size;
    CGFloat inset = METRICS_SPACE_16;
    CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat y = floor((content.height - rowH) / 2);
    CGFloat inW = WidestLabel(@[ _inputLabel ]);
    CGFloat outW = WidestLabel(@[ _outputLabel ]);
    CGFloat popUpW = floor((content.width - 2 * inset - inW - outW - 2 * METRICS_SPACE_8 - METRICS_SPACE_12) / 2);
    CGFloat x = inset;
    PlaceLabel(_inputLabel, x, y, inW);
    x += inW + METRICS_SPACE_8;
    [_inputPopUp setFrame:NSMakeRect(x, y, popUpW, rowH)];
    x += popUpW + METRICS_SPACE_12;
    PlaceLabel(_outputLabel, x, y, outW);
    x += outW + METRICS_SPACE_8;
    [_outputPopUp setFrame:NSMakeRect(x, y, content.width - inset - x, rowH)];
}

#pragma mark - Rendering

static void SelectRow(NSTableView *table, NSInteger row)
{
    if (row >= 0 && row < [table numberOfRows]) {
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    } else {
        [table deselectAll:nil];
    }
}

/* A field the user is typing in keeps the text; everything else shows the
   backend's value, which also undoes a refused edit. */
static void SetFieldValue(NSTextField *field, NSString *value, BOOL enabled)
{
    if ([field currentEditor] == nil && ![[field stringValue] isEqual:value]) {
        [field setStringValue:value];
    }
    [field setEnabled:enabled];
}

static void FillPopUp(NSPopUpButton *popUp, NSArray *titles, NSInteger index, BOOL enabled)
{
    NSArray *current = [popUp itemTitles];
    if (![current isEqual:titles]) {
        [popUp removeAllItems];
        [popUp addItemsWithTitles:titles];
    }
    if ([popUp indexOfSelectedItem] != index) {
        [popUp selectItemAtIndex:index];
    }
    [popUp setEnabled:enabled];
}

- (void)render
{
    if (_mainView == nil) {
        return;
    }
    MIDIPaneViewState *v = [MIDIPaneViewState viewStateWithBackend:_backend selection:_selection lastError:_lastError];
    _viewState = v;
    _selection = [v.selection copy];
    _rendering = YES;

    [_sessionTable reloadData];
    SelectRow(_sessionTable, v.selectedSessionRow);
    [_addSessionButton setEnabled:v.canAddSession];
    [_removeSessionButton setEnabled:v.canRemoveSession];

    SetFieldValue(_localNameField, v.localName, v.detailsEnabled);
    SetFieldValue(_advertisedNameField, v.advertisedName, v.detailsEnabled);
    SetFieldValue(_portField, v.portText, v.detailsEnabled);
    FillPopUp(_policyPopUp, v.policyTitles, v.policyIndex, v.detailsEnabled);

    [_directoryTable reloadData];
    SelectRow(_directoryTable, v.selectedHostRow);
    [_addHostButton setEnabled:v.canAddHost];
    [_removeHostButton setEnabled:v.canRemoveHost];
    [_connectButton setEnabled:v.canConnect];

    [_participantTable reloadData];
    SelectRow(_participantTable, v.selectedParticipantRow);
    [_disconnectButton setEnabled:v.canDisconnect];

    [self fitColumns];

    FillPopUp(_inputPopUp, v.inputPortTitles, v.inputPortIndex, v.routingEnabled);
    FillPopUp(_outputPopUp, v.outputPortTitles, v.outputPortIndex, v.routingEnabled);

    [_statusField setStringValue:v.statusText];
    [_statusField setTextColor:v.statusIsError
        ? [NSColor colorWithCalibratedRed:0.7 green:0.0 blue:0.0 alpha:1.0]
        : [NSColor controlTextColor]];
    _rendering = NO;
}

/* Every user action goes through here: the outcome is either a cleared
   error or the backend's error in the status line, then one render. */
- (void)perform:(BOOL (^)(NSError * __autoreleasing *error))change
{
    NSError *error = nil;
    _lastError = change(&error) ? nil : error;
    [self render];
}

#pragma mark - Actions

- (void)addSession:(id)sender
{
    MIDINetworkSession *session = [MIDIPaneViewState proposedSessionForBackend:_backend];
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        if (![self->_backend addSession:session error:error]) {
            return NO;
        }
        self->_selection.sessionIdentifier = session.identifier;
        return YES;
    }];
}

- (void)removeSession:(id)sender
{
    NSString *identifier = _selection.sessionIdentifier;
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend removeSessionWithIdentifier:identifier error:error];
    }];
}

- (void)commitSessionDetails:(id)sender
{
    if (_rendering) {
        return;
    }
    MIDINetworkSession *session = [_backend sessionWithIdentifier:_selection.sessionIdentifier];
    if (session == nil) {
        return;
    }
    MIDINetworkSession *edited = [session copy];
    edited.name = [_localNameField stringValue];
    edited.advertisedName = [_advertisedNameField stringValue];
    /* Not a number becomes 0, which the backend refuses with a clear
       message instead of the pane guessing a port. */
    NSInteger port = [[_portField stringValue] integerValue];
    edited.port = port > 0 ? (NSUInteger)port : 0;
    edited.policy = (MIDINetworkConnectionPolicy)[_policyPopUp indexOfSelectedItem];
    if ([edited isEqual:session]) {
        return;
    }
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend updateSession:edited error:error];
    }];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    [self commitSessionDetails:[notification object]];
}

- (void)addHost:(id)sender
{
    MIDINetworkHost *host = [[[MIDIAddHostPanel alloc] init] runModal];
    if (host == nil) {
        return;
    }
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        if (![self->_backend addManualHost:host error:error]) {
            return NO;
        }
        self->_selection.hostIdentifier = host.identifier;
        return YES;
    }];
}

- (void)removeHost:(id)sender
{
    NSString *identifier = _selection.hostIdentifier;
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend removeHostWithIdentifier:identifier error:error];
    }];
}

- (void)connect:(id)sender
{
    if (!_viewState.canConnect) {
        return;     /* double-click on a row while Connect is disabled */
    }
    NSString *session = _selection.sessionIdentifier;
    NSString *host = _selection.hostIdentifier;
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend connectSessionWithIdentifier:session toHostWithIdentifier:host error:error];
    }];
}

- (void)disconnect:(id)sender
{
    NSString *session = _selection.sessionIdentifier;
    NSString *participant = _selection.participantIdentifier;
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend disconnectParticipantWithIdentifier:participant
                                         fromSessionWithIdentifier:session error:error];
    }];
}

- (void)changeRoute:(id)sender
{
    if (_rendering || _selection.sessionIdentifier == nil) {
        return;
    }
    id input = [_viewState.inputPortIdentifiers objectAtIndex:MAX(0, [_inputPopUp indexOfSelectedItem])];
    id output = [_viewState.outputPortIdentifiers objectAtIndex:MAX(0, [_outputPopUp indexOfSelectedItem])];
    MIDINetworkRoute *route = [MIDINetworkRoute routeForSession:_selection.sessionIdentifier
                                                      inputPort:(input == [NSNull null]) ? nil : input
                                                     outputPort:(output == [NSNull null]) ? nil : output];
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend setRoute:route error:error];
    }];
}

#pragma mark - Tables

- (NSArray *)rowsForTable:(NSTableView *)table
{
    if (table == _sessionTable) {
        return _viewState.sessionRows;
    }
    if (table == _directoryTable) {
        return _viewState.directoryRows;
    }
    return _viewState.participantRows;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
    return (NSInteger)[[self rowsForTable:table] count];
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSArray *rows = [self rowsForTable:table];
    if (row < 0 || row >= (NSInteger)[rows count]) {
        return nil;
    }
    MIDIPaneRow *r = [rows objectAtIndex:row];
    if ([[column identifier] isEqual:kColumnCheck]) {
        return @(r.checked);
    }
    return [[column identifier] isEqual:kColumnDetail] ? r.detail : r.title;
}

/* Only the session list's check boxes are editable: they turn a session
   on or off. */
- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column
              row:(NSInteger)row
{
    if (table != _sessionTable || ![[column identifier] isEqual:kColumnCheck]
        || row < 0 || row >= (NSInteger)[_viewState.sessionRows count]) {
        return;
    }
    MIDIPaneRow *r = [_viewState.sessionRows objectAtIndex:row];
    BOOL enabled = [value boolValue];
    _selection.sessionIdentifier = r.identifier;
    [self perform:^BOOL(NSError * __autoreleasing *error) {
        return [self->_backend setEnabled:enabled forSessionWithIdentifier:r.identifier error:error];
    }];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if (_rendering) {
        return;
    }
    NSTableView *table = [notification object];
    NSInteger row = [table selectedRow];
    NSArray *rows = [self rowsForTable:table];
    NSString *identifier = (row >= 0 && row < (NSInteger)[rows count]) ? [[rows objectAtIndex:row] identifier] : nil;
    if (table == _sessionTable) {
        if (identifier == nil) {
            return;     /* keep a session selected while there are any */
        }
        _selection.sessionIdentifier = identifier;
        _selection.participantIdentifier = nil;
    } else if (table == _directoryTable) {
        _selection.hostIdentifier = identifier;
    } else {
        _selection.participantIdentifier = identifier;
    }
    [self render];
}

#pragma mark - Backend delegate

- (void)midiNetworkBackendStatusDidChange:(id<MIDINetworkBackend>)backend { [self render]; }
- (void)midiNetworkBackendSessionsDidChange:(id<MIDINetworkBackend>)backend { [self render]; }
- (void)midiNetworkBackendDirectoryDidChange:(id<MIDINetworkBackend>)backend { [self render]; }
- (void)midiNetworkBackend:(id<MIDINetworkBackend>)backend participantsDidChangeForSession:(NSString *)session
{
    [self render];
}
- (void)midiNetworkBackendRoutesDidChange:(id<MIDINetworkBackend>)backend { [self render]; }
- (void)midiNetworkBackendLocalPortsDidChange:(id<MIDINetworkBackend>)backend { [self render]; }

- (void)midiNetworkBackend:(id<MIDINetworkBackend>)backend didEncounterError:(NSError *)error
{
    _lastError = error;
    [self render];
}

@end

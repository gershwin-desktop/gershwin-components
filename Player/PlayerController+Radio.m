/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerController.h"
#import "PlayerController+Private.h"
#import "PlayerMenu.h"
#import "RadioStation.h"
#import "AppearanceMetrics.h"

@implementation PlayerController (Radio)

- (void)createRadioViews
{
    NSSearchField *field = [[[NSSearchField alloc] initWithFrame:NSZeroRect] autorelease];
    [[field cell] setPlaceholderString:@"Search Radio Stations"];
    [field setTarget:self];
    [field setAction:@selector(radioSearch:)];
    [field setHidden:YES];
    [contentView addSubview:field];
    searchField = field;

    statusLabel = [self labelWithFont:METRICS_FONT_SYSTEM_BOLD_13];
    [statusLabel setAlignment:NSCenterTextAlignment];
    [statusLabel setHidden:YES];

    radioTextLabel = [self labelWithFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [radioTextLabel setAlignment:NSCenterTextAlignment];
    [radioTextLabel setHidden:YES];
}

#pragma mark - Mode switching

- (IBAction)toggleRadioMode:(id)sender
{
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    } else {
        [self enterRadioMode];
    }
}

- (void)enterRadioMode
{
    if (playerMode == PlayerModeRadio) {
        return;
    }
    [self exitFullscreen];
    [session stop];
    [self showCoverArt];
    playerMode = PlayerModeRadio;
    [[NSUserDefaults standardUserDefaults] setInteger:PlayerModeRadio forKey:PlayerDefaultsMode];

    RadioManager *radio = [RadioManager sharedManager];
    [radio setDelegate:self];
    [radio setVolume:[self volume]];
    [radio setMuted:[session muted]];

    [self setRadioStatus:@"Loading stations..."];
    [radioTextLabel setStringValue:@""];
    [flowView reloadData];
    if ([[radio stations] count] == 0) {
        [radio loadLocalStations];
    } else {
        [self radioManagerDidUpdateStations:radio];
    }
    [self layoutSubviews];
    [self updateControls];
    [self updateWindowTitle];
    [mainWindow makeFirstResponder:searchField];
}

- (void)exitRadioMode
{
    if (playerMode != PlayerModeRadio) {
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(playPendingStation)
                                               object:nil];
    [pendingRadioStation release];
    pendingRadioStation = nil;
    [[RadioManager sharedManager] stop];
    [progressIndicator stopAnimation:self];
    playerMode = PlayerModeLocal;
    [[NSUserDefaults standardUserDefaults] setInteger:PlayerModeLocal forKey:PlayerDefaultsMode];

    [self layoutSubviews];
    [self playlistDidChange];
    [mainWindow makeFirstResponder:contentView];
}

#pragma mark - Layout

// Search at the top, stations in the middle, then what plays, the
// transport and the volume at the bottom.
- (void)layoutRadioMode
{
    NSRect bounds = [contentView bounds];
    CGFloat W = NSWidth(bounds);
    CGFloat H = NSHeight(bounds);
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat right = W - METRICS_CONTENT_SIDE_MARGIN;

    [self setViews:[self trackInfoViews] hidden:YES];
    [self setViews:[self positionViews] hidden:YES];
    [self setViews:@[openButton, fullscreenButton] hidden:YES];
    [self setViews:@[searchField, statusLabel, radioTextLabel] hidden:NO];
    [self setViews:[self transportViews] hidden:NO];
    [self setViews:@[volumeLabel, volumeSlider, muteCheckbox] hidden:NO];

    CGFloat y = METRICS_CONTENT_BOTTOM_MARGIN;
    NSRect mute = [muteCheckbox frame];
    NSRect slider = [volumeSlider frame];
    CGFloat volumeWidth = 50 + METRICS_SPACE_8 + NSWidth(slider) + METRICS_SPACE_8 + NSWidth(mute);
    CGFloat x = floor(NSMidX(bounds) - volumeWidth / 2.0);
    [volumeLabel setFrame:NSMakeRect(x, y + 3, 50, 14)];
    x += 50 + METRICS_SPACE_8;
    [volumeSlider setFrame:NSMakeRect(x, y, NSWidth(slider), METRICS_BUTTON_HEIGHT)];
    x += NSWidth(slider) + METRICS_SPACE_8;
    [muteCheckbox setFrame:NSMakeRect(x, y + 1, NSWidth(mute), 18)];
    y += METRICS_BUTTON_HEIGHT + METRICS_SPACE_16;

    [self layoutTransportCenteredAt:NSMidX(bounds) y:y];
    y += 24 + METRICS_SPACE_12;

    [radioTextLabel setFrame:NSMakeRect(left, y, right - left, 15)];
    y += 15 + 4;
    [statusLabel setFrame:NSMakeRect(left, y, right - left, 17)];
    [self placeRadioSpinner];
    y += 17 + METRICS_SPACE_12;

    CGFloat searchY = H - METRICS_CONTENT_TOP_MARGIN - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    [searchField setFrame:NSMakeRect(left, searchY, right - left, METRICS_TEXT_INPUT_FIELD_HEIGHT)];

    [self setPictureFrame:NSMakeRect(0, y, W, searchY - METRICS_SPACE_12 - y)];
}

#pragma mark - Controls

// A station is being tuned in from the moment it is chosen until it plays
// or fails, including the short wait while the choice may still change.
- (BOOL)radioTuning
{
    return pendingRadioStation != nil || [[RadioManager sharedManager] isConnecting];
}

- (void)setRadioStatus:(NSString *)status
{
    [statusLabel setStringValue:status];
    [self placeRadioSpinner];
}

// The spinner sits just before the centered status text
- (void)placeRadioSpinner
{
    NSRect frame = [statusLabel frame];
    CGFloat textWidth = MIN(NSWidth(frame), [[statusLabel cell] cellSize].width);
    CGFloat x = floor(NSMidX(frame) - textWidth / 2.0) - METRICS_SPACE_8 - 16;
    [progressIndicator setFrameOrigin:NSMakePoint(MAX(NSMinX(frame), x),
                                                  floor(NSMidY(frame) - 8))];
}

- (void)updateRadioControls
{
    RadioManager *radio = [RadioManager sharedManager];
    NSUInteger count = [[radio stations] count];
    BOOL tuning = [self radioTuning];
    // While tuning in, the button stops the attempt like pausing a stream
    BOOL active = [radio isPlaying] || tuning;

    if (tuning) {
        [progressIndicator startAnimation:self];
    } else {
        [progressIndicator stopAnimation:self];
    }
    [playButton setImage:active ? pauseImage : playImage];
    [playButton setTitle:active ? @"Pause" : @"Play"];
    [playButton setToolTip:[playButton title]];
    [playButton setEnabled:count > 0];
    [stopButton setEnabled:active];
    [previousButton setEnabled:count > 1];
    [nextButton setEnabled:count > 1];
    [self revalidateMenu];
}

- (void)radioPlayPause
{
    RadioManager *radio = [RadioManager sharedManager];
    if ([radio isPlaying] || [self radioTuning]) {
        // A live stream cannot resume where it paused; pausing stops it
        [self radioStop];
    } else {
        [self radioSelectStationAtIndex:[flowView selectedIndex]];
    }
}

- (void)radioStop
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(playPendingStation)
                                               object:nil];
    [pendingRadioStation release];
    pendingRadioStation = nil;
    [[RadioManager sharedManager] stop];
    [self updateControls];
}

- (void)radioStepBy:(NSInteger)delta
{
    NSUInteger count = [[[RadioManager sharedManager] stations] count];
    if (count < 2) {
        return;
    }
    NSUInteger index = [flowView selectedIndex];
    if (index >= count) {
        index = 0;
    }
    index = (index + count + delta) % count;
    suppressFlowSelection = YES;
    [flowView setSelectedIndex:index];
    suppressFlowSelection = NO;
    [self radioSelectStationAtIndex:index];
}

- (void)radioNextStation
{
    [self radioStepBy:1];
}

- (void)radioPreviousStation
{
    [self radioStepBy:-1];
}

// Stations are tuned in only once the selection rests, so stepping through
// them does not open a connection for each.
- (void)radioSelectStationAtIndex:(NSUInteger)index
{
    NSArray *stations = [[RadioManager sharedManager] stations];
    if (index >= [stations count]) {
        return;
    }
    RadioStation *station = [stations objectAtIndex:index];
    RadioManager *radio = [RadioManager sharedManager];
    if ([radio isPlaying] && [[radio currentStationName] isEqualToString:[station name]]) {
        // Back to the station that plays: forget a choice not tuned in yet
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(playPendingStation)
                                                   object:nil];
        [pendingRadioStation release];
        pendingRadioStation = nil;
        [self setRadioStatus:[NSString stringWithFormat:@"Playing: %@", [station name]]];
        [self updateControls];
        return;
    }
    [pendingRadioStation release];
    pendingRadioStation = [station retain];
    [self setRadioStatus:[NSString stringWithFormat:@"Tuning in %@...", [station name]]];
    [radioTextLabel setStringValue:@""];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(playPendingStation)
                                               object:nil];
    [self performSelector:@selector(playPendingStation) withObject:nil afterDelay:0.3];
    [self updateControls];
}

- (void)playPendingStation
{
    RadioStation *station = [pendingRadioStation autorelease];
    pendingRadioStation = nil;
    if (station && playerMode == PlayerModeRadio) {
        [[RadioManager sharedManager] playStation:station];
    }
    [self updateControls];
}

- (void)radioSearch:(id)sender
{
    NSString *query = [[sender stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    [self setRadioStatus:@"Searching..."];
    if ([query length] == 0) {
        [[RadioManager sharedManager] loadLocalStations];
    } else {
        [[RadioManager sharedManager] searchStations:query];
    }
}

#pragma mark - Radio menu

- (void)rebuildRadioStationMenu
{
    NSMenu *menu = [[[NSApp mainMenu] itemWithTitle:@"Radio"] submenu];
    NSInteger separator = [menu indexOfItemWithTag:PlayerMenuStationListTag];
    if (separator < 0) {
        return;
    }
    while ([menu numberOfItems] > separator + 1) {
        [menu removeItemAtIndex:[menu numberOfItems] - 1];
    }
    for (RadioStation *station in [[RadioManager sharedManager] stations]) {
        NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:[station name] ?: @"Unknown Station"
                                           action:@selector(radioStationChosen:)
                                    keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:station];
    }
}

- (void)radioStationChosen:(id)sender
{
    if (playerMode != PlayerModeRadio) {
        [self enterRadioMode];
    }
    NSUInteger index = [[[RadioManager sharedManager] stations]
        indexOfObject:[sender representedObject]];
    if (index == NSNotFound) {
        return;
    }
    suppressFlowSelection = YES;
    [flowView setSelectedIndex:index];
    suppressFlowSelection = NO;
    [self radioSelectStationAtIndex:index];
}

- (BOOL)validateRadioMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(toggleRadioMode:)) {
        [item setState:(playerMode == PlayerModeRadio) ? NSOnState : NSOffState];
        return YES;
    }
    RadioStation *station = [item representedObject];
    if ([station isKindOfClass:[RadioStation class]]) {
        RadioManager *radio = [RadioManager sharedManager];
        BOOL on = playerMode == PlayerModeRadio && [radio isPlaying]
            && [[station name] isEqualToString:[radio currentStationName]];
        [item setState:on ? NSOnState : NSOffState];
    }
    return YES;
}

#pragma mark - RadioManagerDelegate

- (void)radioManagerDidUpdateStations:(RadioManager *)manager
{
    if (playerMode != PlayerModeRadio) {
        return;
    }
    NSUInteger count = [[manager stations] count];
    [flowView reloadData];
    if (count > 0) {
        [flowView updateTexturesForIndices:
            [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, MIN(24, count))]];
        suppressFlowSelection = YES;
        [flowView setSelectedIndex:0];
        suppressFlowSelection = NO;
    }
    if (![manager isPlaying]) {
        [self setRadioStatus:count > 0
            ? [NSString stringWithFormat:@"%lu stations", (unsigned long)count]
            : @"No stations found"];
    }
    [self rebuildRadioStationMenu];
    [self updateControls];
}

- (void)radioManagerDidStartPlaying:(RadioManager *)manager station:(RadioStation *)station
{
    [radioTextLabel setStringValue:@""];
    [self setRadioStatus:station ? [station name] : @"Playing"];
    NSUInteger index = [[manager stations] indexOfObject:station];
    if (index != NSNotFound && index != [flowView selectedIndex]) {
        suppressFlowSelection = YES;
        [flowView setSelectedIndex:index];
        suppressFlowSelection = NO;
    }
    [self updateControls];
    [self updateWindowTitle];
}

- (void)radioManagerDidStop:(RadioManager *)manager
{
    [radioTextLabel setStringValue:@""];
    NSString *name = [manager currentStationName];
    [self setRadioStatus:name ? [NSString stringWithFormat:@"%@ - Stopped", name]
                                     : @"Stopped"];
    [self updateControls];
}

- (void)radioManager:(RadioManager *)manager didFailWithError:(NSString *)errorMessage
{
    [self setRadioStatus:[NSString stringWithFormat:@"Cannot play: %@", errorMessage]];
    [self updateControls];
}

- (void)radioManagerDidUpdateStatus:(RadioManager *)manager status:(NSString *)status
{
    if ([status length] > 0) {
        [self setRadioStatus:status];
    }
    [self updateControls];
}

- (void)radioManager:(RadioManager *)manager didUpdateRadioText:(NSString *)radioText
{
    [radioTextLabel setStringValue:radioText ?: @""];
}

- (void)radioManager:(RadioManager *)manager didUpdateMetadata:(NSDictionary *)metadata
{
    NSString *title = [metadata objectForKey:@"StreamTitle"];
    if ([title length] > 0) {
        [radioTextLabel setStringValue:title];
    }
}

- (void)radioManager:(RadioManager *)manager didLoadIconAtIndex:(NSUInteger)index
{
    if (playerMode == PlayerModeRadio) {
        [flowView updateTexturesForIndices:[NSIndexSet indexSetWithIndex:index]];
    }
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerController.h"
#import "PlayerController+Private.h"
#import "PlayerMenu.h"
#import "AppearanceMetrics.h"
#import "Podcast.h"
#import "PodcastEpisode.h"
#import "PodcastChapter.h"
#import "StreamPlayer.h"

// GNUstep's -setUsesAlternatingRowBackgroundColors: only has an effect when
// the active theme's NSColorList happens to supply two visibly distinct
// "rowBackgroundColor"/"alternateRowBackgroundColor" entries; under Eau it
// does not (ProcessesController.m's ProcessTableView hits the same thing),
// so the stripes are painted directly instead, the same way that table does.
@interface PodcastEpisodeTableView : NSTableView
@end

@implementation PodcastEpisodeTableView

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clipRect
{
    NSRect rowRect = [self rectOfRow:row];

    if ([self isRowSelected:row]) {
        [[NSColor selectedControlColor] setFill];
    } else if (row % 2 == 0) {
        [[NSColor controlBackgroundColor] setFill];
    } else {
        [[NSColor colorWithCalibratedWhite:0.93 alpha:1.0] setFill];
    }
    NSRectFill(rowRect);

    [super drawRow:row clipRect:clipRect];
}

@end

@implementation PlayerController (Podcast)

- (void)createPodcastViews
{
    NSSearchField *field = [[[NSSearchField alloc] initWithFrame:NSZeroRect] autorelease];
    [[field cell] setPlaceholderString:@"Search Podcasts"];
    [field setTarget:self];
    [field setAction:@selector(podcastSearch:)];
    [field setHidden:YES];
    [contentView addSubview:field];
    podcastSearchField = field;

    subscribeButton = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [subscribeButton setBezelStyle:NSRoundedBezelStyle];
    [subscribeButton setTitle:@"Subscribe"];
    [subscribeButton setTarget:self];
    [subscribeButton setAction:@selector(toggleSubscribe:)];
    [subscribeButton setRefusesFirstResponder:YES];
    [subscribeButton setHidden:YES];
    [contentView addSubview:subscribeButton];

    backButton = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
    [backButton setBezelStyle:NSRoundedBezelStyle];
    [backButton setTitle:@"< Shows"];
    [backButton setTarget:self];
    [backButton setAction:@selector(backToShows:)];
    [backButton setRefusesFirstResponder:YES];
    [backButton setHidden:YES];
    [contentView addSubview:backButton];

    episodeTableView = [[[PodcastEpisodeTableView alloc] initWithFrame:NSZeroRect] autorelease];
    NSTableColumn *titleColumn = [[[NSTableColumn alloc] initWithIdentifier:@"title"] autorelease];
    [[titleColumn headerCell] setStringValue:@"Title"];
    [titleColumn setWidth:300];
    [episodeTableView addTableColumn:titleColumn];

    NSTableColumn *dateColumn = [[[NSTableColumn alloc] initWithIdentifier:@"date"] autorelease];
    [[dateColumn headerCell] setStringValue:@"Date"];
    [dateColumn setWidth:140];
    [episodeTableView addTableColumn:dateColumn];

    NSTableColumn *durationColumn = [[[NSTableColumn alloc] initWithIdentifier:@"duration"] autorelease];
    [[durationColumn headerCell] setStringValue:@"Duration"];
    [durationColumn setWidth:70];
    [episodeTableView addTableColumn:durationColumn];

    [episodeTableView setDataSource:self];
    [episodeTableView setDelegate:self];
    [episodeTableView setTarget:self];
    [episodeTableView setDoubleAction:@selector(playSelectedEpisode:)];
    [episodeTableView setAllowsEmptySelection:YES];

    episodeScrollView = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    [episodeScrollView setDocumentView:episodeTableView];
    [episodeScrollView setHasVerticalScroller:YES];
    [episodeScrollView setAutohidesScrollers:YES];
    [episodeScrollView setBorderType:NSBezelBorder];
    [episodeScrollView setHidden:YES];
    [contentView addSubview:episodeScrollView];

    // Built in the order ODLogWindowController/MarkdownReader's AppController
    // use for a programmatic wrapping NSTextView in an NSScrollView: size
    // the scroll view first and read its real contentSize back, then give
    // the text view an explicit -setMaxSize: and container size matching
    // it. Skipping -setMaxSize: leaves it capped at the view's small
    // creation-time frame, which produces a negative, warned-about
    // container width once -layoutPodcastMode later resizes it larger.
    showNotesScrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 100, 80)] autorelease];
    [showNotesScrollView setHasVerticalScroller:YES];
    [showNotesScrollView setAutohidesScrollers:YES];
    [showNotesScrollView setBorderType:NSBezelBorder];

    NSSize notesContentSize = [showNotesScrollView contentSize];
    showNotesTextView = [[[NSTextView alloc]
        initWithFrame:NSMakeRect(0, 0, notesContentSize.width, notesContentSize.height)] autorelease];
    [showNotesTextView setMinSize:NSMakeSize(0.0, notesContentSize.height)];
    [showNotesTextView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [showNotesTextView setVerticallyResizable:YES];
    [showNotesTextView setHorizontallyResizable:NO];
    [showNotesTextView setAutoresizingMask:NSViewWidthSizable];
    [showNotesTextView setEditable:NO];
    [showNotesTextView setSelectable:YES];
    [showNotesTextView setDrawsBackground:YES];
    [showNotesTextView setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [showNotesTextView setTextContainerInset:NSMakeSize(4.0, 4.0)];
    [[showNotesTextView textContainer] setContainerSize:NSMakeSize(notesContentSize.width, FLT_MAX)];
    [[showNotesTextView textContainer] setWidthTracksTextView:YES];

    [showNotesScrollView setDocumentView:showNotesTextView];
    [showNotesScrollView setHidden:YES];
    [contentView addSubview:showNotesScrollView];

    podcastTimelineView = [[[PlayerTimelineView alloc] initWithFrame:NSZeroRect] autorelease];
    [podcastTimelineView setTarget:self];
    [podcastTimelineView setAction:@selector(podcastTimelineSeek:)];
    [podcastTimelineView setEnabled:NO];
    [podcastTimelineView setHidden:YES];
    [contentView addSubview:podcastTimelineView];
}

#pragma mark - Mode switching

- (IBAction)toggleBrowsePodcasts:(id)sender
{
    if (playerMode == PlayerModePodcast) {
        [self exitPodcastMode];
    } else {
        [self enterPodcastMode];
    }
}

- (void)enterPodcastMode
{
    [self enterPodcastModeResuming:NO];
}

- (void)enterPodcastModeResuming:(BOOL)resume
{
    if (playerMode == PlayerModePodcast) {
        return;
    }
    // Both modes play through the shared RadioManager; switching straight
    // from one to the other has to stop the radio first, or it would keep
    // playing underneath the podcast screen
    if (playerMode == PlayerModeRadio) {
        [self exitRadioMode];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [session stop];
    [self showCoverArt];
    playerMode = PlayerModePodcast;
    [defaults setInteger:PlayerModePodcast forKey:PlayerDefaultsMode];

    RadioManager *radio = [RadioManager sharedManager];
    [radio setDelegate:self];
    [radio setVolume:[self volume]];
    [radio setMuted:[session muted]];

    PodcastManager *podcasts = [PodcastManager sharedManager];
    [podcasts setDelegate:self];
    [podcasts clearSelectedShow];

    // Back where it was left only when resuming at launch; switching modes
    // within a running session starts the search box, and the Subscribe
    // button it drives, clean
    NSString *query = resume ? ([defaults stringForKey:PlayerDefaultsPodcastSearch] ?: @"") : @"";
    [podcastSearchField setStringValue:query];
    [subscribeButton setTitle:@"Subscribe"];
    [subscribeButton setEnabled:NO];

    Podcast *restoredShow = resume
        ? [Podcast podcastWithPropertyList:[defaults dictionaryForKey:PlayerDefaultsPodcastShow]]
        : nil;
    if (restoredShow) {
        [pendingResumeEpisodeIdentifier release];
        pendingResumeEpisodeIdentifier = [[defaults stringForKey:PlayerDefaultsPodcastEpisode] copy];
        pendingResumePosition = [defaults doubleForKey:PlayerDefaultsPodcastPosition];
        pendingResumeShouldPlay = [defaults boolForKey:PlayerDefaultsPodcastPlaying];
        [self setRadioStatus:@"Loading episodes..."];
        [podcasts selectShow:restoredShow];
    } else {
        [self setRadioStatus:@"Loading..."];
        [flowView reloadData];
        [podcasts searchPodcasts:query];
    }

    [self layoutSubviews];
    [self updateControls];
    [self updateWindowTitle];
    [mainWindow makeFirstResponder:podcastSearchField];
}

- (void)exitPodcastMode
{
    if (playerMode != PlayerModePodcast) {
        return;
    }
    [[RadioManager sharedManager] stop];
    [progressIndicator stopAnimation:self];
    [[PodcastManager sharedManager] clearSelectedShow];
    [currentPlayingEpisode release];
    currentPlayingEpisode = nil;
    [currentPlayingPodcast release];
    currentPlayingPodcast = nil;
    [positionTimer invalidate];
    positionTimer = nil;
    playerMode = PlayerModeLocal;
    [[NSUserDefaults standardUserDefaults] setInteger:PlayerModeLocal forKey:PlayerDefaultsMode];

    [self layoutSubviews];
    [self playlistDidChange];
    [mainWindow makeFirstResponder:contentView];
}

// Called from -applicationShouldTerminate: while the episode is still
// playing (or sitting where it was stopped), so -currentTime reads the
// real position rather than whatever it was left at by a later -stop.
- (void)savePodcastPlaybackStateForQuit
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (currentPlayingPodcast) {
        [defaults setObject:[currentPlayingPodcast propertyList] forKey:PlayerDefaultsPodcastShow];
    }
    NSString *identifier = [currentPlayingEpisode guid] ?: [currentPlayingEpisode streamURL];
    [defaults setObject:identifier ?: @"" forKey:PlayerDefaultsPodcastEpisode];
    StreamPlayer *player = [[RadioManager sharedManager] player];
    [defaults setDouble:(player ? [player currentTime] : 0) forKey:PlayerDefaultsPodcastPosition];
    [defaults setBool:[[RadioManager sharedManager] isPlaying] forKey:PlayerDefaultsPodcastPlaying];
}

#pragma mark - Layout

// Shows screen: the same carousel + search field idiom as Radio, with a
// Subscribe/Unsubscribe button beside the search field. Episodes screen:
// a Back button where the search field was, and a table in place of the
// carousel - episodes share one artwork, so a table of title/date/duration
// carries more information than a row of identical covers.
- (void)layoutPodcastMode
{
    NSRect bounds = [contentView bounds];
    CGFloat W = NSWidth(bounds);
    CGFloat H = NSHeight(bounds);
    CGFloat left = METRICS_CONTENT_SIDE_MARGIN;
    CGFloat right = W - METRICS_CONTENT_SIDE_MARGIN;
    BOOL showingEpisodes = [[PodcastManager sharedManager] currentShow] != nil;

    [flowView setUncoveredRects:nil];
    [contentView setBlackBackground:NO];
    [self setViews:[self trackInfoViews] hidden:YES];
    [self setViews:[self positionViews] hidden:YES];
    [self setViews:@[searchField, radioTextLabel] hidden:YES];
    [self setViews:@[statusLabel] hidden:NO];
    [self setViews:[self transportViews] hidden:NO];
    [self setViews:[self volumeViews] hidden:NO];
    [self setViews:@[podcastSearchField, subscribeButton] hidden:showingEpisodes];
    [self setViews:@[backButton, episodeScrollView, showNotesScrollView] hidden:!showingEpisodes];
    [self setViews:@[currentTimeLabel, podcastTimelineView, totalTimeLabel] hidden:!showingEpisodes];
    [self setViews:@[topBarView] hidden:NO];
    [flowView setHidden:showingEpisodes];

    CGFloat y = METRICS_CONTENT_BOTTOM_MARGIN;
    [self layoutTransportCenteredAt:NSMidX(bounds) y:y];
    y += 24 + METRICS_SPACE_12;

    [self layoutVolumeCenteredAt:NSMidX(bounds) y:y];
    y += METRICS_BUTTON_HEIGHT + METRICS_SPACE_16;

    // Same vertical rhythm as Radio even without the radio-text line, so
    // the status row lands in the same place in both modes
    y += 15 + 4;
    [statusLabel setFrame:NSMakeRect(left, y, right - left, 17)];
    [self placeRadioSpinner];
    y += 17 + METRICS_SPACE_12;

    CGFloat topRowY = H - METRICS_CONTENT_TOP_MARGIN - METRICS_TEXT_INPUT_FIELD_HEIGHT;
    CGFloat buttonY = topRowY + (METRICS_TEXT_INPUT_FIELD_HEIGHT - METRICS_BUTTON_HEIGHT) / 2.0;

    CGFloat topBarBottom = topRowY - METRICS_SPACE_12;
    [topBarView setFrame:NSMakeRect(0, topBarBottom, W, H - topBarBottom)];

    if (showingEpisodes) {
        [backButton setFrame:NSMakeRect(left, buttonY, METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];

        // Bottom-up, under the Back button: the timeline sits right above
        // the transport cluster (it is about current playback, so it
        // belongs with the controls below it), show notes above that, and
        // the episode table - the primary content - takes whatever space
        // is left at the top.
        CGFloat timelineRowHeight = 16.0;
        [self layoutTimelineRowFrom:left to:right y:y];
        CGFloat afterTimeline = y + timelineRowHeight + METRICS_SPACE_12;

        CGFloat notesHeight = 80.0;
        [showNotesScrollView setFrame:NSMakeRect(left, afterTimeline, right - left, notesHeight)];
        CGFloat afterNotes = afterTimeline + notesHeight + METRICS_SPACE_12;

        [episodeScrollView setFrame:NSMakeRect(left, afterNotes, right - left,
                                                topRowY - METRICS_SPACE_12 - afterNotes)];
        // The carousel draws through its own X subwindow, which -setHidden:
        // above does not unmap - it has to be parked at zero size, same as
        // when video replaces it (setPictureFrame:'s own doc comment)
        [self setPictureFrame:NSZeroRect];
    } else {
        CGFloat buttonWidth = METRICS_BUTTON_MIN_WIDTH;
        CGFloat fieldWidth = (right - left) - buttonWidth - METRICS_SPACE_8;
        [podcastSearchField setFrame:NSMakeRect(left, topRowY, fieldWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
        [subscribeButton setFrame:NSMakeRect(left + fieldWidth + METRICS_SPACE_8, buttonY,
                                              buttonWidth, METRICS_BUTTON_HEIGHT)];
        [self setPictureFrame:NSMakeRect(0, y, W, topRowY - METRICS_SPACE_12 - y)];
    }
}

#pragma mark - Shows screen

- (NSArray *)podcastShowsList
{
    PodcastManager *podcasts = [PodcastManager sharedManager];
    if ([[podcastSearchField stringValue] length] > 0) {
        return [podcasts searchResults];
    }
    return [podcasts subscriptions];
}

- (void)updatePodcastSubscribeButton
{
    NSArray *shows = [self podcastShowsList];
    NSUInteger index = [flowView selectedIndex];
    if (index >= [shows count]) {
        [subscribeButton setEnabled:NO];
        return;
    }
    Podcast *show = [shows objectAtIndex:index];
    BOOL subscribed = [[PodcastManager sharedManager] isSubscribed:show];
    [subscribeButton setTitle:subscribed ? @"Unsubscribe" : @"Subscribe"];
    [subscribeButton setEnabled:YES];
}

- (void)prefetchPodcastArtworkAround:(NSUInteger)index
{
    PodcastManager *podcasts = [PodcastManager sharedManager];
    NSArray *shows = [self podcastShowsList];
    NSUInteger count = [shows count];
    if (count == 0) {
        return;
    }
    NSUInteger first = index > 12 ? index - 12 : 0;
    NSUInteger last = MIN(count, index + 13);
    for (NSUInteger i = first; i < last; i++) {
        [podcasts prefetchArtworkForPodcast:[shows objectAtIndex:i] atIndex:i];
    }
    [flowView updateTexturesForIndices:
        [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(first, last - first)]];
}

// Browsing the carousel (mouse or arrow keys) only updates what is on
// screen here - the Subscribe button's state and which artwork is loaded.
// It does NOT open the show: unlike Radio (where resting plays a preview
// at once), opening a podcast's episode list is a deliberate step, taken
// by pressing Play/Space (-podcastPlayPause) or choosing a subscription
// from the Podcasts menu (-podcastShowChosen:).
- (void)podcastBrowseToShowAtIndex:(NSUInteger)index
{
    NSArray *shows = [self podcastShowsList];
    if (index >= [shows count]) {
        return;
    }
    [self prefetchPodcastArtworkAround:index];
    [self updatePodcastSubscribeButton];
}

- (void)podcastSearch:(id)sender
{
    NSString *query = [[sender stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:query forKey:PlayerDefaultsPodcastSearch];
    [defaults synchronize];
    [[PodcastManager sharedManager] searchPodcasts:query];
}

- (IBAction)toggleSubscribe:(id)sender
{
    NSArray *shows = [self podcastShowsList];
    NSUInteger index = [flowView selectedIndex];
    if (index >= [shows count]) {
        return;
    }
    Podcast *show = [shows objectAtIndex:index];
    PodcastManager *podcasts = [PodcastManager sharedManager];
    if ([podcasts isSubscribed:show]) {
        [podcasts unsubscribeFromPodcast:show];
    } else {
        [podcasts subscribeToPodcast:show];
    }
    [self updatePodcastSubscribeButton];
}

#pragma mark - Episodes screen

- (IBAction)backToShows:(id)sender
{
    [[PodcastManager sharedManager] clearSelectedShow];
    [flowView reloadData];
    [self layoutSubviews];
    [self updateControls];
    [mainWindow makeFirstResponder:podcastSearchField];
}

- (void)playPodcastEpisodeAtIndex:(NSUInteger)index
{
    NSArray *episodes = [[PodcastManager sharedManager] episodes];
    if (index >= [episodes count]) {
        return;
    }
    PodcastEpisode *episode = [episodes objectAtIndex:index];
    if ([[episode streamURL] length] == 0) {
        return;
    }
    [currentPlayingEpisode release];
    currentPlayingEpisode = [episode retain];
    [currentPlayingPodcast release];
    currentPlayingPodcast = [[[PodcastManager sharedManager] currentShow] retain];
    [[PodcastManager sharedManager] markEpisodePlayed:episode];
    [podcastTimelineView setDuration:0];
    [podcastTimelineView setCurrentTime:0];
    [self loadChaptersForEpisode:episode];
    [[RadioManager sharedManager] setDelegate:self];
    [[RadioManager sharedManager] playURL:[episode streamURL] displayName:[episode title]];
    [episodeTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self updateShowNotesForSelection];
    [self updateControls];
}

- (void)applyChapters:(NSArray *)chapters toTimeline:(PlayerTimelineView *)timeline
{
    NSMutableArray *times = [NSMutableArray arrayWithCapacity:[chapters count]];
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[chapters count]];
    for (PodcastChapter *chapter in chapters) {
        [times addObject:@([chapter startTime])];
        [titles addObject:[chapter title] ?: @""];
    }
    [timeline setChapterTimes:times titles:titles];
}

// Chapters come either inline from the feed (Podlove Simple Chapters,
// already parsed) or, when the feed only pointed at a separate JSON file
// (Podcast Namespace <podcast:chapters url>), fetched here the first time
// the episode is actually played - not for every episode in the list.
- (void)loadChaptersForEpisode:(PodcastEpisode *)episode
{
    NSArray *chapters = [episode chapters];
    if ([chapters count] > 0) {
        [self applyChapters:chapters toTimeline:podcastTimelineView];
        return;
    }
    [podcastTimelineView setChapterTimes:nil titles:nil];

    NSString *url = [episode chaptersURL];
    if ([url length] == 0) {
        return;
    }
    [PodcastChapter fetchChaptersFromURL:url completion:^(NSArray *fetched, NSError *error) {
        if (self->currentPlayingEpisode != episode || [fetched count] == 0) {
            return;   // a different episode started meanwhile, or nothing came back
        }
        [episode setChapters:fetched];
        [self applyChapters:fetched toTimeline:self->podcastTimelineView];
    }];
}

- (void)playSelectedEpisode:(id)sender
{
    NSInteger row = [episodeTableView clickedRow];
    if (row < 0) {
        row = [episodeTableView selectedRow];
    }
    if (row < 0) {
        return;
    }
    [self playPodcastEpisodeAtIndex:(NSUInteger)row];
}

#pragma mark - Controls

- (void)podcastPlayPause
{
    PodcastManager *podcasts = [PodcastManager sharedManager];
    if ([podcasts currentShow] == nil) {
        // Shows screen: Play is the explicit "open this show" action -
        // browsing the carousel itself never opens the episode list
        NSArray *shows = [self podcastShowsList];
        NSUInteger index = [flowView selectedIndex];
        if (index < [shows count]) {
            [podcasts selectShow:[shows objectAtIndex:index]];
        }
        return;
    }
    RadioManager *radio = [RadioManager sharedManager];
    if ([radio isPlaying] || [self radioTuning]) {
        // A stream cannot resume where it paused; pausing stops it, as Radio does
        [self podcastStop];
        return;
    }
    NSInteger row = [episodeTableView selectedRow];
    if (row < 0 && [[podcasts episodes] count] > 0) {
        row = 0;
    }
    if (row >= 0) {
        [self playPodcastEpisodeAtIndex:(NSUInteger)row];
    }
}

- (void)podcastStop
{
    [[RadioManager sharedManager] stop];
    [self updateControls];
}

- (void)podcastStepEpisodeBy:(NSInteger)delta
{
    NSInteger count = (NSInteger)[[[PodcastManager sharedManager] episodes] count];
    if (count < 2) {
        return;
    }
    NSInteger current = [episodeTableView selectedRow];
    if (current < 0) {
        current = 0;
    }
    NSInteger newIndex = ((current + delta) % count + count) % count;
    [self playPodcastEpisodeAtIndex:(NSUInteger)newIndex];
}

- (void)podcastNextEpisode
{
    [self podcastStepEpisodeBy:1];
}

- (void)podcastPreviousEpisode
{
    [self podcastStepEpisodeBy:-1];
}

- (void)updatePodcastControls
{
    RadioManager *radio = [RadioManager sharedManager];
    PodcastManager *podcasts = [PodcastManager sharedManager];
    BOOL showingEpisodes = [podcasts currentShow] != nil;
    NSUInteger episodeCount = [[podcasts episodes] count];
    BOOL tuning = [self radioTuning];
    BOOL active = [radio isPlaying] || tuning;

    if (tuning) {
        [progressIndicator startAnimation:self];
    } else {
        [progressIndicator stopAnimation:self];
    }
    // On the Shows screen, Play is relabeled "Open" - it opens the
    // highlighted show's episode list rather than making any sound
    BOOL canOpenShow = !showingEpisodes && [[self podcastShowsList] count] > 0;
    [playButton setImage:active ? pauseImage : playImage];
    [playButton setTitle:active ? @"Pause" : (showingEpisodes ? @"Play" : @"Open")];
    [playButton setToolTip:[playButton title]];
    [playButton setEnabled:(showingEpisodes && episodeCount > 0) || canOpenShow];
    [stopButton setEnabled:active];
    [previousButton setEnabled:showingEpisodes && episodeCount > 1];
    [nextButton setEnabled:showingEpisodes && episodeCount > 1];
    [self revalidateMenu];
}

#pragma mark - Podcasts menu

- (void)rebuildPodcastSubscriptionMenu
{
    NSMenu *menu = [[[NSApp mainMenu] itemWithTitle:@"Podcasts"] submenu];
    NSInteger separator = [menu indexOfItemWithTag:PlayerMenuSubscriptionListTag];
    if (separator < 0) {
        return;
    }
    while ([menu numberOfItems] > separator + 1) {
        [menu removeItemAtIndex:[menu numberOfItems] - 1];
    }
    for (Podcast *show in [[PodcastManager sharedManager] subscriptions]) {
        NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:[show name] ?: @"Unknown Podcast"
                                           action:@selector(podcastShowChosen:)
                                    keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:show];
    }
}

- (void)podcastShowChosen:(id)sender
{
    if (playerMode != PlayerModePodcast) {
        [self enterPodcastMode];
    }
    [[PodcastManager sharedManager] selectShow:[sender representedObject]];
}

- (BOOL)validatePodcastMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(toggleBrowsePodcasts:)) {
        [item setState:(playerMode == PlayerModePodcast) ? NSOnState : NSOffState];
        return YES;
    }
    Podcast *show = [item representedObject];
    if ([show isKindOfClass:[Podcast class]]) {
        Podcast *current = [[PodcastManager sharedManager] currentShow];
        BOOL on = playerMode == PlayerModePodcast && current != nil
            && [current isSamePodcastAs:show];
        [item setState:on ? NSOnState : NSOffState];
    }
    return YES;
}

#pragma mark - PodcastManagerDelegate

- (void)podcastManagerDidUpdateSearchResults:(PodcastManager *)manager
{
    if (playerMode != PlayerModePodcast || [manager currentShow] != nil) {
        return;
    }
    [flowView reloadData];
    NSArray *shows = [self podcastShowsList];
    if ([shows count] > 0) {
        suppressFlowSelection = YES;
        [flowView setSelectedIndex:0];
        suppressFlowSelection = NO;
        [self prefetchPodcastArtworkAround:0];
    }
    [self updatePodcastSubscribeButton];
    [self updateControls];
}

- (void)podcastManagerDidUpdateSubscriptions:(PodcastManager *)manager
{
    if (playerMode != PlayerModePodcast) {
        return;
    }
    [self rebuildPodcastSubscriptionMenu];
    if ([manager currentShow] == nil && [[podcastSearchField stringValue] length] == 0) {
        [flowView reloadData];
    }
    [self updatePodcastSubscribeButton];
}

- (void)podcastManager:(PodcastManager *)manager didUpdateEpisodesForShow:(Podcast *)show
   episodes:(NSArray *)episodes error:(NSString *)error
{
    if (playerMode != PlayerModePodcast) {
        return;
    }
    if (!episodes) {
        [self setRadioStatus:[NSString stringWithFormat:@"Cannot load episodes: %@", error]];
        [manager clearSelectedShow];
        [self layoutSubviews];
        [self updateControls];
        return;
    }
    [self layoutSubviews];
    [episodeTableView reloadData];
    [self setRadioStatus:[NSString stringWithFormat:@"%tu episodes - %@",
        [episodes count], [show name]]];

    // Opening a show never restarts something already underway: first, an
    // episode of this exact show still loaded from earlier this session
    // (Back doesn't stop playback, so reopening must not jump to a
    // different episode); second, the show/episode/position saved at the
    // last quit, restored at launch. Only once neither applies does Play
    // actually pick something - the newest episode, or the oldest one not
    // yet heard, per Preferences.
    NSString *continuingIdentifier = (currentPlayingEpisode != nil
        && currentPlayingPodcast != nil && [currentPlayingPodcast isSamePodcastAs:show])
        ? ([currentPlayingEpisode guid] ?: [currentPlayingEpisode streamURL])
        : nil;
    NSUInteger continuingIndex = continuingIdentifier
        ? [self indexOfEpisodeMatchingIdentifier:continuingIdentifier inEpisodes:episodes]
        : NSNotFound;

    if (continuingIndex != NSNotFound) {
        [episodeTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:continuingIndex] byExtendingSelection:NO];
        [episodeTableView scrollRowToVisible:continuingIndex];
    } else {
        NSUInteger resumeIndex = pendingResumeEpisodeIdentifier
            ? [self indexOfEpisodeMatchingIdentifier:pendingResumeEpisodeIdentifier inEpisodes:episodes]
            : NSNotFound;
        if (resumeIndex != NSNotFound) {
            [episodeTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:resumeIndex] byExtendingSelection:NO];
            [episodeTableView scrollRowToVisible:resumeIndex];
            if (pendingResumeShouldPlay) {
                [self playPodcastEpisodeAtIndex:resumeIndex];
            }
            // Not auto-playing: pendingResumeEpisodeIdentifier stays armed
            // so the saved position is applied once the user presses Play
            // on the already-selected row (-podcastPlayPause plays the
            // selection)
        } else {
            if (pendingResumeEpisodeIdentifier) {
                // The saved episode is no longer in the feed; nothing to resume
                [pendingResumeEpisodeIdentifier release];
                pendingResumeEpisodeIdentifier = nil;
            }
            NSUInteger autoPlayIndex = [self indexOfAutoPlayEpisodeInEpisodes:episodes];
            if (autoPlayIndex != NSNotFound) {
                [self playPodcastEpisodeAtIndex:autoPlayIndex];
            }
        }
    }
    [self updateShowNotesForSelection];
    [self updateControls];
    [mainWindow makeFirstResponder:episodeTableView];
}

// Play is what opens a show - the newest episode by default, or the
// oldest one Preferences says has not been played yet (scanning from the
// end of a newest-first feed). Everything already played falls back to
// the newest, same as the default.
- (NSUInteger)indexOfAutoPlayEpisodeInEpisodes:(NSArray *)episodes
{
    if ([episodes count] == 0) {
        return NSNotFound;
    }
    if (![PreferencesController podcastAutoPlayOldestUnplayed]) {
        return 0;
    }
    PodcastManager *podcasts = [PodcastManager sharedManager];
    for (NSInteger i = (NSInteger)[episodes count] - 1; i >= 0; i--) {
        if (![podcasts isEpisodePlayed:[episodes objectAtIndex:(NSUInteger)i]]) {
            return (NSUInteger)i;
        }
    }
    return 0;
}

- (NSUInteger)indexOfEpisodeMatchingIdentifier:(NSString *)identifier inEpisodes:(NSArray *)episodes
{
    for (NSUInteger i = 0; i < [episodes count]; i++) {
        PodcastEpisode *episode = [episodes objectAtIndex:i];
        NSString *episodeIdentifier = [episode guid] ?: [episode streamURL];
        if ([episodeIdentifier isEqualToString:identifier]) {
            return i;
        }
    }
    return NSNotFound;
}

- (void)podcastManagerDidUpdateStatus:(PodcastManager *)manager status:(NSString *)status
{
    if (playerMode != PlayerModePodcast) {
        return;
    }
    if ([status length] > 0) {
        [self setRadioStatus:status];
    }
}

- (void)podcastManager:(PodcastManager *)manager didLoadArtworkAtIndex:(NSUInteger)index
{
    if (playerMode == PlayerModePodcast && [manager currentShow] == nil) {
        [flowView updateTexturesForIndices:[NSIndexSet indexSetWithIndex:index]];
    }
}

#pragma mark - RadioManagerDelegate forwarding (called from PlayerController+Radio.m)

- (void)podcastDidStartPlayingEpisode
{
    [self setRadioStatus:currentPlayingEpisode ? [currentPlayingEpisode title] : @"Playing"];
    // The chance to resume applies once, to whichever episode starts
    // playing first after launch - whether that was auto-played or the
    // user pressed Play on the already-selected, restored row
    if (pendingResumeEpisodeIdentifier) {
        NSString *identifier = [currentPlayingEpisode guid] ?: [currentPlayingEpisode streamURL];
        if ([identifier isEqualToString:pendingResumeEpisodeIdentifier]) {
            [[[RadioManager sharedManager] player] seekToTime:pendingResumePosition];
        }
        [pendingResumeEpisodeIdentifier release];
        pendingResumeEpisodeIdentifier = nil;
    }
    if (!positionTimer) {
        positionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                           target:self
                                                         selector:@selector(positionTimerFired:)
                                                         userInfo:nil
                                                          repeats:YES];
    }
    [self updatePodcastPosition];
    [self updateControls];
    [self updateWindowTitle];
    // The podcast started on its own: a client's pause ends here
    [mediaRemote notePlaybackChanged];
}

- (void)podcastDidStop
{
    NSString *title = [currentPlayingEpisode title];
    [self setRadioStatus:title ? [NSString stringWithFormat:@"%@ - Stopped", title] : @"Stopped"];
    [positionTimer invalidate];
    positionTimer = nil;
    [self updateControls];
}

// Mode dispatch target of PlayerController.m's -updatePosition (its
// -positionTimerFired: drives both modes through the same ivar/timer)
- (void)updatePodcastPosition
{
    StreamPlayer *player = [[RadioManager sharedManager] player];
    NSTimeInterval duration = player ? [player duration] : 0;
    NSTimeInterval position = player ? [player currentTime] : 0;

    [currentTimeLabel setStringValue:[self formatTime:position]];
    [totalTimeLabel setStringValue:duration > 0 ? [self formatTime:duration] : @""];
    [podcastTimelineView setEnabled:duration > 0];
    [podcastTimelineView setDuration:duration];
    [podcastTimelineView setCurrentTime:position];
}

- (void)podcastTimelineSeek:(id)sender
{
    StreamPlayer *player = [[RadioManager sharedManager] player];
    [player seekToTime:[podcastTimelineView currentTime]];
    [self updatePodcastPosition];
}

- (void)podcastDidFailWithError:(NSString *)errorMessage
{
    [self setRadioStatus:[NSString stringWithFormat:@"Cannot play: %@", errorMessage]];
    [positionTimer invalidate];
    positionTimer = nil;
    [self updateControls];
}

#pragma mark - Episode table (NSTableViewDataSource/Delegate)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView != episodeTableView) {
        return 0;
    }
    return (NSInteger)[[[PodcastManager sharedManager] episodes] count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    if (tableView != episodeTableView) {
        return nil;
    }
    NSArray *episodes = [[PodcastManager sharedManager] episodes];
    if (row < 0 || (NSUInteger)row >= [episodes count]) {
        return nil;
    }
    PodcastEpisode *episode = [episodes objectAtIndex:row];
    NSString *identifier = [column identifier];
    if ([identifier isEqualToString:@"title"]) {
        return [episode title] ?: @"";
    }
    if ([identifier isEqualToString:@"date"]) {
        return [episode pubDateString] ?: @"";
    }
    if ([identifier isEqualToString:@"duration"]) {
        return [episode formattedDuration];
    }
    return nil;
}

// The cell's own opaque background would otherwise paint over
// PodcastEpisodeTableView's striping (ProcessesController.m's
// willDisplayCell: does the same for the same reason).
- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell
   forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView != episodeTableView) {
        return;
    }
    if ([cell respondsToSelector:@selector(setDrawsBackground:)]) {
        [cell setDrawsBackground:NO];
    }
    if ([cell respondsToSelector:@selector(setTextColor:)]) {
        [cell setTextColor:[tableView isRowSelected:row]
            ? [NSColor selectedTextColor] : [NSColor controlTextColor]];
    }
}

#pragma mark - Show notes

// AppKit posts NSTableViewSelectionDidChangeNotification, which a delegate
// implementing this method receives automatically - no explicit observer
// registration needed.
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if ([notification object] != episodeTableView) {
        return;
    }
    [self updateShowNotesForSelection];
}

- (void)updateShowNotesForSelection
{
    NSInteger row = [episodeTableView selectedRow];
    NSArray *episodes = [[PodcastManager sharedManager] episodes];
    NSString *notes = @"";
    if (row >= 0 && (NSUInteger)row < [episodes count]) {
        PodcastEpisode *episode = [episodes objectAtIndex:row];
        notes = [self plainTextFromHTML:[episode summary]];
    }
    [showNotesTextView setString:notes ?: @""];
}

// Feeds write show notes as a snippet of HTML (<description> or
// <itunes:summary>); strip it down to plain text good enough for a
// read-only notes box rather than pulling in an HTML renderer for it.
// Block-level tags become line breaks first, or the result would be one
// run-on paragraph.
- (NSString *)plainTextFromHTML:(NSString *)html
{
    if ([html length] == 0) {
        return @"";
    }
    NSMutableString *text = [html mutableCopy];
    NSArray *blockBreaks = @[@"<br>", @"<br/>", @"<br />", @"<BR>", @"<BR/>", @"<BR />",
                              @"</p>", @"</P>", @"</div>", @"</DIV>", @"</li>", @"</LI>"];
    for (NSString *tag in blockBreaks) {
        [text replaceOccurrencesOfString:tag withString:@"\n"
                                  options:0 range:NSMakeRange(0, [text length])];
    }

    NSMutableString *stripped = [NSMutableString stringWithCapacity:[text length]];
    BOOL inTag = NO;
    for (NSUInteger i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '<') { inTag = YES; continue; }
        if (c == '>') { inTag = NO; continue; }
        if (!inTag) { [stripped appendFormat:@"%C", c]; }
    }
    [text release];

    NSDictionary *entities = @{
        @"&amp;": @"&", @"&lt;": @"<", @"&gt;": @">",
        @"&quot;": @"\"", @"&#39;": @"'", @"&apos;": @"'", @"&nbsp;": @" "
    };
    for (NSString *entity in entities) {
        [stripped replaceOccurrencesOfString:entity withString:[entities objectForKey:entity]
                                      options:0 range:NSMakeRange(0, [stripped length])];
    }

    while ([stripped rangeOfString:@"\n\n\n"].location != NSNotFound) {
        [stripped replaceOccurrencesOfString:@"\n\n\n" withString:@"\n\n"
                                      options:0 range:NSMakeRange(0, [stripped length])];
    }
    return [stripped stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end

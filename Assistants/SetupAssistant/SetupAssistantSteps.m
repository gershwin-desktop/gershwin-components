/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SetupAssistantSteps.h"
#import <GSLocaleHelper.h>
#import <GSAssistantFramework.h>
#import <unistd.h>
#import <sys/types.h>
#import <pwd.h>

/* Geometry shared by every step design.
 *
 * The assistant card hands each step view 378 points of width (620 point
 * window - 170 point sidebar - 2 x 24 point margin - 2 x 12 point card inset)
 * and 264 points of height.  Each step lays out a fixed-size design that fits
 * inside that, and SAStepContainerView keeps the design centered horizontally
 * and a little below the top of whatever frame the framework assigns - so no
 * control can ever be clipped off the right edge, at any display scale. */
static const CGFloat kSAStepWidth   = 366.0;
static const CGFloat kSALabelX      = 20.0;
static const CGFloat kSALabelWidth  = 130.0;
static const CGFloat kSAFieldX      = 154.0;   /* kSALabelX + kSALabelWidth + 4 */
static const CGFloat kSAFieldWidth  = 192.0;   /* kSAStepWidth - kSAFieldX - 20 */
static const CGFloat kSATextX       = 20.0;
static const CGFloat kSATextWidth   = 326.0;   /* kSAStepWidth - 2 * 20 */
static const CGFloat kSATopGap      = 12.0;    /* clears the card description */

#pragma mark - SAStepContainerView

@interface SAStepContainerView : NSView
- (void)setDesignView:(NSView *)designView;
@end

@implementation SAStepContainerView
{
    NSView *_designView;
}

- (void)dealloc {
    [_designView release];
    [super dealloc];
}

- (void)setDesignView:(NSView *)designView {
    if (_designView == designView) return;
    [_designView removeFromSuperview];
    [_designView release];
    _designView = [designView retain];
    if (_designView) {
        [self addSubview:_designView];
    }
    [self layoutDesignView];
}

/* The assistant framework sizes this view to fill the card, so every resize
 * has to re-place the design inside it. */
- (void)setFrameSize:(NSSize)size {
    NSSize oldSize = [self frame].size;
    [super setFrameSize:size];
    if (!NSEqualSizes(oldSize, size)) {
        [self layoutDesignView];
    }
}

- (void)setFrame:(NSRect)frame {
    NSSize oldSize = [self frame].size;
    [super setFrame:frame];
    if (!NSEqualSizes(oldSize, frame.size)) {
        [self layoutDesignView];
    }
}

- (void)layoutDesignView {
    if (!_designView) return;
    NSSize design = [_designView frame].size;
    NSSize bounds = [self bounds].size;

    CGFloat x = floor((bounds.width - design.width) / 2.0);
    if (x < 0.0) x = 0.0;

    CGFloat y = bounds.height - design.height - kSATopGap;
    if (y < 0.0) y = 0.0;

    [_designView setFrameOrigin:NSMakePoint(x, y)];
}

@end

#pragma mark - SAWelcomeStep

@implementation SAWelcomeStep

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Welcome", @"");
        self.stepDescription = NSLocalizedString(@"Welcome to the Setup Assistant. This assistant will help you configure your system.", @"");
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_stepView release];
    [_containerView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 160)];

    NSTextField *descLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kSATextX, 88, kSATextWidth, 68)];
    [descLabel setStringValue:NSLocalizedString(@"This assistant will help you set up your new Gershwin system. "
                                                 "You will be asked to configure your language, keyboard, regional settings, "
                                                 "create a user account, and set your computer name.", @"")];
    [descLabel setBezeled:NO];
    [descLabel setDrawsBackground:NO];
    [descLabel setEditable:NO];
    [descLabel setSelectable:NO];
    [descLabel setFont:[NSFont systemFontOfSize:13]];
    [[descLabel cell] setWraps:YES];
    [[descLabel cell] setScrollable:NO];
    [_stepView addSubview:descLabel];
    [descLabel release];

    NSTextField *clickLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kSATextX, 60, kSATextWidth, 20)];
    [clickLabel setStringValue:NSLocalizedString(@"Click Continue to begin.", @"")];
    [clickLabel setBezeled:NO];
    [clickLabel setDrawsBackground:NO];
    [clickLabel setEditable:NO];
    [clickLabel setSelectable:NO];
    [clickLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:clickLabel];
    [clickLabel release];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    return YES;
}

@end

#pragma mark - SALanguageKeyboardStep

@implementation SALanguageKeyboardStep

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Language and Keyboard", @"");
        self.stepDescription = NSLocalizedString(@"Select your language and keyboard layout.", @"");
        _keyboardManager = [[KeyboardManager alloc] init];
        [_keyboardManager detectKeyboardWithPasswd:NULL];
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_languageDropdown release];
    [_keyboardDropdown release];
    [_languageNames release];
    [_keyboardManager release];
    [_stepView release];
    [_containerView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 160)];

    _languageNames = [@[
        @"English", @"German", @"French", @"Spanish", @"Italian",
        @"Portuguese", @"Russian", @"Dutch", @"Danish", @"Swedish",
        @"Norwegian", @"Finnish", @"Japanese", @"Korean", @"Chinese",
        @"Czech", @"Hungarian", @"Polish", @"Slovak", @"Bulgarian",
        @"Ukrainian", @"Croatian", @"Romanian", @"Slovenian", @"Estonian",
        @"Latvian", @"Lithuanian", @"Icelandic", @"Greek", @"Turkish",
        @"Hebrew", @"Vietnamese", @"Thai"
    ] retain];

    CGFloat labelX = kSALabelX;
    CGFloat labelW = kSALabelWidth;
    CGFloat fieldX = kSAFieldX;
    CGFloat fieldW = kSAFieldWidth;
    CGFloat rowY = 130;

    NSTextField *langLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, rowY, labelW, 20)];
    [langLabel setStringValue:NSLocalizedString(@"Language:", @"")];
    [langLabel setBezeled:NO];
    [langLabel setDrawsBackground:NO];
    [langLabel setEditable:NO];
    [langLabel setSelectable:NO];
    [langLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:langLabel];
    [langLabel release];

    _languageDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, rowY - 4, fieldW, 26)];
    [_languageDropdown addItemsWithTitles:_languageNames];
    NSString *detectedLang = [self detectGSLanguage];
    if (detectedLang) {
        [_languageDropdown selectItemWithTitle:detectedLang];
    }
    [_stepView addSubview:_languageDropdown];

    rowY = 80;
    static const char *commonLayouts[][3] = {
        {"us", "US", "US English"},
        {"de", "German", "German"},
        {"fr", "French", "French"},
        {"es", "Spanish", "Spanish"},
        {"it", "Italian", "Italian"},
        {"pt", "Portuguese", "Portuguese"},
        {"ru", "Russian", "Russian"},
        {"nl", "Dutch", "Dutch"},
        {"dk", "Danish", "Danish"},
        {"se", "Swedish", "Swedish"},
        {"no", "Norwegian", "Norwegian"},
        {"fi", "Finnish", "Finnish"},
        {"jp", "Japanese", "Japanese"},
        {"kr", "Korean", "Korean"},
        {"cn", "Chinese", "Chinese"},
        {"cz", "Czech", "Czech"},
        {"hu", "Hungarian", "Hungarian"},
        {"pl", "Polish", "Polish"},
        {"gb", "UK", "UK English"},
        {"br", "Brazilian", "Brazilian"},
        {"ca", "Canadian", "Canadian"},
        {"tr", "Turkish", "Turkish"},
        {"il", "Hebrew", "Hebrew"},
        {"gr", "Greek", "Greek"},
        {NULL, NULL, NULL}
    };

    NSTextField *kbdLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, rowY, labelW, 20)];
    [kbdLabel setStringValue:NSLocalizedString(@"Keyboard Layout:", @"")];
    [kbdLabel setBezeled:NO];
    [kbdLabel setDrawsBackground:NO];
    [kbdLabel setEditable:NO];
    [kbdLabel setSelectable:NO];
    [kbdLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:kbdLabel];
    [kbdLabel release];

    _keyboardDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, rowY - 4, fieldW, 26)];

    NSString *detectedLayout = _keyboardManager.layout;
    for (int i = 0; commonLayouts[i][0]; i++) {
        NSString *labelStr = [NSString stringWithFormat:@"%s (%s)",
                             commonLayouts[i][2], commonLayouts[i][0]];
        [_keyboardDropdown addItemWithTitle:labelStr];
        [[_keyboardDropdown lastItem] setRepresentedObject:[NSString stringWithUTF8String:commonLayouts[i][0]]];

        if (detectedLayout && [[NSString stringWithUTF8String:commonLayouts[i][0]] isEqualToString:detectedLayout]) {
            [_keyboardDropdown selectItemWithTitle:labelStr];
        }
    }
    [_stepView addSubview:_keyboardDropdown];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (NSString *)detectGSLanguage {
    static const char *langMap[][2] = {
        {"de","German"},{"fr","French"},{"es","Spanish"},
        {"it","Italian"},{"pt","Portuguese"},{"ru","Russian"},
        {"nl","Dutch"},{"tr","Turkish"},{"il","Hebrew"},
        {"dk","Danish"},{"se","Swedish"},{"no","Norwegian"},
        {"fi","Finnish"},{"jp","Japanese"},{"kr","Korean"},
        {"cn","Chinese"},{"cz","Czech"},{"hu","Hungarian"},
        {"pl","Polish"},{"sk","Slovak"},{"bg","Bulgarian"},
        {"ua","Ukrainian"},{"hr","Croatian"},{"ro","Romanian"},
        {"si","Slovenian"},{"ee","Estonian"},{"lv","Latvian"},
        {"lt","Lithuanian"},{"is","Icelandic"},{"gr","Greek"},
        {"vn","Vietnamese"},{"th","Thai"},{"by","Belarusian"},
        {"mk","Macedonian"},{"mt","Maltese"},{"ca","French"},
        {"gb","English"},{"us","English"},{"br","Portuguese"},
        {NULL,NULL}
    };

    NSString *localeStr = _keyboardManager.language;
    if (!localeStr) return nil;

    NSString *langCode = nil;
    NSRange underscore = [localeStr rangeOfString:@"_"];
    if (underscore.location != NSNotFound)
        langCode = [localeStr substringToIndex:underscore.location];
    else {
        NSRange dot = [localeStr rangeOfString:@"."];
        if (dot.location != NSNotFound)
            langCode = [localeStr substringToIndex:dot.location];
        else
            langCode = localeStr;
    }
    if (!langCode || [langCode length] < 2) return nil;

    for (int i = 0; langMap[i][0]; i++) {
        if ([langCode isEqualToString:[NSString stringWithUTF8String:langMap[i][0]]]) {
            return [NSString stringWithUTF8String:langMap[i][1]];
        }
    }
    return nil;
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    return YES;
}

- (NSString *)selectedLanguage {
    return [_languageDropdown titleOfSelectedItem];
}

- (NSString *)selectedKeyboardLayout {
    id selected = [_keyboardDropdown selectedItem];
    if ([selected isKindOfClass:[NSMenuItem class]]) {
        return [(NSMenuItem *)selected representedObject] ?: @"us";
    }
    return @"us";
}

@end

#pragma mark - SARegionStep

@implementation SARegionStep
{
}

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Region and Formats", @"");
        self.stepDescription = NSLocalizedString(@"Select your region and formatting preferences.", @"");
        _kb = [[KeyboardManager alloc] init];
        [_kb detectKeyboardWithPasswd:NULL];
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_regionDropdown release];
    [_currencyDropdown release];
    [_measurementDropdown release];
    [_stepView release];
    [_containerView release];
    [_kb release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 160)];
    /* The measurement popup titles are the longest strings in the assistant
     * ("Metrisch (Kilometer, Kilogramm)"), so this step keeps a narrower
     * label column and a wider control column than the shared geometry. */
    CGFloat labelX = kSALabelX;
    CGFloat labelW = 92.0;
    CGFloat dropdownX = 116.0;
    CGFloat dropdownW = 234.0;
    CGFloat rowH = 40;
    CGFloat topY = 125;

    NSDictionary *regionInfo = [_kb suggestedRegionFromLayout:_kb.layout];
    NSString *suggestedRegion = regionInfo[@"region"] ?: @"United States";
    NSString *suggestedCurrency = regionInfo[@"currency"] ?: @"USD ($)";
    NSString *suggestedMeasurement = regionInfo[@"measurement"] ?: @"Imperial (miles, pounds)";

    NSTextField *regionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY, labelW, 20)];
    [regionLabel setStringValue:NSLocalizedString(@"Region:", @"")];
    [regionLabel setBezeled:NO];
    [regionLabel setDrawsBackground:NO];
    [regionLabel setEditable:NO];
    [regionLabel setSelectable:NO];
    [regionLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:regionLabel];
    [regionLabel release];

    _regionDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(dropdownX, topY - 4, dropdownW, 26)];
    [_regionDropdown addItemsWithTitles:@[
        @"United States", @"Germany", @"France", @"Spain", @"Italy",
        @"United Kingdom", @"Japan", @"Canada", @"Australia", @"Brazil",
        @"Russia", @"China", @"India", @"Netherlands", @"Sweden"
    ]];
    [self selectPopup:_regionDropdown matchingKey:suggestedRegion fallback:@"United States"];
    [_stepView addSubview:_regionDropdown];

    NSTextField *currencyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY - rowH, labelW, 20)];
    [currencyLabel setStringValue:NSLocalizedString(@"Currency:", @"")];
    [currencyLabel setBezeled:NO];
    [currencyLabel setDrawsBackground:NO];
    [currencyLabel setEditable:NO];
    [currencyLabel setSelectable:NO];
    [currencyLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:currencyLabel];
    [currencyLabel release];

    _currencyDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(dropdownX, topY - rowH - 4, dropdownW, 26)];
    [_currencyDropdown addItemsWithTitles:@[
        @"USD ($)", @"EUR (€)", @"GBP (£)", @"JPY (¥)", @"CAD ($)",
        @"AUD ($)", @"BRL (R$)", @"CNY (¥)", @"INR (₹)", @"RUB (₽)"
    ]];
    [self selectPopup:_currencyDropdown matchingKey:suggestedCurrency fallback:@"USD ($)"];
    [_stepView addSubview:_currencyDropdown];

    NSTextField *measurementLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY - rowH * 2, labelW, 20)];
    [measurementLabel setStringValue:NSLocalizedString(@"Measurement:", @"")];
    [measurementLabel setBezeled:NO];
    [measurementLabel setDrawsBackground:NO];
    [measurementLabel setEditable:NO];
    [measurementLabel setSelectable:NO];
    [measurementLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:measurementLabel];
    [measurementLabel release];

    _measurementDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(dropdownX, topY - rowH * 2 - 4, dropdownW, 26)];
    [_measurementDropdown addItemsWithTitles:@[
        NSLocalizedString(@"Imperial (miles, pounds)", @""),
        NSLocalizedString(@"Metric (kilometers, kilograms)", @"")
    ]];
    [self selectPopup:_measurementDropdown matchingKey:suggestedMeasurement
             fallback:NSLocalizedString(@"Imperial (miles, pounds)", @"")];
    [_stepView addSubview:_measurementDropdown];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    return YES;
}

/* The detector hands back English keys while the popup items are localized,
 * so a suggestion only matches as-is in an English UI.  In every other
 * language selectItemWithTitle: found nothing, left the popup with no
 * selection and it came up blank.  Translate the suggestion first, and when a
 * suggestion is simply not one of the canned items, add it rather than show an
 * empty popup. */
- (void)selectPopup:(NSPopUpButton *)popup matchingKey:(NSString *)key fallback:(NSString *)fallback {
    NSString *title = key ? NSLocalizedString(key, @"") : nil;
    if (title) {
        [popup selectItemWithTitle:title];
    }
    if ([popup indexOfSelectedItem] < 0) {
        [popup addItemWithTitle:(title ?: fallback)];
        [popup selectItemWithTitle:(title ?: fallback)];
    }
}

- (NSString *)selectedRegion {
    return [_regionDropdown titleOfSelectedItem];
}

- (NSString *)selectedCurrency {
    return [_currencyDropdown titleOfSelectedItem];
}

- (NSString *)selectedMeasurement {
    return [_measurementDropdown titleOfSelectedItem];
}

@end

#pragma mark - SADateTimeStep

#pragma mark - SADateTextFormatter

/* An NSDatePicker paints whatever NSCell's formatter makes of its date, and
 * this NSDateFormatter does not format: with no date format set it hands the
 * date's own description back, so both pickers came up showing
 * "2001-01-01 01:00:02 +0100" - the description of a value nobody had set.
 * Going through stringFromDate: is what actually produces the localized date
 * or time the field is supposed to show. */
@interface SADateTextFormatter : NSDateFormatter
@end

@implementation SADateTextFormatter

- (NSString *)stringForObjectValue:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        return [self stringFromDate:obj];
    }
    return [super stringForObjectValue:obj];
}

@end

@implementation SADateTimeStep
{
    KeyboardManager *_kb;
}

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Date and Time", @"");
        self.stepDescription = NSLocalizedString(@"Set your date, time, and timezone.", @"");
        _kb = [[KeyboardManager alloc] init];
        [_kb detectKeyboardWithPasswd:NULL];
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_datePicker release];
    [_timePicker release];
    [_timezoneDropdown release];
    [_networkTimeCheckbox release];
    [_stepView release];
    [_containerView release];
    [_kb release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 160)];
    CGFloat labelX = kSALabelX;
    CGFloat labelW = kSALabelWidth;
    CGFloat controlX = kSAFieldX;
    CGFloat controlW = kSAFieldWidth;
    CGFloat topY = 125;

    NSTextField *tzLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY, labelW, 20)];
    [tzLabel setStringValue:NSLocalizedString(@"Timezone:", @"")];
    [tzLabel setBezeled:NO];
    [tzLabel setDrawsBackground:NO];
    [tzLabel setEditable:NO];
    [tzLabel setSelectable:NO];
    [tzLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:tzLabel];
    [tzLabel release];

    _timezoneDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, topY - 4, controlW, 26)];
    [_timezoneDropdown addItemsWithTitles:@[
        @"America/New_York", @"America/Chicago", @"America/Denver", @"America/Los_Angeles",
        @"America/Toronto", @"America/Vancouver", @"Europe/London", @"Europe/Paris",
        @"Europe/Berlin", @"Europe/Moscow", @"Asia/Tokyo", @"Asia/Shanghai",
        @"Asia/Kolkata", @"Australia/Sydney", @"Pacific/Auckland"
    ]];
    NSString *suggestedTZ = [_kb suggestedTimezoneFromLayout:_kb.layout];
    if (suggestedTZ) {
        [_timezoneDropdown selectItemWithTitle:suggestedTZ];
    }
    [_stepView addSubview:_timezoneDropdown];

    NSTextField *dateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY - 40, labelW, 20)];
    [dateLabel setStringValue:NSLocalizedString(@"Date:", @"")];
    [dateLabel setBezeled:NO];
    [dateLabel setDrawsBackground:NO];
    [dateLabel setEditable:NO];
    [dateLabel setSelectable:NO];
    [dateLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:dateLabel];
    [dateLabel release];

    _datePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(controlX, topY - 44, controlW, 26)];
    [_datePicker setDatePickerStyle:NSTextFieldAndStepperDatePickerStyle];
    [_datePicker setDatePickerElements:NSYearMonthDayDatePickerElementFlag];
    NSDateFormatter *dateFormat = [[SADateTextFormatter alloc] init];
    [dateFormat setDateStyle:NSDateFormatterMediumStyle];
    [dateFormat setTimeStyle:NSDateFormatterNoStyle];
    [_datePicker setFormatter:dateFormat];
    [dateFormat release];
    [_datePicker setDateValue:[NSDate date]];
    [_stepView addSubview:_datePicker];

    NSTextField *timeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, topY - 80, labelW, 20)];
    [timeLabel setStringValue:NSLocalizedString(@"Time:", @"")];
    [timeLabel setBezeled:NO];
    [timeLabel setDrawsBackground:NO];
    [timeLabel setEditable:NO];
    [timeLabel setSelectable:NO];
    [timeLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:timeLabel];
    [timeLabel release];

    _timePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(controlX, topY - 84, controlW, 26)];
    [_timePicker setDatePickerStyle:NSTextFieldAndStepperDatePickerStyle];
    [_timePicker setDatePickerElements:NSHourMinuteDatePickerElementFlag];
    NSDateFormatter *timeFormat = [[SADateTextFormatter alloc] init];
    [timeFormat setDateStyle:NSDateFormatterNoStyle];
    [timeFormat setTimeStyle:NSDateFormatterShortStyle];
    [_timePicker setFormatter:timeFormat];
    [timeFormat release];
    [_timePicker setDateValue:[NSDate date]];
    [_stepView addSubview:_timePicker];

    _networkTimeCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX, topY - 115, kSATextWidth, 20)];
    [_networkTimeCheckbox setButtonType:NSSwitchButton];
    [_networkTimeCheckbox setTitle:NSLocalizedString(@"Set date and time automatically via network", @"")];
    [_networkTimeCheckbox setState:NSOnState];
    [_stepView addSubview:_networkTimeCheckbox];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    return YES;
}

- (NSDate *)selectedDate {
    return [_datePicker dateValue];
}

- (NSDate *)selectedTime {
    return [_timePicker dateValue];
}

- (NSString *)selectedTimezone {
    return [_timezoneDropdown titleOfSelectedItem];
}

- (BOOL)networkTimeEnabled {
    return [_networkTimeCheckbox state] == NSOnState;
}

@end

#pragma mark - SAUserAccountStep

@implementation SAUserAccountStep

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"User Account", @"");
        self.stepDescription = NSLocalizedString(@"Create a user account for yourself.", @"");
        [self checkDscliAvailability];
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_usernameField release];
    [_fullNameField release];
    [_passwordField release];
    [_confirmPasswordField release];
    [_statusLabel release];
    [_stepView release];
    [_containerView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)checkDscliAvailability {
    _hasDscli = ([[NSFileManager defaultManager] fileExistsAtPath:@"/System/Library/Tools/dscli"] == YES);
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 212)];
    CGFloat left = kSALabelX;
    CGFloat labelW = kSALabelWidth;
    CGFloat fieldX = kSAFieldX;
    CGFloat fieldW = kSAFieldWidth;

    NSTextField *fullNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 188, labelW, 16)];
    [fullNameLabel setStringValue:NSLocalizedString(@"Full Name:", @"")];
    [fullNameLabel setBezeled:NO];
    [fullNameLabel setDrawsBackground:NO];
    [fullNameLabel setEditable:NO];
    [fullNameLabel setSelectable:NO];
    [fullNameLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:fullNameLabel];
    [fullNameLabel release];

    _fullNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 184, fieldW, 24)];
    [_fullNameField setTarget:self];
    [_fullNameField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_fullNameField];

    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 156, labelW, 16)];
    [usernameLabel setStringValue:NSLocalizedString(@"Username:", @"")];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [usernameLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:usernameLabel];
    [usernameLabel release];

    _usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 152, fieldW, 24)];
    [_usernameField setTarget:self];
    [_usernameField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_usernameField];

    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 124, labelW, 16)];
    [passwordLabel setStringValue:NSLocalizedString(@"Password:", @"")];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [passwordLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:passwordLabel];
    [passwordLabel release];

    _passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, 120, fieldW, 24)];
    [_passwordField setTarget:self];
    [_passwordField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_passwordField];

    NSTextField *confirmLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 92, labelW, 16)];
    [confirmLabel setStringValue:NSLocalizedString(@"Confirm:", @"")];
    [confirmLabel setBezeled:NO];
    [confirmLabel setDrawsBackground:NO];
    [confirmLabel setEditable:NO];
    [confirmLabel setSelectable:NO];
    [confirmLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:confirmLabel];
    [confirmLabel release];

    _confirmPasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, 88, fieldW, 24)];
    [_confirmPasswordField setTarget:self];
    [_confirmPasswordField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_confirmPasswordField];

    /* Three reserved lines, so validation messages appear without shoving
     * the rest of the form around. */
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 42, kSATextWidth, 42)];
    [_statusLabel setStringValue:@""];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:[NSFont systemFontOfSize:11]];
    [_statusLabel setTextColor:[NSColor secondaryLabelColor]];
    [[_statusLabel cell] setWraps:YES];
    [[_statusLabel cell] setScrollable:NO];
    [_stepView addSubview:_statusLabel];
    [_statusLabel release];

    NSTextField *methodLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 8, kSATextWidth, 30)];
    if (_hasDscli) {
        [methodLabel setStringValue:NSLocalizedString(@"Account will be created using the Gershwin Directory Service.", @"")];
    } else {
        [methodLabel setStringValue:NSLocalizedString(@"Account will be created using standard Unix tools.", @"")];
    }
    [methodLabel setBezeled:NO];
    [methodLabel setDrawsBackground:NO];
    [methodLabel setEditable:NO];
    [methodLabel setSelectable:NO];
    [methodLabel setFont:[NSFont systemFontOfSize:11]];
    [methodLabel setTextColor:[NSColor secondaryLabelColor]];
    [[methodLabel cell] setWraps:YES];
    [[methodLabel cell] setScrollable:NO];
    [_stepView addSubview:methodLabel];
    [methodLabel release];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (void)fieldChanged:(id)sender {
    [self updateStatusLabel];
    [self requestNavigationUpdate];
}

- (void)updateStatusLabel {
    NSString *fullName = [[_fullNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *username = [[_usernameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = [_passwordField stringValue];
    NSString *confirmPassword = [_confirmPasswordField stringValue];

    NSMutableArray *missing = [NSMutableArray array];

    if ([fullName length] == 0) {
        [missing addObject:NSLocalizedString(@"Full Name is required", @"")];
    }
    if ([username length] == 0) {
        [missing addObject:NSLocalizedString(@"Username is required", @"")];
    } else if (![self isValidUsername:username]) {
        [missing addObject:NSLocalizedString(@"Username may only contain letters, numbers, and underscores", @"")];
    }
    if ([password length] > 0 && [confirmPassword length] > 0 && ![password isEqualToString:confirmPassword]) {
        [missing addObject:NSLocalizedString(@"Passwords do not match", @"")];
    }

    if ([missing count] > 0) {
        [_statusLabel setStringValue:[missing componentsJoinedByString:@". "]];
        [_statusLabel setTextColor:[NSColor systemRedColor]];
    } else {
        [_statusLabel setStringValue:@""];
    }
}

- (BOOL)isValidUsername:(NSString *)username {
    if (!username || [username length] == 0) return NO;
    NSCharacterSet *validChars = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    NSCharacterSet *inputChars = [NSCharacterSet characterSetWithCharactersInString:username];
    return [validChars isSupersetOfSet:inputChars];
}

- (void)requestNavigationUpdate {
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    NSString *fullName = [[_fullNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *username = [[_usernameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = [_passwordField stringValue];
    NSString *confirmPassword = [_confirmPasswordField stringValue];

    BOOL passwordOk = ([password length] == 0 && [confirmPassword length] == 0) ||
                       ([password length] > 0 && [confirmPassword length] > 0 && [password isEqualToString:confirmPassword]);

    return [fullName length] > 0 &&
           [username length] > 0 &&
           [self isValidUsername:username] &&
           passwordOk;
}

- (NSString *)username {
    return [_usernameField stringValue];
}

- (NSString *)fullName {
    return [_fullNameField stringValue];
}

- (NSString *)password {
    return [_passwordField stringValue];
}

@end

#pragma mark - SAComputerNameStep

@implementation SAComputerNameStep

@synthesize stepTitle, stepDescription, assistantWindow;

- (instancetype)init {
    if (self = [super init]) {
        self.stepTitle = NSLocalizedString(@"Computer Name", @"");
        self.stepDescription = NSLocalizedString(@"Set your computer name.", @"");
        [self setupView];
    }
    return self;
}

- (void)dealloc {
    [_computerNameField release];
    [_localHostNameField release];
    [_stepView release];
    [_containerView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (NSString *)getCurrentHostname {
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        return [NSString stringWithUTF8String:hostname];
    }
    return @"";
}

- (void)setupView {
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSAStepWidth, 168)];
    CGFloat left = kSALabelX;
    CGFloat labelW = kSALabelWidth;
    CGFloat fieldX = kSAFieldX;
    CGFloat fieldW = kSAFieldWidth;

    NSString *currentHostname = [self getCurrentHostname];

    NSTextField *computerNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 144, labelW, 16)];
    [computerNameLabel setStringValue:NSLocalizedString(@"Computer Name:", @"")];
    [computerNameLabel setBezeled:NO];
    [computerNameLabel setDrawsBackground:NO];
    [computerNameLabel setEditable:NO];
    [computerNameLabel setSelectable:NO];
    [computerNameLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:computerNameLabel];
    [computerNameLabel release];

    _computerNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 140, fieldW, 24)];
    [_computerNameField setStringValue:currentHostname];
    [_stepView addSubview:_computerNameField];

    NSTextField *localHostLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 109, labelW, 16)];
    [localHostLabel setStringValue:NSLocalizedString(@"Local Host Name:", @"")];
    [localHostLabel setBezeled:NO];
    [localHostLabel setDrawsBackground:NO];
    [localHostLabel setEditable:NO];
    [localHostLabel setSelectable:NO];
    [localHostLabel setFont:[NSFont systemFontOfSize:13]];
    [_stepView addSubview:localHostLabel];
    [localHostLabel release];

    NSString *localHost = [currentHostname stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    _localHostNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 105, fieldW, 24)];
    [_localHostNameField setStringValue:localHost];
    [_stepView addSubview:_localHostNameField];

    NSTextField *noteLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 45, kSATextWidth, 46)];
    [noteLabel setStringValue:NSLocalizedString(@"The computer name is how your device appears on the network. "
                                                 "The local host name is used for local networking and file sharing.", @"")];
    [noteLabel setBezeled:NO];
    [noteLabel setDrawsBackground:NO];
    [noteLabel setEditable:NO];
    [noteLabel setSelectable:NO];
    [noteLabel setFont:[NSFont systemFontOfSize:11]];
    [noteLabel setTextColor:[NSColor secondaryLabelColor]];
    [[noteLabel cell] setWraps:YES];
    [[noteLabel cell] setScrollable:NO];
    [_stepView addSubview:noteLabel];
    [noteLabel release];

    _containerView = [[SAStepContainerView alloc] initWithFrame:[_stepView frame]];
    [(SAStepContainerView *)_containerView setDesignView:_stepView];
}

- (NSView *)stepView {
    return _containerView;
}

- (BOOL)canContinue {
    NSString *name = [[_computerNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [name length] > 0;
}

- (NSString *)computerName {
    return [_computerNameField stringValue];
}

- (NSString *)localHostName {
    return [_localHostNameField stringValue];
}

@end

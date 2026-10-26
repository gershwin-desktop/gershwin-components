/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSLocaleHelper.h>
#import <KeyboardManager.h>

@class GSAssistantWindow;

@interface SAWelcomeStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
@end

@interface SALanguageKeyboardStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    NSPopUpButton *_languageDropdown;
    NSPopUpButton *_keyboardDropdown;
    KeyboardManager *_keyboardManager;
    NSArray *_languageNames;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
- (NSString *)selectedLanguage;
- (NSString *)selectedKeyboardLayout;
@end

@interface SARegionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    NSPopUpButton *_regionDropdown;
    NSPopUpButton *_currencyDropdown;
    NSPopUpButton *_measurementDropdown;
    KeyboardManager *_kb;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
- (NSString *)selectedRegion;
- (NSString *)selectedCurrency;
- (NSString *)selectedMeasurement;
@end

@interface SADateTimeStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    NSDatePicker *_datePicker;
    NSDatePicker *_timePicker;
    NSPopUpButton *_timezoneDropdown;
    NSButton *_networkTimeCheckbox;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
- (NSDate *)selectedDate;
- (NSDate *)selectedTime;
- (NSString *)selectedTimezone;
- (BOOL)networkTimeEnabled;
@end

@interface SAUserAccountStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    NSTextField *_usernameField;
    NSTextField *_fullNameField;
    NSSecureTextField *_passwordField;
    NSSecureTextField *_confirmPasswordField;
    NSTextField *_statusLabel;
    BOOL _hasDscli;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
- (NSString *)username;
- (NSString *)fullName;
- (NSString *)password;
@end

@interface SAComputerNameStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSView *_containerView;
    NSTextField *_computerNameField;
    NSTextField *_localHostNameField;
    GSAssistantWindow *_assistantWindow;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (readonly, nonatomic) NSView *stepView;
@property (assign, nonatomic) GSAssistantWindow *assistantWindow;
- (NSString *)computerName;
- (NSString *)localHostName;
@end

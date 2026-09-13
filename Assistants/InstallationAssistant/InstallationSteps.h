/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

//
// InstallationSteps.h
// Installation Assistant - Disk-based System Installer Steps
//

#import <Foundation/Foundation.h>
#import "GSAssistantFramework.h"

// ============================================================================
// Helper: get path to the correct installer script based on uname
// ============================================================================
NSString *IAInstallerScriptPath(void);
NSString *IACheckImageSourceAvailable(void);

// ============================================================================
// IAInstallTypeDelegate - Callback when install type changes
// ============================================================================
@protocol IAInstallTypeDelegate <NSObject>
- (void)installTypeStep:(id)step didSelectImageSource:(NSString *)imageSourcePath;
@end

// ============================================================================
// IAInstallTypeStep - Choose between clone and image-based installation
// ============================================================================
@interface IAInstallTypeStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSButton *_cloneRadio;
    NSButton *_imageRadio;
    NSTextField *_imageSourceLabel;
    NSString *_detectedImageSource;
    BOOL _imageSourceAvailable;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (assign, nonatomic) id<IAInstallTypeDelegate> delegate;
- (BOOL)useImageInstall;
- (NSString *)imageSourcePath;
- (void)detectImageSource;
- (void)setImageSource:(NSString *)sourcePath;
@end

// ============================================================================
// IAWelcomeStep - Introduction screen
// ============================================================================
@interface IAWelcomeStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@end

// ============================================================================
// IALicenseStep - License agreement with checkbox
// ============================================================================
@interface IALicenseStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSTextView *_licenseTextView;
    NSButton *_agreeCheckbox;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
- (BOOL)userAgreedToLicense;
@end

// ============================================================================
// IADestinationStep - Choose installation destination
// ============================================================================
@interface IADestinationStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSPopUpButton *_destinationPopup;
    NSTextField *_spaceRequiredLabel;
    NSTextField *_spaceAvailableLabel;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
- (NSString *)selectedDestination;
@end

// ============================================================================
// IAOptionsStep - Choose optional components
// ============================================================================
@interface IAOptionsStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSButton *_installDevelopmentToolsCheckbox;
    NSButton *_installLinuxCompatibilityCheckbox;
    NSButton *_installDocumentationCheckbox;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
- (BOOL)installDevelopmentTools;
- (BOOL)installLinuxCompatibility;
- (BOOL)installDocumentation;
@end

// ============================================================================
// IADiskInfo - Model object for a physical disk
// ============================================================================
@interface IADiskInfo : NSObject
@property (copy, nonatomic) NSString *devicePath;
@property (copy, nonatomic) NSString *name;
@property (copy, nonatomic) NSString *diskDescription;
@property (assign, nonatomic) unsigned long long sizeBytes;
@property (copy, nonatomic) NSString *formattedSize;
@end

// ============================================================================
// IADiskSelectionDelegate - Callback when disk is selected
// ============================================================================
@protocol IADiskSelectionDelegate <NSObject>
- (void)diskSelectionStep:(id)step didSelectDisk:(IADiskInfo *)disk;
@end

// ============================================================================
// IADiskSelectionStep - Shows available physical disks in a table
// ============================================================================
@interface IADiskSelectionStep : NSObject <GSAssistantStepProtocol, NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *_stepView;
    NSTableView *_tableView;
    NSMutableArray *_disks;
    NSTextField *_statusLabel;
    NSProgressIndicator *_spinner;
    NSMutableString *_diagnostics;
    BOOL _isLoading;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (assign, nonatomic) id<IADiskSelectionDelegate> delegate;
- (IADiskInfo *)selectedDisk;
- (void)refreshDiskList;
@end

// ============================================================================
// IAConfirmStep - Confirm before erasing disk
// ============================================================================
@interface IAConfirmStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSButton *_confirmCheckbox;
    NSTextField *_warningLabel;
    NSTextField *_diskInfoLabel;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
- (void)updateWithDisk:(IADiskInfo *)disk;
@end

// ============================================================================
// IALogWindowController - Separate window for installer log output
// ============================================================================
@interface IALogWindowController : NSWindowController
{
    NSScrollView *_scrollView;
    NSTextView *_logView;
}
- (void)appendLog:(NSString *)text;
- (void)clearLog;
@end

// ============================================================================
// IAInstallProgressDelegate - Callback for installation progress
// ============================================================================
@protocol IAInstallProgressDelegate <NSObject>
- (void)installProgressDidFinish:(BOOL)success;
@end

// ============================================================================
// IAInstallProgressStep - Runs the installer script as NSTask
// ============================================================================
@interface IAInstallProgressStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_stepView;
    NSProgressIndicator *_progressBar;
    NSTextField *_detailLabel;
    NSTextField *_etaLabel;
    NSTask *_installerTask;
    NSPipe *_outputPipe;
    NSMutableString *_lineBuffer;
    NSTimer *_etaTimer;
    BOOL _isRunning;
    BOOL _isFinished;
    BOOL _wasSuccessful;
    NSDate *_startTime;
    double _currentPercent;
}
@property (copy, nonatomic) NSString *stepTitle;
@property (copy, nonatomic) NSString *stepDescription;
@property (assign, nonatomic) id<IAInstallProgressDelegate> delegate;
@property (retain, nonatomic) IALogWindowController *logWindowController;
- (void)startInstallationToDisk:(IADiskInfo *)disk;
- (void)startInstallationToDisk:(IADiskInfo *)disk source:(NSString *)sourcePathOrNil;
- (BOOL)isFinished;
- (BOOL)wasSuccessful;
@end

/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


//
// BhyveController.m
// Bhyve Assistant - Main Controller
//

#import "BhyveController.h"
#import <unistd.h>
#import <sys/socket.h>
#import "BhyveISOSelectionStep.h"
#import "BhyveConfigurationStep.h"
#import "BhyveRunningStep.h"
#import "VNCClient.h"
#import "VNCWindow.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/time.h>

@interface BhyveController()
@property (nonatomic, strong) BhyveISOSelectionStep *isoSelectionStep;
@property (nonatomic, strong) BhyveConfigurationStep *configurationStep;
@property (nonatomic, strong) BhyveRunningStep *runningStep;
@end

@implementation BhyveController

@synthesize selectedISOPath = _selectedISOPath;
@synthesize selectedISOName = _selectedISOName;
@synthesize selectedISOSize = _selectedISOSize;
@synthesize vmName = _vmName;
@synthesize allocatedRAM = _allocatedRAM;
@synthesize allocatedCPUs = _allocatedCPUs;
@synthesize diskSize = _diskSize;
@synthesize enableVNC = _enableVNC;
@synthesize vncPort = _vncPort;
@synthesize vncWindowSize = _vncWindowSize;
@synthesize networkMode = _networkMode;
@synthesize bootMode = _bootMode;
@synthesize vmRunning = _vmRunning;

- (id)init
{
    if (self = [super init]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: init");
        
        // Load user settings first
        [self loadUserSettings];
        
        // Set defaults if no settings exist
        if (!_selectedISOPath) _selectedISOPath = @"";
        if (!_selectedISOName) _selectedISOName = @"";
        if (_selectedISOSize == 0) _selectedISOSize = 0;
        if (!_vmName) _vmName = @"FreeBSD-Live";
        if (_allocatedRAM == 0) _allocatedRAM = 2048; // 2GB default
        if (_allocatedCPUs == 0) _allocatedCPUs = 2;
        if (_diskSize == 0) _diskSize = 20; // 20GB default
        _enableVNC = YES; // Always enable VNC
        if (_vncPort == 0) _vncPort = [self findUnusedVNCPort]; // Find unused port
        if (!_vncWindowSize) _vncWindowSize = @"1024 x 768"; // Default size
        if (!_networkMode) _networkMode = @"bridge";
        if (!_bootMode) _bootMode = @"uefi"; // Default to UEFI boot mode
        _vmRunning = NO;
        _bhyveTask = nil;
        _vncWindow = nil;
        _logWindow = nil;
        _logTextView = nil;
        _logFileHandle = nil;
        _vmLogBuffer = [[NSMutableString alloc] init];
    }
    return self;
}

- (void)dealloc
{
    NSDebugLLog(@"gwcomp", @"BhyveController: dealloc");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [self closeLogWindow];
    if (_vncWindow) {
        [_vncWindow close];
        _vncWindow = nil;
    }
}

- (void)showAssistant
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showAssistant");
    
    // Check system requirements FIRST
    NSString *errorMessage = [self checkSystemRequirements];
    if (errorMessage) {
        // Show error immediately and don't build the normal assistant
        [self showSystemRequirementsError:errorMessage];
        return;
    }
    
    // Create step views
    _isoSelectionStep = [[BhyveISOSelectionStep alloc] init];
    [_isoSelectionStep setController:self];
    _configurationStep = [[BhyveConfigurationStep alloc] init];
    [_configurationStep setController:self];
    _runningStep = [[BhyveRunningStep alloc] init];
    [_runningStep setController:self];
    
    // Build the assistant using the builder
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withTitle:NSLocalizedString(@"Bhyve Virtual Machine", @"Application title")];
    [builder withIcon:[NSImage imageNamed:@"bhyve_logo"]];
    
    // Add configuration steps directly
    [builder addStep:_isoSelectionStep];
    [builder addStep:_configurationStep];
    [builder addStep:_runningStep];
    
    // Build and show
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - Helper Methods

- (NSString *)checkSystemRequirements
{
    NSDebugLLog(@"gwcomp", @"BhyveController: checkSystemRequirements");
    
    // Check if we're on FreeBSD first
    NSTask *unameTask = [[NSTask alloc] init];
    [unameTask setLaunchPath:@"/usr/bin/uname"];
    [unameTask setArguments:@[@"-s"]];
    
    NSPipe *unamePipe = [NSPipe pipe];
    [unameTask setStandardOutput:unamePipe];
    
    @try {
        [unameTask launch];
        [unameTask waitUntilExit];
        
        NSData *data = [[unamePipe fileHandleForReading] readDataToEndOfFile];
        NSString *osName = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        osName = [osName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        NSDebugLLog(@"gwcomp", @"BhyveController: Operating system: %@", osName);
        
        if (![osName isEqualToString:@"FreeBSD"]) {
            NSString *error = [NSString stringWithFormat:@"bhyve is only available on FreeBSD.\n\nCurrent operating system: %@\n\nThis assistant requires FreeBSD with bhyve support to create and run virtual machines.", osName];
            return error;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error checking OS: %@", [exception reason]);
        return @"Unable to determine the operating system.\n\nThis assistant requires FreeBSD with bhyve support.";
    }
    
    // Check if bhyve is available
    if (![self checkBhyveAvailable]) {
        return @"bhyve is not available on this system. Please ensure bhyve is installed (pkg install bhyve-firmware), the vmm kernel module is loaded, you have root privileges, and hardware virtualization is enabled in BIOS. For more information, see the FreeBSD Handbook chapter on bhyve.";
    }
    
    // Test bhyve basic functionality
    if (![self testBhyveBasicFunction]) {
        return @"bhyve permission test failed. This usually indicates insufficient privileges (not running as root), hardware virtualization not enabled in BIOS, conflicting hypervisor software running, or VMM kernel module issues. Please run the assistant with 'sudo -A -E' and ensure hardware virtualization is enabled.";
    }
    
    // Check if UEFI firmware is available (required for most ISOs)
    NSArray *uefiPaths = @[
        @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
        @"/usr/local/share/edk2-bhyve/BHYVE_UEFI.fd",
        @"/usr/local/share/bhyve/BHYVE_UEFI.fd"
    ];
    
    BOOL uefiFound = NO;
    for (NSString *path in uefiPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            uefiFound = YES;
            break;
        }
    }
    
    if (!uefiFound) {
        return @"UEFI firmware not found. Most modern ISOs (including GhostBSD and Linux) require UEFI firmware to boot in bhyve. Please install the firmware: sudo pkg install bhyve-firmware";
    }
    
    // Check if libvncclient is available for VNC support
    if (![self checkLibVNCClientAvailable]) {
        return @"libvncclient not found. VNC display support requires libvncclient. Please install it: sudo pkg install libvncserver";
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: All system requirements met");
    return nil; // No error
}

- (void)showSystemRequirementsError:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showSystemRequirementsError: %@", message);
    
    // Create a minimal assistant builder just to show the error page
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withTitle:NSLocalizedString(@"Bhyve Virtual Machine", @"Application title")];
    [builder withIcon:[NSImage imageNamed:@"bhyve_logo"]];
    
    // Build the assistant window but don't add any steps
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    
    // Show the window first
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
    
    // Then immediately show the error page
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: calling showErrorPageWithTitle:message:");
        [_assistantWindow showErrorPageWithTitle:@"System Requirements Not Met" message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: calling showErrorPageWithMessage:");
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSDebugLLog(@"gwcomp", @"BhyveController: assistant window doesn't respond to error page methods");
        // Fallback - just log the error
        NSDebugLLog(@"gwcomp", @"BhyveController: System requirements error: %@", message);
    }
}

- (BOOL)checkBhyveAvailable
{
    NSDebugLLog(@"gwcomp", @"BhyveController: checkBhyveAvailable");
    
    // Check if bhyve command exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyve"]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: bhyve binary not found at /usr/sbin/bhyve");
        return NO;
    }
    
    // Check if bhyvectl exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyvectl"]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: bhyvectl binary not found at /usr/sbin/bhyvectl");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: bhyve tools available");
    return YES;
}

- (BOOL)checkLibVNCClientAvailable
{
    NSDebugLLog(@"gwcomp", @"BhyveController: checkLibVNCClientAvailable");
    
    return [VNCClient isLibVNCClientAvailable];
}

- (BOOL)validateVMConfiguration
{
    NSDebugLLog(@"gwcomp", @"BhyveController: validateVMConfiguration");
    
    // Check if ISO is selected
    if (!_selectedISOPath || [_selectedISOPath length] == 0) {
        NSDebugLLog(@"gwcomp", @"BhyveController: No ISO selected");
        return NO;
    }
    
    // Check if ISO file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:_selectedISOPath]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: ISO file does not exist: %@", _selectedISOPath);
        return NO;
    }
    
    // Check VM name
    if (!_vmName || [_vmName length] == 0) {
        NSDebugLLog(@"gwcomp", @"BhyveController: No VM name specified");
        return NO;
    }
    
    // Check memory allocation (minimum 512MB)
    if (_allocatedRAM < 512) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Insufficient RAM allocated: %ld MB", (long)_allocatedRAM);
        return NO;
    }
    
    // Check CPU allocation (minimum 1)
    if (_allocatedCPUs < 1) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Invalid CPU count: %ld", (long)_allocatedCPUs);
        return NO;
    }
    
    // Check if bhyve command exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyve"]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: bhyve command not found");
        return NO;
    }
    
    // Check if bhyvectl command exists  
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/bhyvectl"]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: bhyvectl command not found");
        return NO;
    }
    
    // Check if running as root (bhyve typically requires root privileges)
    if (getuid() != 0) {
        NSDebugLLog(@"gwcomp", @"BhyveController: ERROR - Not running as root, bhyve will fail");
        return NO; // Fail validation if not root
    } else {
        NSDebugLLog(@"gwcomp", @"BhyveController: Running as root - good");
    }
    
    // Check if vmm kernel module is available
    NSTask *kldstatTask = [[NSTask alloc] init];
    [kldstatTask setLaunchPath:@"/sbin/kldstat"];
    [kldstatTask setArguments:@[@"-q", @"-m", @"vmm"]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    [kldstatTask setStandardOutput:outputPipe];
    [kldstatTask setStandardError:outputPipe];
    
    @try {
        [kldstatTask launch];
        [kldstatTask waitUntilExit];
        int kldstatStatus = [kldstatTask terminationStatus];
        
        if (kldstatStatus != 0) {
            NSDebugLLog(@"gwcomp", @"BhyveController: vmm kernel module not loaded, will attempt to load");
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: vmm kernel module is loaded");
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error checking vmm module: %@", [exception reason]);
        // Continue anyway
    }
    
    // Check hardware virtualization support
    NSTask *hwVirtTask = [[NSTask alloc] init];
    [hwVirtTask setLaunchPath:@"/sbin/sysctl"];
    [hwVirtTask setArguments:@[@"-n", @"hw.vmm.vmx.initialized"]];
    
    NSPipe *hwVirtPipe = [NSPipe pipe];
    [hwVirtTask setStandardOutput:hwVirtPipe];
    [hwVirtTask setStandardError:hwVirtPipe];
    
    @try {
        [hwVirtTask launch];
        [hwVirtTask waitUntilExit];
        int hwVirtStatus = [hwVirtTask terminationStatus];
        
        if (hwVirtStatus == 0) {
            NSData *data = [[hwVirtPipe fileHandleForReading] readDataToEndOfFile];
            NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([result isEqualToString:@"1"]) {
                NSDebugLLog(@"gwcomp", @"BhyveController: Hardware virtualization (VMX) is enabled");
            } else {
                NSDebugLLog(@"gwcomp", @"BhyveController: WARNING - Hardware virtualization (VMX) may not be enabled");
            }
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: Could not check hardware virtualization status");
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error checking hardware virtualization: %@", [exception reason]);
    }
    
    return YES;
}

- (NSString *)generateVMCommand
{
    NSDebugLLog(@"gwcomp", @"BhyveController: generateVMCommand");
    
    NSMutableString *command = [NSMutableString string];
    
    // First, destroy any existing VM instance
    [command appendFormat:@"bhyvectl --destroy --vm=\"%@\" 2>/dev/null || true; ", _vmName];
    
    // For UEFI mode, we need different setup
    if ([_bootMode isEqualToString:@"uefi"]) {
        // UEFI requires specific configuration - use more conservative options
        [command appendString:@"bhyve -A -H -P"];
        
        // Memory
        [command appendFormat:@" -m %ldM", (long)_allocatedRAM];
        
        // CPUs
        [command appendFormat:@" -c %ld", (long)_allocatedCPUs];
        
        // PCI slots
        [command appendString:@" -s 0:0,hostbridge"];
        [command appendString:@" -s 31,lpc"];
        
        // CDROM (ISO) - Use ahci-cd for UEFI
        [command appendFormat:@" -s 2:0,ahci-cd,\"%@\"", _selectedISOPath];
        
        // Virtual disk
        NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
        [command appendFormat:@" -s 3:0,virtio-blk,\"%@\"", diskPath];
        
        // Network - only add if network interfaces are available
        if ([_networkMode isEqualToString:@"bridge"] || [_networkMode isEqualToString:@"nat"]) {
            // For now, skip networking to avoid interface issues
            // [command appendString:@" -s 4:0,virtio-net"];
            NSDebugLLog(@"gwcomp", @"BhyveController: Skipping network configuration to avoid interface issues");
        }
        // Skip network entirely for "none" mode
        
        // VNC - Use enhanced framebuffer device configuration
        if (_enableVNC) {
            [command appendString:[self generateVNCFramebufferConfig]];
        }
        
        // Console output disabled to prevent bhyve startup issues
        // Note: Removed -l com1,/dev/null as it causes "Inappropriate ioctl" errors
        
        // UEFI firmware - check multiple possible paths
        NSArray *uefiPaths = @[
            @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
            @"/usr/local/share/bhyve/BHYVE_UEFI.fd",
            @"/usr/share/bhyve/BHYVE_UEFI.fd",
            @"/boot/firmware/BHYVE_UEFI.fd"
        ];
        
        NSString *uefiPath = nil;
        for (NSString *path in uefiPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                uefiPath = path;
                break;
            }
        }
        
        if (uefiPath) {
            [command appendFormat:@" -l bootrom,\"%@\"", uefiPath];
            NSDebugLLog(@"gwcomp", @"BhyveController: Using UEFI firmware: %@", uefiPath);
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: WARNING - UEFI firmware not found in standard locations");
            // Continue anyway - bhyve might have a default
        }
        
        // VM name (must be last)
        [command appendFormat:@" \"%@\"", _vmName];
    } else {
        // BIOS mode - use simpler configuration that works with most ISOs
        [command appendString:@"bhyve -A -H -P"];
        
        // Memory
        [command appendFormat:@" -m %ldM", (long)_allocatedRAM];
        
        // CPUs 
        [command appendFormat:@" -c %ld", (long)_allocatedCPUs];
        
        // PCI slots
        [command appendString:@" -s 0:0,hostbridge"];
        [command appendString:@" -s 31,lpc"];
        
        // CDROM (ISO) as primary boot device - Use ahci-cd which supports boot
        [command appendFormat:@" -s 2:0,ahci-cd,\"%@\"", _selectedISOPath];
        
        // Virtual disk as secondary
        NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
        [command appendFormat:@" -s 3:0,virtio-blk,\"%@\"", diskPath];
        
        // Network - only add if network mode is not "none"
        if ([_networkMode isEqualToString:@"bridge"] || [_networkMode isEqualToString:@"nat"]) {
            // For now, skip networking to avoid interface issues
            // [command appendString:@" -s 4:0,virtio-net"];
            NSDebugLLog(@"gwcomp", @"BhyveController: Skipping network configuration to avoid interface issues");
        }
        
        // VNC - Use enhanced framebuffer device configuration
        if (_enableVNC) {
            [command appendString:[self generateVNCFramebufferConfig]];
        }
        
        // Console output disabled to prevent bhyve startup issues
        // Note: Removed -l com1,/dev/null as it causes "Inappropriate ioctl" errors
        
        // Both BIOS and modern ISOs need UEFI firmware to boot properly
        // Check multiple possible paths for UEFI firmware
        NSArray *uefiPaths = @[
            @"/usr/local/share/uefi-firmware/BHYVE_UEFI.fd",
            @"/usr/local/share/edk2-bhyve/BHYVE_UEFI.fd",
            @"/usr/local/share/bhyve/BHYVE_UEFI.fd",
            @"/usr/share/bhyve/BHYVE_UEFI.fd",
            @"/boot/firmware/BHYVE_UEFI.fd"
        ];
        
        NSString *uefiPath = nil;
        for (NSString *path in uefiPaths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                uefiPath = path;
                break;
            }
        }
        
        if (uefiPath) {
            [command appendFormat:@" -l bootrom,\"%@\"", uefiPath];
            NSDebugLLog(@"gwcomp", @"BhyveController: Using UEFI firmware: %@", uefiPath);
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: WARNING - UEFI firmware not found, VM may not boot properly");
            NSDebugLLog(@"gwcomp", @"BhyveController: Install with: pkg install bhyve-firmware");
        }
        
        // VM name (must be last)
        [command appendFormat:@" \"%@\"", _vmName];
    }
    
    // Don't redirect bhyve output so we can see errors for debugging
    // [command appendString:@" >/dev/null 2>&1"];
    
    NSDebugLLog(@"gwcomp", @"BhyveController: Generated VM command: %@", command);
    return [NSString stringWithString:command];
}

- (BOOL)createVirtualDisk
{
    NSDebugLLog(@"gwcomp", @"BhyveController: createVirtualDisk");
    
    NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
    
    // Check if disk already exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Virtual disk already exists at %@", diskPath);
        return YES;
    }
    
    // Create sparse disk image using truncate
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/truncate"];
    [task setArguments:@[@"-s", [NSString stringWithFormat:@"%ldG", (long)_diskSize], diskPath]];
    
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        int exitStatus = [task terminationStatus];
        
        if (exitStatus != 0) {
            NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"BhyveController: Failed to create virtual disk (exit code %d): %@", exitStatus, errorOutput);
            return NO;
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: Created virtual disk at %@ (%ld GB)", diskPath, (long)_diskSize);
            return YES;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error creating virtual disk: %@", [exception reason]);
        return NO;
    }
}

#pragma mark - VM Management

- (void)startVirtualMachine
{
    NSDebugLLog(@"gwcomp", @"BhyveController: startVirtualMachine");
    
    if (_vmRunning) {
        NSDebugLLog(@"gwcomp", @"BhyveController: VM is already running");
        return;
    }
    
    // Find an unused VNC port before starting VM
    NSInteger newVNCPort = [self findUnusedVNCPort];
    if (newVNCPort != _vncPort) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Using VNC port %ld instead of %ld", (long)newVNCPort, (long)_vncPort);
        [self setVncPort:newVNCPort];
    }
    
    if (![self validateVMConfiguration]) {
        [self showVMError:@"Invalid VM configuration"];
        return;
    }
    
    // Create virtual disk
    if (![self createVirtualDisk]) {
        [self showVMError:@"Failed to create virtual disk"];
        return;
    }
    
    // Generate VM command
    NSString *command = [self generateVMCommand];
    NSDebugLLog(@"gwcomp", @"BhyveController: VM command: %@", command);
    
    // Load bhyve kernel module if needed
    NSTask *kldloadTask = [[NSTask alloc] init];
    [kldloadTask setLaunchPath:@"/sbin/kldload"];
    [kldloadTask setArguments:@[@"vmm"]];
    
    @try {
        [kldloadTask launch];
        [kldloadTask waitUntilExit];
        int kldloadStatus = [kldloadTask terminationStatus];
        if (kldloadStatus == 0) {
            NSDebugLLog(@"gwcomp", @"BhyveController: vmm module loaded successfully");
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: vmm module load failed (exit code %d) - may already be loaded", kldloadStatus);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error loading vmm module: %@", [exception reason]);
        // Continue anyway - module might already be loaded
    }
    
    // Start bhyve VM in background
    _bhyveTask = [[NSTask alloc] init];
    [_bhyveTask setLaunchPath:@"/bin/sh"];
    [_bhyveTask setArguments:@[@"-c", command]];
    
    // Set up pipes for output
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [_bhyveTask setStandardOutput:outputPipe];
    [_bhyveTask setStandardError:errorPipe];
    
    NSDebugLLog(@"gwcomp", @"BhyveController: About to launch bhyve command: %@", command);
    
    @try {
        [_bhyveTask launch];
        
        NSDebugLLog(@"gwcomp", @"BhyveController: bhyve task launched with PID %d", [_bhyveTask processIdentifier]);
        
        // Wait a moment to see if the process starts successfully
        [NSThread sleepForTimeInterval:1.0];
        
        if ([_bhyveTask isRunning]) {
            _vmRunning = YES;
            [self showVMStatus:[NSString stringWithFormat:@"Virtual Machine '%@' started successfully (PID: %d)", _vmName, [_bhyveTask processIdentifier]]];
            
            // Initialize log with startup message
            NSString *startupLog = [NSString stringWithFormat:@"=== VM '%@' Started ===\nPID: %d\nCommand: %@\n\n", 
                                   _vmName, [_bhyveTask processIdentifier], command];
            [self updateVMLog:startupLog];
            
            // Set up continuous log monitoring in background
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self monitorVMOutput:@[outputPipe, errorPipe]];
            });
            
            // Start VNC viewer if enabled
            if (_enableVNC) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self startVNCViewer];
                });
            }
            
            NSDebugLLog(@"gwcomp", @"BhyveController: VM running with PID %d", [_bhyveTask processIdentifier]);
        } else {
            // Process died immediately - check error output
            NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
            NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSString *stdOutput = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
            int exitStatus = [_bhyveTask terminationStatus];
            
            // Combine output and error, look for exit_reason
            NSMutableString *fullOutput = [NSMutableString string];
            if (stdOutput && [stdOutput length] > 0) {
                [fullOutput appendString:stdOutput];
            }
            if (errorOutput && [errorOutput length] > 0) {
                if ([fullOutput length] > 0) [fullOutput appendString:@"\n"];
                [fullOutput appendString:errorOutput];
            }
            
            // Look for specific bhyve error patterns
            NSString *exitReason = nil;
            NSMutableString *errorMessage = [NSMutableString string];
            
            if ([fullOutput containsString:@"Operation not permitted"]) {
                [errorMessage appendString:@"bhyve Permission Error - bhyve requires root privileges and proper system configuration. Please ensure you are running as root (use sudo), VMM kernel module is loaded, hardware virtualization is enabled in BIOS, and no conflicting hypervisors are running."];
            } else if ([fullOutput containsString:@"Usage: bhyve"]) {
                [errorMessage appendString:@"bhyve Command Syntax Error - The bhyve command has invalid syntax. This is likely a configuration issue in the BhyveAssistant."];
            } else if ([fullOutput containsString:@"exit_reason"]) {
                NSArray *lines = [fullOutput componentsSeparatedByString:@"\n"];
                for (NSString *line in lines) {
                    if ([line containsString:@"exit_reason"]) {
                        exitReason = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        break;
                    }
                }
                [errorMessage appendFormat:@"bhyve VM Exit - %@", exitReason];
            } else {
                [errorMessage appendFormat:@"VM failed to start (exit code %d)", exitStatus];
            }
            
            if ([fullOutput length] > 0) {
                [errorMessage appendFormat:@" Full Output: %@", fullOutput];
            } else {
                [errorMessage appendString:@" No output captured from bhyve process."];
            }
            
            NSDebugLLog(@"gwcomp", @"BhyveController: VM process died immediately (exit code %d): %@", exitStatus, fullOutput);
            [self showVMError:[NSString stringWithString:errorMessage]];
            
            _vmRunning = NO;
            _bhyveTask = nil;
        }
        
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error starting VM: %@", [exception reason]);
        [self showVMError:[NSString stringWithFormat:@"Failed to start VM: %@", [exception reason]]];
        _vmRunning = NO;
        _bhyveTask = nil;
    }
}

- (void)startVNCViewer
{
    NSDebugLLog(@"gwcomp", @"BhyveController: startVNCViewer");
    
    // Check if libvncclient is available first
    if (![self checkLibVNCClientAvailable]) {
        [self showVMError:@"libvncclient not available. Please install libvncserver package to enable VNC display."];
        return;
    }
    
    // Close existing VNC window if open
    if (_vncWindow) {
        [_vncWindow close];
        _vncWindow = nil;
    }
    
    // Show status that we're waiting for VNC server
    [self showVMStatus:@"Waiting for VNC server to start..."];
    
    // Wait longer for bhyve VNC server to initialize properly
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self tryVNCConnection];
    });
}

- (void)tryVNCConnection
{
    [self tryVNCConnectionWithRetry:0];
}

- (void)tryVNCConnectionWithRetry:(NSInteger)retryCount
{
    NSDebugLLog(@"gwcomp", @"BhyveController: tryVNCConnectionWithRetry: %ld", (long)retryCount);
    
    if (retryCount >= 8) { // Increased max retries
        [self showVMError:[NSString stringWithFormat:@"Failed to connect to VNC server on 127.0.0.1:%ld after multiple attempts", (long)_vncPort]];
        return;
    }
    
    // Check if VNC port is accepting connections
    if (![self isVNCServerRunning]) {
        NSDebugLLog(@"gwcomp", @"BhyveController: VNC server not ready on port %ld, retrying in 3 seconds...", (long)_vncPort);
        [self showVMStatus:[NSString stringWithFormat:@"Waiting for VNC server... (attempt %ld/8)", (long)(retryCount + 1)]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self retryVNCConnection:@(retryCount + 1)];
        });
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: VNC server is ready, creating VNC window for 127.0.0.1:%ld", (long)_vncPort);
    
    // Create VNC window with selected size
    NSSize vncSize = [self parseVNCWindowSize:_vncWindowSize];
    NSRect windowRect = NSMakeRect(100, 100, vncSize.width, vncSize.height);
    NSDebugLLog(@"gwcomp", @"BhyveController: Creating VNC window with size: %.0fx%.0f", vncSize.width, vncSize.height);
    _vncWindow = [[VNCWindow alloc] initWithContentRect:windowRect 
                                               hostname:@"127.0.0.1" 
                                                   port:_vncPort];
    
    if (_vncWindow) {
        /* Owned by ARC through this reference; if it were also released on
         * close, -close would release it a second time. */
        [_vncWindow setReleasedWhenClosed:NO];

        // Set delegate to receive close notifications
        [_vncWindow setVncDelegate:self];
        
        // Make window visible
        [_vncWindow makeKeyAndOrderFront:nil];
        
        // Show connecting status
        [self showVMStatus:[NSString stringWithFormat:@"Connecting to VNC server on 127.0.0.1:%ld...", (long)_vncPort]];
        
        // Attempt connection
        BOOL connected = [_vncWindow connectToVNC];
        if (connected) {
            [self showVMStatus:[NSString stringWithFormat:@"VNC viewer connected to 127.0.0.1:%ld", (long)_vncPort]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showVNCConnectionInfo];
            });
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: VNC connection failed, retrying...");
            [_vncWindow close];
            _vncWindow = nil;
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self retryVNCConnection:@(retryCount + 1)];
            });
        }
    } else {
        [self showVMError:@"Failed to create VNC viewer window"];
    }
}

- (void)retryVNCConnection:(NSNumber *)retryNumber
{
    [self tryVNCConnectionWithRetry:[retryNumber integerValue]];
}

- (BOOL)isVNCServerRunning
{
    // Try to connect to the VNC port to see if it's accepting connections
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return NO;
    }
    
    // Set socket timeout
    struct timeval timeout;
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        close(sockfd);
        return NO;
    }
    
    if (setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
        close(sockfd);
        return NO;
    }
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons((uint16_t)_vncPort);
    
    int result = connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
    close(sockfd);
    
    if (result == 0) {
        NSDebugLLog(@"gwcomp", @"BhyveController: VNC server is accepting connections on port %ld", (long)_vncPort);
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"BhyveController: VNC server not ready on port %ld (errno: %d)", (long)_vncPort, errno);
        return NO;
    }
}

- (void)stopVirtualMachine
{
    NSDebugLLog(@"gwcomp", @"BhyveController: stopVirtualMachine");
    
    if (!_vmRunning) {
        NSDebugLLog(@"gwcomp", @"BhyveController: VM is not running");
        return;
    }
    
    // Stop VNC window
    if (_vncWindow) {
        [_vncWindow disconnectFromVNC];
        [_vncWindow close];
        _vncWindow = nil;
    }
    
    // Stop bhyve VM
    if (_bhyveTask && [_bhyveTask isRunning]) {
        [_bhyveTask terminate];
        [_bhyveTask waitUntilExit];
        _bhyveTask = nil;
    }
    
    // Destroy VM instance
    NSTask *destroyTask = [[NSTask alloc] init];
    [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [destroyTask setArguments:@[@"--destroy", [@"--vm=" stringByAppendingString:_vmName]]];
    
    NSPipe *pipe = [NSPipe pipe];
    [destroyTask setStandardOutput:pipe];
    [destroyTask setStandardError:pipe];
    
    @try {
        [destroyTask launch];
        [destroyTask waitUntilExit];
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error destroying VM: %@", [exception reason]);
    }
    
    _vmRunning = NO;
    [self showVMStatus:@"Virtual Machine stopped"];
}

#pragma mark - Success and Error Handling

- (void)showVMStatus:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showVMStatus: %@", message);
    
    // Update running step if available
    if (_runningStep) {
        [_runningStep updateStatus:message];
    }
}

- (void)showVMError:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showVMError: %@", message);
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showVMError:message];
        });
        return;
    }
    
    // Use the framework's built-in error page method
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        [_assistantWindow showErrorPageWithTitle:@"Virtual Machine Error" message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error - assistant window doesn't support error pages");
    }
}

#pragma mark - Log Management

- (void)showVMLog
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showVMLog");
    
    if (_logWindow) {
        // Window already exists, just bring it to front
        [_logWindow makeKeyAndOrderFront:nil];
        return;
    }
    
    // Create log window
    NSRect logFrame = NSMakeRect(100, 100, 600, 400);
    _logWindow = [[NSWindow alloc] initWithContentRect:logFrame
                                             styleMask:(NSWindowStyleMaskTitled | 
                                                       NSWindowStyleMaskClosable | 
                                                       NSWindowStyleMaskMiniaturizable | 
                                                       NSWindowStyleMaskResizable)
                                               backing:NSBackingStoreBuffered 
                                                 defer:NO];
    
    /* Owned by ARC through this reference; if it were also released on
     * close, -close would release it a second time. */
    [_logWindow setReleasedWhenClosed:NO];
    [_logWindow setTitle:[NSString stringWithFormat:@"VM Log - %@", _vmName]];
    [_logWindow setDelegate:self];
    
    // Create scroll view with text view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:[[_logWindow contentView] bounds]];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:YES];
    [scrollView setAutohidesScrollers:NO];
    [scrollView setBorderType:NSNoBorder];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    
    // Create text view
    NSRect textFrame = [[scrollView contentView] bounds];
    _logTextView = [[NSTextView alloc] initWithFrame:textFrame];
    [_logTextView setMinSize:NSMakeSize(0.0, 0.0)];
    [_logTextView setMaxSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    [_logTextView setVerticallyResizable:YES];
    [_logTextView setHorizontallyResizable:NO];
    [_logTextView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [[_logTextView textContainer] setContainerSize:NSMakeSize(textFrame.size.width, CGFLOAT_MAX)];
    [[_logTextView textContainer] setWidthTracksTextView:YES];
    [_logTextView setEditable:NO];
    [_logTextView setSelectable:YES];
    [_logTextView setFont:[NSFont fontWithName:@"Monaco" size:10.0]];
    
    // Set up the text view in the scroll view
    [scrollView setDocumentView:_logTextView];
    [[_logWindow contentView] addSubview:scrollView];
    
    // Add any existing log content
    if ([_vmLogBuffer length] > 0) {
        [_logTextView setString:_vmLogBuffer];
        // Scroll to bottom
        [_logTextView scrollRangeToVisible:NSMakeRange([[_logTextView string] length], 0)];
    }
    
    [_logWindow makeKeyAndOrderFront:nil];
}

- (void)updateVMLog:(NSString *)logText
{
    if (!logText || [logText length] == 0) return;
    
    // Add to buffer
    [_vmLogBuffer appendString:logText];
    
    // If log window is open, update it
    if (_logTextView) {
        NSString *logContent = [NSString stringWithString:_vmLogBuffer];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateLogTextView:logContent];
        });
    }
}

- (void)closeLogWindow
{
    NSDebugLLog(@"gwcomp", @"BhyveController: closeLogWindow");
    
    if (_logWindow) {
        [_logWindow close];
        _logWindow = nil;
    }
    
    _logTextView = nil;
    
    if (_logFileHandle) {
        [_logFileHandle closeFile];
        _logFileHandle = nil;
    }
}

- (void)updateLogTextView:(NSString *)logText
{
    if (_logTextView) {
        [_logTextView setString:logText];
        // Scroll to bottom
        [_logTextView scrollRangeToVisible:NSMakeRange([logText length], 0)];
    }
}

- (void)monitorVMOutput:(NSArray *)pipes
{
    NSDebugLLog(@"gwcomp", @"BhyveController: monitorVMOutput - starting background monitoring");
    
    NSPipe *outputPipe = [pipes objectAtIndex:0];
    NSPipe *errorPipe = [pipes objectAtIndex:1];
    
    NSFileHandle *outputHandle = [outputPipe fileHandleForReading];
    NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
    
    // Monitor both output and error streams
    while (_vmRunning && _bhyveTask && [_bhyveTask isRunning]) {
        @autoreleasepool {
            // Check for output data
            NSData *outputData = [outputHandle availableData];
            if (outputData && [outputData length] > 0) {
                NSString *outputText = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
                if (outputText) {
                    [self updateVMLog:outputText];
                }
            }
            
            // Check for error data
            NSData *errorData = [errorHandle availableData];
            if (errorData && [errorData length] > 0) {
                NSString *errorText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                if (errorText) {
                    NSString *prefixedError = [NSString stringWithFormat:@"[ERROR] %@", errorText];
                    [self updateVMLog:prefixedError];
                }
            }
            
            // Small delay to avoid busy waiting
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    
    // When VM stops, read any remaining output
    NSData *finalOutput = [outputHandle readDataToEndOfFile];
    if (finalOutput && [finalOutput length] > 0) {
        NSString *finalText = [[NSString alloc] initWithData:finalOutput encoding:NSUTF8StringEncoding];
        if (finalText) {
            [self updateVMLog:finalText];
        }
    }
    
    NSData *finalError = [errorHandle readDataToEndOfFile];
    if (finalError && [finalError length] > 0) {
        NSString *finalErrorText = [[NSString alloc] initWithData:finalError encoding:NSUTF8StringEncoding];
        if (finalErrorText) {
            NSString *prefixedFinalError = [NSString stringWithFormat:@"[ERROR] %@", finalErrorText];
            [self updateVMLog:prefixedFinalError];
        }
    }
    
    [self updateVMLog:@"\n=== VM Process Terminated ===\n"];
    
    NSDebugLLog(@"gwcomp", @"BhyveController: monitorVMOutput - monitoring ended");
}

#pragma mark - Cleanup

- (void)cleanupTemporaryFiles
{
    NSDebugLLog(@"gwcomp", @"BhyveController: cleanupTemporaryFiles");
    
    // Remove virtual disk file
    NSString *diskPath = [NSString stringWithFormat:@"/tmp/%@.img", _vmName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        NSError *error = nil;
        if ([[NSFileManager defaultManager] removeItemAtPath:diskPath error:&error]) {
            NSDebugLLog(@"gwcomp", @"BhyveController: Removed virtual disk: %@", diskPath);
        } else {
            NSDebugLLog(@"gwcomp", @"BhyveController: Failed to remove virtual disk %@: %@", diskPath, [error localizedDescription]);
        }
    }
    
    // Clean up any VM instances
    NSTask *destroyTask = [[NSTask alloc] init];
    [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [destroyTask setArguments:@[@"--destroy", [@"--vm=" stringByAppendingString:_vmName]]];
    
    NSPipe *pipe = [NSPipe pipe];
    [destroyTask setStandardOutput:pipe];
    [destroyTask setStandardError:pipe];
    
    @try {
        [destroyTask launch];
        [destroyTask waitUntilExit];
        int exitStatus = [destroyTask terminationStatus];
        if (exitStatus == 0) {
            NSDebugLLog(@"gwcomp", @"BhyveController: Cleaned up VM instance: %@", _vmName);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error during VM cleanup: %@", [exception reason]);
    }
}

#pragma mark - GSAssistantWindowDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window
{
    NSDebugLLog(@"gwcomp", @"BhyveController: assistantWindowWillFinish");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSDebugLLog(@"gwcomp", @"BhyveController: assistantWindowDidFinish");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [[window window] close];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSDebugLLog(@"gwcomp", @"BhyveController: assistantWindowDidCancel");
    [self stopVirtualMachine];
    [self cleanupTemporaryFiles];
    [[window window] close];
    [NSApp terminate:nil];
}

- (BOOL)testBhyveBasicFunction
{
    NSDebugLLog(@"gwcomp", @"BhyveController: testBhyveBasicFunction");
    
    // Try to create and immediately destroy a test VM to check permissions
    NSTask *testTask = [[NSTask alloc] init];
    [testTask setLaunchPath:@"/usr/sbin/bhyvectl"];
    [testTask setArguments:@[@"--create", @"--vm=bhyve-test"]];
    
    NSPipe *testPipe = [NSPipe pipe];
    [testTask setStandardOutput:testPipe];
    [testTask setStandardError:testPipe];
    
    @try {
        [testTask launch];
        [testTask waitUntilExit];
        int testStatus = [testTask terminationStatus];
        
        if (testStatus == 0) {
            NSDebugLLog(@"gwcomp", @"BhyveController: bhyve VM creation test successful");
            
            // Clean up test VM
            NSTask *destroyTask = [[NSTask alloc] init];
            [destroyTask setLaunchPath:@"/usr/sbin/bhyvectl"];
            [destroyTask setArguments:@[@"--destroy", @"--vm=bhyve-test"]];
            
            @try {
                [destroyTask launch];
                [destroyTask waitUntilExit];
            } @catch (NSException *exception) {
                NSDebugLLog(@"gwcomp", @"BhyveController: Error cleaning up test VM: %@", [exception reason]);
            }
            return YES;
        } else {
            NSData *errorData = [[testPipe fileHandleForReading] readDataToEndOfFile];
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"BhyveController: bhyve VM creation test failed (exit code %d): %@", testStatus, errorOutput);
            return NO;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Error running bhyve test: %@", [exception reason]);
        return NO;
    }
}

#pragma mark - VNC Configuration

- (NSString *)generateVNCFramebufferConfig
{
    NSDebugLLog(@"gwcomp", @"BhyveController: generateVNCFramebufferConfig for port %ld", (long)_vncPort);
    
    // Enhanced framebuffer configuration for better X11 compatibility
    // The 'wait' option helps with synchronization issues that can occur with X11
    // Higher resolution provides better desktop experience
    // The framebuffer should be configured to work well with both text console and X11
    
    NSMutableString *vncConfig = [NSMutableString string];
    
    // Main framebuffer device with enhanced settings for X11 compatibility
    // Key parameters:
    // - wait: Wait for VNC client connection before starting VM (helps with sync)
    // - w=1280,h=1024: Good resolution that works well with X11
    // - tcp=0.0.0.0: Listen on all interfaces
    // - Using slot 29 to avoid conflicts with other devices
    [vncConfig appendFormat:@" -s 29:0,fbuf,tcp=127.0.0.1:%ld,w=1280,h=1024", (long)_vncPort];
    
    // Add tablet device for better mouse handling in VNC
    // This provides absolute mouse positioning which works better than relative mouse in VNC
    [vncConfig appendString:@" -s 30:0,xhci,tablet"];
    
    NSDebugLLog(@"gwcomp", @"BhyveController: VNC framebuffer config: %@", vncConfig);
    return [NSString stringWithString:vncConfig];
}

- (void)showVNCConnectionInfo
{
    NSDebugLLog(@"gwcomp", @"BhyveController: showVNCConnectionInfo");
    
    if (!_enableVNC) {
        return;
    }
    
    NSInteger displayNumber = _vncPort - 5900;
    
    NSString *vncInfo = [NSString stringWithFormat:
        @"VNC Server Information: Port %ld, Display Number %ld, Address 127.0.0.1:%ld, Resolution 1280x1024. "
        @"Text console should appear immediately, X11 may take 10-30 seconds to start. "
        @"If X11 doesn't appear, try restarting VNC viewer.",
        (long)_vncPort, (long)displayNumber, (long)_vncPort];
    
    [self showVMStatus:vncInfo];
}

#pragma mark - Port Management

- (NSInteger)findUnusedVNCPort
{
    NSDebugLLog(@"gwcomp", @"BhyveController: findUnusedVNCPort");
    
    // Start checking from port 5900 (standard VNC port)
    for (NSInteger port = 5900; port <= 5999; port++) {
        if ([self isPortAvailable:port]) {
            NSDebugLLog(@"gwcomp", @"BhyveController: Found unused VNC port: %ld", (long)port);
            return port;
        }
    }
    
    // If no standard VNC ports available, try higher range
    for (NSInteger port = 6000; port <= 6099; port++) {
        if ([self isPortAvailable:port]) {
            NSDebugLLog(@"gwcomp", @"BhyveController: Found unused VNC port in extended range: %ld", (long)port);
            return port;
        }
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: Warning - no unused VNC ports found, using 5900");
    return 5900; // Fallback to standard port
}

- (BOOL)isPortAvailable:(NSInteger)port
{
    // Create a socket to test if the port is available
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return NO;
    }
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons((uint16_t)port);
    
    int result = bind(sockfd, (struct sockaddr*)&addr, sizeof(addr));
    close(sockfd);
    
    return (result == 0);
}

#pragma mark - Settings Persistence

- (void)loadUserSettings
{
    NSDebugLLog(@"gwcomp", @"BhyveController: loadUserSettings");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load all persistent settings
    NSString *savedISOPath = [defaults stringForKey:@"BhyveAssistant.selectedISOPath"];
    if (savedISOPath) {
        _selectedISOPath = savedISOPath;
    }
    
    NSString *savedISOName = [defaults stringForKey:@"BhyveAssistant.selectedISOName"];
    if (savedISOName) {
        _selectedISOName = savedISOName;
    }
    
    NSInteger savedISOSize = [defaults integerForKey:@"BhyveAssistant.selectedISOSize"];
    if (savedISOSize > 0) {
        _selectedISOSize = savedISOSize;
    }
    
    NSString *savedVMName = [defaults stringForKey:@"BhyveAssistant.vmName"];
    if (savedVMName) {
        _vmName = savedVMName;
    }
    
    NSInteger savedRAM = [defaults integerForKey:@"BhyveAssistant.allocatedRAM"];
    if (savedRAM > 0) {
        _allocatedRAM = savedRAM;
    }
    
    NSInteger savedCPUs = [defaults integerForKey:@"BhyveAssistant.allocatedCPUs"];
    if (savedCPUs > 0) {
        _allocatedCPUs = savedCPUs;
    }
    
    NSInteger savedDiskSize = [defaults integerForKey:@"BhyveAssistant.diskSize"];
    if (savedDiskSize > 0) {
        _diskSize = savedDiskSize;
    }
    
    BOOL savedEnableVNC = [defaults boolForKey:@"BhyveAssistant.enableVNC"];
    _enableVNC = savedEnableVNC; // VNC is always enabled but load the setting anyway
    
    NSString *savedNetworkMode = [defaults stringForKey:@"BhyveAssistant.networkMode"];
    if (savedNetworkMode) {
        _networkMode = savedNetworkMode;
    }
    
    NSString *savedBootMode = [defaults stringForKey:@"BhyveAssistant.bootMode"];
    if (savedBootMode) {
        _bootMode = savedBootMode;
    }
    
    NSInteger savedVNCPort = [defaults integerForKey:@"BhyveAssistant.vncPort"];
    if (savedVNCPort > 0) {
        _vncPort = savedVNCPort;
    }
    
    NSString *savedVNCWindowSize = [defaults stringForKey:@"BhyveAssistant.vncWindowSize"];
    if (savedVNCWindowSize) {
        _vncWindowSize = savedVNCWindowSize;
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: Loaded settings - ISO: %@, VM: %@, RAM: %ld MB, CPUs: %ld, Disk: %ld GB, Network: %@, Boot: %@, VNC Port: %ld, VNC Size: %@", 
          _selectedISOPath ? _selectedISOPath : @"(none)", _vmName, (long)_allocatedRAM, (long)_allocatedCPUs, (long)_diskSize, _networkMode, _bootMode, (long)_vncPort, _vncWindowSize);
}

- (void)saveUserSettings
{
    NSDebugLLog(@"gwcomp", @"BhyveController: saveUserSettings");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Save all persistent settings
    if (_selectedISOPath) {
        [defaults setObject:_selectedISOPath forKey:@"BhyveAssistant.selectedISOPath"];
    }
    
    if (_selectedISOName) {
        [defaults setObject:_selectedISOName forKey:@"BhyveAssistant.selectedISOName"];
    }
    
    [defaults setInteger:_selectedISOSize forKey:@"BhyveAssistant.selectedISOSize"];
    
    if (_vmName) {
        [defaults setObject:_vmName forKey:@"BhyveAssistant.vmName"];
    }
    
    [defaults setInteger:_allocatedRAM forKey:@"BhyveAssistant.allocatedRAM"];
    [defaults setInteger:_allocatedCPUs forKey:@"BhyveAssistant.allocatedCPUs"];
    [defaults setInteger:_diskSize forKey:@"BhyveAssistant.diskSize"];
    [defaults setInteger:_vncPort forKey:@"BhyveAssistant.vncPort"];
    [defaults setBool:_enableVNC forKey:@"BhyveAssistant.enableVNC"];
    
    if (_networkMode) {
        [defaults setObject:_networkMode forKey:@"BhyveAssistant.networkMode"];
    }
    
    if (_bootMode) {
        [defaults setObject:_bootMode forKey:@"BhyveAssistant.bootMode"];
    }
    
    if (_vncWindowSize) {
        [defaults setObject:_vncWindowSize forKey:@"BhyveAssistant.vncWindowSize"];
    }
    
    [defaults synchronize];
    
    NSDebugLLog(@"gwcomp", @"BhyveController: Saved settings - ISO: %@, VM: %@, RAM: %ld MB, CPUs: %ld, Disk: %ld GB, Network: %@, Boot: %@, VNC Port: %ld, VNC Size: %@", 
          _selectedISOPath ? _selectedISOPath : @"(none)", _vmName, (long)_allocatedRAM, (long)_allocatedCPUs, (long)_diskSize, _networkMode, _bootMode, (long)_vncPort, _vncWindowSize);
}

#pragma mark - Property Setters with Persistence

- (void)setVmName:(NSString *)vmName
{
    if (_vmName != vmName) {
        _vmName = vmName;
        [self saveUserSettings];
    }
}

- (void)setAllocatedRAM:(NSInteger)allocatedRAM
{
    if (_allocatedRAM != allocatedRAM) {
        _allocatedRAM = allocatedRAM;
        [self saveUserSettings];
    }
}

- (void)setAllocatedCPUs:(NSInteger)allocatedCPUs
{
    if (_allocatedCPUs != allocatedCPUs) {
        _allocatedCPUs = allocatedCPUs;
        [self saveUserSettings];
    }
}

- (void)setDiskSize:(NSInteger)diskSize
{
    if (_diskSize != diskSize) {
        _diskSize = diskSize;
        [self saveUserSettings];
    }
}

- (void)setVncPort:(NSInteger)vncPort
{
    if (_vncPort != vncPort) {
        _vncPort = vncPort;
        [self saveUserSettings];
    }
}

- (void)setNetworkMode:(NSString *)networkMode
{
    if (_networkMode != networkMode) {
        _networkMode = networkMode;
        [self saveUserSettings];
    }
}

- (void)setBootMode:(NSString *)bootMode
{
    if (_bootMode != bootMode) {
        _bootMode = bootMode;
        [self saveUserSettings];
    }
}

- (void)setSelectedISOPath:(NSString *)selectedISOPath
{
    if (_selectedISOPath != selectedISOPath) {
        _selectedISOPath = selectedISOPath;
        [self saveUserSettings];
    }
}

- (void)setSelectedISOName:(NSString *)selectedISOName
{
    if (_selectedISOName != selectedISOName) {
        _selectedISOName = selectedISOName;
        [self saveUserSettings];
    }
}

- (void)setSelectedISOSize:(long long)selectedISOSize
{
    if (_selectedISOSize != selectedISOSize) {
        _selectedISOSize = selectedISOSize;
        [self saveUserSettings];
    }
}

- (void)setEnableVNC:(BOOL)enableVNC
{
    if (_enableVNC != enableVNC) {
        _enableVNC = enableVNC;
        [self saveUserSettings];
    }
}

- (void)setVncWindowSize:(NSString *)vncWindowSize
{
    if (_vncWindowSize != vncWindowSize) {
        _vncWindowSize = vncWindowSize;
        [self saveUserSettings];
    }
}

- (NSSize)parseVNCWindowSize:(NSString *)sizeString
{
    NSDebugLLog(@"gwcomp", @"BhyveController: parseVNCWindowSize: %@", sizeString);
    
    // Default size if parsing fails
    NSSize defaultSize = NSMakeSize(1024, 768);
    
    if (!sizeString || [sizeString length] == 0) {
        return defaultSize;
    }
    
    // Parse format like "1024 x 768"
    NSArray *components = [sizeString componentsSeparatedByString:@" x "];
    if ([components count] != 2) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Invalid VNC size format: %@", sizeString);
        return defaultSize;
    }
    
    NSInteger width = [[components objectAtIndex:0] integerValue];
    NSInteger height = [[components objectAtIndex:1] integerValue];
    
    if (width <= 0 || height <= 0) {
        NSDebugLLog(@"gwcomp", @"BhyveController: Invalid VNC size values: %ldx%ld", (long)width, (long)height);
        return defaultSize;
    }
    
    NSDebugLLog(@"gwcomp", @"BhyveController: Parsed VNC size: %ldx%ld", (long)width, (long)height);
    return NSMakeSize(width, height);
}

#pragma mark - VNCWindowDelegate

- (void)vncWindowWillClose:(VNCWindow *)window
{
    NSDebugLLog(@"gwcomp", @"BhyveController: VNC window closing, stopping VM");
    [self stopVirtualMachine];
}

@end

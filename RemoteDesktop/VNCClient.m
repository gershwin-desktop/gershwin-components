/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

//
// VNCClient.m  
// Remote Desktop - VNC Client using libvncclient
//

#import "VNCClient.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>

// libvncclient includes
#include <rfb/rfbclient.h>

// Forward declare VNCClient for the helper class
@class VNCClient;

#pragma mark - Helper class for synchronous main-thread password prompt

@interface VNCPasswordPromptHelper : NSObject
{
    VNCClient *_client;
    NSString *_result;
}
@property (nonatomic, retain) NSString *result;
- (id)initWithClient:(VNCClient *)client;
- (void)promptPassword;
- (void)promptCredentials;
@end

@implementation VNCPasswordPromptHelper
@synthesize result = _result;

- (id)initWithClient:(VNCClient *)client
{
    self = [super init];
    if (self) {
        _client = client;  // weak reference
        _result = nil;
    }
    return self;
}

- (void)dealloc
{
    [_result release];
    [super dealloc];
}

- (void)promptPassword
{
    // This runs on main thread via performSelectorOnMainThread:waitUntilDone:YES
    id<VNCClientDelegate> delegate = [_client delegate];
    if (delegate && [delegate respondsToSelector:@selector(vncClientNeedsPassword:)]) {
        self.result = [delegate vncClientNeedsPassword:_client];
    }
}

- (void)promptCredentials
{
    // This runs on main thread via performSelectorOnMainThread:waitUntilDone:YES
    id<VNCClientDelegate> delegate = [_client delegate];
    if (delegate && [delegate respondsToSelector:@selector(vncClientNeedsCredentials:)]) {
        NSDictionary *creds = [delegate vncClientNeedsCredentials:_client];
        // Store credentials in client using property setters
        if (creds) {
            NSString *username = [creds objectForKey:@"username"];
            NSString *password = [creds objectForKey:@"password"];
            
            NSDebugLLog(@"gwcomp", @"VNCPasswordPromptHelper: Received credentials from dialog - username: '%@' (length: %lu), password: %@ (length: %lu)",
                  username ? username : @"(nil)",
                  (unsigned long)[username length],
                  password && [password length] > 0 ? @"<provided>" : @"<empty>",
                  (unsigned long)[password length]);
            
            // Only store non-empty credentials
            if (username && [username length] > 0 && password && [password length] > 0) {
                [_client setUsername:username];
                [_client setPassword:password];
                
                NSDebugLLog(@"gwcomp", @"VNCPasswordPromptHelper: Stored in VNCClient - username: '%@', password: <provided>",
                      [_client username]);
                
                self.result = @"OK";
            } else {
                NSDebugLLog(@"gwcomp", @"VNCPasswordPromptHelper: ERROR - Empty credentials not stored (username: %lu chars, password: %lu chars)",
                      (unsigned long)[username length],
                      (unsigned long)[password length]);
                self.result = nil;
            }
        } else {
            NSDebugLLog(@"gwcomp", @"VNCPasswordPromptHelper: No credentials returned (user cancelled)");
            self.result = nil;
        }
    }
}
@end

#pragma mark - Global variable for error callback context
static VNCClient *g_currentVNCClient = nil;

#pragma mark - VNCClient Implementation

@implementation VNCClient

@synthesize hostname = _hostname;
@synthesize port = _port;
@synthesize username = _username;
@synthesize password = _password;
@synthesize connected = _connected;
@synthesize connecting = _connecting;
@synthesize headlessMode = _headlessMode;
@synthesize width = _width;
@synthesize height = _height;
@synthesize depth = _depth;
@synthesize delegate = _delegate;

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        _rfbClient = NULL;
        _hostname = nil;
        _port = 5900;
        _username = nil;
        _password = nil;
        _connected = NO;
        _connecting = NO;
        _width = 0;
        _height = 0;
        _depth = 0;
        _framebuffer = NULL;
        _framebufferSize = NSZeroSize;
        _connectionThread = nil;
        _shouldStop = NO;
        _delegate = nil;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [_hostname release];
    [_username release];
    [_password release];
    [super dealloc];
}

#pragma mark - Class Methods

+ (BOOL)isLibVNCClientAvailable
{
    // Try to load libvncclient
    void *handle = dlopen("libvncclient.so", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/usr/local/lib/libvncclient.so", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/usr/lib/libvncclient.so", RTLD_LAZY);
    }
    
    if (handle) {
        dlclose(handle);
        return YES;
    }
    
    NSDebugLLog(@"gwcomp", @"VNCClient: libvncclient not found. Install libvncserver package.");
    return NO;
}

#pragma mark - libvncclient Callbacks

// Callback for password authentication
static char *VNCGetPassword(rfbClient *client)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return NULL;
    }
    
    // If we already have a password, use it
    NSString *existingPassword = [vncClient password];
    if (existingPassword && [existingPassword length] > 0) {
        return strdup([existingPassword UTF8String]);
    }
    
    // In headless mode, don't prompt
    if ([vncClient headlessMode]) {
        NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Password required but running in headless mode (CLI)");
        NSDebugLLog(@"gwcomp", @"VNCClient: Please provide --password on the command line");
        return NULL;
    }
    
    // Otherwise prompt the user on main thread
    NSDebugLLog(@"gwcomp", @"VNCClient: Server requires password, prompting user...");
    
    VNCPasswordPromptHelper *helper = [[VNCPasswordPromptHelper alloc] initWithClient:vncClient];
    [helper performSelectorOnMainThread:@selector(promptPassword) withObject:nil waitUntilDone:YES];
    
    NSString *password = [helper result];
    [helper release];
    
    if (password && [password length] > 0) {
        // Store the password for future use
        [vncClient setPassword:password];
        char *result = strdup([password UTF8String]);
        NSDebugLLog(@"gwcomp", @"VNCClient: Password provided (length: %lu)", (unsigned long)[password length]);
        return result;
    }
    
    NSDebugLLog(@"gwcomp", @"VNCClient: No password provided or empty password");
    return NULL;
}

// Callback for credential authentication (username + password)
static rfbCredential *VNCGetCredential(rfbClient *client, int credentialType)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return NULL;
    }
    
    if (credentialType == rfbCredentialTypeUser) {
        NSDebugLLog(@"gwcomp", @"VNCClient: Server requires username/password credentials");
        
        // Check if we already have credentials - retain them to ensure they stay valid
        NSString *username = [[vncClient username] retain];
        NSString *password = [[vncClient password] retain];
        
        // If we don't have both, prompt the user (unless in headless mode)
        if (!username || [username length] == 0 || !password || [password length] == 0) {
            [username release];
            [password release];
            
            if ([vncClient headlessMode]) {
                NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Credentials required but running in headless mode (CLI)");
                NSDebugLLog(@"gwcomp", @"VNCClient: Please provide --user and --password on the command line");
                return NULL;
            }
            
            NSDebugLLog(@"gwcomp", @"VNCClient: Prompting user for credentials...");
            
            VNCPasswordPromptHelper *helper = [[VNCPasswordPromptHelper alloc] initWithClient:vncClient];
            [helper performSelectorOnMainThread:@selector(promptCredentials) withObject:nil waitUntilDone:YES];
            
            // Check if user actually provided credentials
            if (![helper result]) {
                NSDebugLLog(@"gwcomp", @"VNCClient: User cancelled or provided invalid credentials");
                [helper release];
                return NULL;
            }
            [helper release];
            
            // Credentials are now stored in vncClient - retain them again
            username = [[vncClient username] retain];
            password = [[vncClient password] retain];
        }
        
        NSDebugLLog(@"gwcomp", @"VNCGetCredential: Retrieved from VNCClient - username: '%@' (length: %lu), password: %@ (length: %lu)",
              username ? username : @"(nil)",
              (unsigned long)[username length],
              password && [password length] > 0 ? @"<provided>" : @"<empty>",
              (unsigned long)[password length]);
        
        // Defensive check - must have both valid credentials
        if (!username || [username length] == 0) {
            NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Empty username! Apple Remote Desktop requires both username AND password.");
            [username release];
            [password release];
            return NULL;
        }
        if (!password || [password length] == 0) {
            NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Empty password!");
            [username release];
            [password release];
            return NULL;
        }
        
        NSDebugLLog(@"gwcomp", @"VNCGetCredential: Creating rfbCredential with username='%@', password=<provided>", username);
        
        // Get C strings from NSString - these are temporary pointers, so strdup immediately
        const char *usernameC = [username UTF8String];
        const char *passwordC = [password UTF8String];
        
        rfbCredential *cred = (rfbCredential *)malloc(sizeof(rfbCredential));
        if (!cred) {
            NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Failed to allocate credential struct");
            [username release];
            [password release];
            return NULL;
        }
        
        // strdup creates permanent copies that libvncclient can use
        cred->userCredential.username = strdup(usernameC);
        cred->userCredential.password = strdup(passwordC);
        
        // Release our retained copies - we're done with them
        [username release];
        [password release];
        
        if (!cred->userCredential.username || !cred->userCredential.password) {
            NSDebugLLog(@"gwcomp", @"VNCClient: ERROR - Failed to duplicate credential strings");
            if (cred->userCredential.username) free(cred->userCredential.username);
            if (cred->userCredential.password) free(cred->userCredential.password);
            free(cred);
            return NULL;
        }
        
        NSDebugLLog(@"gwcomp", @"VNCGetCredential: Returning credential struct (username ptr: %p, password ptr: %p)",
              cred->userCredential.username, cred->userCredential.password);
        return cred;
    }
    
    NSDebugLLog(@"gwcomp", @"VNCClient: Unsupported credential type: %d", credentialType);
    return NULL;
}

// Callback for framebuffer size changes
static rfbBool VNCMallocFrameBuffer(rfbClient *client)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return FALSE;
    }
    
    NSDebugLLog(@"gwcomp", @"VNCClient: Framebuffer size: %dx%d, depth: %d, bpp: %d",
          client->width, client->height, client->format.depth, client->format.bitsPerPixel);
    
    // Free old framebuffer
    if (vncClient->_framebuffer) {
        free(vncClient->_framebuffer);
        vncClient->_framebuffer = NULL;
    }
    
    // Update size information
    vncClient->_width = client->width;
    vncClient->_height = client->height;
    vncClient->_depth = client->format.bitsPerPixel;
    vncClient->_framebufferSize = NSMakeSize(client->width, client->height);
    
    // Allocate new framebuffer
    int bytesPerPixel = client->format.bitsPerPixel / 8;
    size_t bufferSize = client->width * client->height * bytesPerPixel;
    
    vncClient->_framebuffer = (unsigned char *)malloc(bufferSize);
    if (!vncClient->_framebuffer) {
        NSDebugLLog(@"gwcomp", @"VNCClient: Failed to allocate framebuffer of size %zu", bufferSize);
        return FALSE;
    }
    
    client->frameBuffer = vncClient->_framebuffer;
    
    NSDebugLLog(@"gwcomp", @"VNCClient: Using server pixel format - red:%d green:%d blue:%d",
          client->format.redShift, client->format.greenShift, client->format.blueShift);
    
    // Notify delegate on main thread
    if (vncClient->_delegate && [vncClient->_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        NSRect fullRect = NSMakeRect(0, 0, client->width, client->height);
        [vncClient performSelectorOnMainThread:@selector(notifyFramebufferUpdate:)
                                    withObject:[NSValue valueWithRect:fullRect]
                                 waitUntilDone:NO];
    }
    
    return TRUE;
}

// Callback for framebuffer updates
static void VNCGotFrameBufferUpdate(rfbClient *client, int x, int y, int w, int h)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return;
    }
    
    // Notify delegate on main thread
    if (vncClient->_delegate && [vncClient->_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        NSRect updateRect = NSMakeRect(x, y, w, h);
        [vncClient performSelectorOnMainThread:@selector(notifyFramebufferUpdate:)
                                    withObject:[NSValue valueWithRect:updateRect]
                                 waitUntilDone:NO];
    }
}

// Log callback
static void VNCLog(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    NSDebugLLog(@"gwcomp", @"VNCClient libvncclient: %s", buffer);
    
    va_end(args);
}

// Error callback - also detects unsupported authentication schemes
static void VNCErr(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    NSDebugLLog(@"gwcomp", @"VNCClient libvncclient ERROR: %s", buffer);
    
    va_end(args);
    
    // Check for Apple Remote Desktop authentication schemes (30, 35)
    // libvncclient logs "Unknown authentication scheme from VNC server: 30" or "35"
    if (strstr(buffer, "Unknown authentication scheme") != NULL) {
        // Check for scheme 30 or 35 (Apple Remote Desktop)
        if (strstr(buffer, ": 30") != NULL || strstr(buffer, ": 35") != NULL ||
            strstr(buffer, ", 30") != NULL || strstr(buffer, ", 35") != NULL) {
            
            // Show error on main thread via the global client reference
            if (g_currentVNCClient && g_currentVNCClient->_delegate && 
                [g_currentVNCClient->_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
                
                NSString *errorMessage = @"This server uses Apple Remote Desktop authentication, "
                    @"which is not supported by standard VNC clients.\n\n"
                    @"To connect to this Mac, enable standard VNC authentication:\n\n"
                    @"1. Open System Preferences → Sharing\n"
                    @"2. Select 'Remote Management' or 'Screen Sharing'\n"
                    @"3. Click 'Computer Settings...'\n"
                    @"4. Check 'VNC viewers may control screen with password'\n"
                    @"5. Set a VNC password\n\n"
                    @"Then retry the connection.";
                
                [g_currentVNCClient performSelectorOnMainThread:@selector(notifyError:)
                                                     withObject:errorMessage
                                                  waitUntilDone:NO];
            }
        }
    }
}

#pragma mark - Connection Management

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port
{
    return [self connectToHost:hostname port:port password:nil];
}

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port password:(NSString *)password
{
    if (_connecting || _connected) {
        NSDebugLLog(@"gwcomp", @"VNCClient: Already connecting or connected");
        return NO;
    }
    
    if (![VNCClient isLibVNCClientAvailable]) {
        if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
            [_delegate vncClient:self didReceiveError:@"libvncclient not available"];
        }
        return NO;
    }
    
    [_hostname release];
    _hostname = [hostname copy];
    _port = port;
    [_password release];
    _password = [password copy];
    
    _connecting = YES;
    _shouldStop = NO;
    
    // Start connection in background thread
    _connectionThread = [[NSThread alloc] initWithTarget:self 
                                               selector:@selector(connectionThreadMain:) 
                                                 object:nil];
    [_connectionThread start];
    
    return YES;
}

- (void)disconnect
{
    NSDebugLLog(@"gwcomp", @"VNCClient: Disconnecting...");
    
    _shouldStop = YES;
    _connecting = NO;
    
    // Close VNC connection
    if (_rfbClient) {
        rfbClient *client = (rfbClient *)_rfbClient;
        rfbClientCleanup(client);
        _rfbClient = NULL;
    }
    
    // Wait for connection thread to finish
    if (_connectionThread && ![_connectionThread isFinished]) {
        [_connectionThread cancel];
        for (int i = 0; i < 10 && ![_connectionThread isFinished]; i++) {
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    [_connectionThread release];
    _connectionThread = nil;
    
    // Free framebuffer
    if (_framebuffer) {
        free(_framebuffer);
        _framebuffer = NULL;
    }
    
    _connected = NO;
    _width = 0;
    _height = 0;
    _depth = 0;
    _framebufferSize = NSZeroSize;
    
    // Notify delegate
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didDisconnect:)]) {
        [self performSelectorOnMainThread:@selector(notifyDisconnect:)
                               withObject:@"User requested disconnect"
                            waitUntilDone:NO];
    }
}

#pragma mark - Connection Thread

- (void)connectionThreadMain:(id)object
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSDebugLLog(@"gwcomp", @"VNCClient: Starting connection to %@:%ld", _hostname, (long)_port);
    
    // Initialize libvncclient logging
    rfbClientLog = VNCLog;
    rfbClientErr = VNCErr;
    
    // Enable verbose libvncclient logging
    rfbEnableClientLogging = TRUE;
    
    NSDebugLLog(@"gwcomp", @"VNCClient: libvncclient verbose logging enabled");
    
    // Set global reference for error callback to access
    g_currentVNCClient = self;
    
    // Note: rfbInitClient() frees the client on failure, so we cannot retry
    // with the same client object. We create a fresh client for each attempt.
    
    rfbClient *client = NULL;
    int connectResult = 0;
    
    for (int attempt = 0; attempt < 3; attempt++) {
        if (_shouldStop) {
            NSDebugLLog(@"gwcomp", @"VNCClient: Connection cancelled before attempt %d", attempt + 1);
            [self notifyConnectionResult:NO error:@"Connection cancelled"];
            goto cleanup;
        }
        
        NSDebugLLog(@"gwcomp", @"VNCClient: Connection attempt %d/3", attempt + 1);
        
        // Create a fresh client for each attempt
        client = rfbGetClient(8, 3, 4);
        if (!client) {
            NSDebugLLog(@"gwcomp", @"VNCClient: Failed to create RFB client");
            continue;
        }
        
        // Set up client data and callbacks
        rfbClientSetClientData(client, NULL, self);
        client->GetPassword = VNCGetPassword;
        client->GetCredential = VNCGetCredential;
        client->MallocFrameBuffer = VNCMallocFrameBuffer;
        client->GotFrameBufferUpdate = VNCGotFrameBufferUpdate;
        
        // Configure client settings
        client->canHandleNewFBSize = TRUE;
        client->format.depth = 24;
        client->format.bitsPerPixel = 32;
        client->format.trueColour = TRUE;
        // Set proper RGB shifts for 32-bit ARGB format
        client->format.redShift = 16;
        client->format.greenShift = 8;
        client->format.blueShift = 0;
        client->format.redMax = 255;
        client->format.greenMax = 255;
        client->format.blueMax = 255;
        
        // Connection parameters
        client->serverHost = strdup([_hostname UTF8String]);
        client->serverPort = (int)_port;
        
        NSDebugLLog(@"gwcomp", @"VNCClient: Attempting to connect to %s:%d", client->serverHost, client->serverPort);
        
        // rfbInitClient returns 0 on failure AND frees the client!
        // So after a failed call, client is invalid
        connectResult = rfbInitClient(client, NULL, NULL);
        
        if (connectResult) {
            NSDebugLLog(@"gwcomp", @"VNCClient: Connection successful on attempt %d", attempt + 1);
            _rfbClient = client;
            break;
        }
        
        // rfbInitClient already freed the client on failure, so set to NULL
        client = NULL;
        
        NSDebugLLog(@"gwcomp", @"VNCClient: Connection attempt %d failed, waiting before retry...", attempt + 1);
        
        // If we have stored credentials (meaning authentication succeeded but connection failed for another reason),
        // don't retry - the issue is likely not authentication-related
        if (_username && _password) {
            NSDebugLLog(@"gwcomp", @"VNCClient: Have stored credentials - authentication likely succeeded but connection failed. Not retrying.");
            break;
        }
        
        if (attempt < 2) {
            // Only clear credentials if connection attempt failed AND we don't have pre-set credentials
            // If credentials were provided (e.g., via command line), keep them for retry
            if (!_username && !_password) {
                NSDebugLLog(@"gwcomp", @"VNCClient: No pre-set credentials, will prompt again on retry");
            }
            
            // Use autorelease pool around sleep to ensure modal dialog cleanup
            NSDebugLLog(@"gwcomp", @"VNCClient: Sleeping 2 seconds before retry %d...", attempt + 2);
            {
                NSAutoreleasePool *sleepPool = [[NSAutoreleasePool alloc] init];
                sleep(2);
                [sleepPool drain];
            }
            NSDebugLLog(@"gwcomp", @"VNCClient: Woke up, preparing for retry %d", attempt + 2);
        }
    }
    
    if (!connectResult || !_rfbClient) {
        NSDebugLLog(@"gwcomp", @"VNCClient: All connection attempts failed");
        [self notifyConnectionResult:NO error:@"Failed to connect to VNC server. The server may use unsupported authentication (e.g., Apple Remote Desktop)."];
        goto cleanup;
    }
    
    client = (rfbClient *)_rfbClient;
    
    NSDebugLLog(@"gwcomp", @"VNCClient: Successfully connected to %@:%ld", _hostname, (long)_port);
    _connected = YES;
    _connecting = NO;
    
    [self notifyConnectionResult:YES error:nil];
    
    // Main message loop
    int maxFd;
    fd_set readfds;
    struct timeval timeout;
    
    while (!_shouldStop && _connected) {
        FD_ZERO(&readfds);
        FD_SET(client->sock, &readfds);
        maxFd = client->sock + 1;
        
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000; // 100ms timeout
        
        int result = select(maxFd, &readfds, NULL, NULL, &timeout);
        
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            NSDebugLLog(@"gwcomp", @"VNCClient: select() error: %s", strerror(errno));
            break;
        }
        
        if (result > 0 && FD_ISSET(client->sock, &readfds)) {
            int msgResult = HandleRFBServerMessage(client);
            if (msgResult == FALSE) {
                NSDebugLLog(@"gwcomp", @"VNCClient: HandleRFBServerMessage failed");
                break;
            }
        }
        
        usleep(1000); // 1ms
    }
    
cleanup:
    NSDebugLLog(@"gwcomp", @"VNCClient: Connection thread ending");
    
    // Clear global reference
    if (g_currentVNCClient == self) {
        g_currentVNCClient = nil;
    }
    
    if (_rfbClient) {
        rfbClient *client = (rfbClient *)_rfbClient;
        if (client->serverHost) {
            free(client->serverHost);
            client->serverHost = NULL;
        }
        rfbClientCleanup(client);
        _rfbClient = NULL;
    }
    
    _connected = NO;
    _connecting = NO;
    
    if (!_shouldStop) {
        [self notifyConnectionResult:NO error:@"Connection lost"];
    }
    
    [pool release];
}

- (void)notifyConnectionResult:(BOOL)success error:(NSString *)error
{
    if (_delegate) {
        NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithBool:success], @"success",
                              error ? error : @"", @"error",
                              nil];
        [self performSelectorOnMainThread:@selector(notifyConnectionOnMainThread:)
                               withObject:info
                            waitUntilDone:NO];
    }
}

#pragma mark - Input Handling

- (void)sendKeyboardEvent:(NSUInteger)key pressed:(BOOL)pressed
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    SendKeyEvent(client, (uint32_t)key, pressed ? TRUE : FALSE);
}

- (void)sendMouseEvent:(NSPoint)position buttons:(NSUInteger)buttonMask
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    
    // Convert position to VNC coordinates (flip Y axis)
    int x = (int)position.x;
    int y = (int)(_height - position.y);
    
    // Clamp to framebuffer bounds
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= _width) x = _width - 1;
    if (y >= _height) y = _height - 1;
    
    SendPointerEvent(client, x, y, (int)buttonMask);
}

- (void)sendMouseMoveEvent:(NSPoint)position
{
    [self sendMouseEvent:position buttons:0];
}

- (void)sendMouseButtonEvent:(NSUInteger)button pressed:(BOOL)pressed position:(NSPoint)position
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    static NSUInteger currentButtonMask = 0;
    
    if (pressed) {
        currentButtonMask |= (1 << (button - 1));
    } else {
        currentButtonMask &= ~(1 << (button - 1));
    }
    
    [self sendMouseEvent:position buttons:currentButtonMask];
}

#pragma mark - Framebuffer Access

- (NSData *)framebufferData
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    int bytesPerPixel = _depth / 8;
    size_t bufferSize = _width * _height * bytesPerPixel;
    
    return [NSData dataWithBytes:_framebuffer length:bufferSize];
}

- (NSImage *)framebufferImage
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    static unsigned char *staticConvertedBuffer = NULL;
    static size_t staticBufferSize = 0;
    
    int bytesPerPixel = 4;
    size_t bufferSize = _width * _height * bytesPerPixel;
    
    if (staticBufferSize != bufferSize) {
        if (staticConvertedBuffer) {
            free(staticConvertedBuffer);
        }
        staticConvertedBuffer = (unsigned char *)malloc(bufferSize);
        staticBufferSize = bufferSize;
    }
    
    if (!staticConvertedBuffer) {
        return nil;
    }
    
    // Fast memory copy and conversion from server's RGB format to RGBA
    uint32_t *sourcePixels = (uint32_t*)_framebuffer;
    uint32_t *destPixels = (uint32_t*)staticConvertedBuffer;
    
    for (int i = 0; i < _width * _height; i++) {
        uint32_t pixel = sourcePixels[i];
        
        unsigned char red = (pixel >> 16) & 0xFF;
        unsigned char green = (pixel >> 8) & 0xFF;
        unsigned char blue = pixel & 0xFF;
        
        destPixels[i] = (0xFF << 24) | (blue << 16) | (green << 8) | red;
    }
    
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] 
        initWithBitmapDataPlanes:&staticConvertedBuffer
                      pixelsWide:_width
                      pixelsHigh:_height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:_width * bytesPerPixel
                    bitsPerPixel:32];
    
    if (!bitmapRep) {
        return nil;
    }
    
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(_width, _height)];
    [image setCacheMode:NSImageCacheAlways];
    [image addRepresentation:bitmapRep];
    [bitmapRep release];
    
    return [image autorelease];
}

- (void)requestFramebufferUpdate:(NSRect)rect incremental:(BOOL)incremental
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    SendFramebufferUpdateRequest(client, 
                                (int)rect.origin.x, 
                                (int)rect.origin.y,
                                (int)rect.size.width, 
                                (int)rect.size.height,
                                incremental ? TRUE : FALSE);
}

- (void)requestFullFramebufferUpdate
{
    if (_width > 0 && _height > 0) {
        NSRect fullRect = NSMakeRect(0, 0, _width, _height);
        [self requestFramebufferUpdate:fullRect incremental:NO];
    }
}

#pragma mark - Main Thread Callback Helpers

- (void)notifyFramebufferUpdate:(NSValue *)rectValue
{
    NSRect rect = [rectValue rectValue];
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        [_delegate vncClient:self framebufferDidUpdate:rect];
    }
}

- (void)notifyDisconnect:(NSString *)reason
{
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didDisconnect:)]) {
        [_delegate vncClient:self didDisconnect:reason];
    }
}

- (void)notifyError:(NSString *)error
{
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
        [_delegate vncClient:self didReceiveError:error];
    }
}

- (void)notifyConnectionOnMainThread:(NSDictionary *)info
{
    BOOL success = [[info objectForKey:@"success"] boolValue];
    NSString *error = [info objectForKey:@"error"];
    
    if (success && [_delegate respondsToSelector:@selector(vncClient:didConnect:)]) {
        [_delegate vncClient:self didConnect:YES];
    } else if (!success) {
        if ([_delegate respondsToSelector:@selector(vncClient:didConnect:)]) {
            [_delegate vncClient:self didConnect:NO];
        }
        if (error && [error length] > 0 && [_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
            [_delegate vncClient:self didReceiveError:error];
        }
    }
}

@end

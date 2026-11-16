#import <Foundation/Foundation.h>

@protocol DSPlatform <NSObject>

@required

// Platform identification
- (NSString *)platformName;
- (BOOL)isAvailable;

// Server (promote) operations
- (BOOL)configureNFSExports;
- (BOOL)enableNFSServer;
- (BOOL)startNFSServer;
// dshelper runs only on a directory server (to advertise it for join);
// nss_gershwin resolves users without it. Enable it at boot and (re)start it.
- (BOOL)startDSHelper;

// Server (demote) operations
- (BOOL)removeNFSExports;
- (BOOL)stopNFSServer;
- (BOOL)unregisterService;
// Stop dshelper and stop starting it at boot.
- (BOOL)stopDSHelper;

// Client (join) operations
- (BOOL)enableNFSClient;
- (BOOL)startNFSClient;
- (BOOL)createNetworkMount:(NSString *)server;
- (BOOL)addFstabEntry:(NSString *)server;
- (BOOL)mountNetwork;

// Discovery
- (NSString *)discoverDirectoryServer;

// Client (leave) operations
- (BOOL)unmountNetwork;
- (BOOL)removeFstabEntry;

@optional
// Server: list currently-connected NFS client IPs (live, not historical).
// Returns nil if the platform has no implementation yet; caller may fall back.
- (NSArray<NSString *> *)connectedClients;

@end

// Get the appropriate platform implementation for the current system
id<DSPlatform> DSPlatformCreate(void);

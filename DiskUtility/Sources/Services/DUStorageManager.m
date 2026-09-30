/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageManager.h"

#import "DUErrors.h"
#import "DUNotifications.h"
#import "DUCreateImageOperation.h"
#import "DUConvertImageOperation.h"
#import "DUResizeImageOperation.h"
#import "DUBurnOperation.h"
#import "DUBlankDiscOperation.h"
#import "DUVerifyDiscOperation.h"
#import "DUOperation.h"
#import "DUOperationManager.h"
#import "DUStorageBackend.h"
#import "DUDiskImage.h"
#import "DUPartition.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"
#import "DURepairOperation.h"
#import "DUVerifyOperation.h"

// Per-operation UI callbacks registered by the convenience starters.
@interface DUCallbackPair : NSObject
@property (nonatomic, copy) void (^progress)(double progress, NSString *message);
@property (nonatomic, copy) void (^completion)(NSError *error);
@end
@implementation DUCallbackPair
@end

@implementation DUStorageManager {
    NSLock *_lock;
    id<DUStorageBackend> _backend;
    DUOperationManager *_operationManager;
    NSArray<DUStorageObject *> *_currentObjects;
    NSMutableSet<NSString *> *_busyIdentifiers;

    // operation identifier -> locked resource identifier, so finished
    // operations release exactly the lock they acquired.
    NSMutableDictionary<NSString *, NSString *> *_operationLocks;
    // operation identifier -> UI callbacks for started convenience ops.
    NSMutableDictionary<NSString *, DUCallbackPair *> *_operationCallbacks;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                operationManager:(DUOperationManager *)operationManager
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(operationManager != nil);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _lock = [[NSLock alloc] init];
    _backend = backend;
    _operationManager = operationManager;
    _currentObjects = @[];
    _busyIdentifiers = [NSMutableSet set];
    _operationLocks = [NSMutableDictionary dictionary];
    _operationCallbacks = [NSMutableDictionary dictionary];

    // One permanent observer handles lock release and callback forwarding
    // for every operation; no per-op observer churn.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidStartNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidUpdateNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFinishNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFailNotification
             object:nil];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id<DUStorageBackend>)backend
{
    return _backend;
}

- (DUOperationManager *)operationManager
{
    return _operationManager;
}

// --- Snapshot ------------------------------------------------------------

- (NSArray<DUStorageObject *> *)currentObjects
{
    [_lock lock];
    NSArray *snapshot = [_currentObjects copy];
    [_lock unlock];
    return snapshot;
}

- (DUStorageObject *)objectForIdentifier:(NSString *)identifier
{
    if (identifier.length == 0) {
        return nil;
    }
    for (DUStorageObject *root in self.currentObjects) {
        DUStorageObject *hit = [root objectForIdentifier:identifier];
        if (hit != nil) {
            return hit;
        }
    }
    return nil;
}

- (DUStorageCapabilities *)capabilitiesForObject:(DUStorageObject *)object
{
    // The model carries per-object capabilities; the platform-wide backend
    // report is exposed separately via -backendCapabilitiesReport.
    return object.capabilities;
}

- (NSDictionary *)backendCapabilitiesReport
{
    return [_backend capabilitiesReport];
}

// --- Refresh / reconcile -------------------------------------------------

/* Structural comparison keyed by stable identifiers, over EVERY object in
 * the tree rather than the roots only. The old version looked at each root's
 * own type/name/path and its children.count, which never changes when a
 * partition is resized, deleted, added at a deeper level, or when a volume is
 * mounted or unmounted - so the sidebar and the Information panel froze on
 * the layout captured at launch. Worst case: swap one bridged drive for
 * another of the same model while the app runs (same identifier, name, path
 * and child count) and it kept presenting the previous disk's partitions to
 * a user who is about to erase. */
- (BOOL)differsFromSnapshot:(NSArray<DUStorageObject *> *)fresh
{
    NSArray<DUStorageObject *> *old = _currentObjects;
    if (old.count != fresh.count) {
        return YES;
    }
    NSMutableDictionary<NSString *, DUStorageObject *> *byId =
        [NSMutableDictionary dictionary];
    for (DUStorageObject *object in [self flattenObjects:fresh]) {
        byId[object.identifier] = object;
    }
    NSMutableDictionary<NSString *, DUStorageObject *> *previousById =
        [NSMutableDictionary dictionary];
    for (DUStorageObject *object in [self flattenObjects:old]) {
        previousById[object.identifier] = object;
    }
    if (byId.count != previousById.count) {
        return YES;
    }
    for (NSString *identifier in previousById) {
        DUStorageObject *previous = previousById[identifier];
        DUStorageObject *next = byId[identifier];
        if (next == nil) {
            return YES;
        }
        if (previous.type != next.type ||
            ![previous.displayName isEqualToString:next.displayName] ||
            !(previous.backendPath == next.backendPath ||
              [previous.backendPath isEqualToString:next.backendPath])) {
            return YES;
        }
        if ([self mutableStateOfObject:previous] !=
            [self mutableStateOfObject:next]) {
            return YES;
        }
    }
    return NO;
}

// The state that changes under a live disk without changing its identity or
// name. Built as one comparable string per object so a single equality test
// covers every field that moves.
- (NSString *)mutableStateOfObject:(DUStorageObject *)object
{
    NSMutableString *state = [NSMutableString string];
    [state appendFormat:@"c=%lu", (unsigned long)object.children.count];
    if ([object isKindOfClass:[DUStorageDevice class]]) {
        DUStorageDevice *device = (DUStorageDevice *)object;
        [state appendFormat:@"|cap=%llu|s=%@|sm=%ld|h=%@|u=%d",
                             device.capacityBytes,
                             device.partitionScheme ?: @"-",
                             (long)device.smartStatus,
                             device.healthStatus ?: @"-",
                             device.partitionTableUnreadable];
    } else if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        [state appendFormat:@"|i=%ld|o=%llu|z=%llu|t=%@|f=%@|n=%@",
                             (long)partition.index, partition.offsetBytes,
                             partition.sizeBytes,
                             partition.partitionType ?: @"-",
                             partition.filesystemType ?: @"-",
                             partition.name ?: @"-"];
    } else if ([object isKindOfClass:[DUStorageVolume class]]) {
        DUStorageVolume *volume = (DUStorageVolume *)object;
        [state appendFormat:@"|f=%@|cap=%llu|m=%@|mp=%@|av=%llu|us=%llu",
                             volume.filesystemType ?: @"-",
                             volume.capacityBytes,
                             volume.mounted ? @"1" : @"0",
                             volume.mountPoint ?: @"-",
                             volume.availableBytes, volume.usedBytes];
    } else if ([object isKindOfClass:[DUDiskImage class]]) {
        DUDiskImage *image = (DUDiskImage *)object;
        [state appendFormat:@"|p=%@|z=%llu", image.path ?: @"-",
                             image.sizeBytes];
    }
    return state;
}

// Pre-order flatten, iterative so it cannot retain-cycle under ARC.
- (NSArray<DUStorageObject *> *)flattenObjects:(NSArray<DUStorageObject *> *)roots
{
    NSMutableArray<DUStorageObject *> *all = [NSMutableArray array];
    NSMutableArray<DUStorageObject *> *work = [NSMutableArray array];
    for (DUStorageObject *root in [roots reverseObjectEnumerator]) {
        [work addObject:root];
    }
    while (work.count > 0) {
        DUStorageObject *object = work.lastObject;
        [work removeLastObject];
        [all addObject:object];
        for (DUStorageObject *child in [object.children reverseObjectEnumerator]) {
            [work addObject:child];
        }
    }
    return all;
}

- (BOOL)refreshWithError:(NSError **)error
{
    NSError *discoveryError = nil;
    NSArray *discovered = [_backend discoverStorageObjects:&discoveryError];
    if (discovered == nil) {
        if (error != nil) {
            *error = discoveryError ?:
                DUErrorMake(DUErrorDiscoveryFailed,
                            NSLocalizedString(@"Discovery failed", nil));
        }
        return NO;
    }

    [_lock lock];
    BOOL changed = [self differsFromSnapshot:discovered];
    _currentObjects = [discovered copy];
    [_lock unlock];

    if (changed) {
        // One coarse signal keeps controllers simple; they re-read the
        // snapshot instead of tracking incremental deltas. Observers drive
        // AppKit while callers refresh from worker threads (device monitor,
        // operation completion), so delivery must happen on the main
        // thread or the UI corrupts sporadically.
        [self performSelectorOnMainThread:@selector(postTopologyDidChange)
                               withObject:nil
                            waitUntilDone:NO];
    }
    return YES;
}

// Main-thread continuation of refreshWithError:; observers touch views.
- (void)postTopologyDidChange
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:DUStorageTopologyDidChangeNotification
                      object:self];
}

// --- Busy locks ----------------------------------------------------------

- (BOOL)isBusyIdentifier:(NSString *)identifier
{
    [_lock lock];
    BOOL busy = [_busyIdentifiers containsObject:identifier];
    [_lock unlock];
    return busy;
}

- (BOOL)acquireLock:(NSString *)identifier error:(NSError **)error
{
    NSParameterAssert(identifier.length > 0);
    [_lock lock];
    if ([_busyIdentifiers containsObject:identifier]) {
        [_lock unlock];
        if (error != nil) {
            *error = DUErrorMake(DUErrorDeviceBusy,
                                 [NSString stringWithFormat:@"%@ is busy",
                                            identifier]);
        }
        return NO;
    }
    [_busyIdentifiers addObject:identifier];
    [_lock unlock];
    return YES;
}

- (void)releaseLock:(NSString *)identifier
{
    if (identifier.length == 0) {
        return;
    }
    [_lock lock];
    [_busyIdentifiers removeObject:identifier];
    [_lock unlock];
}

// --- Observer fan-out ------------------------------------------------------

// Operations post their events on the main thread, so this runs there.
- (void)operationNotification:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    NSString *operationId = operation.identifier;
    if (operationId.length == 0) {
        return;
    }

    BOOL terminal =
        [note.name isEqualToString:DUOperationDidFinishNotification] ||
        [note.name isEqualToString:DUOperationDidFailNotification];

    [_lock lock];
    NSString *resource = _operationLocks[operationId];
    DUCallbackPair *callbacks = _operationCallbacks[operationId];
    if (terminal) {
        [_operationLocks removeObjectForKey:operationId];
        [_operationCallbacks removeObjectForKey:operationId];
    }
    [_lock unlock];

    if (!terminal && callbacks.progress != nil &&
        [note.name isEqualToString:DUOperationDidUpdateNotification]) {
        callbacks.progress(operation.progress, operation.message);
    }

    if (terminal) {
        [self releaseLock:resource];
        if (callbacks.completion != nil) {
            callbacks.completion(note.userInfo[kDUUserInfoErrorKey]);
        }
    }
}

// --- Convenience starter -----------------------------------------------------

- (DUOperation *)repairObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error
{
    NSParameterAssert(object != nil);

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DURepairOperation *operation =
        [[DURepairOperation alloc] initWithBackend:_backend object:object];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

- (DUOperation *)verifyObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error
{
    NSParameterAssert(object != nil);

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUVerifyOperation *operation =
        [[DUVerifyOperation alloc] initWithBackend:_backend object:object];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        // Rejected before it ran; drop bookkeeping and free the device so a
        // failed start can never leave a phantom busy state behind.
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

- (DUOperation *)createImageFromObject:(DUStorageObject *)object
                               options:(NSDictionary *)options
                            onProgress:(void (^)(double progress, NSString *message))progress
                          onCompletion:(void (^)(NSError *error))completion
                                 error:(NSError **)error
{
    NSParameterAssert(object != nil);

    if (![_backend respondsToSelector:@selector(createImageFromObject:options:progress:completion:)]) {
        if (error != nil) {
            *error = DUErrorMake(DUErrorUnsupportedOperation,
                                 NSLocalizedString(
                                     @"This backend cannot create images.",
                                     nil));
        }
        return nil;
    }

    NSError *localError = nil;
    if (![self acquireLock:object.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUCreateImageOperation *operation =
        [[DUCreateImageOperation alloc] initWithBackend:_backend
                                                 object:object
                                                options:options];

    [_lock lock];
    _operationLocks[operation.identifier] = object.identifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    if (![_operationManager startOperation:operation error:&localError]) {
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:object.identifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

// Shared tail of the image-operation starters: register bookkeeping, start
// the operation, unwind on failure. The lock on resourceIdentifier must
// already be held.
- (DUOperation *)startImageOperation:(DUOperation *)operation
                    resourceIdentifier:(NSString *)resourceIdentifier
                             onProgress:(void (^)(double, NSString *))progress
                           onCompletion:(void (^)(NSError *))completion
                                  error:(NSError **)error
{
    [_lock lock];
    _operationLocks[operation.identifier] = resourceIdentifier;
    if (progress != nil || completion != nil) {
        DUCallbackPair *pair = [[DUCallbackPair alloc] init];
        pair.progress = progress;
        pair.completion = completion;
        _operationCallbacks[operation.identifier] = pair;
    }
    [_lock unlock];

    NSError *localError = nil;
    if (![_operationManager startOperation:operation error:&localError]) {
        [_lock lock];
        [_operationLocks removeObjectForKey:operation.identifier];
        [_operationCallbacks removeObjectForKey:operation.identifier];
        [_lock unlock];
        [self releaseLock:resourceIdentifier];
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    return operation;
}

// Backend-verb availability gate shared by the image starters.
- (BOOL)imageVerbAvailable:(SEL)verb
                   message:(NSString *)message
                     error:(NSError **)error
{
    if ([_backend respondsToSelector:verb]) {
        return YES;
    }
    if (error != nil) {
        *error = DUErrorMake(DUErrorUnsupportedOperation, message);
    }
    return NO;
}

- (DUOperation *)convertImage:(DUStorageObject *)image
                       options:(NSDictionary *)options
                    onProgress:(void (^)(double, NSString *))progress
                  onCompletion:(void (^)(NSError *))completion
                         error:(NSError **)error
{
    NSParameterAssert(image != nil);

    if (![self imageVerbAvailable:@selector(convertImage:options:
                                                  progress:completion:)
                          message:NSLocalizedString(@"This backend cannot convert ", nil)
                            error:error]) {
        return nil;
    }

    NSError *localError = nil;
    if (![self acquireLock:image.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUConvertImageOperation *operation =
        [[DUConvertImageOperation alloc] initWithBackend:_backend
                                                  object:image
                                                 options:options];
    return [self startImageOperation:operation
                   resourceIdentifier:image.identifier
                           onProgress:progress
                         onCompletion:completion
                                error:error];
}

- (DUOperation *)resizeImage:(DUStorageObject *)image
                      options:(NSDictionary *)options
                   onProgress:(void (^)(double, NSString *))progress
                 onCompletion:(void (^)(NSError *))completion
                        error:(NSError **)error
{
    NSParameterAssert(image != nil);

    if (![self imageVerbAvailable:@selector(resizeImage:options:
                                                  progress:completion:)
                          message:NSLocalizedString(@"This backend cannot resize ", nil)
                            error:error]) {
        return nil;
    }

    NSError *localError = nil;
    if (![self acquireLock:image.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUResizeImageOperation *operation =
        [[DUResizeImageOperation alloc] initWithBackend:_backend
                                                 object:image
                                                options:options];
    return [self startImageOperation:operation
                   resourceIdentifier:image.identifier
                           onProgress:progress
                         onCompletion:completion
                                error:error];
}

- (DUOperation *)burnImage:(DUStorageObject *)image
                 toObject:(DUStorageObject *)opticalDrive
               onProgress:(void (^)(double, NSString *))progress
             onCompletion:(void (^)(NSError *))completion
                    error:(NSError **)error
{
    NSParameterAssert(image != nil);
    NSParameterAssert(opticalDrive != nil);

    if (![self imageVerbAvailable:@selector(burnImage:toObject:progress:
                                                      completion:)
                          message:NSLocalizedString(
                                      @"This backend cannot burn discs.",
                                      nil)
                            error:error]) {
        return nil;
    }

    // The drive is the exclusive resource; the image is only read.
    NSError *localError = nil;
    if (![self acquireLock:opticalDrive.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUBurnOperation *operation =
        [[DUBurnOperation alloc] initWithBackend:_backend
                                            image:image
                                     opticalDrive:opticalDrive];
    return [self startImageOperation:operation
                   resourceIdentifier:opticalDrive.identifier
                           onProgress:progress
                         onCompletion:completion
                                error:error];
}

- (DUOperation *)blankOpticalDisc:(DUStorageObject *)opticalDrive
                           options:(NSDictionary *)options
                        onProgress:(void (^)(double, NSString *))progress
                      onCompletion:(void (^)(NSError *))completion
                             error:(NSError **)error
{
    NSParameterAssert(opticalDrive != nil);

    if (![self imageVerbAvailable:@selector(blankOpticalDisc:
                                                    options:
                                                    progress:completion:)
                           message:NSLocalizedString(
                                       @"This backend cannot blank discs.",
                                       nil)
                             error:error]) {
        return nil;
    }

    NSError *localError = nil;
    if (![self acquireLock:opticalDrive.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUBlankDiscOperation *operation =
        [[DUBlankDiscOperation alloc] initWithBackend:_backend
                                         opticalDrive:opticalDrive
                                              options:options];
    return [self startImageOperation:operation
                   resourceIdentifier:opticalDrive.identifier
                           onProgress:progress
                         onCompletion:completion
                                error:error];
}

- (DUOperation *)verifyDisc:(DUStorageObject *)opticalDrive
               againstImage:(DUStorageObject *)image
                  onProgress:(void (^)(double, NSString *))progress
                onCompletion:(void (^)(NSError *))completion
                       error:(NSError **)error
{
    NSParameterAssert(opticalDrive != nil);
    NSParameterAssert(image != nil);

    if (![self imageVerbAvailable:@selector(verifyDisc:
                                                   againstImage:
                                                   progress:completion:)
                           message:NSLocalizedString(
                                       @"This backend cannot verify discs.",
                                       nil)
                             error:error]) {
        return nil;
    }

    // The drive is the exclusive resource; the image is only read.
    NSError *localError = nil;
    if (![self acquireLock:opticalDrive.identifier error:&localError]) {
        if (error != nil) {
            *error = localError;
        }
        return nil;
    }

    DUVerifyDiscOperation *operation =
        [[DUVerifyDiscOperation alloc] initWithBackend:_backend
                                         opticalDrive:opticalDrive
                                                image:image];
    return [self startImageOperation:operation
                   resourceIdentifier:opticalDrive.identifier
                           onProgress:progress
                         onCompletion:completion
                                error:error];
}

- (NSArray<NSDictionary *> *)imageCreationFormats
{
    if ([_backend respondsToSelector:@selector(imageCreationFormats)]) {
        return [(id)_backend imageCreationFormats] ?: @[];
    }
    return @[];
}

// --- Backend passthrough --------------------------------------------------

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    // Optional protocol method; absence means "no formats offered".
    if ([_backend respondsToSelector:@selector(supportedFormatsForObject:)]) {
        return [(id)_backend supportedFormatsForObject:object] ?: @[];
    }
    return @[];
}

- (NSArray<NSDictionary *> *)eraseSecurityOptions
{
    // The pinned protocol defines no query method, so the standard choices
    // are derived from the shared constants here.
    return @[
        @{ kDUEraseSecurityMethodKey : kDUEraseMethodStandardKey },
        @{ kDUEraseSecurityMethodKey : kDUEraseMethodZerosKey },
    ];
}

@end

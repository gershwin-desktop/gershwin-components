/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuExtraManager.h"
#import "GSExtrasMenuView.h"
#import "GSMenuExtra.h"
#import "GSMenuExtraContext.h"
#import "GSMenuExtraBundle.h"
#import "GSMenuExtraInstance.h"
#import "MenuExtrasPrefPanel.h"
#import <dispatch/dispatch.h>
#import <AppKit/NSMenuView.h>
#import <GNUstepGUI/GSTheme.h>
#import "TintedMenuItemCell.h"
#import <sys/stat.h>
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
#import <sys/sysctl.h>
#endif
#if defined(__linux__)
#import <dirent.h>
#endif




static char kExtrasSubmenuIdentifierKey;

/* The gap between the extras and the end of the bar.
 *
 * One number, used by both the manager (which places the extras) and the
 * controller (which lays the app titles out in what is left), because the two
 * have to agree: a margin that differed between them would show up as the
 * titles and the extras not lining up.
 *
 * The value is chosen so the gap at this end of the bar matches the gap at
 * the other one.  The app titles start at the very edge of the bar and their
 * first item carries its own inset, which is what the eye reads as the
 * margin on that side; without a matching gap here the two ends look
 * uneven, and the difference grows with whatever is leftmost. */
const CGFloat GSExtrasEdgeMargin = 8.0;

static NSMutableDictionary<NSString *, GSMenuExtraInstance *> *GSMenuExtraInstanceDictionary = nil;

#pragma mark - MenuExtraManager

static NSString *const GSMenuExtraEnabledKey = @"GSMenuExtraEnabled";
static NSString *const GSMenuExtraOrderKey = @"GSMenuExtraOrder";

@interface MenuExtraManager () <GSExtrasMenuViewWidthProvider>
{
    MenuExtrasPrefPanel *_prefPanel;
    NSMutableDictionary<NSString *, GSMenuExtraInstance *> *_instances;
    dispatch_source_t _fsMonitorSource;
    NSMutableSet<NSString *> *_knownBundlePaths;
    NSMenu *_extrasMenu;
    GSExtrasMenuView *_extrasMenuView;
    NSMutableDictionary *_extrasMenuItems;

    /* The items of extras that are enabled but have nothing to show, keyed
       by identifier, so they can go back into the bar where they were. */
    NSMutableDictionary *_hiddenExtraItems;
    NSMutableArray<GSMenuExtraInstance *> *_allExtras;
    NSConnection *_doConnection;
    BOOL _needsUpdateGuard;
    BOOL _needsReload;
    NSTimer *_reloadTimer;
    NSArray *_pendingIdentifiers;

    /* The single leading item currently standing in for whatever extras
       are folded away, or nil when nothing is folded. */
    NSMenuItem *_extrasOverflowItem;

    /* How many leading entries of _menuExtras are currently folded behind
       _extrasOverflowItem.  Lets setCollapsedExtraCount: no-op on a repeat
       call with the same count. */
    NSUInteger _currentCollapsedExtraCount;
}
@end

@implementation MenuExtraManager

/* The width provider of the extras view (GSExtrasMenuView.h says why the
   view, not a counter, names the item being measured).

   -preferredWidth is the width of the extra's TITLE plus its own padding; the
   view adds the icon and the bar's padding on top of it, which is how every
   titled extra has always been drawn.  An extra that wants the WHOLE item
   measured otherwise says so with -totalWidthInMenuBar, and the chrome is
   taken off that instead - returning it as-is would make the item wider
   than asked for by the icon and the padding, and push everything to its
   left along. */
- (CGFloat)extrasMenuView:(GSExtrasMenuView *)aMenuView
       proposedTitleWidth:(CGFloat)proposedWidth
           forItemAtIndex:(NSInteger)index
{
    NSArray *items = [[aMenuView menu] itemArray];
    if (index < 0 || (NSUInteger)index >= [items count]) {
        return proposedWidth;
    }
    NSMenuItem *item = [items objectAtIndex:(NSUInteger)index];
    NSString *ident = [item representedObject];
    if (!ident || !GSMenuExtraInstanceDictionary) {
        return proposedWidth;
    }
    GSMenuExtraInstance *inst = [GSMenuExtraInstanceDictionary objectForKey:ident];
    if (!inst) {
        return proposedWidth;
    }
    CGFloat result = proposedWidth;
    @try {
        CGFloat wanted = [inst width];
        if ([inst statesTotalWidthInMenuBar]) {
            NSMenuItemCell *cell = [aMenuView menuItemCellForItemAtIndex:index];
            CGFloat chrome = 2.0 * [aMenuView horizontalEdgePadding];
            if (cell && [cell imageWidth]) {
                chrome += [cell imageWidth] + GSCellTextImageXDist;
            }
            result = MAX(0.0, wanted - chrome);
        } else {
            result = wanted;
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtra: exception in proposedTitleWidth for %@: %@", ident, e);
    }
    return result;
}

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height
{
    self = [super init];
    if (self) {
        _screenWidth = width;
        _menuBarHeight = height;
        _menuExtras = [NSMutableArray array];
        _allExtras = [NSMutableArray array];
        _extrasMenuItems = [NSMutableDictionary dictionary];
        _hiddenExtraItems = [NSMutableDictionary dictionary];
        _instances = [NSMutableDictionary dictionary];
        GSMenuExtraInstanceDictionary = [NSMutableDictionary dictionary];
        _knownBundlePaths = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc
{
    [self unloadAllMenuExtras];
}

#pragma mark - Bundle discovery

+ (NSArray<NSString *> *)searchPaths
{
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];

        [result addObject:[[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"MenuExtras"]];

        NSSearchPathDomainMask domains[] = {
            NSSystemDomainMask,
            NSLocalDomainMask,
            NSUserDomainMask
        };
        for (int i = 0; i < 3; i++) {
            NSString *libDir = [NSSearchPathForDirectoriesInDomains(
                NSLibraryDirectory, domains[i], YES) firstObject];
            if (libDir) {
                [result addObject:[libDir stringByAppendingPathComponent:@"MenuExtras"]];
            }
        }

        paths = [result copy];
    });
    return paths;
}

- (void)collectBundlesInDirectory:(NSString *)dirPath
                           result:(NSMutableDictionary *)bundlesById
{
    [self collectBundlesInDirectory:dirPath result:bundlesById depth:0];
}

- (void)collectBundlesInDirectory:(NSString *)dirPath
                           result:(NSMutableDictionary *)bundlesById
                            depth:(NSUInteger)depth
{
    /* Cap recursion: a symlink loop in a MenuExtras search directory (or
       simply a pathologically deep tree) would otherwise recurse until the
       stack overflows and kills the process. */
    if (depth > 5) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error || !contents) return;

    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

        NSString *ext = [[fullPath pathExtension] lowercaseString];
        if ([ext isEqualToString:@"bundle"] || [ext isEqualToString:@"gsmenuextra"]) {
            GSMenuExtraBundle *bundle = [[GSMenuExtraBundle alloc] initWithURL:[NSURL fileURLWithPath:fullPath]];
            NSString *ident = [bundle identifier];
            GSMenuExtraBundle *existing = [bundlesById objectForKey:ident];
            if (!existing) {
                [bundlesById setObject:bundle forKey:ident];
                [_knownBundlePaths addObject:fullPath];
                NSLog(@"GSMenuExtra: discovered %@ at %@", ident, fullPath);
            }
        } else {
            [self collectBundlesInDirectory:fullPath result:bundlesById depth:depth + 1];
        }
    }
}

- (NSArray<GSMenuExtraBundle *> *)discoverBundles
{
    NSMutableDictionary *bundlesById = [NSMutableDictionary dictionary];

    for (NSString *searchPath in [[self class] searchPaths]) {
        [self collectBundlesInDirectory:searchPath result:bundlesById];
    }

    NSLog(@"GSMenuExtra: discovered %lu bundles total", (unsigned long)[bundlesById count]);
    return [bundlesById allValues];
}

#pragma mark - Bundle loading

- (GSMenuExtraInstance *)loadInstanceFromBundle:(GSMenuExtraBundle *)bundle
{
    NSBundle *nsBundle = [bundle bundle];

    @try {
        if (![nsBundle isLoaded]) {
            if (![nsBundle load]) {
                NSLog(@"GSMenuExtra: failed to load bundle %@", [bundle identifier]);
                return nil;
            }
        }

        Class principalClass = [nsBundle principalClass];
        if (!principalClass) return nil;

        if (![principalClass conformsToProtocol:@protocol(GSMenuExtra)]) {
            NSLog(@"GSMenuExtra: principal class %@ does not conform to GSMenuExtra", NSStringFromClass(principalClass));
            return nil;
        }

        id<GSMenuExtra> extra = [[principalClass alloc] init];
        if (!extra) return nil;

        // Check system compatibility before loading.
        // Non-compatible extras are silently skipped - they won't appear
        // in the menu bar or the preferences panel.
        if ([extra respondsToSelector:@selector(isCompatibleWithSystem)]
            && ![extra isCompatibleWithSystem]) {
            NSLog(@"GSMenuExtra: %@ is not compatible with this system, skipping",
                  [bundle identifier]);
            return nil;
        }

        GSMenuExtraInstance *instance = [[GSMenuExtraInstance alloc] initWithExtra:extra
                                                                          identifier:[bundle identifier]
                                                                         displayName:[bundle displayName]
                                                                          priority:[bundle priority]
                                                                          manager:self];

        return instance;
    } @catch (NSException *exception) {
        NSLog(@"GSMenuExtra: exception loading bundle %@: %@", [bundle identifier], exception);
        return nil;
    }
}

#pragma mark - Main loading

- (void)loadMenuExtras
{
    NSMutableArray *allInstances = [NSMutableArray array];

    NSArray *bundles = [self discoverBundles];

    for (GSMenuExtraBundle *bundle in bundles) {
        NSString *ident = [bundle identifier];

        if ([_instances objectForKey:ident]) continue;

        NSLog(@"GSMenuExtra: loading bundle %@", ident);
        GSMenuExtraInstance *instance = [self loadInstanceFromBundle:bundle];
        if (instance) {
            [_instances setObject:instance forKey:ident];
            [GSMenuExtraInstanceDictionary setObject:instance forKey:ident];

            [allInstances addObject:instance];
            NSLog(@"GSMenuExtra: loaded bundle %@", ident);
        } else {
            NSLog(@"GSMenuExtra: FAILED to load bundle %@", ident);
        }
    }

    NSSet *enabledSet = [self loadEnabledPreference];

    NSArray *savedOrder = [self loadOrderPreference];
    NSMutableArray *orderedAll = [NSMutableArray arrayWithCapacity:[allInstances count]];

    NSMutableDictionary *instancesById = [NSMutableDictionary dictionary];
    for (GSMenuExtraInstance *inst in allInstances) {
        [instancesById setObject:inst forKey:[inst identifier]];
    }

    for (NSString *ident in savedOrder) {
        GSMenuExtraInstance *inst = [instancesById objectForKey:ident];
        if (inst) {
            [orderedAll addObject:inst];
            [instancesById removeObjectForKey:ident];
        }
    }

    for (GSMenuExtraInstance *inst in allInstances) {
        if ([instancesById objectForKey:[inst identifier]]) {
            [orderedAll addObject:inst];
        }
    }

    NSComparisonResult (^instanceComparator)(GSMenuExtraInstance *, GSMenuExtraInstance *) =
        ^NSComparisonResult(GSMenuExtraInstance *a, GSMenuExtraInstance *b) {
            NSInteger pa = [a displayPriority];
            NSInteger pb = [b displayPriority];
            if (pa < pb) return NSOrderedAscending;
            if (pa > pb) return NSOrderedDescending;
            return NSOrderedSame;
        };

    _allExtras = orderedAll;
    [_allExtras sortUsingComparator:instanceComparator];
    _menuExtras = [NSMutableArray array];

    [self applyEnabledSet:enabledSet];

    // Load enabled extras (calls menuExtraDidLoad wrapped in @try/@catch).
    for (GSMenuExtraInstance *inst in _menuExtras) {
        [inst load];
    }

    [self setupDOServer];
    [self startFileSystemMonitoring];
}

- (NSArray<GSMenuExtraInstance *> *)allMenuExtras
{
    return _allExtras;
}

- (void)reloadEnabledFromDefaults
{
    NSLog(@"GSMenuExtra: reloadEnabledFromDefaults called, _allExtras=%@",
          _allExtras ? @"non-nil" : @"nil");
    if (!_allExtras) return;

    NSSet *enabledSet = [self loadEnabledPreference];
    NSLog(@"GSMenuExtra: enabledSet=%@", enabledSet ?: @"nil (show all)");
    [self applyEnabledSet:enabledSet];
}

- (void)setupDOServer
{
    _doConnection = [[NSConnection alloc] init];
    [_doConnection setRootObject:self];
    if ([_doConnection registerName:@"io.github.gershwin-desktop.MenuExtraConfigServer"]) {
        NSLog(@"GSMenuExtra: DO server registered for config changes");
    }
}

- (BOOL)updateEnabledExtras:(NSArray *)identifiers
{
    NSLog(@"GSMenuExtra: DO received %lu identifiers", (unsigned long)[identifiers count]);
    _pendingIdentifiers = [NSArray arrayWithArray:identifiers];
    _needsReload = YES;

    if (!_reloadTimer) {
        _reloadTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(reloadTimerFired:)
                                                      userInfo:nil
                                                       repeats:NO];
    }
    NSLog(@"GSMenuExtra: DO method returning YES");
    return YES;
}

- (void)reloadTimerFired:(NSTimer *)timer
{
    if (!_needsReload || !_pendingIdentifiers || !_allExtras || [_allExtras count] == 0) {
        _needsReload = NO;
        _pendingIdentifiers = nil;
        [_reloadTimer invalidate];
        _reloadTimer = nil;
        return;
    }

    _needsReload = NO;
    NSArray *pending = _pendingIdentifiers;
    _pendingIdentifiers = nil;
    [_reloadTimer invalidate];
    _reloadTimer = nil;

    for (id obj in pending) {
        if (![obj isKindOfClass:[NSString class]]) {
            NSLog(@"GSMenuExtra: reloadTimerFired - BAD identifier type: %@", [obj class]);
            return;
        }
    }

    [[NSUserDefaults standardUserDefaults] setObject:pending forKey:GSMenuExtraEnabledKey];
    [[NSUserDefaults standardUserDefaults] setObject:pending forKey:GSMenuExtraOrderKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSSet *enabledSet = [NSSet setWithArray:pending];
    [self applyEnabledSet:enabledSet];
}



- (void)rebuildExtrasMenu
{
    NSLog(@"GSMenuExtra: rebuildExtrasMenu start, extras=%lu, menuItems=%lu",
          (unsigned long)[_menuExtras count], (unsigned long)[_extrasMenuItems count]);

    if (!_extrasMenu) {
        _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];
        NSLog(@"GSMenuExtra: created new _extrasMenu");
    }

    /* The incremental add/remove logic below walks _extrasMenu's top-level
       items by identifier; an active collapse hides some of them inside
       the overflow item's submenu instead, where this method would not see
       them.  Restore to unfolded first so it always edits a consistent,
       fully-expanded menu. */
    if (_extrasOverflowItem) {
        [self setCollapsedExtraCount:0];
    }

    /* Remove items no longer wanted */
    NSMutableArray *identsToRemove = [NSMutableArray array];
    for (NSString *ident in _extrasMenuItems) {
        BOOL found = NO;
        for (GSMenuExtraInstance * p in _menuExtras) {
            if ([[p identifier] isEqualToString:ident]) {
                found = YES;
                break;
            }
        }
        if (!found) {
            [identsToRemove addObject:ident];
        }
    }
    NSLog(@"GSMenuExtra: removing %lu items", (unsigned long)[identsToRemove count]);
    for (NSString *ident in identsToRemove) {
        NSMenuItem *item = [_extrasMenuItems objectForKey:ident];
        NSInteger idx = [_extrasMenu indexOfItem:item];
        if (idx >= 0) {
            [_extrasMenu removeItemAtIndex:idx];
        }
        [_extrasMenuItems removeObjectForKey:ident];
        /* An extra that was hidden is not in the menu to be removed, but if
           it is being switched off its remembered item has to go too, or it
           would come back to a bar it is no longer part of. */
        [_hiddenExtraItems removeObjectForKey:ident];
    }

    /* Add items that are new */
    NSLog(@"GSMenuExtra: adding new items");
    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        if ([_extrasMenuItems objectForKey:ident]) continue;

        /* An extra with nothing to show is not in the bar, and a rebuild is
           not a reason to put it back: that would undo the very state the
           extra is in.  Its item is remembered so it can return by itself. */
        if ([provider isHiddenFromMenuBar]) {
            if ([_hiddenExtraItems objectForKey:ident] == nil) {
                NSMenuItem *hidden =
                    [[NSMenuItem alloc] initWithTitle:[provider title] ?: ident
                                               action:NULL
                                        keyEquivalent:@""];
                [hidden setRepresentedObject:ident];
                [_hiddenExtraItems setObject:hidden forKey:ident];
            }
            continue;
        }
        NSLog(@"GSMenuExtra:   adding item %@", ident);

        NSString *title = [provider title] ? [provider title] : ident;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        NSLog(@"GSMenuExtra:   created item");
        if ([provider respondsToSelector:@selector(icon)]) {
            [self showIconOfExtra:provider inItem:item];
        }
        NSLog(@"GSMenuExtra:   set icon");
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = [provider menu];
            if (submenu) {
                [self configureSubmenu:submenu forIdentifier:ident];
                [item setSubmenu:submenu];
            }
        }
        NSLog(@"GSMenuExtra:   set submenu");
        [item setRepresentedObject:ident];

        NSInteger insertIdx = [_extrasMenu numberOfItems];
        for (NSUInteger i = 0; i < [_menuExtras count]; i++) {
            if ([[_menuExtras[i] identifier] isEqualToString:ident]) {
                for (NSUInteger j = 0; j < (NSUInteger)[_extrasMenu numberOfItems]; j++) {
                    NSMenuItem *existing = [_extrasMenu itemAtIndex:j];
                    NSString *eid = [existing representedObject];
                    for (GSMenuExtraInstance * ep in _menuExtras) {
                        if ([[ep identifier] isEqualToString:eid]) {
                            NSInteger pa = 100, pb = 100;
                            if ([provider respondsToSelector:@selector(displayPriority)])
                                pa = [provider displayPriority];
                            if ([ep respondsToSelector:@selector(displayPriority)])
                                pb = [ep displayPriority];
                            if (pa > pb) {
                                insertIdx = j;
                            }
                            break;
                        }
                    }
                }
                break;
            }
        }
        NSLog(@"GSMenuExtra:   inserting at %ld", (long)insertIdx);
        [_extrasMenu insertItem:item atIndex:insertIdx];
        NSLog(@"GSMenuExtra:   inserted OK");
        [_extrasMenuItems setObject:item forKey:ident];
    }

    /* Update view */
    NSLog(@"GSMenuExtra: updating view");
    if (!_extrasMenuView) {
        _extrasMenuView = [[GSExtrasMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, _menuBarHeight)];
        [_extrasMenuView setHorizontal:YES];
        [_extrasMenuView setWidthProvider:self];

        [_extrasMenuView setMenu:_extrasMenu];
    } else if ([_extrasMenuView menu] != _extrasMenu) {
        /* Only a NEW menu is attached: attaching the one the view already
           has adds a second set of cells behind the first (-setMenu: makes a
           cell per item and keeps the old ones), and from then on the view
           has cells no item accounts for. */
        [_extrasMenuView setMenu:_extrasMenu];
    }
    NSLog(@"GSMenuExtra: view menu set");

    [_extrasMenuView sizeToFit];
    CGFloat width = [self extrasMenuWidth];
    NSLog(@"GSMenuExtra: width=%g", width);

    [self placeExtrasViewWithWidth:width];
    NSLog(@"GSMenuExtra: rebuildExtrasMenu done");
}

- (void)applyEnabledSet:(NSSet *)enabledSet
{
    if (!_allExtras || [_allExtras count] == 0) return;

    NSMutableArray *newEnabled = [NSMutableArray array];
    for (GSMenuExtraInstance * p in _allExtras) {
        if (!enabledSet || [enabledSet containsObject:[p identifier]]) {
            [newEnabled addObject:p];
        }
    }

    if (enabledSet && [enabledSet count] > 0 && [newEnabled count] == 0 && [_allExtras count] > 0) {
        NSLog(@"GSMenuExtra: enabledSet contains NO matching extras (%lu identifiers, %lu loaded) - ignoring",
              (unsigned long)[enabledSet count], (unsigned long)[_allExtras count]);
        newEnabled = [NSMutableArray arrayWithArray:_allExtras];
    }

    NSLog(@"GSMenuExtra: applyEnabledSet: %lu extras enabled out of %lu total",
          (unsigned long)[newEnabled count], (unsigned long)[_allExtras count]);

    [newEnabled sortUsingComparator:^NSComparisonResult(GSMenuExtraInstance * a, GSMenuExtraInstance * b) {
        NSInteger pa = 100, pb = 100;
        if ([a respondsToSelector:@selector(displayPriority)]) pa = [a displayPriority];
        if ([b respondsToSelector:@selector(displayPriority)]) pb = [b displayPriority];
        if (pa < pb) return NSOrderedAscending;
        if (pa > pb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    BOOL changed = ([_menuExtras count] != [newEnabled count]);
    if (!changed) {
        for (NSUInteger i = 0; i < [_menuExtras count]; i++) {
            if (![[_menuExtras[i] identifier] isEqualToString:[newEnabled[i] identifier]]) {
                changed = YES;
                break;
            }
        }
    }
    if (!changed) return;

    // On subsequent calls (toggles), stop disabled extras and start re-enabled ones.
    if ([_menuExtras count] > 0) {
        for (GSMenuExtraInstance *inst in _allExtras) {
            if (![newEnabled containsObject:inst]) {
                @try {
                    [inst unload];
                } @catch (NSException *e) {
                    NSLog(@"GSMenuExtra: exception in unload for %@: %@", [inst identifier], e);
                }
            }
        }
        for (GSMenuExtraInstance *inst in newEnabled) {
            BOOL wasEnabled = NO;
            for (GSMenuExtraInstance *oi in _menuExtras) {
                if ([[oi identifier] isEqualToString:[inst identifier]]) {
                    wasEnabled = YES;
                    break;
                }
            }
            if (!wasEnabled) {
                [inst load];
            }
        }
    }

    _menuExtras = newEnabled;

    if (!_extrasMenu) {
        _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];
    }

    // Detach submenus before removing items to prevent "already has supermenu" exceptions
    // when reusing the same submenu object on a new item (CPU/RAM cache their menu objects).
    for (NSMenuItem *existingItem in [_extrasMenu itemArray]) {
        if ([existingItem hasSubmenu]) {
            [existingItem setSubmenu:nil];
        }
    }
    [_extrasMenu removeAllItems];
    [_extrasMenuItems removeAllObjects];

    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        NSString *title = ident;
        @try {
            title = [provider title] ?: ident;
        } @catch (NSException *e) {
            NSLog(@"GSMenuExtra: exception in title for %@: %@", ident, e);
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        if ([provider respondsToSelector:@selector(icon)]) {
            @try {
                [self showIconOfExtra:provider inItem:item];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception in icon for %@: %@", ident, e);
            }
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = nil;
            @try {
                submenu = [provider menu];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception in menu for %@: %@", ident, e);
            }
            if (submenu) {
                /* Same as the other two build paths: without the delegate the
                   submenu never gets menuNeedsUpdate:/menuWillOpen again, so
                   this extra's menu would stop refreshing on open (and lose
                   its Customize... item) the moment the user toggles anything
                   in the preferences panel. */
                [self configureSubmenu:submenu forIdentifier:ident];
                [item setSubmenu:submenu];
            }
        }
        [item setRepresentedObject:ident];
        [_extrasMenu addItem:item];
        [_extrasMenuItems setObject:item forKey:ident];
    }

    /* Every item above is freshly created and placed at top level, so any
       collapse that was applied before this rebuild no longer describes
       reality - the overflow item it made is gone (detached above) and its
       submenu's items were never re-created.  Without this,
       setCollapsedExtraCount: would see the same count requested again
       right after this and treat it as already applied, leaving every
       extra shown uncollapsed. */
    _extrasOverflowItem = nil;
    _currentCollapsedExtraCount = 0;

    if (_extrasMenuView) {
        [_extrasMenuView setFrameSize:NSMakeSize(0, _menuBarHeight)];
        [_extrasMenuView sizeToFit];
        CGFloat width = [self extrasMenuWidth];
        [self placeExtrasViewWithWidth:width];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraEnabledSetDidChange"
                                                        object:self];

    NSLog(@"GSMenuExtra: applied enabled set, %lu items active",
          (unsigned long)[_menuExtras count]);
}

- (void)unloadAllMenuExtras
{
    [self stopUpdateTimers];

    _needsReload = NO;
    _pendingIdentifiers = nil;
    [_reloadTimer invalidate];
    _reloadTimer = nil;

    if (_doConnection) {
        [_doConnection invalidate];
        _doConnection = nil;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_fsMonitorSource) {
        dispatch_source_cancel(_fsMonitorSource);
        _fsMonitorSource = nil;
    }

    [self savePreferences];

    for (GSMenuExtraInstance * item in _menuExtras) {
        @try {
            if ([item respondsToSelector:@selector(unload)]) [item unload];
        } @catch (NSException *exception) {}
    }

    [_extrasMenuItems removeAllObjects];
    _extrasMenu = nil;
    _extrasMenuView = nil;
    [_menuExtras removeAllObjects];
    [_instances removeAllObjects];
    [GSMenuExtraInstanceDictionary removeAllObjects];
}

- (GSMenuExtraInstance *)providerForIdentifier:(NSString *)identifier
{
    if (!identifier) return nil;

    for (GSMenuExtraInstance * provider in _allExtras) {
        if ([[provider identifier] isEqualToString:identifier]) {
            return provider;
        }
    }
    return nil;
}

- (void)configureSubmenu:(NSMenu *)submenu forIdentifier:(NSString *)identifier
{
    if (!submenu || !identifier) return;

    objc_setAssociatedObject(submenu, &kExtrasSubmenuIdentifierKey, identifier, OBJC_ASSOCIATION_RETAIN);
    [submenu setDelegate:(id<NSMenuDelegate>)self];
    [submenu setAutoenablesItems:NO];

    if ([submenu numberOfItems] > 0
        && [[submenu itemAtIndex:[submenu numberOfItems] - 1] action] != @selector(showPreferencesPanel)) {
        [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Customize..."
                                                           action:@selector(showPreferencesPanel)
                                                    keyEquivalent:@""];
        [prefsItem setTarget:self];
        [submenu addItem:prefsItem];
    }
}

/* An open menu is never rebuilt: replacing its items under the pointer drops
   the highlight, and highlighting again changes an item, which updates the
   menu once more, so it would rebuild itself over and over and flicker.
   -[NSMenu display] updates a menu before it shows its window, so every menu
   is still rebuilt each time it opens. */
- (BOOL)isMenuOnScreen:(NSMenu *)menu
{
    return [[menu window] isVisible];
}

- (void)replaceMenu:(NSMenu *)target withMenu:(NSMenu *)source
{
    if (!target || !source || target == source) return;

    while ([target numberOfItems] > 0) {
        [target removeItemAtIndex:0];
    }
    while ([source numberOfItems] > 0) {
        NSMenuItem *item = [source itemAtIndex:0];
        [source removeItemAtIndex:0];
        [target addItem:item];
    }
}

#pragma mark - View creation

- (NSView *)createExtrasMenuView
{
    _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];

    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        NSString *title = [provider title] ? [provider title] : ident;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        if ([provider respondsToSelector:@selector(icon)]) {
            [self showIconOfExtra:provider inItem:item];
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = [provider menu];
            if (submenu) {
                [self configureSubmenu:submenu forIdentifier:ident];
                [item setSubmenu:submenu];
            }
        }
        [item setRepresentedObject:ident];
        [_extrasMenu addItem:item];
        [_extrasMenuItems setObject:item forKey:ident];
    }
    _extrasMenuView = [[GSExtrasMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, _menuBarHeight)];
    [_extrasMenuView setHorizontal:YES];
    [_extrasMenuView setWidthProvider:self];
    [_extrasMenuView setMenu:_extrasMenu];

    CGFloat width = [self extrasMenuWidth];
    [_extrasMenuView setFrameSize:NSMakeSize(width, _menuBarHeight)];

    return _extrasMenuView;
}

/* Puts the extras group at the right end of the bar and pins its right edge
   there, so the view keeps it through every later resize of its own. */
- (void)placeExtrasViewWithWidth:(CGFloat)width
{
    NSView *superview = [_extrasMenuView superview];
    if (superview) {
        CGFloat menuBarW = NSWidth([superview bounds]);
        [_extrasMenuView setAnchoredRightEdge:menuBarW - GSExtrasEdgeMargin];
        [_extrasMenuView setFrame:NSMakeRect(menuBarW - width - GSExtrasEdgeMargin, 0, width, _menuBarHeight)];
        [superview setNeedsDisplay:YES];
    } else {
        [_extrasMenuView setFrameSize:NSMakeSize(width, _menuBarHeight)];
    }
}

- (CGFloat)extrasMenuWidthForView:(GSExtrasMenuView *)view menu:(NSMenu *)menu
{
    if (!view || !menu || [[menu itemArray] count] == 0) return 0;

    [view sizeToFit];
    /* The resting width: while items slide, the rects they are drawn at are
       off their places, and the bar is laid out around where they will come
       to rest. */
    return [view itemsWidth];
}

- (CGFloat)extrasMenuWidth
{
    return [self extrasMenuWidthForView:_extrasMenuView menu:_extrasMenu];
}

#pragma mark - Menu bar layout (extras collapse)

- (NSArray<NSNumber *> *)naturalExtraWidthsLeastImportantFirst
{
    NSUInteger total = [_menuExtras count];
    if (total == 0) return @[];

    /* Measure against the fully unfolded state, then restore whatever fold
       was in effect - the caller is expected to immediately apply the
       fresh layout decision anyway, but leaving the view in a half-measured
       state if it does not would be a foot-gun. */
    NSUInteger savedCollapse = _currentCollapsedExtraCount;
    [self setCollapsedExtraCount:0];

    [_extrasMenuView sizeToFit];

    /* One width per extra, in _menuExtras order, taken from the item that
       extra has in the menu: an extra with nothing to show has no item and
       takes no room, so it is 0 rather than the rect of whatever item sits
       at its index - past the end of the menu once one extra is hidden. */
    NSMutableArray *widths = [NSMutableArray arrayWithCapacity:total];
    for (NSUInteger i = 0; i < total; i++) {
        NSMenuItem *item = [_extrasMenuItems objectForKey:[_menuExtras[i] identifier]];
        NSInteger idx = item ? [_extrasMenu indexOfItem:item] : -1;
        CGFloat width = 0.0;
        if (idx >= 0) {
            width = NSWidth([_extrasMenuView restingRectOfItemAtIndex:idx]);
        }
        [widths addObject:@(width)];
    }

    [self setCollapsedExtraCount:savedCollapse];
    return widths;
}

- (void)setCollapsedExtraCount:(NSUInteger)count
{
    NSUInteger total = [_menuExtras count];
    if (count > total) count = total;
    if (count == _currentCollapsedExtraCount) return;
    if (!_extrasMenu) return;

    /* Detach the current overflow wrapper (if any) so its submenu's items
       are free to be redistributed below; the NSMenuItem objects themselves
       are never rebuilt here (they stay in _extrasMenuItems by identity),
       so a title update by identifier (the periodic tick) keeps working
       whichever slot an extra currently occupies. */
    if (_extrasOverflowItem) {
        [_extrasOverflowItem setSubmenu:nil];
        _extrasOverflowItem = nil;
    }
    while ([_extrasMenu numberOfItems] > 0) {
        [_extrasMenu removeItemAtIndex:0];
    }

    NSUInteger idx = 0;
    if (count > 0) {
        NSMenu *overflowMenu = [[NSMenu alloc] initWithTitle:@"More"];
        [overflowMenu setAutoenablesItems:NO];
        for (; idx < count; idx++) {
            NSMenuItem *item = [_extrasMenuItems objectForKey:[_menuExtras[idx] identifier]];
            if (item) [overflowMenu addItem:item];
        }
        /* A left-pointing chevron: this sits at the LEFT of the extras
           cluster (nearest the app's own titles), the opposite end from
           the app menu's own trailing ">>" overflow, so the two are never
           mistaken for each other. */
        NSMenuItem *overflow = [[NSMenuItem alloc] initWithTitle:@"«" action:NULL keyEquivalent:@""];
        [overflow setSubmenu:overflowMenu];
        [_extrasMenu addItem:overflow];
        _extrasOverflowItem = overflow;
    }
    for (; idx < total; idx++) {
        NSMenuItem *item = [_extrasMenuItems objectForKey:[_menuExtras[idx] identifier]];
        if (item) [_extrasMenu addItem:item];
    }

    _currentCollapsedExtraCount = count;

    [_extrasMenuView sizeToFit];
    CGFloat width = [self extrasMenuWidth];
    [self placeExtrasViewWithWidth:width];
}

#pragma mark - Update timers

- (void)startUpdateTimers
{
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    target:self
                                                  selector:@selector(updateTimerFired:)
                                                  userInfo:[_menuExtras copy]
                                                   repeats:YES];
    [self updateTimerFired:_updateTimer];
}

- (void)updateTimerFired:(NSTimer *)timer
{
    @try {
        /* The list is taken live, not from the timer's userInfo: enabling or
           disabling an extra from the preferences panel replaces _menuExtras,
           and the snapshot taken when the timer started would leave every
           newly enabled extra unticked (its readings frozen at load, exactly
           the bug this shared timer exists to prevent) while removed ones
           kept ticking forever. */
        NSArray *items = [_menuExtras copy];

        /* Work out first what has to change, so the items are moved in one
           go and the bar is laid out once afterwards.  The view keeps its
           right edge on the bar's through every pass of its own, so an item
           leaving or arriving never shows the group anywhere else. */
        NSMutableArray *toHide = [NSMutableArray array];
        NSMutableArray *toShow = [NSMutableArray array];
        for (GSMenuExtraInstance * item in items) {
            NSString *ident = [item identifier];
            if (!ident) continue;
            BOOL wantHidden = [item isHiddenFromMenuBar];
            BOOL isHidden = ([_extrasMenuItems objectForKey:ident] == nil);
            if (wantHidden == isHidden) continue;
            if (wantHidden) {
                [toHide addObject:ident];
            } else {
                [toShow addObject:ident];
            }
        }
        BOOL visibilityChanged = ([toHide count] > 0 || [toShow count] > 0);

        for (GSMenuExtraInstance * item in items) {
            @try {
                [item tick];
                NSString *title = [item title];
                if (!title) {
                    title = [NSString stringWithFormat:@"[%@]", [item identifier]];
                }
                NSMenuItem *menuItem = [_extrasMenuItems objectForKey:[item identifier]];
                if (menuItem) [menuItem setTitle:title];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception updating item %@: %@", [item identifier], e);
            }
        }

        NSUInteger ci;
        for (ci = 0; ci < [toHide count]; ci++) {
            [self setExtraHidden:YES forIdentifier:[toHide objectAtIndex:ci]];
        }
        for (ci = 0; ci < [toShow count]; ci++) {
            [self setExtraHidden:NO forIdentifier:[toShow objectAtIndex:ci]];
        }

        if (visibilityChanged) {
            /* The view followed the items out of and into the menu through
               NSMenu's notifications, which are posted as they happen, so it
               can be laid out and placed right away. */
            [self relayoutExtras];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtra: exception in updateTimerFired: %@", e);
    }
}

/* Takes one extra's item out of, or puts it back into, the bar's menu.
 *
 * The view lays out every item it is given and adds its own padding to each,
 * so an extra that wants no room cannot get none while it is still in the
 * menu - it would leave a gap the width of that padding.  Removing the item
 * is what actually gives the space back, and the extras either side of it
 * close up because they are laid out from the menu's own contents.
 *
 * Returns YES if the item actually moved, so the caller can lay out once
 * rather than on every tick. */
- (BOOL)setExtraHidden:(BOOL)hidden forIdentifier:(NSString *)identifier
{
    if (!identifier) return NO;
    NSMenuItem *inMenu = [_extrasMenuItems objectForKey:identifier];

    if (hidden) {
        if (!inMenu) return NO;
        NSInteger idx = [_extrasMenu indexOfItem:inMenu];
        if (idx < 0) return NO;
        [_extrasMenu removeItemAtIndex:idx];
        /* Kept out of _extrasMenuItems on purpose: that is what tells the
           rebuild below this item is not in the menu, so it does not try to
           remove it a second time.  It is remembered here instead, so it can
           go back into the bar where it was when the extra has something to
           show again. */
        [_extrasMenuItems removeObjectForKey:identifier];
        [_hiddenExtraItems setObject:inMenu forKey:identifier];
        return YES;
    }

    /* Already showing: nothing to do.  This also covers an extra that was
       never hidden, so the common case costs one dictionary lookup. */
    if (inMenu) return NO;

    NSMenuItem *remembered = [_hiddenExtraItems objectForKey:identifier];
    if (!remembered) {
        /* Hidden by something other than us (or a rebuild dropped it), so it
           is not ours to put back - the next rebuild will make it. */
        return NO;
    }
    [_hiddenExtraItems removeObjectForKey:identifier];

    /* Back where the enabled-extras order says it belongs, counting only the
       items that are actually in the menu - a hidden extra before it must
       not push it along. */
    NSInteger insertIdx = (NSInteger)[_extrasMenu numberOfItems];
    NSUInteger want = [_menuExtras indexOfObject:
        [self instanceForIdentifier:identifier]];
    if (want != NSNotFound) {
        NSUInteger before = 0;
        for (NSUInteger i = 0; i < want; i++) {
            NSString *otherId = [[_menuExtras objectAtIndex: i] identifier];
            if ([_extrasMenuItems objectForKey:otherId] != nil) {
                before++;
            }
        }
        if ((NSUInteger)insertIdx > before) insertIdx = (NSInteger)before;
    }
    [_extrasMenu insertItem:remembered atIndex:insertIdx];
    [_extrasMenuItems setObject:remembered forKey:identifier];

    /* The item goes back carrying whatever it had when it left, and an extra
       that hides itself usually had no icon at that moment - it had nothing
       to show.  By now it has been asked to draw again, so the icon has to be
       put on the item here: without this the extra returns as a blank gap
       the width of an icon, which is the one thing it was meant to stop
       being. */
    [self refreshExtraWithIdentifier:identifier];
    return YES;
}

- (GSMenuExtraInstance *)instanceForIdentifier:(NSString *)identifier
{
    for (GSMenuExtraInstance *inst in _menuExtras) {
        if ([[inst identifier] isEqualToString:identifier]) return inst;
    }
    return nil;
}

/* Lays the extras out again after their number or their widths changed, and
   tells the bar so the app titles make room. */
- (void)relayoutExtras
{
    [_extrasMenuView sizeToFit];

    CGFloat width = [self extrasMenuWidth];
    [self placeExtrasViewWithWidth:width];
    [_extrasMenuView setNeedsDisplay:YES];

    /* The app titles share the bar with the extras and are laid out from the
       width the extras leave them, so they have to be told. */
    [_layoutDelegate menuExtraManagerNeedsLayout:self];
}

- (void)stopUpdateTimers
{
    [_updateTimer invalidate];
    _updateTimer = nil;
}

#pragma mark - Presentation invalidation

/* Every extra icon goes through here so that it gets the menu bar size and,
   while the extra's menu is open, the highlight color. */
- (void)showIconOfExtra:(GSMenuExtraInstance *)provider inItem:(NSMenuItem *)item
{
    NSImage *icon = [provider icon];
    if (icon) {
        CGFloat iconSize = _menuBarHeight - 4.0;
        [icon setSize:NSMakeSize(iconSize, iconSize)];
    }
    [item setMenuBarImage:icon];
}

- (void)invalidateWidthForExtraWithIdentifier:(NSString *)identifier
{
    if (!identifier) return;
    for (GSMenuExtraInstance *provider in _menuExtras) {
        if (![[provider identifier] isEqualToString:identifier]) continue;
        @try {
            [provider invalidateWidth];
        } @catch (NSException *e) {
            NSLog(@"GSMenuExtra: exception in invalidateWidth for %@: %@", identifier, e);
        }
        break;
    }
}

- (void)refreshExtraWithIdentifier:(NSString *)identifier
{
    NSMenuItem *menuItem = [_extrasMenuItems objectForKey:identifier];
    if (!menuItem) return;

    for (GSMenuExtraInstance * provider in _menuExtras) {
        if ([[provider identifier] isEqualToString:identifier]) {
            @try {
                NSString *title = [provider title];
                if (title) [menuItem setTitle:title];

                if ([provider respondsToSelector:@selector(icon)]) {
                    [self showIconOfExtra:provider inItem:menuItem];
                    if (_extrasMenuView) {
                        /* Every extra ticks in the same timer pass, and each
                           queued redraw of the whole bar ran on its own. */
                        [NSObject cancelPreviousPerformRequestsWithTarget:_extrasMenuView
                                                                 selector:@selector(display)
                                                                   object:nil];
                        [_extrasMenuView performSelector:@selector(display)
                                             withObject:nil
                                             afterDelay:0];
                    }
                }
                /* The submenu is deliberately left alone here. An extra
                   reports a new value every second, and building its menu
                   again means a whole menu with two windows of its own for
                   something nobody is looking at. What is on screen is the
                   title and the icon above, and the submenu is built afresh
                   in menuNeedsUpdate: at the moment it is opened. */
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception refreshing %@: %@", identifier, e);
            }
            break;
        }
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (_needsUpdateGuard || [self isMenuOnScreen:menu]) return;
    _needsUpdateGuard = YES;

    NSString *identifier = objc_getAssociatedObject(menu, &kExtrasSubmenuIdentifierKey);
    GSMenuExtraInstance * provider = [self providerForIdentifier:identifier];
    if (!provider) { _needsUpdateGuard = NO; return; }

    @try {
        if ([provider respondsToSelector:@selector(menuWillOpen)]) {
            [provider menuWillOpen];
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *freshMenu = [provider menu];
            if (freshMenu && freshMenu != menu) {
                [self replaceMenu:menu withMenu:freshMenu];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"MenuExtraManager: exception in menuNeedsUpdate for %@: %@", identifier, exception);
    }

    _needsUpdateGuard = NO;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self menuNeedsUpdate:menu];
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSString *identifier = objc_getAssociatedObject(menu, &kExtrasSubmenuIdentifierKey);
    GSMenuExtraInstance * provider = [self providerForIdentifier:identifier];
    if ([provider respondsToSelector:@selector(menuDidClose)]) {
        [provider menuDidClose];
    }
}

#pragma mark - Preferences

- (void)savePreferences
{
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:[_menuExtras count]];
    for (GSMenuExtraInstance * item in _menuExtras) {
        [order addObject:[item identifier]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:GSMenuExtraOrderKey];

    NSMutableArray *enabled = [NSMutableArray arrayWithCapacity:[_menuExtras count]];
    for (GSMenuExtraInstance * item in _menuExtras) {
        [enabled addObject:[item identifier]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:enabled forKey:GSMenuExtraEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray<NSString *> *)loadOrderPreference
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:GSMenuExtraOrderKey];
    if ([saved isKindOfClass:[NSArray class]]) return saved;
    return @[];
}

- (NSSet *)loadEnabledPreference
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:GSMenuExtraEnabledKey];
    if (![saved isKindOfClass:[NSArray class]]) return nil;

    NSMutableSet *enabled = [NSMutableSet setWithArray:saved];
    /* An extra that asked to be there from the start (MediaExtra, which a
       media key acts on) is put into the saved set the first time it is
       seen, so that it appears in the menu bar without the user having to
       go looking for it.  It is added to the user's own set, not shown in
       spite of it: unticking it afterwards removes it for good, exactly as
       unticking any other extra does. */
    BOOL addedAny = NO;
    NSUInteger addedCount = 0;
    for (NSString *identifier in [self defaultsEnabledExtraIdentifiers]) {
        if (![enabled containsObject:identifier]) {
            [enabled addObject:identifier];
            addedCount++;
            addedAny = YES;
        }
    }
    if (addedAny) {
        [[NSUserDefaults standardUserDefaults] setObject:[enabled allObjects]
                                                  forKey:GSMenuExtraEnabledKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"GSMenuExtra: added %lu default-enabled extra(s) to the saved set (%lu enabled in all)",
              (unsigned long)addedCount, (unsigned long)[enabled count]);
    }
    return enabled;
}

/* The identifiers of the loaded extras that asked to be enabled by default.
   Read from the instances rather than from a list here, so that an extra
   which is not installed - MediaExtra without libdbus, say - is never put
   into a set it cannot be shown from. */
- (NSArray<NSString *> *)defaultsEnabledExtraIdentifiers
{
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (GSMenuExtraInstance *instance in [_instances allValues]) {
        @try {
            if ([instance enabledByDefault]) {
                [identifiers addObject:[instance identifier]];
            }
        } @catch (NSException *e) {
            NSLog(@"GSMenuExtra: exception in enabledByDefault for %@: %@", [instance identifier], e);
        }
    }
    return identifiers;
}

#pragma mark - Configuration panel

- (void)showPreferencesPanel
{
    if (!_prefPanel) {
        _prefPanel = [[MenuExtrasPrefPanel alloc] initWithManager:self];
    } else {
        [_prefPanel reloadExtras];
    }
    [_prefPanel showWindow:nil];
    [[_prefPanel window] makeKeyAndOrderFront:nil];
}

#pragma mark - File system monitoring

- (void)startFileSystemMonitoring
{
#if !defined(__linux__) && !defined(__FreeBSD__) && !defined(__OpenBSD__)
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int fd = open([[[[self class] searchPaths] firstObject] fileSystemRepresentation], O_EVTONLY);
    if (fd < 0) return;

    _fsMonitorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, queue);

    dispatch_source_set_event_handler(_fsMonitorSource, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self rescanBundles];
        });
    });

    dispatch_source_set_cancel_handler(_fsMonitorSource, ^{
        close(fd);
    });

    dispatch_resume(_fsMonitorSource);
#else
    /* Poll-based fallback: rescan every 10 seconds */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:10.0
                                         target:self
                                       selector:@selector(rescanBundles)
                                       userInfo:nil
                                        repeats:YES];
    });
#endif
}

- (void)rescanBundles
{
    [self rescanBundlesNow];
}

- (void)rescanBundlesNow
{
    NSMutableSet *currentPaths = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *searchPath in [[self class] searchPaths]) {
        if (![fm fileExistsAtPath:searchPath]) continue;
        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:searchPath error:&error];
        if (!contents) continue;

        for (NSString *item in contents) {
            NSString *fullPath = [searchPath stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;
            NSString *ext = [[fullPath pathExtension] lowercaseString];
            if (![ext isEqualToString:@"bundle"] && ![ext isEqualToString:@"gsmenuextra"]) continue;
            [currentPaths addObject:fullPath];
        }
    }

    NSMutableSet *added = [NSMutableSet setWithSet:currentPaths];
    [added minusSet:_knownBundlePaths];

    NSMutableSet *removed = [NSMutableSet setWithSet:_knownBundlePaths];
    [removed minusSet:currentPaths];

    for (NSString *path in removed) {
        NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
        GSMenuExtraInstance * toRemove = nil;
        for (GSMenuExtraInstance * p in _menuExtras) {
            if ([[p identifier] isEqualToString:name] || [[p identifier] isEqualToString:path]) {
                toRemove = p;
                break;
            }
        }
        if (toRemove) {
            if ([toRemove respondsToSelector:@selector(unload)]) [toRemove unload];
            [_menuExtras removeObject:toRemove];
            NSString *ident = [toRemove identifier];
            [_extrasMenuItems removeObjectForKey:ident];
            [_instances removeObjectForKey:ident];
            [GSMenuExtraInstanceDictionary removeObjectForKey:ident];
        }
        [_knownBundlePaths removeObject:path];
    }

    for (NSString *path in added) {
        NSURL *url = [NSURL fileURLWithPath:path];
        GSMenuExtraBundle *bundle = [[GSMenuExtraBundle alloc] initWithURL:url];

        NSString *ident = [bundle identifier];
        if (ident && ![_instances objectForKey:ident]) {
            GSMenuExtraInstance *instance = [self loadInstanceFromBundle:bundle];
            if (instance) {
                [_menuExtras addObject:instance];
                [_knownBundlePaths addObject:path];
                [_instances setObject:instance forKey:ident];
                [GSMenuExtraInstanceDictionary setObject:instance forKey:ident];

                [self rebuildExtrasMenu];
            }
        }
    }

    if ([added count] > 0 || [removed count] > 0) {
        [self savePreferences];
        if (_extrasMenuView) {
            CGFloat w = [self extrasMenuWidth];
            [_extrasMenuView setFrameSize:NSMakeSize(w, NSHeight([_extrasMenuView frame]))];
        }
    }
}

@end

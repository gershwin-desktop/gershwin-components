/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayConfiguration.h"
#import "DisplayLayout.h"
#import "DisplayArrangement.h"

#import <math.h>

NSString * const DisplayLayoutsDomain = @"io.github.gershwin-desktop.DisplayLayouts";

@interface DisplayOutput (Private)
- (void)setMode:(DisplayMode *)m;
@end

/* How a monitor is recognized across connectors; the same rule as
 * -[DisplayLayout configurationKey]. */
static NSString *identityOf(DisplayOutput *o)
{
    return [o edidIdentity] ? [o edidIdentity]
                            : [NSString stringWithFormat:@"connector:%@", [o name]];
}

@implementation DisplayLayoutStore

+ (instancetype)userStore
{
    return [[[self alloc] initWithDomainName:DisplayLayoutsDomain] autorelease];
}

- (instancetype)initWithDomainName:(NSString *)domainName
{
    self = [super init];
    if (self) {
        _domainName = [domainName copy];
    }
    return self;
}

- (void)dealloc
{
    [_domainName release];
    [super dealloc];
}

- (NSDictionary *)domain
{
    /* The pane and the tool write the same domain from two processes; read
     * what is on disk now, not what this process cached at start. */
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults synchronize];
    return [defaults persistentDomainForName:_domainName];
}

- (DisplayLayout *)layoutForKey:(NSString *)key
{
    id plist = [[self domain] objectForKey:key];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    return [DisplayLayout layoutWithPropertyList:plist];
}

- (BOOL)saveLayout:(DisplayLayout *)layout
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:[self domain]];
    [d setObject:[layout propertyList] forKey:[layout configurationKey]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:d forName:_domainName];
    return [defaults synchronize];
}

- (NSDictionary *)allLayouts
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *d = [self domain];
    for (NSString *key in d) {
        id plist = [d objectForKey:key];
        if ([plist isKindOfClass:[NSDictionary class]]) {
            [result setObject:[DisplayLayout layoutWithPropertyList:plist] forKey:key];
        }
    }
    return result;
}

@end

static void setProblem(NSString **problem, NSString *text)
{
    if (problem) *problem = text;
}

DisplayLayout *DisplayResolveSavedLayout(DisplayLayout *saved,
                                         DisplayLayout *current,
                                         NSString **problem)
{
    if (![[saved configurationKey] isEqualToString:[current configurationKey]]) {
        setProblem(problem, [NSString stringWithFormat:
            @"The saved layout is for other monitors (%@, connected: %@).",
            [saved configurationKey], [current configurationKey]]);
        return nil;
    }
    DisplayLayout *result = [[current copy] autorelease];
    NSMutableSet *used = [NSMutableSet set];
    for (DisplayOutput *o in [result outputs]) {
        /* Identical monitors share an EDID identity; the one on the same
         * connector is the better match. */
        DisplayOutput *match = nil;
        for (DisplayOutput *s in [saved outputs]) {
            if ([used containsObject:s] || ![identityOf(s) isEqualToString:identityOf(o)]) continue;
            if (match == nil || [[s name] isEqualToString:[o name]]) match = s;
        }
        if (match == nil) {
            setProblem(problem, [NSString stringWithFormat:
                @"Display %@ is not in the saved layout.", [o name]]);
            return nil;
        }
        [used addObject:match];
        [o setEnabled:[match enabled]];
        [o setPrimary:[match enabled] && [match primary]];
        [o setX:[match x]];
        [o setY:[match y]];
        [o setTransformScaleX:[match transformScaleX]];
        [o setTransformScaleY:[match transformScaleY]];
        [o setRotation:[match rotation]];
        if (![match enabled]) continue;
        DisplayMode *m = DisplaySelectMode([o modes], [match modeWidth], [match modeHeight],
                                           [match modeRefresh]);
        if (m == nil) {
            setProblem(problem, [NSString stringWithFormat:
                @"Display %@ no longer offers the saved mode %dx%d.",
                [o name], [match modeWidth], [match modeHeight]]);
            return nil;
        }
        [o setMode:m];
    }
    if ([[result enabledOutputs] count] == 0) {
        setProblem(problem, @"The saved layout has no display switched on.");
        return nil;
    }
    [result ensurePrimary];
    [result setScaleFactor:[saved scaleFactor]];
    return result;
}

static BOOL enabledOutputsOverlap(DisplayLayout *l)
{
    NSArray *enabled = [l enabledOutputs];
    for (NSUInteger i = 0; i < [enabled count]; i++) {
        for (NSUInteger j = i + 1; j < [enabled count]; j++) {
            if (NSIntersectsRect([[enabled objectAtIndex:i] frame],
                                 [[enabled objectAtIndex:j] frame])) {
                return YES;
            }
        }
    }
    return NO;
}

DisplayLayout *DisplayDefaultLayout(DisplayLayout *current)
{
    DisplayLayout *l = [[current copy] autorelease];
    if ([[l outputs] count] == 0) return l;

    if (enabledOutputsOverlap(l) && ![l isMirrored]) {
        [l ensurePrimary];
        for (DisplayOutput *o in [l outputs]) {
            if ([o preferredMode]) [o setMode:[o preferredMode]];
        }
        DisplayLayout *spread = [l extendedLayout];
        return spread ? spread : l;
    }

    for (DisplayOutput *o in [l outputs]) {
        if ([o enabled] || [o preferredMode] == nil) continue;
        NSRect bounds = [l boundingRect];
        [o setMode:[o preferredMode]];
        [o setTransformScaleX:1.0];
        [o setTransformScaleY:1.0];
        [o setX:[[l enabledOutputs] count] ? (int)NSMaxX(bounds) : 0];
        [o setY:[[l enabledOutputs] count] ? (int)NSMinY(bounds) : 0];
        [o setEnabled:YES];
    }
    /* X has no negative coordinates and an empty strip at the top or left
     * would still be screen: what is left after a monitor went away starts
     * at 0,0 again. */
    NSRect bounds = [l boundingRect];
    for (DisplayOutput *o in [l enabledOutputs]) {
        [o setX:[o x] - (int)NSMinX(bounds)];
        [o setY:[o y] - (int)NSMinY(bounds)];
    }
    [l ensurePrimary];
    return l;
}

static BOOL sameScale(double a, double b)
{
    return fabs(a - b) < 1e-4;
}

BOOL DisplayLayoutsDiffer(DisplayLayout *wanted, DisplayLayout *current)
{
    NSMutableSet *names = [NSMutableSet setWithArray:[wanted outputNames]];
    [names addObjectsFromArray:[current outputNames]];
    for (NSString *name in names) {
        DisplayOutput *w = [wanted outputNamed:name];
        DisplayOutput *c = [current outputNamed:name];
        BOOL wOn = w && [w enabled], cOn = c && [c enabled];
        if (wOn != cOn) return YES;
        if (!wOn) continue;
        if ([w modeWidth] != [c modeWidth] || [w modeHeight] != [c modeHeight]) return YES;
        /* 0 means "any refresh" to the mode selection. */
        if ([w modeRefresh] > 0 && [c modeRefresh] > 0
            && fabs([w modeRefresh] - [c modeRefresh]) > 0.5) return YES;
        if ([w x] != [c x] || [w y] != [c y]) return YES;
        if (!sameScale([w transformScaleX], [c transformScaleX])
            || !sameScale([w transformScaleY], [c transformScaleY])) return YES;
        if ([w rotation] != [c rotation]) return YES;
        if ([w primary] != [c primary]) return YES;
    }
    return NO;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayLayout.h"
#import "DisplayArrangement.h"

#import <math.h>

@implementation DisplayMode

@synthesize modeID = _modeID, width = _width, height = _height,
    refresh = _refresh, interlaced = _interlaced, preferred = _preferred;

+ (instancetype)modeWithID:(unsigned long)modeID
                     width:(int)width
                    height:(int)height
                   refresh:(double)refresh
                interlaced:(BOOL)interlaced
                 preferred:(BOOL)preferred
{
    DisplayMode *m = [[[self alloc] init] autorelease];
    m->_modeID = modeID;
    m->_width = width;
    m->_height = height;
    m->_refresh = refresh;
    m->_interlaced = interlaced;
    m->_preferred = preferred;
    return m;
}

- (id)copyWithZone:(NSZone *)zone
{
    /* Immutable. */
    return [self retain];
}

- (NSString *)sizeString
{
    return [NSString stringWithFormat:@"%dx%d", _width, _height];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%dx%d@%.2f%s%s (0x%lx)", _width, _height,
            _refresh, _interlaced ? "i" : "", _preferred ? " preferred" : "", _modeID];
}

@end

static BOOL scaleIsIdentity(double s)
{
    return fabs(s - 1.0) < 1e-9;
}

@implementation DisplayOutput

@synthesize name = _name, edidIdentity = _edidIdentity, monitorName = _monitorName,
    connected = _connected, enabled = _enabled, modes = _modes,
    modeWidth = _modeWidth, modeHeight = _modeHeight, modeRefresh = _modeRefresh,
    x = _x, y = _y, transformScaleX = _transformScaleX,
    transformScaleY = _transformScaleY, rotation = _rotation, primary = _primary,
    possibleCrtcs = _possibleCrtcs, crtc = _crtc, widthMM = _widthMM,
    heightMM = _heightMM;

- (id)init
{
    self = [super init];
    if (self) {
        _transformScaleX = 1.0;
        _transformScaleY = 1.0;
        _rotation = 1;
        _modes = [[NSArray alloc] init];
        _possibleCrtcs = [[NSArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_name release];
    [_edidIdentity release];
    [_monitorName release];
    [_modes release];
    [_possibleCrtcs release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    DisplayOutput *o = [[DisplayOutput allocWithZone:zone] init];
    [o setName:_name];
    [o setEdidIdentity:_edidIdentity];
    [o setMonitorName:_monitorName];
    [o setConnected:_connected];
    [o setEnabled:_enabled];
    [o setModes:_modes];
    [o setModeWidth:_modeWidth];
    [o setModeHeight:_modeHeight];
    [o setModeRefresh:_modeRefresh];
    [o setX:_x];
    [o setY:_y];
    [o setTransformScaleX:_transformScaleX];
    [o setTransformScaleY:_transformScaleY];
    [o setRotation:_rotation];
    [o setPrimary:_primary];
    [o setPossibleCrtcs:_possibleCrtcs];
    [o setCrtc:_crtc];
    [o setWidthMM:_widthMM];
    [o setHeightMM:_heightMM];
    return o;
}

- (DisplayMode *)currentMode
{
    return DisplaySelectMode(_modes, _modeWidth, _modeHeight, _modeRefresh);
}

- (DisplayMode *)preferredMode
{
    for (DisplayMode *m in _modes) {
        if ([m preferred]) return m;
    }
    return [_modes count] > 0 ? [_modes objectAtIndex:0] : nil;
}

- (NSArray *)resolutionStrings
{
    NSMutableArray *result = [NSMutableArray array];
    for (DisplayMode *m in _modes) {
        if (![result containsObject:[m sizeString]]) [result addObject:[m sizeString]];
    }
    return result;
}

- (NSSize)size
{
    /* A quarter turn swaps the mode's width and height on the screen. */
    BOOL quarter = (_rotation & (2 | 8)) != 0;
    int w = quarter ? _modeHeight : _modeWidth;
    int h = quarter ? _modeWidth : _modeHeight;
    return NSMakeSize(DisplayTransformedExtent(w, _transformScaleX),
                      DisplayTransformedExtent(h, _transformScaleY));
}

- (NSRect)frame
{
    NSSize s = [self size];
    return NSMakeRect(_x, _y, s.width, s.height);
}

- (BOOL)hasTransform
{
    return !scaleIsIdentity(_transformScaleX) || !scaleIsIdentity(_transformScaleY);
}

- (void)setMode:(DisplayMode *)m
{
    _modeWidth = [m width];
    _modeHeight = [m height];
    _modeRefresh = [m refresh];
}

- (void)clearTransform
{
    _transformScaleX = 1.0;
    _transformScaleY = 1.0;
}

- (NSDictionary *)propertyList
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:_name forKey:@"name"];
    if (_edidIdentity) [d setObject:_edidIdentity forKey:@"edid"];
    if (_monitorName) [d setObject:_monitorName forKey:@"monitorName"];
    [d setObject:[NSNumber numberWithBool:_enabled] forKey:@"enabled"];
    [d setObject:[NSNumber numberWithBool:_primary] forKey:@"primary"];
    [d setObject:[NSNumber numberWithInt:_modeWidth] forKey:@"width"];
    [d setObject:[NSNumber numberWithInt:_modeHeight] forKey:@"height"];
    [d setObject:[NSNumber numberWithDouble:_modeRefresh] forKey:@"refresh"];
    [d setObject:[NSNumber numberWithInt:_x] forKey:@"x"];
    [d setObject:[NSNumber numberWithInt:_y] forKey:@"y"];
    [d setObject:[NSNumber numberWithDouble:_transformScaleX] forKey:@"transformScaleX"];
    [d setObject:[NSNumber numberWithDouble:_transformScaleY] forKey:@"transformScaleY"];
    [d setObject:[NSNumber numberWithInt:_rotation] forKey:@"rotation"];
    [d setObject:[NSNumber numberWithInt:_widthMM] forKey:@"widthMM"];
    [d setObject:[NSNumber numberWithInt:_heightMM] forKey:@"heightMM"];
    return d;
}

+ (DisplayOutput *)outputWithPropertyList:(NSDictionary *)d
{
    DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
    [o setName:[d objectForKey:@"name"]];
    [o setEdidIdentity:[d objectForKey:@"edid"]];
    [o setMonitorName:[d objectForKey:@"monitorName"]];
    [o setConnected:YES];
    [o setEnabled:[[d objectForKey:@"enabled"] boolValue]];
    [o setPrimary:[[d objectForKey:@"primary"] boolValue]];
    [o setModeWidth:[[d objectForKey:@"width"] intValue]];
    [o setModeHeight:[[d objectForKey:@"height"] intValue]];
    [o setModeRefresh:[[d objectForKey:@"refresh"] doubleValue]];
    [o setX:[[d objectForKey:@"x"] intValue]];
    [o setY:[[d objectForKey:@"y"] intValue]];
    [o setTransformScaleX:[[d objectForKey:@"transformScaleX"] doubleValue]];
    [o setTransformScaleY:[[d objectForKey:@"transformScaleY"] doubleValue]];
    [o setRotation:[d objectForKey:@"rotation"] ? [[d objectForKey:@"rotation"] intValue] : 1];
    [o setWidthMM:[[d objectForKey:@"widthMM"] intValue]];
    [o setHeightMM:[[d objectForKey:@"heightMM"] intValue]];
    return o;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %s %dx%d@%.2f +%d+%d%s%s>", _name,
            _enabled ? "on" : "off", _modeWidth, _modeHeight, _modeRefresh, _x, _y,
            _primary ? " primary" : "", [self hasTransform] ? " transformed" : ""];
}

@end

@interface DisplayOutput (Private)
- (void)setMode:(DisplayMode *)m;
- (void)clearTransform;
- (NSDictionary *)propertyList;
+ (DisplayOutput *)outputWithPropertyList:(NSDictionary *)d;
@end

@implementation DisplayLayout

@synthesize outputs = _outputs, scaleFactor = _scaleFactor;

+ (instancetype)layoutWithOutputs:(NSArray *)outputs
{
    DisplayLayout *l = [[[self alloc] init] autorelease];
    [l setOutputs:outputs];
    return l;
}

- (id)init
{
    self = [super init];
    if (self) {
        _outputs = [[NSArray alloc] init];
        _scaleFactor = 1.0;
    }
    return self;
}

- (void)dealloc
{
    [_outputs release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    DisplayLayout *l = [[DisplayLayout allocWithZone:zone] init];
    NSMutableArray *outs = [NSMutableArray array];
    for (DisplayOutput *o in _outputs) {
        DisplayOutput *c = [o copy];
        [outs addObject:c];
        [c release];
    }
    [l setOutputs:outs];
    [l setScaleFactor:_scaleFactor];
    return l;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[DisplayLayout class]]) return NO;
    return [[self propertyList] isEqual:[other propertyList]];
}

- (NSUInteger)hash
{
    return [[self configurationKey] hash];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<DisplayLayout %@%s>", _outputs,
            [self isMirrored] ? " mirrored" : ""];
}

- (DisplayOutput *)outputNamed:(NSString *)name
{
    for (DisplayOutput *o in _outputs) {
        if ([[o name] isEqualToString:name]) return o;
    }
    return nil;
}

- (DisplayOutput *)primaryOutput
{
    for (DisplayOutput *o in _outputs) {
        if ([o enabled] && [o primary]) return o;
    }
    return nil;
}

- (NSArray *)enabledOutputs
{
    NSMutableArray *result = [NSMutableArray array];
    for (DisplayOutput *o in _outputs) {
        if ([o enabled]) [result addObject:o];
    }
    return result;
}

- (NSArray *)outputNames
{
    NSMutableArray *result = [NSMutableArray array];
    for (DisplayOutput *o in _outputs) [result addObject:[o name]];
    return result;
}

- (BOOL)isMirrored
{
    NSArray *enabled = [self enabledOutputs];
    if ([enabled count] < 2) return NO;
    NSRect first = [[enabled objectAtIndex:0] frame];
    for (DisplayOutput *o in enabled) {
        if (!NSEqualRects([o frame], first)) return NO;
    }
    return YES;
}

- (NSRect)boundingRect
{
    NSRect r = NSZeroRect;
    BOOL any = NO;
    for (DisplayOutput *o in [self enabledOutputs]) {
        r = any ? NSUnionRect(r, [o frame]) : [o frame];
        any = YES;
    }
    return r;
}

#pragma mark - Operations

/* Gives a primary to a layout that lost it: the top-left enabled output. */
- (void)ensurePrimary
{
    if ([self primaryOutput]) return;
    DisplayOutput *best = nil;
    for (DisplayOutput *o in [self enabledOutputs]) {
        if (best == nil || [o y] < [best y] || ([o y] == [best y] && [o x] < [best x])) {
            best = o;
        }
    }
    for (DisplayOutput *o in _outputs) [o setPrimary:(o == best)];
}

/* Resolves overlaps and gaps among the enabled outputs; `moved` is placed
 * last at `origin`. */
- (void)arrangeMoving:(NSString *)moved toOrigin:(NSPoint)origin snap:(CGFloat)snap
{
    NSMutableDictionary *proposed = [NSMutableDictionary dictionary];
    for (DisplayOutput *o in [self enabledOutputs]) {
        NSRect f = [o frame];
        if (moved && [[o name] isEqualToString:moved]) f.origin = origin;
        [proposed setObject:[NSValue valueWithRect:f] forKey:[o name]];
    }
    NSDictionary *placed = DisplayArrangeRects(proposed, [[self primaryOutput] name],
                                               moved, snap);
    for (NSString *name in placed) {
        NSRect f = [[placed objectForKey:name] rectValue];
        DisplayOutput *o = [self outputNamed:name];
        [o setX:(int)NSMinX(f)];
        [o setY:(int)NSMinY(f)];
    }
}

- (DisplayLayout *)layoutBySettingResolution:(NSString *)resolution
                                   forOutput:(NSString *)name
{
    NSArray *parts = [resolution componentsSeparatedByString:@"x"];
    if ([parts count] != 2) return nil;
    int w = [[parts objectAtIndex:0] intValue];
    int h = [[parts objectAtIndex:1] intValue];

    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *o = [l outputNamed:name];
    if (o == nil) return nil;
    DisplayMode *m = DisplaySelectMode([o modes], w, h, [o enabled] ? [o modeRefresh] : 0);
    if (m == nil) return nil;

    /* In a mirror every output keeps the shared origin; elsewhere the
     * arrangement is repaired around the new size. */
    BOOL mirrored = [l isMirrored];
    if (![o enabled]) {
        NSRect bounds = [l boundingRect];
        [o setX:(int)NSMaxX(bounds)];
        [o setY:(int)NSMinY(bounds)];
        [o setEnabled:YES];
    }
    [o setMode:m];
    [o clearTransform];
    [l ensurePrimary];
    if (!mirrored) [l arrangeMoving:nil toOrigin:NSZeroPoint snap:0];
    return l;
}

- (DisplayLayout *)layoutByDisablingOutput:(NSString *)name
{
    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *o = [l outputNamed:name];
    if (o == nil) return nil;
    if (![o enabled]) return l;
    if ([[l enabledOutputs] count] < 2) return nil;
    BOOL mirrored = [l isMirrored];
    [o setEnabled:NO];
    [o setPrimary:NO];
    [o clearTransform];
    [l ensurePrimary];
    if (!mirrored) [l arrangeMoving:nil toOrigin:NSZeroPoint snap:0];
    return l;
}

- (DisplayLayout *)layoutByMovingOutput:(NSString *)name
                               toOrigin:(NSPoint)proposed
                           snapDistance:(CGFloat)snap
{
    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *o = [l outputNamed:name];
    if (o == nil || ![o enabled]) return nil;
    [l arrangeMoving:name toOrigin:proposed snap:snap];
    return l;
}

- (DisplayLayout *)layoutBySettingPrimary:(NSString *)name
{
    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *target = [l outputNamed:name];
    if (target == nil || ![target enabled]) return nil;
    for (DisplayOutput *o in [l outputs]) [o setPrimary:(o == target)];
    return l;
}

- (DisplayLayout *)mirroredLayout
{
    if ([_outputs count] < 2) return nil;
    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *primary = [l primaryOutput];
    if (primary == nil) primary = [[l outputs] objectAtIndex:0];

    NSMutableArray *lists = [NSMutableArray array];
    for (DisplayOutput *o in [l outputs]) [lists addObject:[o modes]];
    NSString *common = DisplayCommonResolution(lists);

    if (common) {
        NSArray *parts = [common componentsSeparatedByString:@"x"];
        int w = [[parts objectAtIndex:0] intValue];
        int h = [[parts objectAtIndex:1] intValue];
        for (DisplayOutput *o in [l outputs]) {
            [o setMode:DisplaySelectMode([o modes], w, h, [o modeRefresh])];
            [o clearTransform];
        }
    } else {
        /* No size all outputs can show: the others are scaled to the
         * primary's picture so every output shows all of it. */
        DisplayMode *pm = [primary enabled] ? [primary currentMode] : [primary preferredMode];
        if (pm == nil) return nil;
        [primary setMode:pm];
        [primary clearTransform];
        for (DisplayOutput *o in [l outputs]) {
            if (o == primary) continue;
            DisplayMode *m = [o preferredMode];
            if (m == nil) return nil;
            [o setMode:m];
            [o setTransformScaleX:(double)[pm width] / [m width]];
            [o setTransformScaleY:(double)[pm height] / [m height]];
        }
    }
    for (DisplayOutput *o in [l outputs]) {
        [o setEnabled:YES];
        [o setX:0];
        [o setY:0];
        [o setPrimary:(o == primary)];
    }
    return l;
}

- (DisplayLayout *)extendedLayout
{
    DisplayLayout *l = [[self copy] autorelease];
    DisplayOutput *primary = [l primaryOutput];
    if (primary == nil) primary = [[l outputs] objectAtIndex:0];
    NSArray *others = [[l outputs] sortedArrayUsingComparator:
        ^NSComparisonResult(DisplayOutput *a, DisplayOutput *b) {
            if ([a x] != [b x]) return [a x] < [b x] ? NSOrderedAscending : NSOrderedDescending;
            return [[a name] compare:[b name]];
        }];
    NSMutableArray *order = [NSMutableArray arrayWithObject:primary];
    for (DisplayOutput *o in others) {
        if (o != primary) [order addObject:o];
    }
    int x = 0;
    for (DisplayOutput *o in order) {
        DisplayMode *m = [o preferredMode];
        if (m == nil) return nil;
        [o setMode:m];
        [o clearTransform];
        [o setEnabled:YES];
        [o setPrimary:(o == primary)];
        [o setX:x];
        [o setY:0];
        x += (int)[o size].width;
    }
    return l;
}

#pragma mark - Stored form

- (NSDictionary *)propertyList
{
    NSMutableArray *outs = [NSMutableArray array];
    for (DisplayOutput *o in _outputs) [outs addObject:[o propertyList]];
    return [NSDictionary dictionaryWithObjectsAndKeys:
        outs, @"outputs",
        [NSNumber numberWithBool:[self isMirrored]], @"mirrored",
        [NSNumber numberWithDouble:_scaleFactor], @"scaleFactor", nil];
}

+ (instancetype)layoutWithPropertyList:(NSDictionary *)plist
{
    NSMutableArray *outs = [NSMutableArray array];
    for (NSDictionary *d in [plist objectForKey:@"outputs"]) {
        [outs addObject:[DisplayOutput outputWithPropertyList:d]];
    }
    DisplayLayout *l = [self layoutWithOutputs:outs];
    [l setScaleFactor:[[plist objectForKey:@"scaleFactor"] doubleValue]];
    return l;
}

- (NSString *)configurationKey
{
    NSMutableArray *ids = [NSMutableArray array];
    for (DisplayOutput *o in _outputs) {
        /* Outputs without EDID (projectors, virtual outputs) can only be
         * told apart by their connector. */
        [ids addObject:[o edidIdentity]
            ? [o edidIdentity]
            : [NSString stringWithFormat:@"connector:%@", [o name]]];
    }
    return [[ids sortedArrayUsingSelector:@selector(compare:)]
               componentsJoinedByString:@","];
}

@end

#pragma mark - EDID

static BOOL isEDIDBlock(NSData *edid)
{
    static const unsigned char header[8] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};
    return [edid length] >= 128 && memcmp([edid bytes], header, 8) == 0;
}

NSString *DisplayEDIDIdentity(NSData *edid)
{
    if (!isEDIDBlock(edid)) return nil;
    const unsigned char *e = [edid bytes];
    unsigned vendor = (e[8] << 8) | e[9];
    char v[4] = {
        (char)('A' - 1 + ((vendor >> 10) & 0x1F)),
        (char)('A' - 1 + ((vendor >> 5) & 0x1F)),
        (char)('A' - 1 + (vendor & 0x1F)), 0 };
    unsigned product = e[10] | (e[11] << 8);
    unsigned long serial = (unsigned long)e[12] | ((unsigned long)e[13] << 8)
        | ((unsigned long)e[14] << 16) | ((unsigned long)e[15] << 24);
    return [NSString stringWithFormat:@"%s-%04X-%08lX", v, product, serial];
}

NSString *DisplayEDIDMonitorName(NSData *edid)
{
    if (!isEDIDBlock(edid)) return nil;
    const unsigned char *e = [edid bytes];
    for (int d = 54; d <= 108; d += 18) {
        if (e[d] == 0 && e[d + 1] == 0 && e[d + 2] == 0 && e[d + 3] == 0xFC) {
            char text[14];
            int n = 0;
            for (int i = 5; i < 18 && e[d + i] != 0x0A; i++) text[n++] = (char)e[d + i];
            text[n] = 0;
            NSString *s = [NSString stringWithCString:text encoding:NSISOLatin1StringEncoding];
            return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

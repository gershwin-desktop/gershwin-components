/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The display layout model: which outputs are connected, which mode each
 * one runs, where it sits on the X screen, which one is primary and whether
 * they mirror each other.  Foundation only, so the decisions can be tested
 * headless and a later per-user display configuration can store and apply
 * the same model without the pane. */

#import <Foundation/Foundation.h>

@interface DisplayMode : NSObject <NSCopying>
{
    unsigned long _modeID;
    int _width;
    int _height;
    double _refresh;
    BOOL _interlaced;
    BOOL _preferred;
}

+ (instancetype)modeWithID:(unsigned long)modeID
                     width:(int)width
                    height:(int)height
                   refresh:(double)refresh
                interlaced:(BOOL)interlaced
                 preferred:(BOOL)preferred;

/* RRMode on the X server the layout was read from; 0 when not known. */
@property (readonly) unsigned long modeID;
@property (readonly) int width;
@property (readonly) int height;
@property (readonly) double refresh;
@property (readonly) BOOL interlaced;
/* The monitor names this mode as its native one (EDID preferred timing). */
@property (readonly) BOOL preferred;

/* "1920x1080", the form the pane offers in its resolution pop-up. */
- (NSString *)sizeString;

@end

@interface DisplayOutput : NSObject <NSCopying>
{
    NSString *_name;
    NSString *_edidIdentity;
    NSString *_monitorName;
    BOOL _connected;
    BOOL _enabled;
    NSArray *_modes;
    int _modeWidth;
    int _modeHeight;
    double _modeRefresh;
    int _x;
    int _y;
    double _transformScaleX;
    double _transformScaleY;
    int _rotation;
    BOOL _primary;
    NSArray *_possibleCrtcs;
    unsigned long _crtc;
    int _widthMM;
    int _heightMM;
    double _scale;
}

/* Connector name as RandR reports it, e.g. "eDP-1", "HDMI-1". */
@property (copy) NSString *name;
/* "VVV-PPPP-SSSSSSSS" from the EDID (vendor, product, serial); nil when the
 * output has no EDID.  Connector names change between ports and docks, the
 * EDID identity does not, so stored layouts are keyed by it. */
@property (copy) NSString *edidIdentity;
@property (copy) NSString *monitorName;
@property BOOL connected;
@property BOOL enabled;
/* DisplayMode objects, in the order the output lists them. */
@property (copy) NSArray *modes;
/* The mode the output runs (or should run): size plus refresh. */
@property int modeWidth;
@property int modeHeight;
@property double modeRefresh;
/* Top-left corner on the X screen, in screen pixels (y grows downwards). */
@property int x;
@property int y;
/* RandR transform: how many screen pixels one mode pixel covers.  1.0 is no
 * transform; a mirrored output whose mode differs from the primary's gets
 * the factor that makes it show the whole picture. */
@property double transformScaleX;
@property double transformScaleY;
/* RandR rotation bits (1 = normal, 2 = 90, 4 = 180, 8 = 270 degrees); kept
 * so applying a layout does not undo a rotation set elsewhere. */
@property int rotation;
@property BOOL primary;
/* X server details, only meaningful for a layout read from the server. */
@property (copy) NSArray *possibleCrtcs;
@property unsigned long crtc;
@property int widthMM;
@property int heightMM;
/* The monitor's own user interface scale, published to clients as the
 * RandR output property "DPI" (96 per 1.0); 0 when it has none and follows
 * the layout's scaleFactor.  Read from the server it is the DPI the
 * toolkit sees (see -[DisplayLayout completeServerScales]). */
@property double scale;

/* The mode from -modes that the wanted size and refresh resolve to. */
- (DisplayMode *)currentMode;
- (DisplayMode *)preferredMode;
/* Distinct "WxH" strings in the output's own order. */
- (NSArray *)resolutionStrings;
/* Area the output covers on the X screen (mode size times transform). */
- (NSSize)size;
- (NSRect)frame;
- (BOOL)hasTransform;
/* The mode size as it lies on the screen: a quarter turn swaps width and
 * height.  What "looks like" sizes are computed from. */
- (NSSize)rotatedModeSize;
/* What the X screen must cover for this output: its frame, but at least
 * the untransformed mode at its origin, because RRSetScreenSize checks the
 * screen against the mode size, not the transformed one.  A "looks like"
 * size larger than the panel's default (transform below 1) therefore
 * keeps a screen as large as the mode. */
- (NSRect)screenExtent;

@end

@interface DisplayLayout : NSObject <NSCopying>
{
    NSArray *_outputs;
    double _scaleFactor;
}

+ (instancetype)layoutWithOutputs:(NSArray *)outputs;

/* All connected outputs, enabled or not. */
@property (copy) NSArray *outputs;
/* The global user interface scale (GSScaleFactor).  The toolkit uses it
 * on every monitor unless the lit outputs' scales differ. */
@property double scaleFactor;

- (DisplayOutput *)outputNamed:(NSString *)name;
- (DisplayOutput *)primaryOutput;
- (NSArray *)enabledOutputs;
- (NSArray *)outputNames;
/* Two or more enabled outputs covering exactly the same screen area. */
- (BOOL)isMirrored;
/* Union of the frames of all enabled outputs. */
- (NSRect)boundingRect;

/* Makes sure exactly one enabled output is primary, by
 * DisplayFallbackPrimary(). */
- (void)ensurePrimary;

/* Each operation returns a new layout and leaves the receiver alone, so the
 * pane can keep the previous layout for reverting.  They return nil when the
 * request cannot be satisfied (unknown output, mode the output lacks,
 * disabling the last output). */
- (DisplayLayout *)layoutBySettingResolution:(NSString *)resolution
                                   forOutput:(NSString *)name;
- (DisplayLayout *)layoutByDisablingOutput:(NSString *)name;
- (DisplayLayout *)layoutByMovingOutput:(NSString *)name
                               toOrigin:(NSPoint)proposed
                           snapDistance:(CGFloat)snap;
- (DisplayLayout *)layoutBySettingPrimary:(NSString *)name;
/* `name` with the CRTC transform of a "looks like" size
 * (DisplayScaledResolution); the neighbors move so the arrangement stays
 * connected and free of overlaps around the new size.  nil for a mirror,
 * whose transforms make the outputs show the same picture, and for an
 * output that is off. */
- (DisplayLayout *)layoutBySettingTransformScaleX:(double)scaleX
                                                y:(double)scaleY
                                        forOutput:(NSString *)name;
- (DisplayLayout *)mirroredLayout;
- (DisplayLayout *)extendedLayout;

/* Per-monitor scale.  The toolkit uses a monitor's own factor only when the
 * lit monitors' factors differ ("mixed"); otherwise GSScaleFactor applies
 * everywhere.  These follow the same rule, so the pane shows what
 * applications really do. */
/* Some lit output has its own scale. */
- (BOOL)hasOutputScales;
/* At least two lit outputs whose scales (own, else scaleFactor) differ. */
- (BOOL)hasMixedScales;
/* The scale `name` is drawn at: its own when mixed, else scaleFactor. */
- (double)effectiveScaleForOutputNamed:(NSString *)name;
/* The GSScaleFactor that belongs to this layout: the common scale when all
 * lit outputs agree, else the primary's, because fonts, the window manager
 * and applications with a single factor fall back to it, and the menu bar
 * lives on the primary. */
- (double)preferredScaleFactor;
/* The GSScaleFactor to write in place of `current` after this layout was
 * applied for another reason than a scale change (a new primary): the
 * primary's scale while the scales are mixed, as -preferredScaleFactor
 * says; 0 when `current` stays.  With equal scales GSScaleFactor is the
 * factor applications start with and only a scale change sets it. */
- (double)scaleFactorToStoreReplacing:(double)current;
/* The "DPI" value for every lit output, keyed by output name. */
- (NSDictionary *)DPIByOutputName;
/* For a layout read from the server: when some lit output has a DPI, the
 * lit ones without count as 1.0, as for the toolkit; with no DPI anywhere
 * every output keeps following scaleFactor. */
- (void)completeServerScales;
/* `name` drawn at `scale` (snapped to an offered step).  Every other lit
 * output keeps the scale it is drawn at now, made its own, so the change
 * touches only `name`.  A "looks like" transform of `name` is reset, as it
 * would scale the monitor a second time; a mirror shows one picture, so
 * all its outputs get the scale.  nil for an unknown output or one that
 * is off. */
- (DisplayLayout *)layoutBySettingScale:(double)scale forOutput:(NSString *)name;

/* Plist form for storing a layout; X server details (CRTCs, mode ids) are
 * left out because they are only valid for one server generation. */
- (NSDictionary *)propertyList;
+ (instancetype)layoutWithPropertyList:(NSDictionary *)plist;
/* Identifies the set of connected monitors (sorted EDID identities, the
 * connector name for outputs without EDID), so a stored layout can be found
 * again when the same monitors are connected. */
- (NSString *)configurationKey;

@end

/* The output desktop components treat as the main one, the same rule as
 * Menu's PrimaryMonitor: the RandR primary if it is lit, else the output
 * containing screen point 0,0, else the first lit one; nil when none is
 * lit. */
DisplayOutput *DisplayFallbackPrimary(NSArray *enabledOutputs);

/* RandR "DPI" of a scale, snapped to an offered step: 96 per 1.0. */
long DisplayDPIForScale(double scale);
/* The offered step nearest to a "DPI" value; 0 for none (dpi <= 0). */
double DisplayScaleForDPI(long dpi);
/* Whether an output's "DPI" must be written: `current` is the server's
 * value (-1 when the output has none).  An equal value is left alone, so
 * clients get no needless change events, and a server without DPI stays
 * without as long as the layout has no own scales. */
BOOL DisplayShouldWriteDPI(long current, long wanted, BOOL layoutHasOutputScales);

/* "VVV-PPPP-SSSSSSSS" from a 128-byte EDID block; nil if it is not one. */
NSString *DisplayEDIDIdentity(NSData *edid);
/* The monitor name descriptor (0xFC) of an EDID block, or nil. */
NSString *DisplayEDIDMonitorName(NSData *edid);

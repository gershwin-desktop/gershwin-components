/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_DisplayLayout - the display layout model: resolution changes, enabling
 * a newly connected output, primary, arrangement, mirror and unmirror, the
 * stored form and EDID identities.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayLayout.h"

static NSString * const kInternal = @"internal-panel";

static DisplayMode *M(unsigned long ident, int w, int h, double r, BOOL pref)
{
    return [DisplayMode modeWithID:ident width:w height:h refresh:r
                        interlaced:NO preferred:pref];
}

static DisplayOutput *O(NSString *name, NSArray *modes, BOOL enabled,
                        int w, int h, double r, int x, int y, BOOL primary)
{
    DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
    [o setName:name];
    [o setConnected:YES];
    [o setEnabled:enabled];
    [o setModes:modes];
    [o setModeWidth:w];
    [o setModeHeight:h];
    [o setModeRefresh:r];
    [o setX:x];
    [o setY:y];
    [o setPrimary:primary];
    return o;
}

static NSArray *standardModes(void)
{
    return [NSArray arrayWithObjects:M(1, 2560, 1440, 60, NO),
            M(2, 1920, 1080, 60, YES), M(3, 1920, 1080, 75, NO),
            M(4, 1280, 1024, 60, NO), M(5, 1280, 1024, 75, NO), nil];
}

static NSData *edidBlock(void)
{
    unsigned char e[128];
    memset(e, 0, sizeof(e));
    const unsigned char header[8] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};
    memcpy(e, header, 8);
    e[8] = 0x10; e[9] = 0xAC;              /* "DEL" */
    e[10] = 0xB1; e[11] = 0xA0;            /* product 0xA0B1, little endian */
    e[12] = 0x78; e[13] = 0x56; e[14] = 0x34; e[15] = 0x12;
    const char *name = "DELL U2720Q\n  ";
    e[54 + 3] = 0xFC;
    memcpy(e + 54 + 5, name, 13);
    return [NSData dataWithBytes:e length:sizeof(e)];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSArray *modes = standardModes();

    DisplayLayout *two = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
        O(kInternal, modes, YES, 1920, 1080, 60, 0, 0, YES),
        O(@"HDMI-1", modes, YES, 1920, 1080, 60, 1920, 0, NO), nil]];

    START_SET("resolution changes")
    {
        DisplayLayout *l = [two layoutBySettingResolution:@"2560x1440" forOutput:kInternal];
        DisplayOutput *a = [l outputNamed:kInternal];
        PASS([a modeWidth] == 2560 && [a modeHeight] == 1440,
             "the internal output gets the larger mode");
        PASS([[l outputNamed:@"HDMI-1"] x] == 2560,
             "the neighbor moves so the larger output does not overlap it");
        PASS([two outputNamed:kInternal].modeWidth == 1920,
             "the original layout is left alone (needed for reverting)");
        PASS([two layoutBySettingResolution:@"800x600" forOutput:kInternal] == nil,
             "a size the output does not list is refused");

        DisplayLayout *fast = [two layoutBySettingResolution:@"1920x1080" forOutput:@"HDMI-1"];
        [[fast outputNamed:@"HDMI-1"] setModeRefresh:75];
        l = [fast layoutBySettingResolution:@"1280x1024" forOutput:@"HDMI-1"];
        PASS(EQ([[l outputNamed:@"HDMI-1"] modeRefresh], 75.0),
             "the refresh rate is kept when the new size offers it");
        PASS([[[l outputNamed:@"HDMI-1"] currentMode] modeID] == 5,
             "the mode resolves to the output's own 1280x1024 at 75 Hz");
    }
    END_SET("resolution changes")

    START_SET("a newly connected output can be enabled")
    {
        DisplayLayout *three = [DisplayLayout layoutWithOutputs:
            [[two outputs] arrayByAddingObject:
                O(@"DP-1", modes, NO, 1920, 1080, 60, 0, 0, NO)]];
        PASS([[three enabledOutputs] count] == 2, "the new output starts disabled");
        DisplayLayout *l = [three layoutBySettingResolution:@"1280x1024" forOutput:@"DP-1"];
        DisplayOutput *n = [l outputNamed:@"DP-1"];
        PASS([n enabled] && [n modeWidth] == 1280, "choosing a resolution enables it");
        PASS([n x] == 3840 && [n y] == 0,
             "it is placed right of the existing outputs, top aligned");
    }
    END_SET("a newly connected output can be enabled")

    START_SET("disabling")
    {
        DisplayLayout *l = [two layoutByDisablingOutput:@"HDMI-1"];
        PASS(![[l outputNamed:@"HDMI-1"] enabled], "an output can be turned off");
        PASS([l layoutByDisablingOutput:kInternal] == nil,
             "the last enabled output cannot be turned off");
        l = [two layoutByDisablingOutput:kInternal];
        PASS([[l outputNamed:@"HDMI-1"] primary] && [[l outputNamed:@"HDMI-1"] x] == 0,
             "turning off the primary hands primary to the remaining output at 0,0");
    }
    END_SET("disabling")

    START_SET("primary and arrangement")
    {
        DisplayLayout *l = [two layoutBySettingPrimary:@"HDMI-1"];
        PASS([[l primaryOutput].name isEqualToString:@"HDMI-1"]
             && ![[l outputNamed:kInternal] primary],
             "exactly one output is primary");

        l = [two layoutByMovingOutput:@"HDMI-1" toOrigin:NSMakePoint(-1900, 10)
                         snapDistance:50];
        PASS([[l outputNamed:@"HDMI-1"] x] == 0 && [[l outputNamed:kInternal] x] == 1920
             && [[l outputNamed:@"HDMI-1"] y] == 0,
             "moving the external output left of the internal one");

        l = [two layoutByMovingOutput:@"HDMI-1" toOrigin:NSMakePoint(30, -1000)
                         snapDistance:50];
        PASS([[l outputNamed:@"HDMI-1"] y] == 0 && [[l outputNamed:kInternal] y] == 1080
             && [[l outputNamed:@"HDMI-1"] x] == 0,
             "moving the external output above the internal one");
    }
    END_SET("primary and arrangement")

    START_SET("mirror")
    {
        NSArray *ma = [NSArray arrayWithObjects:M(1, 1920, 1080, 60, YES),
                       M(2, 1280, 1024, 60, NO), nil];
        NSArray *mb = [NSArray arrayWithObjects:M(3, 1680, 1050, 60, YES),
                       M(4, 1280, 1024, 60, NO), nil];
        DisplayLayout *l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(kInternal, ma, YES, 1920, 1080, 60, 0, 0, YES),
            O(@"VGA-1", mb, YES, 1680, 1050, 60, 1920, 0, NO), nil]];
        PASS(![l isMirrored], "side by side is not mirrored");
        DisplayLayout *mir = [l mirroredLayout];
        DisplayOutput *a = [mir outputNamed:kInternal], *b = [mir outputNamed:@"VGA-1"];
        PASS([a modeWidth] == 1280 && [b modeWidth] == 1280 && [b modeHeight] == 1024,
             "both outputs run the largest common mode");
        PASS(![a hasTransform] && ![b hasTransform], "a common mode needs no transform");
        PASS([b x] == 0 && [b y] == 0 && [mir isMirrored], "mirrored at the same origin");

        NSArray *mc = [NSArray arrayWithObjects:M(5, 2048, 1536, 60, YES), nil];
        NSArray *md = [NSArray arrayWithObjects:M(6, 1920, 1080, 60, YES), nil];
        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(kInternal, mc, YES, 2048, 1536, 60, 0, 0, YES),
            O(@"VGA-1", md, YES, 1920, 1080, 60, 2048, 0, NO), nil]];
        mir = [l mirroredLayout];
        a = [mir outputNamed:kInternal];
        b = [mir outputNamed:@"VGA-1"];
        PASS([a modeWidth] == 2048 && ![a hasTransform],
             "without a common mode the primary keeps its mode");
        PASS([b modeWidth] == 1920 && [b hasTransform]
             && NSEqualSizes([b size], [a size]),
             "the other output is scaled so it shows the whole picture");
        PASS([mir isMirrored], "scaled mirror counts as mirrored");

        DisplayLayout *ext = [mir extendedLayout];
        a = [ext outputNamed:kInternal];
        b = [ext outputNamed:@"VGA-1"];
        PASS(![ext isMirrored] && ![b hasTransform] && [a x] == 0 && [b x] == 2048,
             "unmirroring restores an extended layout without transforms");

        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(kInternal, ma, YES, 1920, 1080, 60, 0, 0, YES),
            O(@"VGA-1", mb, YES, 1680, 1050, 60, 1920, 0, NO), nil]];
        [[l outputNamed:@"VGA-1"] setRotation:2];
        mir = [l mirroredLayout];
        PASS([[mir outputNamed:@"VGA-1"] rotation] == 1 && [mir isMirrored],
             "mirroring turns a rotated output back upright, so both show the same picture");

        l = [DisplayLayout layoutWithOutputs:[NSArray arrayWithObjects:
            O(kInternal, ma, YES, 1280, 1024, 60, 0, 0, YES),
            O(@"VGA-1", mb, YES, 1280, 1024, 60, 0, 0, NO), nil]];
        ext = [l extendedLayout];
        PASS([[ext outputNamed:kInternal] modeWidth] == 1280
             && [[ext outputNamed:@"VGA-1"] modeWidth] == 1280
             && [[ext outputNamed:@"VGA-1"] x] == 1280,
             "unmirroring keeps the modes the outputs run");
        [[l outputNamed:@"VGA-1"] setEnabled:NO];
        ext = [l extendedLayout];
        PASS([[ext outputNamed:@"VGA-1"] modeWidth] == 1680,
             "an output that was dark is lit at its preferred mode");
    }
    END_SET("mirror")

    START_SET("rotation and transform")
    {
        DisplayOutput *o = O(@"DP-1", modes, YES, 1920, 1080, 60, 0, 0, YES);
        [o setRotation:2];
        [o setTransformScaleX:1.5];
        [o setTransformScaleY:2.0];
        /* The server composes the CRTC transform as scale x rotation
         * (RRTransformCompute), so the mode is turned first and the turned
         * picture is scaled along the screen axes. */
        PASS(NSEqualSizes([o size], NSMakeSize(1620, 3840)),
             "a turned output is scaled along the screen's axes");
    }
    END_SET("rotation and transform")

    START_SET("stored form")
    {
        DisplayLayout *l = [two copy];
        [[l outputNamed:@"HDMI-1"] setEdidIdentity:@"DEL-A0B1-12345678"];
        [l setScaleFactor:2.0];
        NSDictionary *pl = [l propertyList];
        DisplayLayout *back = [DisplayLayout layoutWithPropertyList:pl];
        PASS_EQUAL([back propertyList], pl, "property list round trip");
        PASS([[back outputNamed:@"HDMI-1"].edidIdentity isEqualToString:@"DEL-A0B1-12345678"]
             && [[back outputNamed:@"HDMI-1"] x] == 1920 && EQ([back scaleFactor], 2.0),
             "identity, position and scale survive");
        PASS([back isEqual:l], "layouts compare equal by their stored form");

        DisplayLayout *swapped = [DisplayLayout layoutWithOutputs:
            [NSArray arrayWithObjects:[[l outputs] objectAtIndex:1],
                                      [[l outputs] objectAtIndex:0], nil]];
        PASS_EQUAL([swapped configurationKey], [l configurationKey],
                   "the configuration key does not depend on output order");
        PASS([[l configurationKey] rangeOfString:@"DEL-A0B1-12345678"].location != NSNotFound
             && [[l configurationKey] rangeOfString:kInternal].location != NSNotFound,
             "the key uses the EDID identity, and the connector without EDID");
        [l release];
    }
    END_SET("stored form")

    START_SET("EDID identity")
    {
        NSData *edid = edidBlock();
        PASS_EQUAL(DisplayEDIDIdentity(edid), @"DEL-A0B1-12345678",
                   "vendor, product and serial");
        PASS_EQUAL(DisplayEDIDMonitorName(edid), @"DELL U2720Q", "monitor name");
        NSMutableData *bad = [[edid mutableCopy] autorelease];
        ((unsigned char *)[bad mutableBytes])[0] = 0x12;
        PASS(DisplayEDIDIdentity(bad) == nil, "not an EDID block: nil");
        PASS(DisplayEDIDIdentity([edid subdataWithRange:NSMakeRange(0, 64)]) == nil,
             "a short block: nil");
    }
    END_SET("EDID identity")

    [arp release];
    return 0;
}

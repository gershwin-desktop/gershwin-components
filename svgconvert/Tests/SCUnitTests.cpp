/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Unit tests for svgconvert's argument parsing and size computation. The
   expected sizes are what ImageMagick 7 convert produces for the same
   command line, so a convert command line keeps its output size. The
   output follows ObjectTesting's "Passed test:" / "FAILED test:" lines;
   ObjectTesting itself needs Objective-C, which this C++ tool avoids. */

#include "SCLayout.h"
#include "SCOptions.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace svgconvert;

static int passed = 0;
static int failed = 0;

static void pass(bool condition, const std::string &description)
{
    if (condition) {
        passed++;
        std::printf("Passed test:     %s\n", description.c_str());
    } else {
        failed++;
        std::printf("FAILED test:     %s\n", description.c_str());
    }
}

static bool parse(const std::vector<std::string> &args, Options &options, std::string &error)
{
    error.clear();
    return parseArguments(args, options, error);
}

static void testGeometry()
{
    Geometry g;
    std::string error;

    pass(parseGeometry("256x256", g, error) && g.hasWidth && g.hasHeight
         && g.width == 256 && g.height == 256 && !g.exact && !g.percent,
         "WxH sets both sides");
    pass(parseGeometry("18x18!", g, error) && g.exact && g.width == 18 && g.height == 18,
         "WxH! is exact");
    pass(parseGeometry("100", g, error) && g.hasWidth && !g.hasHeight && g.width == 100,
         "W sets the width only");
    pass(parseGeometry("x30", g, error) && !g.hasWidth && g.hasHeight && g.height == 30,
         "xH sets the height only");
    pass(parseGeometry("50%", g, error) && g.percent && g.width == 50 && g.height == 50,
         "N% is a percentage");
    pass(parseGeometry("12.5x20", g, error) && g.width == 12.5,
         "fractional sizes are accepted");

    const char *bad[] = {"", "abc", "10x10+5+5", "10x10>", "10x10^", "0x10",
                         "50%x20", "100!", "x", "10x10!!"};
    for (const char *text : bad) {
        error.clear();
        pass(!parseGeometry(text, g, error) && !error.empty(),
             std::string("geometry '") + text + "' is refused with a message");
    }
}

static void testColor()
{
    uint32_t c = 1;
    std::string error;

    pass(parseColor("none", c, error) && c == 0, "none is transparent");
    pass(parseColor("transparent", c, error) && c == 0, "transparent is transparent");
    pass(parseColor("White", c, error) && c == 0xffffffffu, "white, any case");
    pass(parseColor("black", c, error) && c == 0x000000ffu, "black");
    pass(parseColor("#f80", c, error) && c == 0xff8800ffu, "#rgb");
    pass(parseColor("#FF0000", c, error) && c == 0xff0000ffu, "#rrggbb");
    pass(parseColor("#ff000080", c, error) && c == 0xff000080u, "#rrggbbaa");

    const char *bad[] = {"#ff", "#gggggg", "red", "rgb(1,2,3)", ""};
    for (const char *text : bad) {
        error.clear();
        pass(!parseColor(text, c, error) && !error.empty(),
             std::string("colour '") + text + "' is refused with a message");
    }
}

static void testGravity()
{
    Gravity g = Gravity::NorthWest;
    std::string error;

    pass(parseGravity("center", g, error) && g == Gravity::Center, "center");
    pass(parseGravity("Center", g, error) && g == Gravity::Center, "Center, as convert writes it");
    pass(parseGravity("NorthEast", g, error) && g == Gravity::NorthEast, "NorthEast");
    error.clear();
    pass(!parseGravity("middle", g, error) && error.find("middle") != std::string::npos,
         "unknown gravity is named in the error");
}

static void testArguments()
{
    Options o;
    std::string error;

    pass(parse({"in.svg", "-background", "none", "-resize", "256x256", "out.png"}, o, error)
         && o.input == "in.svg" && o.output == "out.png" && o.background == 0
         && o.hasResize && o.resize.width == 256,
         "appwrap's command line");
    pass(parse({"-background", "none", "-density", "144", "in.svg", "-resize", "18x18!",
                "-strip", "-quiet", "out.png"}, o, error)
         && o.density == 144 && o.resize.exact && o.hasResize,
         "options before and after the input, -strip and -quiet accepted");
    pass(parse({"in.svg", "-gravity", "center", "-extent", "64x64", "out.png"}, o, error)
         && o.hasExtent && o.gravity == Gravity::Center && o.extent.width == 64,
         "-gravity center -extent WxH");
    pass(parse({"-size", "512x512", "in.svg", "out.png"}, o, error)
         && o.hasSize && o.size.width == 512, "-size WxH");
    pass(parse({"in.svg", "out.png"}, o, error) && o.background == 0xffffffffu
         && o.density == 96, "defaults are white and 96 dpi, as in convert");
    pass(parse({"icon.svg[0]", "out.png"}, o, error) && o.input == "icon.svg",
         "a [0] frame suffix is dropped");
    pass(parse({"svg:icon.svg", "png:out.img"}, o, error) && o.input == "icon.svg"
         && o.output == "out.img", "svg: and png: prefixes");
    pass(parse({"-", "png:-"}, o, error) && isStandardStream(o.input)
         && isStandardStream(o.output), "standard input and output");
    pass(parse({"in.svg", "OUT.PNG"}, o, error), "the extension is matched in any case");
    pass(parse({"-density", "72x72", "in.svg", "out.png"}, o, error) && o.density == 72,
         "-density XxY with equal axes");
    pass(parse({"-version"}, o, error) && o.showVersion, "-version needs no files");

    struct { std::vector<std::string> args; const char *needle; } bad[] = {
        {{"in.svg", "-flatten", "out.png"}, "-flatten"},
        {{"in.svg", "out.png", "-resize"}, "-resize"},
        {{"in.svg", "out.jpg"}, ".jpg"},
        {{"in.svg", "jpg:out"}, "jpg"},
        {{"in.svg", "out"}, "out"},
        {{"in.svg", "-"}, "png:-"},
        {{"in.svg"}, "output"},
        {{"a.svg", "b.svg", "c.png"}, "c.png"},
        {{"icon.svg[1]", "out.png"}, "frame 1"},
        {{"-density", "72x96", "in.svg", "out.png"}, "72x96"},
        {{"-density", "0", "in.svg", "out.png"}, "density"},
        {{"-background", "red", "in.svg", "out.png"}, "red"},
        {{"-extent", "50%", "in.svg", "out.png"}, "-extent"},
        {{"-size", "50%", "in.svg", "out.png"}, "-size"},
        {{"-gravity", "middle", "in.svg", "out.png"}, "middle"},
        {{"+repage", "in.svg", "out.png"}, "+repage"},
    };
    for (const auto &b : bad) {
        std::string joined;
        for (const auto &a : b.args)
            joined += (joined.empty() ? "" : " ") + a;
        bool refused = !parse(b.args, o, error);
        pass(refused && error.find(b.needle) != std::string::npos,
             "'" + joined + "' is refused naming " + b.needle);
    }
}

static Layout layoutFor(double w, double h, const std::vector<std::string> &opts, bool &ok)
{
    std::vector<std::string> args = opts;
    args.push_back("in.svg");
    args.push_back("out.png");
    Options o;
    std::string error;
    Layout l;
    ok = parseArguments(args, o, error) && computeLayout(w, h, o, l, error);
    return l;
}

static void expectSize(double w, double h, const std::vector<std::string> &opts,
                       int ew, int eh, const std::string &what)
{
    bool ok;
    Layout l = layoutFor(w, h, opts, ok);
    pass(ok && l.canvasWidth == ew && l.canvasHeight == eh,
         what + " gives " + std::to_string(ew) + "x" + std::to_string(eh)
         + " (got " + std::to_string(l.canvasWidth) + "x" + std::to_string(l.canvasHeight) + ")");
}

static void testLayout()
{
    /* A 40x20 drawing, sizes as ImageMagick 7.1 convert gives them. */
    expectSize(40, 20, {}, 40, 20, "no options");
    expectSize(40, 20, {"-density", "192"}, 80, 40, "-density 192");
    expectSize(40, 20, {"-density", "13"}, 5, 3, "-density 13 (rounding)");
    expectSize(40, 20, {"-resize", "64x64"}, 64, 32, "-resize 64x64 (fit)");
    expectSize(40, 20, {"-resize", "64x64!"}, 64, 64, "-resize 64x64!");
    expectSize(40, 20, {"-resize", "100"}, 100, 50, "-resize 100");
    expectSize(40, 20, {"-resize", "x30"}, 60, 30, "-resize x30");
    expectSize(40, 20, {"-resize", "50%"}, 20, 10, "-resize 50%");
    expectSize(40, 20, {"-resize", "33x7"}, 14, 7, "-resize 33x7");
    expectSize(40, 20, {"-size", "100x100"}, 100, 50, "-size 100x100 (fit)");
    expectSize(40, 20, {"-size", "100x100", "-resize", "50%"}, 50, 25, "-size then -resize");
    expectSize(40, 20, {"-size", "100x100!"}, 100, 100, "-size 100x100!");
    expectSize(16, 16, {"-resize", "18x18!"}, 18, 18, "the menu glyph target");
    expectSize(48, 24, {"-background", "none", "-resize", "256x256"}, 256, 128,
               "appwrap on a wide icon keeps the aspect");

    bool ok;
    Layout l = layoutFor(40, 20, {"-resize", "64x64", "-gravity", "center", "-extent", "64x64"}, ok);
    pass(ok && l.drawingWidth == 64 && l.drawingHeight == 32 && l.offsetX == 0 && l.offsetY == 16,
         "-gravity center -extent centres a wide drawing in a square");
    l = layoutFor(40, 20, {"-resize", "65x65", "-gravity", "center", "-extent", "64x64"}, ok);
    pass(ok && l.canvasWidth == 64 && l.offsetX == 0 && l.offsetY == 15,
         "-extent smaller than the drawing crops, offset truncated like convert");
    l = layoutFor(40, 20, {"-gravity", "southeast", "-extent", "50x30"}, ok);
    pass(ok && l.offsetX == 10 && l.offsetY == 10, "-gravity southeast");
    l = layoutFor(40, 20, {"-extent", "50x30"}, ok);
    pass(ok && l.offsetX == 0 && l.offsetY == 0, "-extent defaults to north-west, as in convert");

    Options o;
    std::string error;
    pass(!computeLayout(0, 0, o, l, error) && !error.empty(), "an SVG without a size is refused");
    o.hasResize = true;
    parseGeometry("100000x100000!", o.resize, error);
    error.clear();
    pass(!computeLayout(10, 10, o, l, error) && !error.empty(), "an absurd size is refused");
}

int main()
{
    testGeometry();
    testColor();
    testGravity();
    testArguments();
    testLayout();
    std::printf("\n%d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}

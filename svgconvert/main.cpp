/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* svgconvert renders an SVG file to PNG and takes the subset of ImageMagick
   convert's command line that icon scripts use for SVG, so such a command
   line keeps working when "convert" is replaced by "svgconvert". It exists
   so that Gershwin systems need neither ImageMagick nor librsvg, which pull
   in hundreds of MB of libraries, just to turn icons into bitmaps. */

#include "SCLayout.h"
#include "SCOptions.h"

#include <lunasvg.h>

#include <cstdio>
#include <iostream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

using namespace svgconvert;

namespace {

const char *kUsage =
    "usage: svgconvert [options] input.svg [options] output.png\n"
    "\n"
    "Options (the ImageMagick convert subset for SVG input):\n"
    "  -background COLOR   none, transparent, white, black, #rgb, #rrggbb,\n"
    "                      #rrggbbaa (default white, as in convert)\n"
    "  -density DPI        resolution of the SVG's own size (default 96)\n"
    "  -size GEOMETRY      render size: WxH, W, xH, WxH!\n"
    "  -resize GEOMETRY    WxH (fit, keep aspect), WxH! (exact), W, xH, N%\n"
    "  -gravity GRAVITY    center, north, northeast, ... (for -extent)\n"
    "  -extent WxH         pad or crop to WxH with the background colour\n"
    "  -strip, -quiet      accepted, no effect\n"
    "  -version, -help\n"
    "\n"
    "Options apply wherever they stand. The input may be '-' (stdin) and\n"
    "carry a [0] frame suffix; the output must be .png, png:FILE or png:-.\n"
    "Filters and text are not rendered.\n";

int fail(const std::string &message)
{
    std::cerr << "svgconvert: " << message << std::endl;
    return 1;
}

std::unique_ptr<lunasvg::Document> loadDocument(const std::string &input)
{
    if (!isStandardStream(input))
        return lunasvg::Document::loadFromFile(input);
    std::string data((std::istreambuf_iterator<char>(std::cin)),
                     std::istreambuf_iterator<char>());
    return lunasvg::Document::loadFromData(data);
}

void writeToStdout(void *closure, void *data, int size)
{
    bool *ok = static_cast<bool *>(closure);
    if (std::fwrite(data, 1, static_cast<size_t>(size), stdout) != static_cast<size_t>(size))
        *ok = false;
}

bool writePNG(const lunasvg::Bitmap &bitmap, const std::string &output)
{
    if (!isStandardStream(output))
        return bitmap.writeToPng(output);
    bool ok = true;
    if (!bitmap.writeToPng(writeToStdout, &ok))
        return false;
    return ok && std::fflush(stdout) == 0;
}

} // namespace

int main(int argc, char **argv)
{
    std::vector<std::string> args(argv + 1, argv + argc);
    Options options;
    std::string error;
    if (!parseArguments(args, options, error)) {
        std::cerr << "svgconvert: " << error << "\n\n" << kUsage;
        return 1;
    }
    if (options.showHelp) {
        std::cout << kUsage;
        return 0;
    }
    if (options.showVersion) {
        std::cout << "svgconvert 1.0 (lunasvg " << lunasvg_version_string() << ")\n";
        return 0;
    }

    auto document = loadDocument(options.input);
    if (!document)
        return fail("cannot read SVG from " + options.input);

    Layout layout;
    if (!computeLayout(document->width(), document->height(), options, layout, error))
        return fail(options.input + ": " + error);

    lunasvg::Bitmap canvas(layout.canvasWidth, layout.canvasHeight);
    if (canvas.isNull())
        return fail("out of memory for a " + std::to_string(layout.canvasWidth) + "x"
                    + std::to_string(layout.canvasHeight) + " image");
    /* The background goes under the drawing and into any -extent padding,
       which is where convert puts it too. */
    if (options.background != 0)
        canvas.clear(options.background);

    lunasvg::Matrix matrix(static_cast<float>(layout.drawingWidth) / document->width(), 0,
                           0, static_cast<float>(layout.drawingHeight) / document->height(),
                           static_cast<float>(layout.offsetX),
                           static_cast<float>(layout.offsetY));
    document->render(canvas, matrix);

    if (!writePNG(canvas, options.output))
        return fail("cannot write " + options.output);
    return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#include "SCLayout.h"

#include <algorithm>
#include <cmath>

namespace svgconvert {

namespace {

/* convert rounds every computed size half up and never goes below 1 px. */
int roundSize(double value)
{
    return std::max(1, static_cast<int>(std::floor(value + 0.5)));
}

/* convert centres with integer division, which truncates towards zero when
   -extent crops; matching it keeps outputs pixel-identical. */
int gravityOffset(int canvas, int drawing, int position)
{
    if (position == 0)
        return 0;
    if (position == 1)
        return (canvas - drawing) / 2;
    return canvas - drawing;
}

} // namespace

void applyGeometry(double width, double height, const Geometry &geometry,
                   int &outWidth, int &outHeight)
{
    if (geometry.percent) {
        outWidth = roundSize(width * geometry.width / 100.0);
        outHeight = roundSize(height * geometry.height / 100.0);
        return;
    }
    if (geometry.exact) {
        outWidth = roundSize(geometry.width);
        outHeight = roundSize(geometry.height);
        return;
    }
    double scale;
    if (geometry.hasWidth && geometry.hasHeight)
        scale = std::min(geometry.width / width, geometry.height / height);
    else if (geometry.hasWidth)
        scale = geometry.width / width;
    else
        scale = geometry.height / height;
    outWidth = roundSize(width * scale);
    outHeight = roundSize(height * scale);
}

bool computeLayout(double intrinsicWidth, double intrinsicHeight,
                   const Options &options, Layout &layout, std::string &error)
{
    if (!(intrinsicWidth > 0) || !(intrinsicHeight > 0)) {
        error = "the SVG has no size: it needs width and height or a viewBox";
        return false;
    }

    Layout l;
    if (options.hasSize) {
        applyGeometry(intrinsicWidth, intrinsicHeight, options.size,
                      l.drawingWidth, l.drawingHeight);
    } else {
        double scale = options.density / 96.0;
        l.drawingWidth = roundSize(intrinsicWidth * scale);
        l.drawingHeight = roundSize(intrinsicHeight * scale);
    }

    if (options.hasResize) {
        int w, h;
        applyGeometry(l.drawingWidth, l.drawingHeight, options.resize, w, h);
        l.drawingWidth = w;
        l.drawingHeight = h;
    }

    l.canvasWidth = l.drawingWidth;
    l.canvasHeight = l.drawingHeight;
    if (options.hasExtent) {
        l.canvasWidth = roundSize(options.extent.width);
        l.canvasHeight = roundSize(options.extent.height);
        int g = static_cast<int>(options.gravity);
        l.offsetX = gravityOffset(l.canvasWidth, l.drawingWidth, g % 3);
        l.offsetY = gravityOffset(l.canvasHeight, l.drawingHeight, g / 3);
    }

    /* Guards the pixel buffer size against a typo like -resize 100000x100000. */
    const double maxPixels = 1 << 28;
    if (static_cast<double>(l.canvasWidth) * l.canvasHeight > maxPixels) {
        error = "the output would be larger than 268 megapixels";
        return false;
    }
    layout = l;
    return true;
}

} // namespace svgconvert

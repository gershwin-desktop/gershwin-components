/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#ifndef SC_LAYOUT_H
#define SC_LAYOUT_H

#include "SCOptions.h"

#include <string>

namespace svgconvert {

/* Where the drawing lands in the output, in pixels. The drawing is rendered
   straight at its final size rather than rasterized first and resampled, as
   convert would, so -resize costs no sharpness. */
struct Layout {
    int drawingWidth = 0;
    int drawingHeight = 0;
    int canvasWidth = 0;
    int canvasHeight = 0;
    int offsetX = 0;   /* may be negative when -extent crops */
    int offsetY = 0;
};

/* Scales a width and height by a geometry with convert's rules: fit inside
   the box keeping the aspect ratio, unless the geometry ends in "!". */
void applyGeometry(double width, double height, const Geometry &geometry,
                   int &outWidth, int &outHeight);

/* intrinsicWidth and intrinsicHeight are the SVG's size in CSS pixels, which
   convert treats as 96 dpi. */
bool computeLayout(double intrinsicWidth, double intrinsicHeight,
                   const Options &options, Layout &layout, std::string &error);

} // namespace svgconvert

#endif

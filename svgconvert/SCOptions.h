/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#ifndef SC_OPTIONS_H
#define SC_OPTIONS_H

#include <cstdint>
#include <string>
#include <vector>

namespace svgconvert {

/* An ImageMagick geometry as used by -resize, -size and -extent. */
struct Geometry {
    double width = 0;
    double height = 0;
    bool hasWidth = false;
    bool hasHeight = false;
    bool exact = false;    /* "!": ignore the aspect ratio */
    bool percent = false;  /* "N%": scale factor in percent */
};

enum class Gravity {
    NorthWest, North, NorthEast,
    West, Center, East,
    SouthWest, South, SouthEast
};

struct Options {
    std::string input;
    std::string output;
    /* 0xRRGGBBAA. convert renders SVG on white unless told otherwise, and
       command lines written for convert rely on that. */
    uint32_t background = 0xffffffffu;
    double density = 96;
    bool hasSize = false;
    Geometry size;
    bool hasResize = false;
    Geometry resize;
    bool hasExtent = false;
    Geometry extent;
    Gravity gravity = Gravity::NorthWest;
    bool showVersion = false;
    bool showHelp = false;
};

/* Each returns false and sets error on input that convert would not accept
   or that svgconvert does not support. */
bool parseGeometry(const std::string &text, Geometry &geometry, std::string &error);
bool parseColor(const std::string &text, uint32_t &rgba, std::string &error);
bool parseGravity(const std::string &text, Gravity &gravity, std::string &error);
bool parseArguments(const std::vector<std::string> &args, Options &options, std::string &error);

/* "-" and "png:-" mean standard input or output. */
bool isStandardStream(const std::string &path);

} // namespace svgconvert

#endif

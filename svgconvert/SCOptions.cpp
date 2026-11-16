/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#include "SCOptions.h"

#include <cctype>
#include <cstdlib>

namespace svgconvert {

namespace {

std::string lowercase(const std::string &text)
{
    std::string result = text;
    for (char &c : result)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

bool hasSuffix(const std::string &text, const std::string &suffix)
{
    return text.size() >= suffix.size()
        && text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

/* Reads a non-negative decimal number at pos, as convert accepts "12.5x20". */
bool readNumber(const std::string &text, size_t &pos, double &value)
{
    size_t start = pos;
    bool seenDigit = false;
    bool seenPoint = false;
    while (pos < text.size()) {
        char c = text[pos];
        if (std::isdigit(static_cast<unsigned char>(c)))
            seenDigit = true;
        else if (c == '.' && !seenPoint)
            seenPoint = true;
        else
            break;
        pos++;
    }
    if (!seenDigit)
        return false;
    value = std::strtod(text.substr(start, pos - start).c_str(), nullptr);
    return true;
}

int hexDigit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* convert reads the first frame of a file named "icon.svg[0]"; an SVG has
   only that one, so the suffix is dropped and any other index refused. */
bool stripFrameSuffix(std::string &path, std::string &error)
{
    if (path.empty() || path.back() != ']')
        return true;
    size_t open = path.rfind('[');
    if (open == std::string::npos)
        return true;
    std::string index = path.substr(open + 1, path.size() - open - 2);
    if (index != "0") {
        error = "frame " + index + " of " + path.substr(0, open)
              + " does not exist: an SVG has only frame 0";
        return false;
    }
    path.erase(open);
    return true;
}

bool normalizeInput(std::string &path, std::string &error)
{
    if (lowercase(path.substr(0, 4)) == "svg:")
        path.erase(0, 4);
    if (!stripFrameSuffix(path, error))
        return false;
    if (path.empty()) {
        error = "no input file name";
        return false;
    }
    return true;
}

/* svgconvert writes PNG only, so the output format, which convert takes from
   a "png:" prefix or the extension, must say PNG. */
bool normalizeOutput(std::string &path, std::string &error)
{
    std::string lower = lowercase(path);
    for (const char *prefix : {"png32:", "png:"}) {
        std::string p(prefix);
        if (lower.compare(0, p.size(), p) == 0) {
            path.erase(0, p.size());
            if (path.empty()) {
                error = "no output file name";
                return false;
            }
            return true;
        }
    }
    if (path == "-") {
        error = "writing to standard output needs the format, as in png:-";
        return false;
    }
    size_t colon = lower.find(':');
    if (colon != std::string::npos && lower.find('/') > colon) {
        error = "output format " + path.substr(0, colon)
              + ": is not supported, svgconvert writes PNG only";
        return false;
    }
    if (!hasSuffix(lower, ".png")) {
        size_t dot = lower.rfind('.');
        std::string ext = dot == std::string::npos ? std::string("(none)")
                                                   : path.substr(dot);
        error = "output format " + ext + " of " + path
              + " is not supported, svgconvert writes PNG only";
        return false;
    }
    return true;
}

bool parseDensity(const std::string &text, double &density, std::string &error)
{
    size_t pos = 0;
    double x = 0;
    if (!readNumber(text, pos, x)) {
        error = "invalid density " + text;
        return false;
    }
    if (pos < text.size()) {
        double y = 0;
        if (text[pos] != 'x' || !readNumber(text, ++pos, y) || pos != text.size()) {
            error = "invalid density " + text;
            return false;
        }
        if (y != x) {
            error = "density " + text + " differs per axis, which svgconvert does not support";
            return false;
        }
    }
    if (x <= 0) {
        error = "density must be greater than 0";
        return false;
    }
    density = x;
    return true;
}

} // namespace

bool isStandardStream(const std::string &path)
{
    return path == "-";
}

bool parseGeometry(const std::string &text, Geometry &geometry, std::string &error)
{
    Geometry g;
    std::string body = text;
    if (!body.empty() && body.back() == '!') {
        g.exact = true;
        body.pop_back();
    }
    size_t pos = 0;
    if (readNumber(body, pos, g.width))
        g.hasWidth = true;
    if (pos < body.size() && body[pos] == '%') {
        if (!g.hasWidth || pos + 1 != body.size() || g.exact) {
            error = "geometry " + text + " is not supported: use N% alone";
            return false;
        }
        g.percent = true;
        g.height = g.width;
        g.hasHeight = true;
        pos++;
    } else if (pos < body.size() && (body[pos] == 'x' || body[pos] == 'X')) {
        pos++;
        if (readNumber(body, pos, g.height))
            g.hasHeight = true;
    }
    if (pos != body.size()) {
        error = "geometry " + text
              + " is not supported: only W, xH, WxH, WxH! and N% are";
        return false;
    }
    if (!g.hasWidth && !g.hasHeight) {
        error = "invalid geometry " + text;
        return false;
    }
    if ((g.hasWidth && g.width <= 0) || (g.hasHeight && g.height <= 0)) {
        error = "geometry " + text + " has a zero size";
        return false;
    }
    if (g.exact && !(g.hasWidth && g.hasHeight)) {
        error = "geometry " + text + " needs both width and height with !";
        return false;
    }
    geometry = g;
    return true;
}

bool parseColor(const std::string &text, uint32_t &rgba, std::string &error)
{
    std::string lower = lowercase(text);
    if (lower == "none" || lower == "transparent") {
        rgba = 0x00000000u;
        return true;
    }
    if (lower == "white") {
        rgba = 0xffffffffu;
        return true;
    }
    if (lower == "black") {
        rgba = 0x000000ffu;
        return true;
    }
    if (!lower.empty() && lower[0] == '#') {
        std::string hex = lower.substr(1);
        for (char c : hex) {
            if (hexDigit(c) < 0) {
                error = "invalid colour " + text;
                return false;
            }
        }
        if (hex.size() == 3) {
            uint32_t value = 0;
            for (char c : hex)
                value = (value << 8) | static_cast<uint32_t>(hexDigit(c) * 17);
            rgba = (value << 8) | 0xffu;
            return true;
        }
        if (hex.size() == 6 || hex.size() == 8) {
            uint32_t value = static_cast<uint32_t>(std::strtoul(hex.c_str(), nullptr, 16));
            rgba = hex.size() == 6 ? ((value << 8) | 0xffu) : value;
            return true;
        }
        error = "invalid colour " + text + ": use #rgb, #rrggbb or #rrggbbaa";
        return false;
    }
    error = "colour " + text
          + " is not supported: use none, transparent, white, black or #rrggbb";
    return false;
}

bool parseGravity(const std::string &text, Gravity &gravity, std::string &error)
{
    static const struct { const char *name; Gravity value; } names[] = {
        {"northwest", Gravity::NorthWest}, {"north", Gravity::North},
        {"northeast", Gravity::NorthEast}, {"west", Gravity::West},
        {"center", Gravity::Center}, {"east", Gravity::East},
        {"southwest", Gravity::SouthWest}, {"south", Gravity::South},
        {"southeast", Gravity::SouthEast},
    };
    std::string lower = lowercase(text);
    for (const auto &n : names) {
        if (lower == n.name) {
            gravity = n.value;
            return true;
        }
    }
    error = "unknown gravity " + text;
    return false;
}

bool parseArguments(const std::vector<std::string> &args, Options &options, std::string &error)
{
    Options o;
    std::vector<std::string> files;

    for (size_t i = 0; i < args.size(); i++) {
        const std::string &arg = args[i];
        if (arg.size() < 2 || (arg[0] != '-' && arg[0] != '+')) {
            files.push_back(arg);
            continue;
        }
        if (arg == "-version" || arg == "--version") {
            o.showVersion = true;
            continue;
        }
        if (arg == "-help" || arg == "--help" || arg == "-h") {
            o.showHelp = true;
            continue;
        }
        /* Metadata and warnings do not exist here, so these change nothing;
           they are accepted because convert command lines carry them. */
        if (arg == "-strip" || arg == "-quiet")
            continue;

        bool takesValue = arg == "-background" || arg == "-density"
                       || arg == "-resize" || arg == "-size"
                       || arg == "-gravity" || arg == "-extent";
        if (!takesValue) {
            error = "unsupported option " + arg;
            return false;
        }
        if (i + 1 >= args.size()) {
            error = "option " + arg + " needs a value";
            return false;
        }
        const std::string &value = args[++i];
        bool ok = true;
        if (arg == "-background") {
            ok = parseColor(value, o.background, error);
        } else if (arg == "-density") {
            ok = parseDensity(value, o.density, error);
        } else if (arg == "-resize") {
            ok = parseGeometry(value, o.resize, error);
            o.hasResize = true;
        } else if (arg == "-size") {
            ok = parseGeometry(value, o.size, error);
            if (ok && o.size.percent) {
                error = "-size " + value + ": a percentage is not supported here";
                ok = false;
            }
            o.hasSize = true;
        } else if (arg == "-gravity") {
            ok = parseGravity(value, o.gravity, error);
        } else {
            ok = parseGeometry(value, o.extent, error);
            if (ok && (o.extent.percent || o.extent.exact
                       || !o.extent.hasWidth || !o.extent.hasHeight)) {
                error = "-extent " + value + ": use WxH";
                ok = false;
            }
            o.hasExtent = true;
        }
        if (!ok) {
            error = arg + ": " + error;
            return false;
        }
    }

    if (o.showVersion || o.showHelp) {
        options = o;
        return true;
    }
    if (files.size() != 2) {
        error = files.size() < 2 ? "need an input and an output file"
                                 : "too many files: " + files[2];
        return false;
    }
    o.input = files[0];
    o.output = files[1];
    if (!normalizeInput(o.input, error) || !normalizeOutput(o.output, error))
        return false;
    options = o;
    return true;
}

} // namespace svgconvert

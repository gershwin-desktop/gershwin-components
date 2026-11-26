# svgconvert

Renders SVG to PNG. It takes the part of ImageMagick's `convert` command
line that scripts use for SVG icons, so such a command line keeps working
when `convert` is replaced by `svgconvert`:

    svgconvert icon.svg -background none -resize 256x256 icon.png

Gershwin needs it so that rasterizing an icon needs neither ImageMagick nor
librsvg, which bring hundreds of MB of libraries into the live images. It is
a plain C++17 tool with no dependency beyond libc and the C++ runtime, built
and installed to `/System/Library/Tools` with the rest of
gershwin-components. It is deliberately not installed as `convert`, which
would shadow ImageMagick where that is present.

## Options

| Option | Meaning |
| --- | --- |
| `-background C` | `none`, `transparent`, `white`, `black`, `#rgb`, `#rrggbb`, `#rrggbbaa`; default white, as in convert |
| `-density N` | DPI the SVG's own size is read at (default 96); `NxN` accepted |
| `-size G` | render size before `-resize`: `WxH` (fit), `W`, `xH`, `WxH!` |
| `-resize G` | `WxH` fits inside the box keeping the aspect ratio, `WxH!` exact, `W`, `xH`, `N%` |
| `-gravity G` | `center`, `north`, `northeast`, ... `southwest`; placement for `-extent` |
| `-extent WxH` | pad (or crop) to WxH with the background colour |
| `-strip`, `-quiet` | accepted, no effect |

The input may be `-` for standard input and may carry a `[0]` frame suffix
or an `svg:` prefix. The output must end in `.png` or be written as
`png:FILE` (`png:-` for standard output). Options apply wherever they stand.
Output sizes follow ImageMagick 7's rounding; the drawing is rendered
directly at its final size rather than resampled. Anything else, an unknown
option or another output format, is an error naming it, with a non-zero
exit status.

Differences from convert: `-size` scales an SVG that has a size of its own
(convert ignores it then); filters and text are not rendered.

## Tests

    gmake check

builds the unit test tool (argument parsing and output sizes, checked
against what ImageMagick 7 produces) and a PNG reader, then renders the
fixtures in `Tests/Fixtures` and checks sizes and pixels, including a
gradient set by CSS, `use` of a `symbol`, a clip path and a mask.

`Tests/regression.sh LIST REFDIR` renders a list of icons the way appwrap
does and compares each with a reference PNG made by ImageMagick, failing if
any icon falls below 30 dB PSNR, except the known icons with filters or
text. The reference images are not in the repository; LIST holds lines of
`name.png<TAB>/path/to/icon.svg` and REFDIR the matching `name.png` files.
Run it after `gmake check`, which builds the PNG reader it uses.

## Vendored code

`ThirdParty/lunasvg` and `ThirdParty/plutovg` are lunasvg 3.5.0 and the
plutovg 1.3.3 it bundles, both by Samuel Ugochukwu under the MIT licence
(see their `LICENSE` files; plutovg's rasterizer also carries the FreeType
licence in `source/FTL.TXT`). They come from
https://github.com/sammycage/lunasvg at commit
90d6ff333862acf3f5551ffbbcb1e45957661881, unchanged; only the CMake and
Meson files, examples and the other build glue were left out. The text and
font code is kept because lunasvg does not separate it cleanly.

To update, check out the new lunasvg commit and copy over:

    cp lunasvg/LICENSE                  ThirdParty/lunasvg/
    cp lunasvg/include/lunasvg.h        ThirdParty/lunasvg/include/
    cp lunasvg/source/*                 ThirdParty/lunasvg/source/
    cp lunasvg/plutovg/LICENSE          ThirdParty/plutovg/
    cp lunasvg/plutovg/include/plutovg.h ThirdParty/plutovg/include/
    cp lunasvg/plutovg/source/*         ThirdParty/plutovg/source/

then add any new source files to `LUNASVG_FILES` or `PLUTOVG_FILES` in the
GNUmakefile, update the commit above, and run `gmake check` and
`Tests/regression.sh`.

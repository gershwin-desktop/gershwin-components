include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# A C tool rather than a GNUstep tool: svgconvert must not need Foundation,
# so that it builds early and runs anywhere with only libc and the C++
# runtime. Linking with the C++ driver picks the right runtime per system
# (libstdc++ on Linux, libc++ on the BSDs).
LD = $(CXX)

LUNASVG_FILES = $(addprefix ThirdParty/lunasvg/source/, \
	graphics.cpp lunasvg.cpp svgelement.cpp svggeometryelement.cpp \
	svglayoutstate.cpp svgpaintelement.cpp svgparser.cpp svgproperty.cpp \
	svgrenderstate.cpp svgtextelement.cpp)

PLUTOVG_FILES = $(addprefix ThirdParty/plutovg/source/, \
	plutovg-blend.c plutovg-canvas.c plutovg-font.c plutovg-ft-math.c \
	plutovg-ft-raster.c plutovg-ft-stroker.c plutovg-matrix.c \
	plutovg-paint.c plutovg-path.c plutovg-rasterize.c plutovg-surface.c)

OWN_CC_FILES = SCOptions.cpp SCLayout.cpp

CTOOL_NAME = svgconvert
svgconvert_CC_FILES = main.cpp $(OWN_CC_FILES) $(LUNASVG_FILES)
svgconvert_C_FILES = $(PLUTOVG_FILES)

# The test helpers are built for "gmake check" only, so that an install
# neither compiles nor installs them. Exported, because gnustep-make builds
# each tool in a sub-make whose goal is no longer "check".
ifneq ($(filter check,$(MAKECMDGOALS)),)
export SVGCONVERT_BUILD_TESTS = yes
endif
ifeq ($(SVGCONVERT_BUILD_TESTS),yes)
CTOOL_NAME += svgconvert_unit svgconvert_pnginfo
svgconvert_unit_CC_FILES = Tests/SCUnitTests.cpp $(OWN_CC_FILES)
svgconvert_pnginfo_C_FILES = Tests/pnginfo.c $(PLUTOVG_FILES)
endif

# Static builds of the vendored libraries, as upstream's CMake does by
# default; the _BUILD defines select the library side of their headers.
ADDITIONAL_CPPFLAGS += -DLUNASVG_BUILD -DLUNASVG_BUILD_STATIC \
	-DPLUTOVG_BUILD -DPLUTOVG_BUILD_STATIC
ADDITIONAL_INCLUDE_DIRS += -I. -IThirdParty/lunasvg/include \
	-IThirdParty/plutovg/include
ADDITIONAL_CFLAGS += -std=c11
ADDITIONAL_CCFLAGS += -std=c++17
TARGET_SYSTEM_LIBS += -lm

# Our own code must stay free of warnings; the vendored files are kept
# byte-identical to upstream, so their warnings are upstream's to fix.
OWN_WARNING_FLAGS = -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion
main.cpp_FILE_FLAGS = $(OWN_WARNING_FLAGS)
SCOptions.cpp_FILE_FLAGS = $(OWN_WARNING_FLAGS)
SCLayout.cpp_FILE_FLAGS = $(OWN_WARNING_FLAGS)
Tests/SCUnitTests.cpp_FILE_FLAGS = $(OWN_WARNING_FLAGS)
Tests/pnginfo.c_FILE_FLAGS = $(OWN_WARNING_FLAGS)
$(foreach f,$(LUNASVG_FILES) $(PLUTOVG_FILES),$(eval $(f)_FILE_FLAGS = -w))

include $(GNUSTEP_MAKEFILES)/ctool.make

after-check:: all
	sh Tests/check.sh $(GNUSTEP_OBJ_DIR)

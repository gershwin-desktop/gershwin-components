#
# Headless ObjectTesting coverage for the screen recording command lines:
# gmake, then run ./obj/t_ScreenRecordingOptions.  Recording itself (ffmpeg,
# the frame on the screen) is checked in an isolated X session; nothing here
# needs a display or ffmpeg.
#
ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_ScreenRecordingOptions t_RecordingFrameGeometry

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework -I../..
ADDITIONAL_OBJCFLAGS += -Wno-deprecated -Wall -Wextra -Werror

t_ScreenRecordingOptions_OBJC_FILES = t_ScreenRecordingOptions.m ../../ScreenRecordingOptions.m
t_RecordingFrameGeometry_OBJC_FILES = t_RecordingFrameGeometry.m
# clang 19 / binutils 2.44: a test without constant strings has no
# __objc_constant_string section, yet the runtime's init references its
# bounds; defining them as 0 keeps the (empty) scan a no-op.
t_RecordingFrameGeometry_LDFLAGS += -Wl,--defsym=__start___objc_constant_string=0 \
                                    -Wl,--defsym=__stop___objc_constant_string=0

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core tests.log tests.sum oldtests.log oldtests.sum

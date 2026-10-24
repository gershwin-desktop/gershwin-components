#
# Headless ObjectTesting coverage for Whisper's dictation state machine and
# the view state computed from it.  The app itself (microphone, window) is
# exercised live in an isolated uitest session, see docs/state-machine.md.
#
ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_WDictationMachine t_WDictationViewState t_WKeyRepeatFilter

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wno-deprecated -Wall -Wextra -Werror

t_WDictationMachine_OBJC_FILES = t_WDictationMachine.m ../../WDictationMachine.m
t_WDictationViewState_OBJC_FILES = t_WDictationViewState.m \
	../../WDictationViewState.m ../../WDictationMachine.m
t_WKeyRepeatFilter_OBJC_FILES = t_WKeyRepeatFilter.m ../../WKeyRepeatFilter.m

include $(GNUSTEP_MAKEFILES)/test-tool.make

after-clean::
	rm -f core core.* *.core tests.log tests.sum oldtests.log oldtests.sum

#
# Headless ObjectTesting coverage for the pure-logic podcast pieces:
# Podcast's property-list round trip and PodcastFeedParser's RSS parsing.
# Episode playback and the UI itself are covered by the player*.uitest
# scripts in Tests/, driven with the driveui skill - there is no window or
# network here, just model/parser logic.
#
ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
 $(error You need to set GNUSTEP_MAKEFILES before compiling!)
endif

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_Podcast t_PodcastFeedParser

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_OBJCFLAGS += -Wno-deprecated -Wall -Wextra -Werror

t_Podcast_OBJC_FILES = t_Podcast.m
t_PodcastFeedParser_OBJC_FILES = t_PodcastFeedParser.m
t_PodcastFeedParser_OBJC_FILES += ../../PlayerAsync.m

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core tests.log tests.sum oldtests.log oldtests.sum

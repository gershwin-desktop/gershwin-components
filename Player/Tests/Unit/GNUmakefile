#
# Headless unit tests for Player's model and playback classes.
# Build with "gmake", run each ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_PlayerPlaylist t_StreamPlayer t_PlayerSession t_PlayerSessionMedia t_PlayerMenu t_PlayerViews

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wno-deprecated

t_PlayerPlaylist_OBJC_FILES = t_PlayerPlaylist.m
t_PlayerSession_OBJC_FILES = t_PlayerSession.m ../../PlayerPlaylist.m
t_PlayerSessionMedia_OBJC_FILES = t_PlayerSessionMedia.m TestMedia.m \
	../../PlayerSession.m ../../PlayerPlaylist.m ../../StreamPlayer.m
t_PlayerMenu_OBJC_FILES = t_PlayerMenu.m ../../PlayerMenu.m
t_PlayerMenu_TOOL_LIBS += -lgnustep-gui
t_PlayerViews_OBJC_FILES = t_PlayerViews.m ../../PlayerViews.m
t_PlayerViews_TOOL_LIBS += -lgnustep-gui $(shell pkg-config --libs x11)
t_StreamPlayer_OBJC_FILES = t_StreamPlayer.m TestMedia.m ../../StreamPlayer.m

# StreamPlayer decodes with FFmpeg and plays through libao
FFMPEG_PKGS = libavformat libavcodec libavutil libswresample libswscale
ADDITIONAL_INCLUDE_DIRS += $(shell pkg-config --cflags $(FFMPEG_PKGS))
FFMPEG_LIBS = $(shell pkg-config --libs $(FFMPEG_PKGS) ao)
t_StreamPlayer_TOOL_LIBS += $(FFMPEG_LIBS)
t_PlayerSessionMedia_TOOL_LIBS += $(FFMPEG_LIBS)

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make

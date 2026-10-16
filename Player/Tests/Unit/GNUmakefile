# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
-include ../GNUmakefile.super

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME =  t_MediaRemote t_PlayerMediaInfo t_PlayerMenu t_PlayerPlaybackMachine t_PlayerPlaylist t_PlayerSession t_PlayerSessionMedia t_PlayerViews t_PlayerViewState t_PodcastFeedParser t_Podcast t_RadioManager t_StreamPlayer

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ifeq ($(gcov),yes)
ADDITIONAL_OBJCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_OBJCCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_LDFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_TOOL_LIBS+=-lgcov
endif

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated


t_MediaRemote_OBJC_FILES=t_MediaRemote.m
t_PlayerMediaInfo_OBJC_FILES=t_PlayerMediaInfo.m
t_PlayerMenu_OBJC_FILES=t_PlayerMenu.m
t_PlayerPlaybackMachine_OBJC_FILES=t_PlayerPlaybackMachine.m
t_PlayerPlaylist_OBJC_FILES=t_PlayerPlaylist.m
t_PlayerSession_OBJC_FILES=t_PlayerSession.m
t_PlayerSessionMedia_OBJC_FILES=t_PlayerSessionMedia.m
t_PlayerViews_OBJC_FILES=t_PlayerViews.m
t_PlayerViewState_OBJC_FILES=t_PlayerViewState.m
t_PodcastFeedParser_OBJC_FILES=t_PodcastFeedParser.m
t_Podcast_OBJC_FILES=t_Podcast.m
t_RadioManager_OBJC_FILES=t_RadioManager.m
t_StreamPlayer_OBJC_FILES=t_StreamPlayer.m

-include GNUmakefile.preamble
-include make-check.mak
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum


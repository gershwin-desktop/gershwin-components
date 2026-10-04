# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
-include ../GNUmakefile.super

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME =  t_AGCategoryNames t_AGDiscoverOrder t_AGDownloadResolver t_AGFeedLoader t_AGFeedParser t_AGGridLayout t_AGInstallRegistry t_AGInstallTask t_AGLicenseFormatter t_AGRiskAdviser t_AGSearchIndex

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ifeq ($(gcov),yes)
ADDITIONAL_OBJCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_OBJCCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_LDFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_TOOL_LIBS+=-lgcov
endif

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated


t_AGCategoryNames_OBJC_FILES=t_AGCategoryNames.m
t_AGDiscoverOrder_OBJC_FILES=t_AGDiscoverOrder.m
t_AGDownloadResolver_OBJC_FILES=t_AGDownloadResolver.m
t_AGFeedLoader_OBJC_FILES=t_AGFeedLoader.m
t_AGFeedParser_OBJC_FILES=t_AGFeedParser.m
t_AGGridLayout_OBJC_FILES=t_AGGridLayout.m
t_AGInstallRegistry_OBJC_FILES=t_AGInstallRegistry.m
t_AGInstallTask_OBJC_FILES=t_AGInstallTask.m
t_AGLicenseFormatter_OBJC_FILES=t_AGLicenseFormatter.m
t_AGRiskAdviser_OBJC_FILES=t_AGRiskAdviser.m
t_AGSearchIndex_OBJC_FILES=t_AGSearchIndex.m

-include GNUmakefile.preamble
-include make-check.mak
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum


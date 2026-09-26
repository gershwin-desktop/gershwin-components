include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_SWRepositoryList t_SWGitTool t_SWSelectionRules t_SWGitHubBuildStatus t_SWUpdateChecker t_SWPrerequisitesInstaller t_SWRepositoryUpdater

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter -Wno-deprecated
# PackageManager's own headers (used by t_SWPrerequisitesInstaller) are not
# nullability-annotated; every other consumer in this tree suppresses the
# same warning rather than editing a framework header for cosmetics.
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness
# Testing.h's PASS macros use manual retain/release, so this TU stays MRC;
# the ARC models under test are linked as separate objects instead of
# #include-d, with ARC turned on per-file in GNUmakefile.preamble.

t_SWRepositoryList_OBJC_FILES = t_SWRepositoryList.m
t_SWGitTool_OBJC_FILES = t_SWGitTool.m
t_SWSelectionRules_OBJC_FILES = t_SWSelectionRules.m
t_SWGitHubBuildStatus_OBJC_FILES = t_SWGitHubBuildStatus.m
t_SWUpdateChecker_OBJC_FILES = t_SWUpdateChecker.m
t_SWPrerequisitesInstaller_OBJC_FILES = t_SWPrerequisitesInstaller.m
t_SWRepositoryUpdater_OBJC_FILES = t_SWRepositoryUpdater.m

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/test-tool.make

# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
-include ../GNUmakefile.super

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME =  t_AccelerationCurve t_MouseBackend t_MousePreferences t_PointerDevices

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ifeq ($(gcov),yes)
ADDITIONAL_OBJCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_OBJCCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_LDFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_TOOL_LIBS+=-lgcov
endif

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated


t_AccelerationCurve_OBJC_FILES=t_AccelerationCurve.m
t_MouseBackend_OBJC_FILES=t_MouseBackend.m
t_MousePreferences_OBJC_FILES=t_MousePreferences.m
t_PointerDevices_OBJC_FILES=t_PointerDevices.m

-include GNUmakefile.preamble
-include make-check.mak
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum


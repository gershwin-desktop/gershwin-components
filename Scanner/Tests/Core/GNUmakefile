# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
-include ../GNUmakefile.super

GNUSTEP_OBJ_DIR=./obj

TEST_TOOL_NAME =  t_ImageAnalysis t_ImageBuilder t_ImageWriter t_LanguageGuess t_PermissionCheck t_SaneTestBackend t_TextRecognizer

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ifeq ($(gcov),yes)
ADDITIONAL_OBJCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_OBJCCFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_LDFLAGS += -ftest-coverage -fprofile-arcs
ADDITIONAL_TOOL_LIBS+=-lgcov
endif

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated


t_ImageAnalysis_OBJC_FILES=t_ImageAnalysis.m
t_ImageBuilder_OBJC_FILES=t_ImageBuilder.m
t_ImageWriter_OBJC_FILES=t_ImageWriter.m
t_LanguageGuess_OBJC_FILES=t_LanguageGuess.m
t_PermissionCheck_OBJC_FILES=t_PermissionCheck.m
t_SaneTestBackend_OBJC_FILES=t_SaneTestBackend.m
t_TextRecognizer_OBJC_FILES=t_TextRecognizer.m

-include GNUmakefile.preamble
-include make-check.mak
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum


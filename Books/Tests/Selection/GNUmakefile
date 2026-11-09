include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_TextSelection t_TextExtraction t_CopyToPasteboard

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_CPPFLAGS += -I../..

t_TextSelection_OBJC_FILES = t_TextSelection.m
t_TextExtraction_OBJC_FILES = t_TextExtraction.m
t_CopyToPasteboard_OBJC_FILES = t_CopyToPasteboard.m

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make

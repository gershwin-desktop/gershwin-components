#
# Headless unit tests for Stickies. Build with "gmake", then run each
# ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_StickyNoteViewCursor t_StickyNoteDocumentScrollPosition

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wall

t_StickyNoteViewCursor_OBJC_FILES = t_StickyNoteViewCursor.m \
	../../StickyNoteView.m
t_StickyNoteViewCursor_TOOL_LIBS += -lgnustep-gui

t_StickyNoteDocumentScrollPosition_OBJC_FILES = t_StickyNoteDocumentScrollPosition.m \
	../../StickyNoteDocument.m ../../StickyNoteColors.m
t_StickyNoteDocumentScrollPosition_TOOL_LIBS += -lgnustep-gui

include $(GNUSTEP_MAKEFILES)/test-tool.make

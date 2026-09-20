#
# Headless unit tests for the Profiler model. Build with "gmake", then run
# each ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_PRDemangler t_PRParsers t_PRProfile

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Model
ADDITIONAL_OBJCFLAGS += -Wall

# The model is built with ARC; the test tools themselves are not, because
# the ObjectTesting macros retain and release explicitly.
ARCFLAGS = -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
PRSymbol.m_FILE_FLAGS += $(ARCFLAGS)
PRObjCDemangler.m_FILE_FLAGS += $(ARCFLAGS)
PRCallNode.m_FILE_FLAGS += $(ARCFLAGS)
PRProfile.m_FILE_FLAGS += $(ARCFLAGS)
PRStackParser.m_FILE_FLAGS += $(ARCFLAGS)

MODEL_FILES = ../../Sources/Model/PRSymbol.m ../../Sources/Model/PRObjCDemangler.m \
	../../Sources/Model/PRCallNode.m ../../Sources/Model/PRProfile.m \
	../../Sources/Model/PRStackParser.m

t_PRDemangler_OBJC_FILES = t_PRDemangler.m $(MODEL_FILES)
t_PRParsers_OBJC_FILES = t_PRParsers.m $(MODEL_FILES)
t_PRProfile_OBJC_FILES = t_PRProfile.m $(MODEL_FILES)

include $(GNUSTEP_MAKEFILES)/test-tool.make

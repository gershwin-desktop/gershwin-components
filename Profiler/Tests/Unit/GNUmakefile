#
# Headless unit tests for the Profiler model. Build with "gmake", then run
# each ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_PRDemangler t_PRParsers t_PRProfile t_PRLegend t_PRCensus t_PRMemoryMap t_PRAllocationTrace

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Model -I../../Sources/Views -I../../Sources/Backends
ADDITIONAL_OBJCFLAGS += -Wall

# The model is built with ARC; the test tools themselves are not, because
# the ObjectTesting macros retain and release explicitly.
ARCFLAGS = -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
# The flags are keyed by the path each file is listed with below.
../../Sources/Model/PRSymbol.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRObjCDemangler.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRCallNode.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRProfile.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRStackParser.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRFormat.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRCensus.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRMemoryMap.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Model/PRAllocationTrace.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Backends/PRPrivilegedTask.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Backends/PRRecorder.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Views/PRAppearance.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Views/PRFlameGraphView.m_FILE_FLAGS += $(ARCFLAGS)
../../Sources/Views/PRLegendView.m_FILE_FLAGS += $(ARCFLAGS)

MODEL_FILES = ../../Sources/Model/PRFormat.m ../../Sources/Model/PRSymbol.m ../../Sources/Model/PRObjCDemangler.m \
	../../Sources/Model/PRCallNode.m ../../Sources/Model/PRProfile.m \
	../../Sources/Model/PRStackParser.m

t_PRDemangler_OBJC_FILES = t_PRDemangler.m $(MODEL_FILES)
t_PRParsers_OBJC_FILES = t_PRParsers.m $(MODEL_FILES)
t_PRProfile_OBJC_FILES = t_PRProfile.m $(MODEL_FILES)
t_PRCensus_OBJC_FILES = t_PRCensus.m ../../Sources/Model/PRCensus.m
t_PRMemoryMap_OBJC_FILES = t_PRMemoryMap.m ../../Sources/Model/PRMemoryMap.m
t_PRAllocationTrace_OBJC_FILES = t_PRAllocationTrace.m \
	../../Sources/Model/PRAllocationTrace.m \
	../../Sources/Backends/PRPrivilegedTask.m \
	../../Sources/Backends/PRRecorder.m $(MODEL_FILES)

# The legend is built by the flame graph, so this one needs the views too.
VIEW_FILES = ../../Sources/Views/PRAppearance.m \
	../../Sources/Views/PRFlameGraphView.m ../../Sources/Views/PRLegendView.m
t_PRLegend_OBJC_FILES = t_PRLegend.m $(MODEL_FILES) $(VIEW_FILES)
t_PRLegend_TOOL_LIBS += -lgnustep-gui

include $(GNUSTEP_MAKEFILES)/test-tool.make

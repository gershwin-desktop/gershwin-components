#
# Headless unit tests for the Display pane's layout model and its pure
# geometry and mode decisions. Build with "gmake -j1" (both tools compile the
# same model sources), then run each ./obj/t_* tool. No X display is needed.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_DisplayArrangement t_DisplayLayout t_DisplayConfiguration \
	t_DisplaySystemDefaults t_DisplayScaleHeuristic t_DisplayScaledResolution \
	t_DisplayOutputScale

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wall

MODEL_FILES = ../../DisplayLayout.m ../../DisplayArrangement.m ../../DisplayConfiguration.m \
	../../DisplaySystemDefaults.m ../../DisplayScaleHeuristic.m \
	../../DisplayScaledResolution.m

t_DisplayArrangement_OBJC_FILES = t_DisplayArrangement.m $(MODEL_FILES)
t_DisplayLayout_OBJC_FILES = t_DisplayLayout.m $(MODEL_FILES)
t_DisplayConfiguration_OBJC_FILES = t_DisplayConfiguration.m $(MODEL_FILES)
t_DisplaySystemDefaults_OBJC_FILES = t_DisplaySystemDefaults.m $(MODEL_FILES)
t_DisplayScaleHeuristic_OBJC_FILES = t_DisplayScaleHeuristic.m $(MODEL_FILES)
t_DisplayScaledResolution_OBJC_FILES = t_DisplayScaledResolution.m $(MODEL_FILES)
t_DisplayOutputScale_OBJC_FILES = t_DisplayOutputScale.m $(MODEL_FILES)

include $(GNUSTEP_MAKEFILES)/test-tool.make

# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# Headless unit tests for the Processes model. Build with "gmake", then run
# each ./obj/t_* tool.

include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_ProcessHealth t_ProcessInfo t_SparklineView

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wall

# The analyzer is built with ARC like it is in the application; the test tool
# itself is not, because the ObjectTesting macros retain and release
# explicitly.  The flags are keyed by the path the file is listed with.
ARCFLAGS = -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
../../ProcessHealth.m_FILE_FLAGS += $(ARCFLAGS)
../../SparklineView.m_FILE_FLAGS += $(ARCFLAGS)
../../ProcessInfo.m_FILE_FLAGS += $(ARCFLAGS)

t_ProcessHealth_OBJC_FILES = t_ProcessHealth.m ../../ProcessHealth.m

t_ProcessInfo_OBJC_FILES = t_ProcessInfo.m ../../ProcessInfo.m ../../ProcessHealth.m

t_SparklineView_OBJC_FILES = t_SparklineView.m ../../SparklineView.m
t_SparklineView_TOOL_LIBS += -lgnustep-gui

include $(GNUSTEP_MAKEFILES)/test-tool.make

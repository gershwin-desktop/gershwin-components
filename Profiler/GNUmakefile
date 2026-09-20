#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Profiler
LIBRARY_NAME = libPRCensus
VERSION = 1.0

# Preloaded into the program that is being watched, so it must not drag any
# of our own libraries in: it looks everything up in whatever the program has
# loaded already and stays a plain C shared object.
libPRCensus_C_FILES = Sources/Census/PRCensusShim.c
libPRCensus_LIBRARIES_DEPEND_UPON = -lpthread
libPRCensus_CFLAGS = -Wall -Wextra -O2

Profiler_OBJC_FILES = \
	Sources/main.m \
	Sources/AppDelegate.m \
	Sources/Model/PRSymbol.m \
	Sources/Model/PRObjCDemangler.m \
	Sources/Model/PRCallNode.m \
	Sources/Model/PRProfile.m \
	Sources/Model/PRStackParser.m \
	Sources/Model/PRProcessInfo.m \
	Sources/Model/PRProcessMonitor.m \
	Sources/Model/PRCensus.m \
	Sources/Model/PRMemoryMap.m \
	Sources/Model/PRMemoryMapReader.m \
	Sources/Backends/PRPrivilegedTask.m \
	Sources/Backends/PRRecorder.m \
	Sources/Backends/PRPerfRecorder.m \
	Sources/Backends/PRHeaptrackRecorder.m \
	Sources/Backends/PRDTraceRecorder.m \
	Sources/Backends/PRRecorderFactory.m \
	Sources/Backends/PRCensusClient.m \
	Sources/Views/PRAppearance.m \
	Sources/Views/PRLegendView.m \
	Sources/Views/PRFlameGraphView.m \
	Sources/Views/PRTimelineView.m \
	Sources/Views/PRLiveGraphView.m \
	Sources/Views/PRCallTreeController.m \
	Sources/Views/PRFlatTableController.m \
	Sources/Controllers/PRRecordPanelController.m \
	Sources/Controllers/PRObjectCensusController.m \
	Sources/Controllers/PRMemoryWindowController.m \
	Sources/Controllers/PRProfilerWindowController.m

Profiler_HEADER_FILES_DIR = Sources
Profiler_HEADER_FILES = \
	AppDelegate.h \
	AppearanceMetrics.h \
	Model/PRTypes.h \
	Model/PRSymbol.h \
	Model/PRObjCDemangler.h \
	Model/PRCallNode.h \
	Model/PRProfile.h \
	Model/PRStackParser.h \
	Model/PRProcessInfo.h \
	Model/PRProcessMonitor.h \
	Model/PRCensus.h \
	Model/PRMemoryMap.h \
	Model/PRMemoryMapReader.h \
	Backends/PRPrivilegedTask.h \
	Backends/PRRecorder.h \
	Backends/PRRecorderPrivate.h \
	Backends/PRPerfRecorder.h \
	Backends/PRHeaptrackRecorder.h \
	Backends/PRDTraceRecorder.h \
	Backends/PRRecorderFactory.h \
	Backends/PRCensusClient.h \
	Views/PRAppearance.h \
	Views/PRLegendView.h \
	Views/PRFlameGraphView.h \
	Views/PRTimelineView.h \
	Views/PRLiveGraphView.h \
	Views/PRCallTreeController.h \
	Views/PRFlatTableController.h \
	Controllers/PRRecordPanelController.h \
	Controllers/PRObjectCensusController.h \
	Controllers/PRMemoryWindowController.h \
	Controllers/PRProfilerWindowController.h

Profiler_RESOURCE_FILES = Resources/Dependencies.plist Resources/Profiler.png

Profiler_MAIN_MODEL_FILE =

ADDITIONAL_INCLUDE_DIRS += -ISources -ISources/Model -ISources/Backends \
	-ISources/Views -ISources/Controllers

Profiler_OBJCFLAGS = -Wall -O2
ADDITIONAL_OBJCFLAGS += -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
Profiler_LDFLAGS = -lgnustep-base -lgnustep-gui -Wl,-rpath,/System/Library/Libraries

include $(GNUSTEP_MAKEFILES)/library.make
include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

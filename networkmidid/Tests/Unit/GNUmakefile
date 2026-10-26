#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Headless unit tests for the networkmidid protocol core.  Build with "gmake",
# then run each ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_NMDSessionMessage t_NMDRTPMIDI t_NMDMIDIStreamParser \
	t_NMDPeerConnection t_NMDLocalSession t_NMDLatencyEstimator \
	t_NMDMIDISystemProblem t_NMDPortLayerWatcher

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Protocol
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter

# The units are ARC; the test tools are not, because the ObjectTesting
# macros retain and release explicitly.  Flags are keyed by the listed path.
ARCFLAGS = -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
P = ../../Sources/Protocol
PROTOCOL_FILES = $(P)/NMDSessionMessage.m $(P)/NMDRTPMIDI.m \
	$(P)/NMDMIDIStreamParser.m $(P)/NMDPeerConnection.m $(P)/NMDLocalSession.m \
	$(P)/NMDLatencyEstimator.m \
	$(P)/NMDSocketAddress.m
$(foreach f,$(PROTOCOL_FILES),$(eval $(f)_FILE_FLAGS += $(ARCFLAGS)))

t_NMDSessionMessage_OBJC_FILES = t_NMDSessionMessage.m $(P)/NMDSessionMessage.m
t_NMDRTPMIDI_OBJC_FILES = t_NMDRTPMIDI.m $(P)/NMDRTPMIDI.m
t_NMDMIDIStreamParser_OBJC_FILES = t_NMDMIDIStreamParser.m $(P)/NMDMIDIStreamParser.m
t_NMDPeerConnection_OBJC_FILES = t_NMDPeerConnection.m $(P)/NMDSessionMessage.m \
	$(P)/NMDRTPMIDI.m $(P)/NMDPeerConnection.m $(P)/NMDLatencyEstimator.m
t_NMDLatencyEstimator_OBJC_FILES = t_NMDLatencyEstimator.m $(P)/NMDLatencyEstimator.m
t_NMDLocalSession_OBJC_FILES = t_NMDLocalSession.m $(PROTOCOL_FILES)

# The MIDI system state and its watcher use the models of
# libMIDINetworkBackend; the copy built in this tree is linked when there is
# one, so the tests run before the library is installed.
MNB_DIR = $(CURDIR)/../../../Libraries/MIDINetworkBackend
MNB_LIB := $(wildcard $(MNB_DIR)/obj/libMIDINetworkBackend.so)
MNB_TESTS = t_NMDMIDISystemProblem t_NMDPortLayerWatcher
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Ports -I../../Sources/Daemon \
	-I$(if $(MNB_LIB),$(MNB_DIR),$(GNUSTEP_SYSTEM_HEADERS)/MIDINetworkBackend)
# GNUstep.sh puts the installed libraries in LD_LIBRARY_PATH, which beats a
# DT_RUNPATH but not a DT_RPATH, hence --disable-new-dtags.
ifneq ($(MNB_LIB),)
MNB_LINK = $(MNB_LIB) -Wl,--disable-new-dtags -Wl,-rpath,$(MNB_DIR)/obj
else
MNB_LINK = -lMIDINetworkBackend
endif
$(foreach t,$(MNB_TESTS),$(eval $(t)_TOOL_LIBS += $(MNB_LINK)))
UNITS = ../../Sources/Ports/NMDMIDISystemProblem.m \
	../../Sources/Daemon/NMDPortLayerWatcher.m
$(foreach f,$(UNITS),$(eval $(f)_FILE_FLAGS += $(ARCFLAGS)))

t_NMDMIDISystemProblem_OBJC_FILES = t_NMDMIDISystemProblem.m \
	../../Sources/Ports/NMDMIDISystemProblem.m
t_NMDPortLayerWatcher_OBJC_FILES = t_NMDPortLayerWatcher.m \
	../../Sources/Daemon/NMDPortLayerWatcher.m

include $(GNUSTEP_MAKEFILES)/test-tool.make

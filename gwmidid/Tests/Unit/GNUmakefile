#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Headless unit tests for the gwmidid protocol core.  Build with "gmake",
# then run each ./obj/t_* tool.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_GMSessionMessage t_GMRTPMIDI t_GMMIDIStreamParser \
	t_GMPeerConnection t_GMLocalSession t_GMLatencyEstimator

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../../Sources/Protocol
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter

# The units are ARC; the test tools are not, because the ObjectTesting
# macros retain and release explicitly.  Flags are keyed by the listed path.
ARCFLAGS = -DGS_WITH_ARC=1 -fobjc-arc -fobjc-arc-exceptions
P = ../../Sources/Protocol
PROTOCOL_FILES = $(P)/GMSessionMessage.m $(P)/GMRTPMIDI.m \
	$(P)/GMMIDIStreamParser.m $(P)/GMPeerConnection.m $(P)/GMLocalSession.m \
	$(P)/GMLatencyEstimator.m \
	$(P)/GMSocketAddress.m
$(foreach f,$(PROTOCOL_FILES),$(eval $(f)_FILE_FLAGS += $(ARCFLAGS)))

t_GMSessionMessage_OBJC_FILES = t_GMSessionMessage.m $(P)/GMSessionMessage.m
t_GMRTPMIDI_OBJC_FILES = t_GMRTPMIDI.m $(P)/GMRTPMIDI.m
t_GMMIDIStreamParser_OBJC_FILES = t_GMMIDIStreamParser.m $(P)/GMMIDIStreamParser.m
t_GMPeerConnection_OBJC_FILES = t_GMPeerConnection.m $(P)/GMSessionMessage.m \
	$(P)/GMRTPMIDI.m $(P)/GMPeerConnection.m $(P)/GMLatencyEstimator.m
t_GMLatencyEstimator_OBJC_FILES = t_GMLatencyEstimator.m $(P)/GMLatencyEstimator.m
t_GMLocalSession_OBJC_FILES = t_GMLocalSession.m $(PROTOCOL_FILES)

include $(GNUSTEP_MAKEFILES)/test-tool.make

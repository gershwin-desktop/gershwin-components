#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# networkmidid, the per-user network MIDI (RTP-MIDI) daemon, and networkmidictl, its
# command line client.  Foundation only.
#
include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = networkmidid networkmidictl

# Started by every user's session, so it goes where the session's PATH
# finds it.
TOOL_INSTALL_DIR = $(GNUSTEP_SYSTEM_TOOLS)

UNAME_S := $(shell uname -s)

PROTOCOL_FILES = \
	Sources/Protocol/NMDSessionMessage.m \
	Sources/Protocol/NMDRTPMIDI.m \
	Sources/Protocol/NMDMIDIStreamParser.m \
	Sources/Protocol/NMDPeerConnection.m \
	Sources/Protocol/NMDLocalSession.m \
	Sources/Protocol/NMDSocketAddress.m \
	Sources/Protocol/NMDLatencyEstimator.m

networkmidid_OBJC_FILES = \
	$(PROTOCOL_FILES) \
	Sources/Transport/NMDDescriptorWatcher.m \
	Sources/Transport/NMDUDPEndpoint.m \
	Sources/Ports/NMDALSASequencer.m \
	Sources/Discovery/NMDServiceDirectory.m \
	Sources/Daemon/NMDDaemon.m \
	Sources/Daemon/main.m

networkmidictl_OBJC_FILES = Sources/Control/networkmidictl.m

# The models, the configuration rules and the control interface are shared
# with the MIDI pane in libMIDINetworkBackend.  The library in this tree is
# used when it has been built, so networkmidid can be built and tested before
# the library is installed; otherwise the installed one.
MNB_DIR = $(CURDIR)/../Libraries/MIDINetworkBackend
MNB_LIB := $(wildcard $(MNB_DIR)/obj/libMIDINetworkBackend.so)
ifneq ($(MNB_LIB),)
ADDITIONAL_INCLUDE_DIRS += -I$(MNB_DIR)
ADDITIONAL_LIB_DIRS += -L$(MNB_DIR)/obj
else
ADDITIONAL_INCLUDE_DIRS += -I$(GNUSTEP_SYSTEM_HEADERS)/MIDINetworkBackend
endif
networkmidid_TOOL_LIBS += -lMIDINetworkBackend
networkmidictl_TOOL_LIBS += -lMIDINetworkBackend

ADDITIONAL_INCLUDE_DIRS += -ISources/Protocol -ISources/Transport \
	-ISources/Ports -ISources/Discovery -ISources/Daemon
ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall -Wextra -Wno-unused-parameter

# The MIDI port layer is the ALSA sequencer, through alsa-seq-server on the
# BSDs.  OpenBSD has no ALSA; networkmidid builds there but reports that it has
# no port layer until the sndio one exists.
ifeq ($(UNAME_S),OpenBSD)
ADDITIONAL_OBJCFLAGS += -DNMD_HAVE_ALSA=0
else
ADDITIONAL_OBJCFLAGS += -DNMD_HAVE_ALSA=1
networkmidid_TOOL_LIBS += -lasound
endif
ifneq ($(filter FreeBSD NextBSD,$(UNAME_S)),)
ADDITIONAL_INCLUDE_DIRS += -I/usr/local/include
ADDITIONAL_LIB_DIRS += -L/usr/local/lib
endif

include $(GNUSTEP_MAKEFILES)/tool.make

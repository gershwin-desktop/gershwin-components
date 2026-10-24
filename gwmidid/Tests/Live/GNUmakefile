#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# The MIDI pane's client (MIDINetworkDaemonBackend) against a real, running
# gwmidid.  Run through run-live-control.sh, which starts gwmidid with its
# own defaults directory.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_LiveControl
t_LiveControl_OBJC_FILES = t_LiveControl.m

MNB_DIR := $(CURDIR)/../../../Libraries/MIDINetworkBackend
MNB_LIB := $(wildcard $(MNB_DIR)/obj/libMIDINetworkBackend.so)

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I$(MNB_DIR) -I$(MNB_DIR)/Tests
ADDITIONAL_OBJCFLAGS += -Wall -Wno-unused-parameter
ADDITIONAL_TOOL_LIBS += $(if $(MNB_LIB),$(MNB_LIB),-lMIDINetworkBackend)
ADDITIONAL_LDFLAGS += -Wl,--disable-new-dtags -Wl,-rpath,$(MNB_DIR)/obj

include $(GNUSTEP_MAKEFILES)/test-tool.make

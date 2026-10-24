include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libMIDINetworkBackend
VERSION = 1.0

# Shared by the MIDI pane and gwmidid: the models, the consistency rules
# (MIDINetworkState) and the control interface must be one copy for both,
# so the sources live here rather than in either consumer.
libMIDINetworkBackend_OBJC_FILES = \
	MIDINetworkModels.m \
	MIDINetworkState.m \
	MIDINetworkBaseBackend.m \
	MIDINetworkFakeBackend.m \
	MIDINetworkControl.m \
	MIDINetworkDaemonBackend.m \
	MIDINetworkBackendFactory.m

libMIDINetworkBackend_HEADER_FILES = \
	MIDINetworkModels.h \
	MIDINetworkState.h \
	MIDINetworkBackend.h \
	MIDINetworkBaseBackend.h \
	MIDINetworkFakeBackend.h \
	MIDINetworkControl.h \
	MIDINetworkDaemonBackend.h \
	MIDINetworkBackendFactory.h

libMIDINetworkBackend_HEADER_FILES_INSTALL_DIR = MIDINetworkBackend
libMIDINetworkBackend_FRAMEWORKS_DEPEND_UPON = Foundation

libMIDINetworkBackend_OBJCFLAGS += -Wall -Wextra -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/library.make

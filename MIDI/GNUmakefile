include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = MIDI

MIDI_OBJC_FILES = \
	MIDIPane.m \
	MIDIPaneController.m \
	MIDIPaneViewState.m \
	MIDIAddHostPanel.m

MIDI_RESOURCE_FILES = MIDI.png
MIDI_LOCALIZED_RESOURCE_FILES = Localizable.strings
MIDI_LANGUAGES = English German
MIDI_BUNDLE_LIBS = -lPreferencePanes -lMIDINetworkBackend
MIDI_PRINCIPAL_CLASS = MIDIPane

# The installed library headers by default; a build against an uninstalled
# library passes MIDINET_INCLUDE and ADDITIONAL_LIB_DIRS on the command line.
MIDINET_INCLUDE ?= $(GNUSTEP_SYSTEM_HEADERS)/MIDINetworkBackend
ADDITIONAL_INCLUDE_DIRS += -I$(MIDINET_INCLUDE)
ADDITIONAL_OBJCFLAGS += -Wall -fobjc-arc -fobjc-arc-exceptions

PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

# Install to /System/Library/Bundles/MIDI.prefPane, where System
# Preferences looks for SYSTEM panes, instead of the bundle default.
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION)
	mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR)
	rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION)
	cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/

uninstall:: custom-uninstall

custom-uninstall:
	rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION)

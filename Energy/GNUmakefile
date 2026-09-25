include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

Energy_OBJCFLAGS += -Wall -Wextra -Werror -O2 -I/System/Library/Headers/CPUGovernorBackend

BUNDLE_NAME = Energy
Energy_OBJC_FILES = EnergyPane.m EnergyController.m
Energy_RESOURCE_FILES = Energy.png
# The governor list/read/write logic lives in libCPUGovernorBackend (built
# from Libraries/CPUGovernorBackend, sources in this directory), shared with
# the Battery menu extra the same way Sound shares -lSoundBackend with the
# Sound menu extra - one backend, not two copies of the governor logic.
Energy_BUNDLE_LIBS = -lPreferencePanes -lCPUGovernorBackend
Energy_PRINCIPAL_CLASS = EnergyPane
PREF_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
BUNDLE_EXTENSION = .prefPane

include $(GNUSTEP_MAKEFILES)/bundle.make

.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(BUNDLE_NAME)$(BUNDLE_EXTENSION)
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(BUNDLE_NAME) to $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(DESTDIR)$(PREF_INSTALL_DIR)/; \
	else \
		echo "Installing $(BUNDLE_NAME) to $(PREF_INSTALL_DIR)"; \
		mkdir -p $(PREF_INSTALL_DIR); \
		cp -R $(BUNDLE_NAME)$(BUNDLE_EXTENSION) $(PREF_INSTALL_DIR)/; \
	fi

uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(BUNDLE_NAME) from $(DESTDIR)$(PREF_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	else \
		echo "Uninstalling $(BUNDLE_NAME) from $(PREF_INSTALL_DIR)"; \
		rm -rf $(PREF_INSTALL_DIR)/$(BUNDLE_NAME)$(BUNDLE_EXTENSION); \
	fi

$(BUNDLE_NAME).install.bundle.variables::
	@true

shared-instance-bundle-install::
	@true

internal-bundle-install::
	@true

.PHONY: install uninstall


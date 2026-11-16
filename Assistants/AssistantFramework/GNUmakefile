include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Framework configuration
FRAMEWORK_NAME = GSAssistantFramework
VERSION = 1.0

# Source files
GSAssistantFramework_OBJC_FILES = \
	GSAssistantWindow.m \
	GSAssistantSteps.m \
	GSAssistantUtilities.m \
	GSNetworkUtilities.m \
	GSDiskUtilities.m \
	GSSelectionStep.m \
	GSEnhancedProgressStep.m \
	GSStepBulletView.m \
	GSLocaleHelper.m \
	KeyboardManager.m

# Header files to install
GSAssistantFramework_HEADER_FILES = \
	GSAssistantFramework.h \
	GSAssistantUtilities.h \
	GSNetworkUtilities.h \
	GSDiskUtilities.h \
	GSSelectionStep.h \
	GSEnhancedProgressStep.h \
	GSStepBulletView.h \
	GSLocaleHelper.h \
	KeyboardManager.h

# Headers that should be included in the framework headers
GSAssistantFramework_HEADER_FILES_INSTALL_DIR = GSAssistantFramework

# Resource files to include in the framework.  The localized tables have to be
# part of the framework wrapper itself: the steps look strings up through
# getFrameworkBundle(), which resolves to this bundle, so without them the
# framework's own UI (Go Back, Setup Complete, ...) stays untranslated.
GSAssistantFramework_RESOURCE_FILES = \
	Resources/check.png \
	Resources/cross.png \
	Resources/en.lproj \
	Resources/de.lproj

# Required frameworks and libraries
GSAssistantFramework_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

# Compiler and linker flags
GSAssistantFramework_CPPFLAGS += -Wall -Wextra -fobjc-arc -Werror -Wno-unused-parameter -O2 -I/usr/include
GSAssistantFramework_LDFLAGS += -ldispatch -lX11 -lutil

# Installation directory
FRAMEWORK_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Frameworks

include $(GNUSTEP_MAKEFILES)/framework.make

# The localized tables are copied explicitly after custom-install: the
# default after-install hook runs *before* custom-install, and
# custom-install does a fresh cp -R of the built wrapper, which would
# otherwise wipe whatever after-install put there.
copy-localized-resources::
	@echo "Manually copying localized resources..."
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj
	mkdir -p $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj
	if [ -f Resources/en.lproj/Localizable.strings ]; then cp Resources/en.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/Localizable.strings ]; then cp Resources/de.lproj/Localizable.strings $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/Welcome.txt ]; then cp Resources/en.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/Welcome.txt ]; then cp Resources/de.lproj/Welcome.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/ReadMe.txt ]; then cp Resources/en.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/ReadMe.txt ]; then cp Resources/de.lproj/ReadMe.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	if [ -f Resources/en.lproj/License.txt ]; then cp Resources/en.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/en.lproj/; fi
	if [ -f Resources/de.lproj/License.txt ]; then cp Resources/de.lproj/License.txt $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework/Versions/1/Resources/de.lproj/; fi
	@echo "Localized resources copied to framework"

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall copy-localized-resources

install:: custom-install copy-localized-resources

# A framework bundle contains symlinks (Versions/Current, Resources, Headers).
# Copying over an existing install makes cp descend into those symlinked
# directories: GNU cp replaces the link, but BSD cp refuses with
#   "cannot overwrite directory ... with non-directory"
# which broke reinstalls on OpenBSD. Remove the old bundle first so the copy
# always lands on a clean target.
custom-install: $(FRAMEWORK_NAME).framework
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(FRAMEWORK_NAME) to $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(DESTDIR)$(FRAMEWORK_INSTALL_DIR); \
		rm -rf $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
		cp -R $(FRAMEWORK_NAME).framework $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/; \
	else \
		echo "Installing $(FRAMEWORK_NAME) to $(FRAMEWORK_INSTALL_DIR)"; \
		mkdir -p $(FRAMEWORK_INSTALL_DIR); \
		rm -rf $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
		cp -R $(FRAMEWORK_NAME).framework $(FRAMEWORK_INSTALL_DIR)/; \
	fi

# Override uninstall target to properly support DESTDIR
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)"; \
		rm -rf $(DESTDIR)$(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	else \
		echo "Uninstalling $(FRAMEWORK_NAME) from $(FRAMEWORK_INSTALL_DIR)"; \
		rm -rf $(FRAMEWORK_INSTALL_DIR)/$(FRAMEWORK_NAME).framework; \
	fi

# Override built-in install targets to do nothing
internal-framework-install::
	@true

shared-instance-framework-install::
	@true

# Development helpers
debug:
	@echo "Framework files:"
	@echo "  Source files: $(GSAssistantFramework_OBJC_FILES)"
	@echo "  Header files: $(GSAssistantFramework_HEADER_FILES)"
	@echo "  Install dir: $(FRAMEWORK_INSTALL_DIR)"
	@echo "  DESTDIR: $(DESTDIR)"

clean::
	@echo "Cleaning $(FRAMEWORK_NAME)..."
	rm -rf $(FRAMEWORK_NAME).framework
	rm -rf obj
	rm -rf derived_src

# Test target
test: TestNewLayout
	@echo "Running layout test..."
	@echo "Note: Run './obj/TestNewLayout' to test both layout styles"


include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = SoftwareUpdate
PACKAGE_NAME = SoftwareUpdate
SoftwareUpdate_PRINCIPAL_CLASS = NSApplication
SoftwareUpdate_APPLICATION_ICON = SoftwareUpdate.png

SoftwareUpdate_OBJC_FILES = \
  main.m \
  Models/SWRepository.m \
  Models/SWRepositoryList.m \
  Models/SWGitTool.m \
  Models/SWGitHubBuildStatus.m \
  Models/SWSelectionRules.m \
  Models/SWUpdateChecker.m \
  Models/SWRepositoryUpdater.m \
  Models/SWPrerequisitesInstaller.m \
  Controllers/SWAppDelegate.m \
  Controllers/SWCheckingWindowController.m \
  Controllers/SWMainWindowController.m \
  Controllers/SWProgressPhase.m \
  Controllers/SWProgressWindowController.m \
  Controllers/SWStashAlertController.m \
  Controllers/SWCompletionWindowController.m

SoftwareUpdate_RESOURCE_FILES = \
  Resources/SoftwareUpdate.png \
  Resources/SoftwareUpdate@2x.png \
  Resources/Caution.png \
  Resources/Caution@2x.png \
  Resources/StatusDone.png \
  Resources/StatusDone@2x.png \
  Resources/StatusPending.png \
  Resources/StatusPending@2x.png \
  Resources/StatusRunning.png \
  Resources/StatusRunning@2x.png \
  Resources/StatusSkipped.png \
  Resources/StatusSkipped@2x.png \
  Resources/StatusWarning.png \
  Resources/StatusWarning@2x.png

# Controllers/ import Models/ headers unqualified (e.g. "SWRepository.h").
ADDITIONAL_OBJCFLAGS += -IModels

# ARC throughout, matching PackageManager/OnDemand.
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_OBJCFLAGS += -Wall -Wextra
ADDITIONAL_OBJCFLAGS += -Wno-nullability-completeness -Wno-unused-parameter

# Link against the PackageManager framework (installed system-wide by
# gmake install in PackageManager/) for its shared log window and eventually
# the prerequisite-package install path; do not embed it.
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

SoftwareUpdate_FRAMEWORKS_DEPEND_UPON = AppKit Foundation
ADDITIONAL_LDFLAGS += -ldispatch

# Software Update belongs in /System/Applications/Utilities, like the other
# system tools - and nowhere else. Without this the plain install target
# (and so AGENTS' `gmake install`) puts a second copy in /System/Applications,
# which make_services then reports as a duplicate app, leaving it to the
# search order to decide which one actually launches.
SoftwareUpdate_INSTALL_DIR = /System/Applications/Utilities

include $(GNUSTEP_MAKEFILES)/application.make

SUDO := $(shell if [ "$$(id -u)" = "0" ]; then echo ""; \
	elif command -v sudo >/dev/null 2>&1; then echo "sudo"; \
	else echo ""; fi)

system-install: $(APP_NAME).app
	$(SUDO) mkdir -p /System/Applications/Utilities
	$(SUDO) rm -rf /System/Applications/Utilities/$(APP_NAME).app
	$(SUDO) cp -R $(APP_NAME).app /System/Applications/Utilities/
	$(SUDO) chmod -R a+rX /System/Applications/Utilities/$(APP_NAME).app
	$(SUDO) make_services
	@echo "Installed $(APP_NAME).app to /System/Applications/Utilities/; services database updated"

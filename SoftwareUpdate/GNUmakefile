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
  Models/SWCompletionSummary.m \
  Models/SWRunGuard.m \
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

# Do not invoke sudo unconditionally. Image builds and CI run as root, and a
# stock FreeBSD/OpenBSD install has no sudo at all, so this failed with
# "sudo: No such file or directory" (exit 127). Use it only when we are not
# root and it is actually available.
SUDO := $(shell if [ "$$(id -u)" = "0" ]; then echo ""; \
	elif command -v sudo >/dev/null 2>&1; then echo "sudo"; \
	else echo ""; fi)

# Where a build from before SoftwareUpdate_INSTALL_DIR pinned this app to
# Utilities used to land. make_services scans /System/Applications before it
# descends into Utilities and keeps the *first* app of a given name, so a
# leftover copy here is not merely wasted disk - it is the one the menu, the
# Dock and Workspace all launch. Software Update then installs itself into
# Utilities forever without ever being the build that runs, which is how a
# Sep 26 04:45 binary kept answering checks long after the fixes for them had
# been committed. Every install clears the old path, so the app can update
# itself at all.
.PHONY: remove-legacy-install
install:: remove-legacy-install

remove-legacy-install:
	@if [ -d /System/Applications/$(APP_NAME).app ]; then \
		echo "Removing leftover /System/Applications/$(APP_NAME).app (it shadowed the Utilities install)"; \
		$(SUDO) rm -rf /System/Applications/$(APP_NAME).app; \
	fi

# make_services is what actually decides which path a launched app resolves
# to, and the plain install target never runs it, so without this the app list
# keeps naming whatever was on disk the last time some component remembered to
# register itself - which is how a freshly installed build can sit on disk and
# never be the one that launches. It writes into the desktop user's
# ~/Library/Services, the copy Workspace actually reads, so it has to run as
# that user rather than as the root that installed the app. Same reason, and
# same shape, as Books.
MAKE_SERVICES := /System/Library/Tools/make_services
.PHONY: after-install
after-install::
	-@if [ -x "$(MAKE_SERVICES)" ]; then \
		u="$$SUDO_USER"; [ -z "$$u" ] && u=`whoami`; \
		if [ "$$u" != "root" ] && id "$$u" >/dev/null 2>&1; then \
			su "$$u" -c "$(MAKE_SERVICES)" >/dev/null 2>&1 || true; \
		else \
			"$(MAKE_SERVICES)" >/dev/null 2>&1 || true; \
		fi; \
	fi

include $(GNUSTEP_MAKEFILES)/application.make

system-install: $(APP_NAME).app
	$(SUDO) rm -rf /System/Applications/$(APP_NAME).app
	$(SUDO) mkdir -p /System/Applications/Utilities
	$(SUDO) rm -rf /System/Applications/Utilities/$(APP_NAME).app
	$(SUDO) cp -R $(APP_NAME).app /System/Applications/Utilities/
	$(SUDO) chmod -R a+rX /System/Applications/Utilities/$(APP_NAME).app
	$(MAKE) after-install
	@echo "Installed $(APP_NAME).app to /System/Applications/Utilities/; services database updated"

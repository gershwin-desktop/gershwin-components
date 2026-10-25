#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# displayconfig: applies the user's saved display layout for the monitors
# that are connected (the WindowManager runs it at login and on hotplug),
# saves the current one, and writes the system-wide scale for LoginWindow.
# It is built from the Display pane's own model and X11 sources, so the
# pane and the tool can never disagree about a layout.
#
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = displayconfig
DISPLAY_DIR = ../Display
displayconfig_OBJC_FILES = main.m \
	$(DISPLAY_DIR)/DisplayLayout.m \
	$(DISPLAY_DIR)/DisplayArrangement.m \
	$(DISPLAY_DIR)/DisplayConfiguration.m \
	$(DISPLAY_DIR)/X11DisplayManager.m
displayconfig_TOOL_LIBS = -lXrandr -lX11
ADDITIONAL_INCLUDE_DIRS += -I$(DISPLAY_DIR)
ADDITIONAL_OBJCFLAGS += -Wall

# sudo is found the same way as by every other privileged step of the
# desktop (GWSudoCommand of the installed PackageManager framework).
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers -Wno-nullability-completeness
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

include $(GNUSTEP_MAKEFILES)/tool.make

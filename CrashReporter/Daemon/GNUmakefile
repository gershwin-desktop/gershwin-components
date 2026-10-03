# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gs-crashd

# GSCrashReport and friends are compiled directly into this tool (not linked as
# a dylib) so the GSCrashReport class lives in the main image. Linking it as a
# separate dylib makes GNUstep's atexit class-walk dereference dangling class
# pointers at process exit.
gs-crashd_OBJC_FILES = \
    gs-crashd.m GSCrashDetector.m GSCrashCollector.m \
    ../Library/GSCrashConstants.m \
    ../Library/GSCrashReport.m \
    ../Library/GSCrashReporter.m \
    ../Library/GSCrashPlatformLinux.m \
    ../Library/GSCrashPlatformGeneric.m
gs-crashd_C_FILES = ../Library/gscrash_marker.c

ADDITIONAL_OBJCFLAGS += -fobjc-arc $(shell gnustep-config --objc-flags) -I$(CURDIR)/../Library
ADDITIONAL_CFLAGS += -I$(CURDIR)/../Library

include $(GNUSTEP_MAKEFILES)/tool.make

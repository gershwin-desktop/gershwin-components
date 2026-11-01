# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gs-crashctl gs-crash-test

gs-crashctl_OBJC_FILES = \
    gs-crashctl.m \
    ../Library/GSCrashConstants.m \
    ../Library/GSCrashReport.m \
    ../Library/GSCrashReporter.m \
    ../Library/GSCrashPlatformLinux.m \
    ../Library/GSCrashPlatformGeneric.m
gs-crash-test_OBJC_FILES = \
    gs-crash-test.m \
    ../Library/GSCrashConstants.m \
    ../Library/GSCrashReport.m \
    ../Library/GSCrashReporter.m \
    ../Library/GSCrashPlatformLinux.m \
    ../Library/GSCrashPlatformGeneric.m
gs-crashctl_C_FILES = ../Library/gscrash_marker.c
gs-crash-test_C_FILES = ../Library/gscrash_marker.c

ADDITIONAL_OBJCFLAGS += -fobjc-arc $(shell gnustep-config --objc-flags) -I$(CURDIR)/../Library
ADDITIONAL_CFLAGS += -I$(CURDIR)/../Library

include $(GNUSTEP_MAKEFILES)/tool.make

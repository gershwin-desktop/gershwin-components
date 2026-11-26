# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later

include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = gs-crash-analyzer

gs-crash-analyzer_OBJC_FILES = \
    gs-crash-analyzer.m GSCrashAnalyzer.m \
    ../Library/GSCrashConstants.m \
    ../Library/GSCrashReport.m \
    ../Library/GSCrashReporter.m \
    ../Library/GSCrashPlatformLinux.m \
    ../Library/GSCrashPlatformGeneric.m
gs-crash-analyzer_C_FILES = ../Library/gscrash_marker.c

ADDITIONAL_OBJCFLAGS += -fobjc-arc $(shell gnustep-config --objc-flags) -I$(CURDIR)/../Library
ADDITIONAL_CFLAGS += -I$(CURDIR)/../Library

include $(GNUSTEP_MAKEFILES)/tool.make

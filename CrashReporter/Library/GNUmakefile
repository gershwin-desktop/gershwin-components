# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later

include $(GNUSTEP_MAKEFILES)/common.make

# Built as a STATIC library: the GSCrashReport class then lives in each
# executable's own image (not a separately-unloaded dylib), which avoids a
# GNUstep atexit class-walk crashing on dangling class pointers at process exit.
LIBRARY_NAME = libGSCrashReporter
libGSCrashReporter_OBJC_FILES = \
    GSCrashConstants.m \
    GSCrashReport.m \
    GSCrashReporter.m \
    GSCrashPlatformLinux.m \
    GSCrashPlatformGeneric.m
libGSCrashReporter_C_FILES = gscrash_marker.c

libGSCrashReporter_HEADER_FILES = \
    GSCrashConstants.h \
    GSCrashReport.h \
    GSCrashPlatform.h \
    GSCrashReporter.h \
    gscrash_marker.h \
    libGSCrashReporter.h

ADDITIONAL_CFLAGS += -fobjc-arc $(shell gnustep-config --objc-flags)

include $(GNUSTEP_MAKEFILES)/library.make

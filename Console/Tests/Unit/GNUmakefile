# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause

#
# Headless unit tests for the Console syslog line parser. Build with
# "gmake", then run ./obj/t_SyslogParse.
#
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_SyslogParse

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wall -Wno-import

t_SyslogParse_OBJC_FILES = t_SyslogParse.m ../../LogEntry.m ../../LogSource.m

include $(GNUSTEP_MAKEFILES)/test-tool.make

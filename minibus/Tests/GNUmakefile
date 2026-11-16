# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause
#
# Test tools for minibus, ObjectTesting convention. Build with gmake, run
# the tools directly (./obj/t_*) or use run.sh. Do not use gnustep-tests: it
# rewrites this file.
include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_Sasl t_Hello t_Validation t_Names t_BusMethods t_Match \
                 t_Monitor t_Routing t_Fds t_Scale t_Cli t_System

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
ADDITIONAL_CFLAGS += -std=gnu11 -Wall

# all tools link the independent wire client and the daemon launcher
$(foreach t,$(TEST_TOOL_NAME),$(eval $(t)_OBJC_FILES = $(t).m))
$(foreach t,$(TEST_TOOL_NAME),$(eval $(t)_C_FILES = wire.c harness.c))

include $(GNUSTEP_MAKEFILES)/test-tool.make

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Plain C: the supervisor has no use for a Foundation runtime (see the
# comment in gershwin-session.c).
TOOL_NAME = gershwin-session
gershwin-session_C_FILES = gershwin-session.c
gershwin-session_TOOL_LIBS =

ADDITIONAL_CFLAGS = -Wall -Wextra

# gnustep-make links the Foundation libraries into every tool; this program
# uses none of them, and --as-needed keeps them from being loaded at all.
ADDITIONAL_LDFLAGS += -Wl,--as-needed

# Install into /System/Library/Tools so every user session can find it on
# the standard tool PATH.
TOOL_INSTALL_DIR = $(GNUSTEP_SYSTEM_TOOLS)

include $(GNUSTEP_MAKEFILES)/tool.make

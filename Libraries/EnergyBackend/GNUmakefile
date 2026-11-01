include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libEnergyBackend
VERSION = 1.0

# The Energy prefPane applies backlight, blanking and power settings live and
# gershwin-apply-settings applies them again at login; both go through this
# one backend so the two never use a different path or privilege for them.
# EnergyLidCloseOnce/EnergyLidBackend are the "stay awake at lid close"
# one-shot inhibitor the Battery menu extra uses; they live here for the
# same reason (Menu links -lEnergyBackend, same as it already links
# -lCPUGovernorBackend for the governor submenu).
libEnergyBackend_OBJC_FILES = \
	../../Energy/EnergyBackend.m \
	../../Energy/EnergyLidCloseOnce.m \
	../../Energy/EnergyLidBackend.m

libEnergyBackend_HEADER_FILES_DIR = ../../Energy
libEnergyBackend_HEADER_FILES = \
	EnergyBackend.h \
	EnergyLidCloseOnce.h \
	EnergyLidBackend.h

libEnergyBackend_HEADER_FILES_INSTALL_DIR = EnergyBackend
libEnergyBackend_FRAMEWORKS_DEPEND_UPON = Foundation

libEnergyBackend_OBJCFLAGS += -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

# EnergyLidBackend.m's logind/systemd-inhibit lid watcher is Linux-only
# (#if defined(__linux__) guards every dbus_* call); only that platform
# needs libdbus's headers and library.
ENERGYBACKEND_UNAME_S := $(shell uname -s)
ifeq ($(ENERGYBACKEND_UNAME_S),Linux)
DBUS_CFLAGS := $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
libEnergyBackend_OBJCFLAGS += $(DBUS_CFLAGS)
libEnergyBackend_LIBRARIES_DEPEND_UPON += -ldbus-1
endif

include $(GNUSTEP_MAKEFILES)/library.make

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libEnergyBackend
VERSION = 1.0

# The Energy prefPane applies backlight, blanking and power settings live and
# gershwin-apply-settings applies them again at login; both go through this
# one backend so the two never use a different path or privilege for them.
libEnergyBackend_OBJC_FILES = \
	../../Energy/EnergyBackend.m

libEnergyBackend_HEADER_FILES_DIR = ../../Energy
libEnergyBackend_HEADER_FILES = \
	EnergyBackend.h

libEnergyBackend_HEADER_FILES_INSTALL_DIR = EnergyBackend
libEnergyBackend_FRAMEWORKS_DEPEND_UPON = Foundation

libEnergyBackend_OBJCFLAGS += -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/library.make

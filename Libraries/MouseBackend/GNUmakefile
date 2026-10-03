include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libMouseBackend
VERSION = 1.0

# The Mouse prefPane applies its settings live and gershwin-apply-settings
# applies them again at login; both go through this one xinput backend so the
# two can never drive different libinput properties for the same setting.
libMouseBackend_OBJC_FILES = \
	../../Mouse/MouseBackend.m \
	../../Mouse/PointerDevice.m \
	../../Mouse/AccelerationCurve.m \
	../../Mouse/MousePreferences.m

libMouseBackend_HEADER_FILES_DIR = ../../Mouse
libMouseBackend_HEADER_FILES = \
	MouseBackend.h \
	PointerDevice.h \
	AccelerationCurve.h \
	MousePreferences.h

libMouseBackend_HEADER_FILES_INSTALL_DIR = MouseBackend
libMouseBackend_FRAMEWORKS_DEPEND_UPON = Foundation

libMouseBackend_OBJCFLAGS += -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/library.make

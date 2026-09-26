include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libColorProfileBackend
VERSION = 1.0

# The Color prefPane loads display profiles live and gershwin-apply-settings
# loads the recorded ones again at login (gamma tables do not survive an X
# restart); both go through this one class so they load a profile the same way.
libColorProfileBackend_OBJC_FILES = \
	../../Color/ProfileApplier.m

libColorProfileBackend_HEADER_FILES_DIR = ../../Color
libColorProfileBackend_HEADER_FILES = \
	ProfileApplier.h

libColorProfileBackend_HEADER_FILES_INSTALL_DIR = ColorProfileBackend
libColorProfileBackend_FRAMEWORKS_DEPEND_UPON = Foundation
libColorProfileBackend_LIBRARIES_DEPEND_UPON += -lXrandr -lX11

libColorProfileBackend_OBJCFLAGS += -Wall -Wextra -Werror

include $(GNUSTEP_MAKEFILES)/library.make

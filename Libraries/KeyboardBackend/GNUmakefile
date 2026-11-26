include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libKeyboardBackend
VERSION = 1.0

# The Keyboard prefPane applies a layout live and gershwin-apply-settings
# applies it again at login; both go through this one backend so the two
# can never load a layout differently.
libKeyboardBackend_OBJC_FILES = \
	../../Keyboard/KeyboardBackend.m

libKeyboardBackend_HEADER_FILES_DIR = ../../Keyboard
libKeyboardBackend_HEADER_FILES = \
	KeyboardBackend.h

libKeyboardBackend_HEADER_FILES_INSTALL_DIR = KeyboardBackend
libKeyboardBackend_FRAMEWORKS_DEPEND_UPON = Foundation

libKeyboardBackend_OBJCFLAGS += -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/library.make

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Brightness
BUNDLE_EXTENSION = .gsmenuextra
Brightness_INSTALL_DIR = /System/Library/MenuExtras

Brightness_PRINCIPAL_CLASS = BrightnessExtra
Brightness_OBJC_FILES = BrightnessExtra.m

# Built with ARC like the rest of the desktop: these bundles hand out
# objects they created, such as the menu they build on demand, and
# without ARC every one of them would be leaked by the caller.
ADDITIONAL_OBJCFLAGS += -I../.. -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make


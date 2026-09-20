include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Sound
BUNDLE_EXTENSION = .gsmenuextra

Sound_PRINCIPAL_CLASS = SoundExtra
Sound_OBJC_FILES = SoundExtra.m

Sound_BUNDLE_LIBS += -lSoundBackend
# Built with ARC like the rest of the desktop: these bundles hand out
# objects they created, such as the menu they build on demand, and
# without ARC every one of them would be leaked by the caller.
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../Sound -I/System/Library/Headers/SoundBackend -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make


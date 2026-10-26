include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Media
BUNDLE_EXTENSION = .gsmenuextra
Media_INSTALL_DIR = /System/Library/MenuExtras

Media_PRINCIPAL_CLASS = MediaExtra
Media_OBJC_FILES = MediaExtra.m

# The extra itself speaks no D-Bus: it asks Menu's own MediaHub, which lives
# in the executable and is resolved at run time through the exported symbols
# of the main program.  MediaRemote is where the interface it answers over
# Distributed Objects is declared, so that the two cannot drift apart.
# Built with ARC like the rest of the desktop: these bundles hand out
# objects they created, such as the menu they build on demand, and
# without ARC every one of them would be leaked by the caller.
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../MediaRemote -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make

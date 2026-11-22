include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Keyboard
BUNDLE_EXTENSION = .gsmenuextra

Keyboard_PRINCIPAL_CLASS = KeyboardExtra
Keyboard_OBJC_FILES = KeyboardExtra.m

# The layout loading and the saved choice come from the Keyboard pane's
# backend, so the pane, this extra and the login-time apply never disagree.
Keyboard_BUNDLE_LIBS += -lKeyboardBackend
# Built with ARC like the rest of the desktop: these bundles hand out
# objects they created, such as the menu they build on demand, and
# without ARC every one of them would be leaked by the caller.
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../Keyboard -I/System/Library/Headers/KeyboardBackend -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make

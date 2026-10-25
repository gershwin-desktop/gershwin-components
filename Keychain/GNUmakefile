# Keychain is a Secret Service provider (org.freedesktop.secrets) on the
# session bus, so without D-Bus it has nothing to serve.  NextBSD ships no
# D-Bus, so there it builds and installs nothing, says why, and succeeds.
# uname says FreeBSD on NextBSD, so it is recognised by what it ships, as
# elsewhere in Gershwin: /etc/os-release ID=nextbsd, /bin/nextbsd-version or
# /usr/lib/system.
IS_NEXTBSD := $(shell if [ "$$(uname -s)" = NextBSD ] || grep -Eqs '^ID="?nextbsd"?$$' /etc/os-release || \
	[ -e /bin/nextbsd-version ] || [ -d /usr/lib/system ]; then echo yes; else echo no; fi)
ifeq ($(IS_NEXTBSD),yes)
.PHONY: all install uninstall clean distclean check
all install uninstall clean distclean check:
	@echo "Keychain: skipped on NextBSD — a Secret Service provider over D-Bus, and NextBSD ships no D-Bus"
else
include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Keychain

Keychain_OBJC_FILES = \
	main.m \
	Model/KCCrypto.m \
	Model/KCSecretSession.m \
	Model/KCItem.m \
	Model/KCCollection.m \
	Model/KCKeyring.m \
	DBus/KCDBusMarshal.m \
	DBus/KCDBusConnection.m \
	DBus/KCSecretService.m \
	UI/KCUI.m \
	UI/KCPasswordPanel.m \
	UI/KCItemInspector.m \
	UI/KCItemEditor.m \
	UI/KCKeychainWindowController.m \
	UI/KCAppDelegate.m

# Generated below with the installed executable's path in it.
Keychain_RESOURCE_FILES = \
	org.freedesktop.secrets.service \
	Resources/README-dbus-activation.txt

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions -Wall
ADDITIONAL_INCLUDE_DIRS += -IModel -IDBus -IUI
# One call per module: a missing module must not drop the other's flags too.
ADDITIONAL_CPPFLAGS += $(shell pkg-config --cflags dbus-1)
ADDITIONAL_CPPFLAGS += $(shell pkg-config --cflags libcrypto)
ADDITIONAL_GUI_LIBS += $(shell pkg-config --libs dbus-1)
ADDITIONAL_GUI_LIBS += $(shell pkg-config --libs libcrypto)

include $(GNUSTEP_MAKEFILES)/application.make

# dbus-daemon starts the app by absolute path, which depends on where
# this build installs to.
KEYCHAIN_EXEC = $(GNUSTEP_SYSTEM_APPS)/Keychain.app/Keychain

org.freedesktop.secrets.service: Resources/org.freedesktop.secrets.service.in GNUmakefile
	sed -e 's|@KEYCHAIN_EXEC@|$(KEYCHAIN_EXEC)|' $< > $@

before-all:: org.freedesktop.secrets.service

after-clean::
	rm -f org.freedesktop.secrets.service

before-install::
	mkdir -p $(GNUSTEP_APPS)
endif

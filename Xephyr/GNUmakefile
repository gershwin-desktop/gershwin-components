include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Xephyr
PACKAGE_NAME = Xephyr
Xephyr_PRINCIPAL_CLASS = NSApplication
Xephyr_APPLICATION_ICON = Xephyr.png

Xephyr_RESOURCE_FILES = \
	Resources/Xephyr.png

Xephyr_LOCALIZED_RESOURCE_FILES = \
	Localizable.strings

Xephyr_LANGUAGES = English German

Xephyr_HEADER_FILES = \
	XLController.h \
	XLXephyr.h

Xephyr_OBJC_FILES = \
	main.m \
	XLController.m \
	XLXephyr.m

ADDITIONAL_OBJCFLAGS += -Wall

include $(GNUSTEP_MAKEFILES)/application.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

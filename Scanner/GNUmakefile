include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

APP_NAME = Scanner
Scanner_PRINCIPAL_CLASS = NSApplication
Scanner_APPLICATION_ICON = Scanner.png

Scanner_RESOURCE_FILES = \
	Resources/Scanner.png

# Scanning core, Foundation only (also compiled into Tests/Core)
CORE_OBJC_FILES = \
	SCImage.m \
	SCImageAnalysis.m \
	SCLanguageGuess.m \
	SCImageBuilder.m \
	SCFileNamer.m \
	SCOption.m \
	SCSaneLibrary.m \
	SCScanner.m

Scanner_OBJC_FILES = \
	$(CORE_OBJC_FILES) \
	SCImageWriter.m \
	SCFax.m \
	SCPDFWriter.m \
	SCTextRecognizer.m \
	SCSoftwareInstaller.m \
	SCPermissionCheck.m \
	SCSaver.m \
	SCFormView.m \
	SCOptionControl.m \
	SCPageListView.m \
	SCPreviewView.m \
	SCDeviceChooser.m \
	SCPasswordPanel.m \
	SCPreferences.m \
	SCScanWindow.m \
	SCAppDelegate.m \
	Scanner_main.m

Scanner_HEADER_FILES = \
	SCImage.h \
	SCImageAnalysis.h \
	SCLanguageGuess.h \
	SCImageBuilder.h \
	SCFileNamer.h \
	SCOption.h \
	SCSaneLibrary.h \
	SCScanner.h \
	SCImageWriter.h \
	SCFax.h \
	SCPDFWriter.h \
	SCTextRecognizer.h \
	SCSoftwareInstaller.h \
	SCPermissionCheck.h \
	SCSaver.h \
	SCFormView.h \
	SCOptionControl.h \
	SCPageListView.h \
	SCPreviewView.h \
	SCDeviceChooser.h \
	SCPasswordPanel.h \
	SCPreferences.h \
	SCScanWindow.h \
	SCAppDelegate.h \
	SCMetrics.h

ADDITIONAL_OBJCFLAGS += -fobjc-arc -Wall
# sane-backends, libtiff and ICU live in /usr/local on the BSDs; pkg-config knows where.
# libsane is not linked, only its headers are used: it is loaded at runtime
# (SCSaneLibrary.m) so Scanner starts on systems without it and offers it.
# zlib is part of every base system, which does not always ship a zlib.pc.
ADDITIONAL_CPPFLAGS += $(shell pkg-config --cflags sane-backends libtiff-4 icu-uc)
Scanner_GUI_LIBS += $(shell pkg-config --libs libtiff-4 icu-uc) -lz
# dlopen is in libc on the BSDs and on newer glibc; older glibc needs libdl
ifneq ($(findstring linux,$(GNUSTEP_TARGET_OS)),)
Scanner_GUI_LIBS += -ldl
endif

# Installing text recognition goes through the PackageManager framework,
# which is installed system-wide by 'gmake install' in PackageManager/; it is
# linked from there, not embedded. Its headers use nullability annotations.
ADDITIONAL_OBJCFLAGS += -I/System/Library/Headers -Wno-nullability-completeness
ADDITIONAL_LDFLAGS += -L/System/Library/Frameworks/PackageManager.framework/Versions/1 -lPackageManager
ADDITIONAL_LDFLAGS += -Wl,-rpath,/System/Library/Frameworks/PackageManager.framework/Versions/1

include $(GNUSTEP_MAKEFILES)/application.make

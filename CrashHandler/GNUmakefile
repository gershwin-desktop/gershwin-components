include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = CrashHandler
BUNDLE_EXTENSION = .bundle

CrashHandler_OBJC_FILES = CrashHandler.m
CrashHandler_PRINCIPAL_CLASS = GSCrashHandler
CrashHandler_RESOURCE_FILES = symbolize.sh
CrashHandler_LIBRARIES_DEPEND_UPON = -lgnustep-gui -lgnustep-base -lobjc

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc

# backtrace() is in libexecinfo on the BSDs; where that library is absent the report says it has no native backtrace.
UNAME_S := $(shell uname -s)
ifneq ($(filter FreeBSD NextBSD OpenBSD,$(UNAME_S)),)
  ifneq ($(wildcard /usr/local/lib/libexecinfo.* /usr/lib/libexecinfo.*),)
    ADDITIONAL_OBJCFLAGS += -I/usr/local/include
    ADDITIONAL_LDFLAGS += -L/usr/local/lib -lexecinfo
  endif
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

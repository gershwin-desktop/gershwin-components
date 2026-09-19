include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libSoundBackend
VERSION = 1.0

UNAME_S := $(shell uname -s)
libSoundBackend_OBJC_FILES = \
	../../Sound/SoundModels.m \
	../../Sound/WavScale.m \
	../../Sound/ALSABackend.m \
	../../Sound/SoundBackendFactory.m
ifneq ($(UNAME_S),OpenBSD)
libSoundBackend_OBJC_FILES += ../../Sound/OSSBackend.m
endif

libSoundBackend_HEADER_FILES_DIR = ../../Sound
libSoundBackend_HEADER_FILES = \
	SoundBackend.h \
	WavScale.h \
	ALSABackend.h \
	OSSBackend.h \
	SoundBackendFactory.h

libSoundBackend_HEADER_FILES_INSTALL_DIR = SoundBackend
libSoundBackend_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

include $(GNUSTEP_MAKEFILES)/library.make

after-install::
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/SoundBackend/SoundController.h 2>/dev/null || true
	@rm -f $(GNUSTEP_SYSTEM_HEADERS)/SoundBackend/SoundPane.h 2>/dev/null || true


include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

LIBRARY_NAME = libCPUGovernorBackend
VERSION = 1.0

# The Energy prefPane and the Battery menu extra both switch the CPU/power
# governor; this is the one place that knows how, per OS, so the two never
# show a different list or use a different privilege path for the same
# setting (see Energy/CPUGovernorBackend.m for the per-OS detail).
libCPUGovernorBackend_OBJC_FILES = \
	../../Energy/CPUGovernorBackend.m

libCPUGovernorBackend_HEADER_FILES_DIR = ../../Energy
libCPUGovernorBackend_HEADER_FILES = \
	CPUGovernorBackend.h

libCPUGovernorBackend_HEADER_FILES_INSTALL_DIR = CPUGovernorBackend
libCPUGovernorBackend_FRAMEWORKS_DEPEND_UPON = Foundation

# The class hands out arrays/strings without manual retain/release (see its
# header); build it under ARC so that holds regardless of which target links
# the resulting library.
libCPUGovernorBackend_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/library.make

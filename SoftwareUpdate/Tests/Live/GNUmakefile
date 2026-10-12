# Tools that check SoftwareUpdate's models against the real system rather
# than against canned output. Not part of the headless suite in ../Models:
# they need the network and the operating system they are written for.
include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = sw_pkg_check

sw_pkg_check_OBJC_FILES = sw_pkg_check.m ../../Models/SWSystemPackages.m ../../Models/SWRepository.m
../../Models/SWSystemPackages.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions
../../Models/SWRepository.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions
sw_pkg_check.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

ADDITIONAL_INCLUDE_DIRS += -I../../Models
ADDITIONAL_OBJCFLAGS += -Wall -Wextra -Wno-unused-parameter

include $(GNUSTEP_MAKEFILES)/tool.make

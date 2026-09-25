include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_TintedMenuItemCell t_ShortcutReregistration t_CPUGovernorBackend

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework -I../..
# Testing.h releases its own objects, so the tests are built without ARC.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -Wno-unused-parameter

t_TintedMenuItemCell_OBJC_FILES = t_TintedMenuItemCell.m
t_TintedMenuItemCell_TOOL_LIBS += -lgnustep-gui

t_ShortcutReregistration_OBJC_FILES = t_ShortcutReregistration.m

t_CPUGovernorBackend_OBJC_FILES = t_CPUGovernorBackend.m ../../CPUGovernorBackend.m
# CPUGovernorBackend.m is shared with Energy (a non-ARC target); force ARC
# for it here too so this one source behaves the same in every target that
# compiles it, same as Menu.app's own ADDITIONAL_OBJCFLAGS does.
../../CPUGovernorBackend.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/test-tool.make

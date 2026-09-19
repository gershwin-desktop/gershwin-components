include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_TintedMenuItemCell t_ShortcutReregistration

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework
# Testing.h releases its own objects, so the tests are built without ARC.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -Wno-unused-parameter

t_TintedMenuItemCell_OBJC_FILES = t_TintedMenuItemCell.m
t_TintedMenuItemCell_TOOL_LIBS += -lgnustep-gui

t_ShortcutReregistration_OBJC_FILES = t_ShortcutReregistration.m

include $(GNUSTEP_MAKEFILES)/test-tool.make

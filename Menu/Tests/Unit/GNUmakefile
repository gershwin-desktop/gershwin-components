include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_TintedMenuItemCell t_ShortcutReregistration t_CPUGovernorBackend t_WorldClockList t_WLANMenuListPolicy

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework -I../..
# Testing.h releases its own objects, so the tests are built without ARC.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -Wno-unused-parameter

t_TintedMenuItemCell_OBJC_FILES = t_TintedMenuItemCell.m
t_TintedMenuItemCell_TOOL_LIBS += -lgnustep-gui

t_ShortcutReregistration_OBJC_FILES = t_ShortcutReregistration.m

# CPUGovernorBackend.h/.m live in Energy/ (Libraries/CPUGovernorBackend
# packages the same source as libCPUGovernorBackend for Energy and the
# Battery extra); link the source directly here rather than the library so
# the test needs nothing installed.
t_CPUGovernorBackend_OBJC_FILES = t_CPUGovernorBackend.m ../../../Energy/CPUGovernorBackend.m
t_CPUGovernorBackend_OBJCFLAGS += -I../../../Energy
# It is built ARC in both real targets; match that here too.
../../../Energy/CPUGovernorBackend.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

t_WorldClockList_OBJC_FILES = t_WorldClockList.m ../../MenuExtras/ClockExtra/WorldClockList.m
t_WorldClockList_OBJCFLAGS += -I../../MenuExtras/ClockExtra
../../MenuExtras/ClockExtra/WorldClockList.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

# WLANMenuListPolicy only needs the WLAN model (NetworkModels.m), not the
# nmcli/BSD backends, so link that one collaborator rather than the whole
# NetworkBackend library.
t_WLANMenuListPolicy_OBJC_FILES = t_WLANMenuListPolicy.m \
	../../MenuExtras/WLANExtra/WLANMenuListPolicy.m \
	../../../Network/NetworkModels.m
t_WLANMenuListPolicy_OBJCFLAGS += -I../../MenuExtras/WLANExtra -I../../../Network
t_WLANMenuListPolicy_TOOL_LIBS += -lgnustep-gui
# WLANMenuListPolicy is built ARC in its real target (the WLAN extra bundle);
# match that here. NetworkModels.m (the WLAN model) is MRC in its own
# library and stays that way - forcing ARC on it would conflict with its
# explicit -release calls.
../../MenuExtras/WLANExtra/WLANMenuListPolicy.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/test-tool.make

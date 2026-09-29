include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TEST_TOOL_NAME = t_TintedMenuItemCell t_ShortcutReregistration t_BatteryRefresh t_CPUGovernorBackend t_WorldClockList t_ClockMenu t_WLANMenuListPolicy t_DBusMenuLayout t_LidCloseOnce t_BatteryLidMenuItem t_MenuBarLayout t_ExtrasBarLayout t_ExtrasMenuViewWidths t_MPRISMediaController t_MediaHub

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework -I../..
# Testing.h releases its own objects, so the tests are built without ARC.
ADDITIONAL_OBJCFLAGS += -fobjc-runtime=gnustep-2.0 -Wno-unused-parameter
ADDITIONAL_INCLUDE_DIRS += -I../.. -I../../MenuExtras/BatteryExtra

# BatteryExtra.m's default -createLidArmerWithUnsupportedReason: references
# EnergyLidBackend, so any tool linking the real BatteryExtra.m needs it too
# even when a test subclass overrides that one method and never calls it -
# the class reference is still an undefined symbol at link time otherwise.
# EnergyLidBackend.m's dbus_* calls are behind #if defined(__linux__); only
# that platform needs libdbus to link this test tool.
LIDBACKEND_UNAME_S := $(shell uname -s)

t_TintedMenuItemCell_OBJC_FILES = t_TintedMenuItemCell.m
t_TintedMenuItemCell_TOOL_LIBS += -lgnustep-gui

t_ShortcutReregistration_OBJC_FILES = t_ShortcutReregistration.m

# The extra and the context it repaints through are ARC in Menu; the test
# tool itself stays non-ARC.  Per-file flags are keyed by the path exactly as
# listed above, or they are silently ignored.
ARCFLAGS = -fobjc-arc -fobjc-arc-exceptions
t_BatteryRefresh_OBJC_FILES = t_BatteryRefresh.m \
	../../GSMenuExtraContext.m \
	../../MenuExtras/BatteryExtra/BatteryExtra.m
../../GSMenuExtraContext.m_FILE_FLAGS += $(ARCFLAGS)
../../MenuExtras/BatteryExtra/BatteryExtra.m_FILE_FLAGS += $(ARCFLAGS)
t_BatteryRefresh_TOOL_LIBS += -lgnustep-gui
# The extra's Power Mode submenu calls CPUGovernorBackend on a dispatch
# queue; link the backend source rather than the library so the test
# needs nothing installed.
t_BatteryRefresh_OBJC_FILES += ../../../Energy/CPUGovernorBackend.m
t_BatteryRefresh_OBJCFLAGS += -I../../../Energy
t_BatteryRefresh_TOOL_LIBS += -ldispatch
t_BatteryRefresh_OBJC_FILES += ../../../Energy/EnergyLidCloseOnce.m ../../../Energy/EnergyLidBackend.m
../../../Energy/EnergyLidBackend.m_FILE_FLAGS += $(ARCFLAGS)
ifeq ($(LIDBACKEND_UNAME_S),Linux)
t_BatteryRefresh_OBJCFLAGS += $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
t_BatteryRefresh_TOOL_LIBS += -ldbus-1
endif

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

# The Clock extra's own -menu, so the test can replay the manager's build
# order against it: the extra (ARC, like the bundle) plus GSMenuExtraContext,
# which it calls back through.  GSMenuExtraContext.m and WorldClockList.m
# already carry the ARC flags with their targets above - the flags are keyed
# by the path - so only the extra itself needs them here.
t_ClockMenu_OBJC_FILES = t_ClockMenu.m \
	../../GSMenuExtraContext.m \
	../../MenuExtras/ClockExtra/ClockExtra.m \
	../../MenuExtras/ClockExtra/WorldClockList.m
t_ClockMenu_OBJCFLAGS += -I../../MenuExtras/ClockExtra
../../MenuExtras/ClockExtra/ClockExtra.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions
t_ClockMenu_TOOL_LIBS += -lgnustep-gui

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

# DBusMenuLayout is Foundation-only and ARC in Menu; the test scripts its
# one D-Bus call, so nothing else of Menu is linked.
t_DBusMenuLayout_OBJC_FILES = t_DBusMenuLayout.m ../../DBusMenuLayout.m
../../DBusMenuLayout.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

# EnergyLidCloseOnceArmer is Foundation-only and ships ARC (Libraries/
# EnergyBackend builds it that way); Testing.h is not ARC-safe, so link the
# unit as a separate object (per-file ARC flag below) rather than #include
# it into this test's own (non-ARC) translation unit.
t_LidCloseOnce_OBJC_FILES = t_LidCloseOnce.m ../../../Energy/EnergyLidCloseOnce.m
t_LidCloseOnce_OBJCFLAGS += -I../../../Energy
../../../Energy/EnergyLidCloseOnce.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

# The "Stay awake at lid close" menu item's check mark, driven through the
# extra's real -menu/-validateMenuItem: with a fake armer injected via a
# TestHooks category - proves the UI reflects EnergyLidCloseOnceArmer's
# state, not just that the state machine itself is correct in isolation.
t_BatteryLidMenuItem_OBJC_FILES = t_BatteryLidMenuItem.m \
	../../GSMenuExtraContext.m \
	../../MenuExtras/BatteryExtra/BatteryExtra.m \
	../../../Energy/EnergyLidCloseOnce.m \
	../../../Energy/EnergyLidBackend.m
../../GSMenuExtraContext.m_FILE_FLAGS += $(ARCFLAGS)
../../MenuExtras/BatteryExtra/BatteryExtra.m_FILE_FLAGS += $(ARCFLAGS)
t_BatteryLidMenuItem_TOOL_LIBS += -lgnustep-gui
t_BatteryLidMenuItem_OBJC_FILES += ../../../Energy/CPUGovernorBackend.m
t_BatteryLidMenuItem_OBJCFLAGS += -I../../../Energy
t_BatteryLidMenuItem_TOOL_LIBS += -ldispatch
ifeq ($(LIDBACKEND_UNAME_S),Linux)
t_BatteryLidMenuItem_OBJCFLAGS += $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
t_BatteryLidMenuItem_TOOL_LIBS += -ldbus-1
endif

# MenuBarLayout is Foundation-only (no display needed): the pure geometry
# that decides which titles/extras a bar of a given width can show.
t_MenuBarLayout_OBJC_FILES = t_MenuBarLayout.m ../../MenuBarLayout.m

# The right-hand end of the bar: the extras group, its anchor, and what an
# extra that comes and goes does to the room it takes.  Foundation-only -
# the geometry, with the widths the view adds on top of an extra's own.
t_ExtrasBarLayout_OBJC_FILES = t_ExtrasBarLayout.m

# The extras view lays every item out at the width its extra asked for, on
# the passes NSMenuView runs by itself too.  Needs a display (real fonts):
# skips without $DISPLAY, run under xvfb-run.
t_ExtrasMenuViewWidths_OBJC_FILES = t_ExtrasMenuViewWidths.m ../../GSExtrasMenuView.m
t_ExtrasMenuViewWidths_TOOL_LIBS += -lgnustep-gui
# Menu builds the view with ARC; the tool stays MRC for the PASS macros, so
# only the view's own object gets the ARC flags (keyed by its path as written).
../../GSExtrasMenuView.m_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions

# The media hub.  MPRISMediaController is the D-Bus half and is tested
# against a dbus-daemon and a real (fake) MPRIS2 player that
# t_MPRISMediaController.m starts for itself; t_MediaHub is the merge of the
# bus players with the native player over Distributed Objects, driven
# against a player standing in for Player.  Both link the controller's
# source rather than a library, so neither needs anything installed.
# MediaRemote is where the interface the hub serves, and the one the native
# player serves, are declared; libdispatch comes with the hub's poll queue,
# and libdbus with the controller.
t_MPRISMediaController_OBJC_FILES = t_MPRISMediaController.m ../../MPRISMediaController.m
../../MPRISMediaController.m_FILE_FLAGS += $(ARCFLAGS)
t_MPRISMediaController_OBJCFLAGS += -I../../../MediaRemote
t_MPRISMediaController_OBJCFLAGS += $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
t_MPRISMediaController_TOOL_LIBS += -ldbus-1

t_MediaHub_OBJC_FILES = t_MediaHub.m ../../MediaHub.m ../../MPRISMediaController.m
../../MediaHub.m_FILE_FLAGS += $(ARCFLAGS)
../../MPRISMediaController.m_FILE_FLAGS += $(ARCFLAGS)
t_MediaHub_OBJCFLAGS += -I../../../MediaRemote
t_MediaHub_OBJCFLAGS += $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
t_MediaHub_TOOL_LIBS += -ldbus-1 -ldispatch

include $(GNUSTEP_MAKEFILES)/test-tool.make

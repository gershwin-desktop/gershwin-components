include $(GNUSTEP_MAKEFILES)/common.make

# Pane tests: what the Erase and Partition panes keep when the selected
# object is merely refreshed (a rescan hands them a fresh instance with the
# same identifier) and what they reset when the user selects another object.
# They build real AppKit views, so the tool needs an X display:
#
#     cd Tests/Panes && gmake && DISPLAY=:<private Xvfb> ./obj/t_PaneChoices
#
# The panes are ARC, the test is not (the ObjectTesting macros send explicit
# retain/release), so ARC is switched on per source file below.

TEST_TOOL_NAME = t_PaneChoices

SOURCES = ../../Sources

PANE_SOURCES = \
    $(SOURCES)/Controllers/DUEraseViewController.m \
    $(SOURCES)/Controllers/DUPartitionViewController.m \
    $(SOURCES)/Views/DUDiskMapView.m \
    $(SOURCES)/Views/DUOperationLogView.m \
    $(SOURCES)/Views/DUPaneView.m \
    $(SOURCES)/Backend/DUBackendFactory.m \
    $(SOURCES)/Backend/DUStorageBackend.m \
    $(SOURCES)/Backend/DUFATFormat.m \
    $(SOURCES)/Backend/DUMockStorageBackend.m \
    $(SOURCES)/Backend/Parsers/DUFreeBSDGEOMParser.m \
    $(SOURCES)/Backend/Parsers/DUNetBKSDisklabelParser.m \
    $(SOURCES)/Backend/Parsers/DUOpenBSDDisklabelParser.m \
    $(SOURCES)/Backend/Parsers/DUPartitionTableParser.m \
    $(SOURCES)/Models/DURAIDSet.m \
    $(SOURCES)/Models/DUDiskImage.m \
    $(SOURCES)/Models/DUOpticalMedia.m \
    $(SOURCES)/Models/DUPartition.m \
    $(SOURCES)/Models/DUPartitionLayout.m \
    $(SOURCES)/Models/DUPartitionPlan.m \
    $(SOURCES)/Models/DUStorageCapabilities.m \
    $(SOURCES)/Models/DUStorageDevice.m \
    $(SOURCES)/Models/DUStorageObject.m \
    $(SOURCES)/Models/DUStorageVolume.m \
    $(SOURCES)/Operations/DUBlankDiscOperation.m \
    $(SOURCES)/Operations/DUBurnOperation.m \
    $(SOURCES)/Operations/DUConvertImageOperation.m \
    $(SOURCES)/Operations/DUCreateImageOperation.m \
    $(SOURCES)/Operations/DUEraseOperation.m \
    $(SOURCES)/Operations/DUImageOperation.m \
    $(SOURCES)/Operations/DUOperation.m \
    $(SOURCES)/Operations/DUPartitionOperation.m \
    $(SOURCES)/Operations/DURAIDOperation.m \
    $(SOURCES)/Operations/DURepairOperation.m \
    $(SOURCES)/Operations/DUResizeImageOperation.m \
    $(SOURCES)/Operations/DURestoreOperation.m \
    $(SOURCES)/Operations/DUVerifyDiscOperation.m \
    $(SOURCES)/Operations/DUVerifyOperation.m \
    $(SOURCES)/Services/DUAuthorizationManager.m \
    $(SOURCES)/Services/DUDeviceEventSource.m \
    $(SOURCES)/Services/DUDeviceMonitor.m \
    $(SOURCES)/Services/DUImageService.m \
    $(SOURCES)/Services/DUNotifications.m \
    $(SOURCES)/Services/DUOperationManager.m \
    $(SOURCES)/Services/DUStorageManager.m \
    $(SOURCES)/Utilities/DUErrors.m \
    $(SOURCES)/Utilities/DUParsing.m \
    $(SOURCES)/Utilities/DUProcessRunner.m \
    $(SOURCES)/Utilities/DURepairPermissionsTool.m \
    $(SOURCES)/Utilities/DUSHA256.m

t_PaneChoices_OBJC_FILES = ../TestPaneChoices.m $(PANE_SOURCES)

# gnustep-make keys per-file flags by the path exactly as listed above.
$(foreach f,$(PANE_SOURCES),$(eval $(f)_FILE_FLAGS += -fobjc-arc -fobjc-arc-exceptions))

t_PaneChoices_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra

t_PaneChoices_TOOL_LIBS = -lgnustep-gui -lgnustep-base

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ADDITIONAL_INCLUDE_DIRS += \
    -I../.. \
    -I$(SOURCES) \
    -I$(SOURCES)/Controllers \
    -I$(SOURCES)/Views \
    -I$(SOURCES)/Models \
    -I$(SOURCES)/Services \
    -I$(SOURCES)/Operations \
    -I$(SOURCES)/Utilities \
    -I$(SOURCES)/Backend \
    -I$(SOURCES)/Backend/Parsers

include $(GNUSTEP_MAKEFILES)/test-tool.make

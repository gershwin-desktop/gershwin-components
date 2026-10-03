include $(GNUSTEP_MAKEFILES)/common.make

# Storage-manager tests: the snapshot and busy-lock reconciliation the GUI
# depends on. Hermetic - no real disk, no privilege, no destructive step - but
# kept in its own makefile rather than in ../GNUmakefile, because
# DUStorageManager pulls in the whole operation and notification graph, which
# does not belong in the ARC support library the other tools share. The tools
# in ../ are non-ARC (the ObjectTesting macros send explicit retain/release)
# while the sources here are ARC, so the two cannot share a translation unit.
#
#     cd Tests/Manager && gmake && ./obj/t_StorageManager
#
# ../run.sh builds and runs this alongside the main suite.

TEST_TOOL_NAME = t_StorageManager

SOURCES = ../../Sources

t_StorageManager_OBJC_FILES = \
    ../TestStorageManager.m \
    ../TestControllableBackend.m \
    $(SOURCES)/Backend/DUBackendFactory.m \
    $(SOURCES)/Backend/DUStorageBackend.m \
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

t_StorageManager_OBJCFLAGS = \
    -fobjc-arc -fobjc-arc-exceptions -fobjc-runtime=gnustep-2.0 -fblocks \
    -Wall -Wextra

t_StorageManager_TOOL_LIBS = -lgnustep-base

# The optional-library wrappers (blkid, libmount, ext2fs, fdisk, archive) are
# deliberately absent: the manager tests run entirely over the mock backend and
# never touch a real filesystem, so a host with the headers but not the
# libraries must still be able to build this tool.

ADDITIONAL_INCLUDE_DIRS += \
    -I$(SOURCES) \
    -I$(SOURCES)/Models \
    -I$(SOURCES)/Services \
    -I$(SOURCES)/Operations \
    -I$(SOURCES)/Utilities \
    -I$(SOURCES)/Backend \
    -I$(SOURCES)/Backend/Parsers

include $(GNUSTEP_MAKEFILES)/test-tool.make

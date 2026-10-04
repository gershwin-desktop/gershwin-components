include $(GNUSTEP_MAKEFILES)/common.make

# Live backend exercise (DESTRUCTIVE). Built on demand only:
#
#     cd Tests/Live && gmake && sudo ./obj/t_LiveBackend /dev/da1
#
# It links the real platform backend and drives it against a real device
# node, asserting the result by reading the disk back with gpart/newfs/
# geom/mount/sha256. It is never part of ../run.sh, which stays hermetic.

TEST_TOOL_NAME = t_LiveBackend

SOURCES = ../../Sources

t_LiveBackend_OBJC_FILES = \
    ../TestLiveBackend.m \
    $(SOURCES)/Backend/DUBackendFactory.m \
    $(SOURCES)/Backend/DUStorageBackend.m \
    $(SOURCES)/Backend/DUMockStorageBackend.m \
    $(SOURCES)/Backend/Libraries/DUArchiveLibrary.m \
    $(SOURCES)/Backend/Libraries/DUBlkidLibrary.m \
    $(SOURCES)/Backend/Libraries/DUExt2Library.m \
    $(SOURCES)/Backend/Libraries/DUFdiskLibrary.m \
    $(SOURCES)/Backend/Libraries/DUMountLibrary.m \
    $(SOURCES)/Backend/Parsers/DUBlkidParser.m \
    $(SOURCES)/Backend/Parsers/DUFreeBSDGEOMParser.m \
    $(SOURCES)/Backend/Parsers/DULsblkParser.m \
    $(SOURCES)/Backend/Parsers/DUNetBKSDisklabelParser.m \
    $(SOURCES)/Backend/Parsers/DUOpenBSDDisklabelParser.m \
    $(SOURCES)/Backend/Parsers/DUPartitionTableParser.m \
    $(SOURCES)/Backend/FreeBSD/DUFreeBSDStorageBackend.m \
    $(SOURCES)/Backend/FreeBSD/DUFreeBSDDeviceDiscovery.m \
    $(SOURCES)/Backend/FreeBSD/DUFreeBSDGEOMAdapter.m \
    $(SOURCES)/Backend/NetBSD/DUNetBSDStorageBackend.m \
    $(SOURCES)/Backend/NetBSD/DUNetBSDDeviceDiscovery.m \
    $(SOURCES)/Backend/OpenBSD/DUOpenBSDStorageBackend.m \
    $(SOURCES)/Backend/OpenBSD/DUOpenBSDDeviceDiscovery.m \
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
    $(SOURCES)/Services/DUImageService.m \
    $(SOURCES)/Services/DUNotifications.m \
    $(SOURCES)/Services/DUOperationManager.m \
    $(SOURCES)/Services/DUDeviceEventSource.m \
    $(SOURCES)/Services/DUDeviceMonitor.m \
    $(SOURCES)/Services/DUStorageManager.m \
    $(SOURCES)/Utilities/DUErrors.m \
    $(SOURCES)/Utilities/DUParsing.m \
    $(SOURCES)/Utilities/DUProcessRunner.m \
    $(SOURCES)/Utilities/DURepairPermissionsTool.m \
    $(SOURCES)/Utilities/DUSHA256.m

t_LiveBackend_OBJCFLAGS = \
    -fobjc-arc -fobjc-arc-exceptions -fobjc-runtime=gnustep-2.0 -fblocks \
    -Wall -Wextra

t_LiveBackend_TOOL_LIBS = -lgnustep-base

# Mirror the main GNUmakefile's library detection so the wrappers compile
# against the real headers when present; without a header the stub build
# needs no extra flags at all.
HAVE_LIBBLKID := $(shell test -f /usr/include/blkid/blkid.h && echo yes)
HAVE_LIBMOUNT := $(shell test -f /usr/include/libmount/libmount.h && echo yes)
HAVE_LIBEXT2FS := $(shell test -f /usr/include/ext2fs/ext2fs.h && echo yes)
HAVE_LIBFDISK := $(shell test -f /usr/include/libfdisk/libfdisk.h && echo yes)
HAVE_LIBARCHIVE := $(shell pkg-config --exists libarchive 2>/dev/null && echo yes)

ifneq ($(HAVE_LIBBLKID),)
t_LiveBackend_OBJCFLAGS += -DHAVE_LIBBLKID
ADDITIONAL_LDFLAGS += -lblkid
endif
ifneq ($(HAVE_LIBMOUNT),)
t_LiveBackend_OBJCFLAGS += -DHAVE_LIBMOUNT
ADDITIONAL_LDFLAGS += -lmount
endif
ifneq ($(HAVE_LIBEXT2FS),)
t_LiveBackend_OBJCFLAGS += -DHAVE_LIBEXT2FS
ADDITIONAL_LDFLAGS += -lext2fs -lcom_err
endif
ifneq ($(HAVE_LIBFDISK),)
t_LiveBackend_OBJCFLAGS += -DHAVE_LIBFDISK
ADDITIONAL_LDFLAGS += -lfdisk
endif
ifneq ($(HAVE_LIBARCHIVE),)
t_LiveBackend_OBJCFLAGS += -DHAVE_LIBARCHIVE
ADDITIONAL_LDFLAGS += -larchive
endif

ADDITIONAL_INCLUDE_DIRS += \
    -I$(SOURCES) \
    -I$(SOURCES)/Models \
    -I$(SOURCES)/Services \
    -I$(SOURCES)/Operations \
    -I$(SOURCES)/Utilities \
    -I$(SOURCES)/Backend \
    -I$(SOURCES)/Backend/Libraries \
    -I$(SOURCES)/Backend/Parsers

include $(GNUSTEP_MAKEFILES)/test-tool.make

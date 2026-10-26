include $(GNUSTEP_MAKEFILES)/common.make

# Live backend exercise (DESTRUCTIVE). Built on demand only:
#
#     cd Tests/Live && gmake && sudo ./obj/t_LiveBackend /dev/da1
#
# It links the real platform backend and drives it against a real device
# node, asserting the result by reading the disk back with gpart/newfs/
# geom/mount/sha256. It is never part of ../run.sh, which stays hermetic.

# t_LiveBackend drives the BSD backends (its RAID probe is FreeBSD only and
# does not compile on Linux); t_LiveMount drives the Linux one.
ifeq ($(findstring linux,$(GNUSTEP_TARGET_OS)),linux)
TEST_TOOL_NAME = t_LiveMount
else
TEST_TOOL_NAME = t_LiveBackend
endif

SOURCES = ../../Sources

t_LiveBackend_OBJC_FILES = \
    ../TestLiveBackend.m \
    $(BACKEND_SOURCES)

# t_LiveMount (Linux) mounts, unmounts and ejects the partitions of a loop
# device the caller set up; it refuses any other node and is run as the
# user, the way the app runs:
#
#     cd Tests/Live && gmake && ./obj/t_LiveMount /dev/loopN
t_LiveMount_OBJC_FILES = \
    ../TestLiveMount.m \
    $(BACKEND_SOURCES)

BACKEND_SOURCES = \
    $(SOURCES)/Backend/DUBackendFactory.m \
    $(SOURCES)/Backend/DUStorageBackend.m \
    $(SOURCES)/Backend/DUFATFormat.m \
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
    $(SOURCES)/Backend/Linux/DULinuxStorageBackend.m \
    $(SOURCES)/Backend/Linux/DULinuxDeviceDiscovery.m \
    $(SOURCES)/Backend/Linux/DULinuxUserMount.m \
    $(SOURCES)/Backend/Linux/DULinuxPartitionTool.m \
    $(SOURCES)/Backend/Linux/DULinuxFilesystemTool.m \
    $(SOURCES)/Backend/Linux/DULinuxImageTool.m \
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

LIVE_FLAGS = \
    -fobjc-arc -fobjc-arc-exceptions -fobjc-runtime=gnustep-2.0 -fblocks \
    -Wall -Wextra

t_LiveBackend_TOOL_LIBS = -lgnustep-base
t_LiveMount_TOOL_LIBS = -lgnustep-base

# Mirror the main GNUmakefile's library detection so the wrappers compile
# against the real headers when present; without a header the stub build
# needs no extra flags at all.
HAVE_LIBBLKID := $(shell test -f /usr/include/blkid/blkid.h && echo yes)
HAVE_LIBMOUNT := $(shell test -f /usr/include/libmount/libmount.h && echo yes)
HAVE_LIBEXT2FS := $(shell test -f /usr/include/ext2fs/ext2fs.h && echo yes)
HAVE_LIBFDISK := $(shell test -f /usr/include/libfdisk/libfdisk.h && echo yes)
HAVE_LIBARCHIVE := $(shell pkg-config --exists libarchive 2>/dev/null && echo yes)

ifneq ($(HAVE_LIBBLKID),)
LIVE_FLAGS += -DHAVE_LIBBLKID
ADDITIONAL_LDFLAGS += -lblkid
endif
ifneq ($(HAVE_LIBMOUNT),)
LIVE_FLAGS += -DHAVE_LIBMOUNT
ADDITIONAL_LDFLAGS += -lmount
endif
ifneq ($(HAVE_LIBEXT2FS),)
LIVE_FLAGS += -DHAVE_LIBEXT2FS
ADDITIONAL_LDFLAGS += -lext2fs -lcom_err
endif
ifneq ($(HAVE_LIBFDISK),)
LIVE_FLAGS += -DHAVE_LIBFDISK
ADDITIONAL_LDFLAGS += -lfdisk
endif
ifneq ($(HAVE_LIBARCHIVE),)
LIVE_FLAGS += -DHAVE_LIBARCHIVE
ADDITIONAL_LDFLAGS += -larchive
endif

t_LiveBackend_OBJCFLAGS = $(LIVE_FLAGS)
t_LiveMount_OBJCFLAGS = $(LIVE_FLAGS)

ADDITIONAL_INCLUDE_DIRS += \
    -I$(SOURCES) \
    -I$(SOURCES)/Models \
    -I$(SOURCES)/Services \
    -I$(SOURCES)/Operations \
    -I$(SOURCES)/Utilities \
    -I$(SOURCES)/Backend \
    -I$(SOURCES)/Backend/Libraries \
    -I$(SOURCES)/Backend/Parsers \
    -I$(SOURCES)/Backend/Linux

include $(GNUSTEP_MAKEFILES)/test-tool.make

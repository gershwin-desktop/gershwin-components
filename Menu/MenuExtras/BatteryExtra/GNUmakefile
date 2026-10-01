include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Battery
BUNDLE_EXTENSION = .gsmenuextra

# Menu loads extras from /System/Library/MenuExtras, not the default bundle
# directory, so install there (same as BrightnessExtra and the other extras).
Battery_INSTALL_DIR = /System/Library/MenuExtras

Battery_PRINCIPAL_CLASS = BatteryExtra
Battery_OBJC_FILES = BatteryExtra.m

# The governor switcher is libCPUGovernorBackend (Libraries/CPUGovernorBackend),
# shared with the Energy prefPane - same pattern as Sound_BUNDLE_LIBS in the
# Sound menu extra sharing -lSoundBackend with the Sound prefPane.  The
# "stay awake at lid close" one-shot inhibitor is libEnergyBackend
# (Libraries/EnergyBackend) for the same reason: one backend, so the Battery
# extra and the Energy prefPane can never disagree about how a lid lock is
# taken.
Battery_BUNDLE_LIBS += -lCPUGovernorBackend -lEnergyBackend

# Built with ARC like the rest of the desktop: these bundles hand out
# objects they created, such as the menu they build on demand, and
# without ARC every one of them would be leaked by the caller.
#
# The source tree's own Energy/ comes before the installed-header fallback
# (same order as SoundExtra's -I../../../Sound and WLANExtra's
# -I../../../Network): a fresh checkout has not run "sudo gmake install"
# yet, so /System/Library/Headers/EnergyBackend may be missing a header
# this bundle was just given, or absent outright - only the tree copy is
# guaranteed current.  Linking -lEnergyBackend (like the pre-existing
# -lCPUGovernorBackend) still needs the library installed to /System/Library/
# Libraries; that half of a fresh build is not solved by an include path.
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../Energy -I/System/Library/Headers/CPUGovernorBackend -I/System/Library/Headers/EnergyBackend -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make


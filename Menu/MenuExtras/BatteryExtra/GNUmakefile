include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

BUNDLE_NAME = Battery
BUNDLE_EXTENSION = .gsmenuextra

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
ADDITIONAL_OBJCFLAGS += -I../.. -I/System/Library/Headers/CPUGovernorBackend -I/System/Library/Headers/EnergyBackend -fobjc-arc -fobjc-arc-exceptions

include $(GNUSTEP_MAKEFILES)/bundle.make


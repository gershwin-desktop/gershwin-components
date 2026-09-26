include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# Re-applies the preference panes' saved settings at login (run from
# Gershwin.sh).  It has no apply logic of its own: every setting goes
# through the backend library the pane itself uses.
TOOL_NAME = gershwin-apply-settings

gershwin-apply-settings_OBJC_FILES = \
	main.m \
	SASetting.m \
	SASettingsRegistry.m \
	SASettingsApplier.m

gershwin-apply-settings_OBJCFLAGS += -Wall -Wextra -Werror -fobjc-arc -fobjc-arc-exceptions

# The backend headers sit next to the panes they came from.
ADDITIONAL_INCLUDE_DIRS += -I../Mouse -I../Keyboard -I../Energy -I../Color

SA_BACKENDS = MouseBackend KeyboardBackend EnergyBackend CPUGovernorBackend ColorProfileBackend
gershwin-apply-settings_TOOL_LIBS += $(foreach l,$(SA_BACKENDS),-l$(l))
# The build-tree directories must come first so an uninstalled build links
# the libraries it was built with; gnustep-make puts the installed library
# directory ahead of ADDITIONAL_LIB_DIRS, so they go into the linker flags.
ADDITIONAL_LDFLAGS += $(foreach l,$(SA_BACKENDS),-L../Libraries/$(l)/obj)

include $(GNUSTEP_MAKEFILES)/tool.make

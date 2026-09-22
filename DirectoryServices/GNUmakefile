include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

SUBPROJECTS = dshelper dscli

# NextBSD resolves users and groups from the same plists with its own NSS
# module, nss_directory_services (nextbsd-userland), and owns
# /etc/nsswitch.conf, so nss_gershwin is neither built nor installed there.
# Same NextBSD test as gershwin-developer's install-system-domain.sh: only
# NextBSD has /usr/lib/system.
ifeq ($(wildcard /usr/lib/system),)
SUBPROJECTS += nss_gershwin
endif

include $(GNUSTEP_MAKEFILES)/aggregate.make


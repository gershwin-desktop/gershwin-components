include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

SUBPROJECTS = dshelper dscli

# NextBSD resolves users and groups from the same plists with its own NSS
# module, nss_directory_services (nextbsd-userland), and owns
# /etc/nsswitch.conf, so nss_gershwin is neither built nor installed there.
# nextbsd-installer is shipped by the NextBSD-userland package, so it is on
# every NextBSD install and on no other system. (/usr/lib/system would be
# wrong: macOS has that too.)
ifeq ($(wildcard /usr/sbin/nextbsd-installer),)
SUBPROJECTS += nss_gershwin
endif

include $(GNUSTEP_MAKEFILES)/aggregate.make


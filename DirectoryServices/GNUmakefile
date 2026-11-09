include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

SUBPROJECTS = dshelper dscli

# NextBSD resolves users and groups from the same plists with its own NSS
# module, nss_directory_services (nextbsd-userland), and owns
# /etc/nsswitch.conf, so nss_gershwin is neither built nor installed there.
# nextbsd-version is written by both image builders before anything else is
# built (nextbsd/build.sh, gershwin-desktop targets/nextbsd/build.sh), so it
# is on every NextBSD image and on no other system. (/usr/lib/system would be
# wrong: macOS has that too.)
ifeq ($(wildcard /bin/nextbsd-version),)
SUBPROJECTS += nss_gershwin
endif

include $(GNUSTEP_MAKEFILES)/aggregate.make


# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# GNUstep CrashReporter - top-level dispatcher.
# Builds subprojects in order: the shared library first, then the tools/app
# that link against it. Install goes to the SYSTEM domain (see each subdir).

include $(GNUSTEP_MAKEFILES)/common.make

SUBPROJECTS = Library Daemon Analyzer ctl CrashReporterApp

include $(GNUSTEP_MAKEFILES)/aggregate.make

# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Builds without GTK, GDK or GLib: only a C compiler is needed.
# Gershwin.sh preloads the installed library when it exists:
#
#   LD_PRELOAD=$(PREFIX)/$(LIBRARY)

PREFIX ?= /System/Library/Libraries
CC ?= cc

OBJDIR := obj
LIBRARY := libgershwin-gtk-nocsd.so

# dlsym lives in libdl on older Linux C libraries and in the C library on the BSDs
DL_LIBS := $(if $(filter Linux,$(shell uname -s)),-ldl,)

all: $(OBJDIR)/$(LIBRARY)

$(OBJDIR)/$(LIBRARY): nocsd.c
	mkdir -p $(OBJDIR)
	$(CC) -std=gnu11 -Wall -Wextra -O2 -g -fPIC -fvisibility=hidden -shared -o $@ nocsd.c $(DL_LIBS)

install: $(OBJDIR)/$(LIBRARY)
	mkdir -p $(DESTDIR)$(PREFIX)
	install -m 755 $(OBJDIR)/$(LIBRARY) $(DESTDIR)$(PREFIX)/

clean:
	rm -rf $(OBJDIR)

distclean: clean

.PHONY: all install clean distclean

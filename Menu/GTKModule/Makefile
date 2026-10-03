# SPDX-License-Identifier: BSD-2-Clause
# Builds without GTK, GDK or GLib: only GNUstep base is needed at build time.

PREFIX ?= /System/Library/Libraries/gtk-appmenu-do
CC = clang
GS_FLAGS := $(shell gnustep-config --objc-flags)
GS_LIBS := $(shell gnustep-config --base-libs)

OBJDIR := obj
MODULE := $(OBJDIR)/libgtk-appmenu-do.so
OBJS := $(OBJDIR)/module.o $(OBJDIR)/node.o $(OBJDIR)/bridge.o

all: $(MODULE) $(OBJDIR)/mock-menu-server

$(OBJDIR):
	mkdir -p $@

$(OBJDIR)/%.o: src/%.c src/gad.h | $(OBJDIR)
	$(CC) -std=gnu11 -Wall -Wextra -O2 -g -fPIC -c $< -o $@

$(OBJDIR)/bridge.o: src/bridge.m src/gad.h | $(OBJDIR)
	# ARC: the bridge keeps connections in instance variables across run loop
	# iterations, and a manually released autoreleased connection died right after
	# it was made, so the module never saw Menu.app as reachable.
	$(CC) $(filter-out -MMD -MP,$(GS_FLAGS)) -fobjc-arc -Wno-deprecated-declarations -c $< -o $@

$(MODULE): $(OBJS)
	$(CC) -shared -o $@ $(OBJS) $(GS_LIBS) -ldl -lpthread

$(OBJDIR)/mock-menu-server: tests/mock-menu-server.m | $(OBJDIR)
	$(CC) $(filter-out -MMD -MP,$(GS_FLAGS)) -o $@ $< $(GS_LIBS)

# GTK 2 and GTK 3 both search $GTK_PATH/modules, and the one binary serves both:
# GTK_PATH=$(PREFIX) GTK_MODULES=gtk-appmenu-do
install: $(MODULE)
	mkdir -p $(DESTDIR)$(PREFIX)/modules
	install -m 755 $(MODULE) $(DESTDIR)$(PREFIX)/modules/

test: all
	$(MAKE) -C tests/Unit
	cd tests/Unit && for t in obj/t_*; do [ -x $$t ] && [ -f $$t ] && ./$$t 2>&1; done | tee obj/unit.log | grep -E "Failed|Uncaught" ; \
	  ! grep -qE "Failed|Uncaught" obj/unit.log

check: test
	tests/smoke.sh

clean:
	rm -rf $(OBJDIR)
	-$(MAKE) -C tests/Unit clean

.PHONY: all install test check clean

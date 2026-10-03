# SPDX-License-Identifier: BSD-2-Clause
# Builds without GTK, GDK, GLib or Qt: only GNUstep base is needed at build time.
#
#   GTK 2 and 3:  GTK_PATH=$(PREFIX) GTK_MODULES=gtk-appmenu-do
#   Qt 5 and 6:   QT_PLUGIN_PATH=$(PREFIX) QT_QPA_PLATFORMTHEME=gad

PREFIX ?= /System/Library/Libraries/appmenu-do
CC = clang
GS_FLAGS := $(shell gnustep-config --objc-flags)
GS_LIBS := $(shell gnustep-config --base-libs)

OBJDIR := obj
GTK_MODULE := $(OBJDIR)/modules/libgtk-appmenu-do.so
QT_PLUGIN := $(OBJDIR)/platformthemes/libgad.so
CORE_OBJS := $(OBJDIR)/core/node.o $(OBJDIR)/core/mainsync.o $(OBJDIR)/core/bridge.o

all: $(GTK_MODULE) $(QT_PLUGIN) $(OBJDIR)/mock-menu-server

$(OBJDIR)/%.o: %.c core/gad.h
	mkdir -p $(dir $@)
	$(CC) -std=gnu11 -Wall -Wextra -O2 -g -fPIC -Icore -c $< -o $@

# ARC: the bridge keeps connections in instance variables across run loop
# iterations, and a manually released autoreleased connection died right after
# it was made, so the module never saw Menu.app as reachable.
$(OBJDIR)/core/bridge.o: core/bridge.m core/gad.h
	mkdir -p $(dir $@)
	$(CC) $(filter-out -MMD -MP,$(GS_FLAGS)) -fobjc-arc -Wno-deprecated-declarations -Icore -c $< -o $@

$(GTK_MODULE): $(OBJDIR)/gtk/module.o $(CORE_OBJS)
	mkdir -p $(dir $@)
	$(CC) -shared -o $@ $^ $(GS_LIBS) -ldl -lpthread

# Qt finds the metadata of a plugin in an ELF note that has to come first, so
# the linker must not put a build id note before it.
$(QT_PLUGIN): $(OBJDIR)/qt/qtplugin.o $(OBJDIR)/qt/qt.o $(CORE_OBJS)
	mkdir -p $(dir $@)
	$(CC) -shared -Wl,--build-id=none -o $@ $^ $(GS_LIBS) -ldl -lpthread

qt/qt-metadata.h: qt/tools/gen-qt-metadata.py
	python3 qt/tools/gen-qt-metadata.py $@

$(OBJDIR)/qt/qtplugin.o: qt/qt-metadata.h

$(OBJDIR)/mock-menu-server: tests/mock-menu-server.m
	mkdir -p $(dir $@)
	$(CC) $(filter-out -MMD -MP,$(GS_FLAGS)) -o $@ $< $(GS_LIBS)

install: $(GTK_MODULE) $(QT_PLUGIN)
	mkdir -p $(DESTDIR)$(PREFIX)/modules $(DESTDIR)$(PREFIX)/platformthemes
	install -m 755 $(GTK_MODULE) $(DESTDIR)$(PREFIX)/modules/
	install -m 755 $(QT_PLUGIN) $(DESTDIR)$(PREFIX)/platformthemes/

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

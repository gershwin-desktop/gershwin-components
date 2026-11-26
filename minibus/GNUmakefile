# minibus is plain C and needs neither Foundation nor any GNUstep library, so it
# is built with ordinary rules instead of gnustep-make (which always links
# gnustep-base). It still installs into the SYSTEM domain's tool directory.

CC ?= cc
CFLAGS ?= -O2
CFLAGS += -std=gnu11 -Wall -Wextra -D_GNU_SOURCE
OBJDIR = obj
SRCS = src/minibus_main.c src/mb_main.c src/mb_bus.c src/mb_conn.c \
	src/mb_driver.c src/mb_match.c src/mb_msg.c
OBJS = $(SRCS:src/%.c=$(OBJDIR)/%.o)
DEPS = $(OBJS:.o=.d)

# Where the SYSTEM domain keeps tools
TOOLS_DIR ?= /System/Library/Tools

.PHONY: all clean install check bench
all: $(OBJDIR)/minibus

$(OBJDIR)/minibus: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

$(OBJDIR)/%.o: src/%.c
	@mkdir -p $(OBJDIR)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

clean:
	rm -rf $(OBJDIR)

install: all
	mkdir -p $(DESTDIR)$(TOOLS_DIR)
	install -m 755 $(OBJDIR)/minibus $(DESTDIR)$(TOOLS_DIR)/minibus

check: all
	cd Tests && ./run.sh

# Throughput and footprint measurement, not part of the build
bench: $(OBJDIR)/bench
$(OBJDIR)/bench: bench/bench.c Tests/wire.c Tests/wire.h
	@mkdir -p $(OBJDIR)
	$(CC) -O2 -std=gnu11 -o $@ bench/bench.c Tests/wire.c

-include $(DEPS)

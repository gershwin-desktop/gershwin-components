#
# display-live: a command line driver for the Display pane's layout model
# and X11 backend, used by ../live-multihead.sh against a private X server
# with several RandR outputs. Never run it against a display you do not own.
#
include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = display-live
display-live_OBJC_FILES = display-live.m ../../DisplayLayout.m \
	../../DisplayArrangement.m ../../X11DisplayManager.m
display-live_TOOL_LIBS = -lXrandr -lX11
ADDITIONAL_INCLUDE_DIRS += -I../..
ADDITIONAL_OBJCFLAGS += -Wall

include $(GNUSTEP_MAKEFILES)/tool.make

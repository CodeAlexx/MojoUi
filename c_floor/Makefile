CC = gcc
CFLAGS = -Wall -Wextra -fPIC -O2 -std=c11 -D_POSIX_C_SOURCE=200112L
# `-I.` puts c_floor/ itself on the include path so each TU can pick up
# mojoui_shim.h (the consolidated public C ABI consumed by Mojo FFI).
INC = -I. -Ivendored/sokol -Ivendored/stb
LDFLAGS_LINUX = -lGL -lX11 -lEGL -lXi -lXcursor -ldl -lm -lpthread -lasound
GDK_PIXBUF_CFLAGS := $(shell pkg-config --cflags gdk-pixbuf-2.0 2>/dev/null)
GDK_PIXBUF_LIBS := $(shell pkg-config --libs gdk-pixbuf-2.0 2>/dev/null)
LDFLAGS_LINUX += $(GDK_PIXBUF_LIBS)

SOKOL_DEFINES = -DSOKOL_GLCORE -DSOKOL_NO_ENTRY

OBJ_DIR = build

PLATFORM_OBJ = $(OBJ_DIR)/mojoui_platform.o
RENDER_OBJ   = $(OBJ_DIR)/mojoui_render.o
# FONTS_OBJ added in chunk 5

# Only include chunk objects whose .c sources actually exist on disk yet —
# this lets chunks land independently without breaking the build.
OBJS :=
ifneq ($(wildcard mojoui_platform.c),)
OBJS += $(PLATFORM_OBJ)
endif
ifneq ($(wildcard mojoui_render.c),)
OBJS += $(RENDER_OBJ)
endif
ifneq ($(wildcard mojoui_fonts.c),)
OBJS += $(OBJ_DIR)/mojoui_fonts.o
endif
ifneq ($(wildcard mojoui_image_loader.c),)
OBJS += $(OBJ_DIR)/mojoui_image_loader.o
endif
ifneq ($(wildcard mojoui_video.c),)
OBJS += $(OBJ_DIR)/mojoui_video.o
endif
ifneq ($(wildcard mojoui_audio.c),)
OBJS += $(OBJ_DIR)/mojoui_audio.o
endif
ifneq ($(wildcard mojoui_system.c),)
OBJS += $(OBJ_DIR)/mojoui_system.o
endif

LIB = ../libmojoui_floor.so

.PHONY: all clean

all: $(LIB)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/mojoui_platform.o: mojoui_platform.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(SOKOL_DEFINES) $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_render.o: mojoui_render.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(SOKOL_DEFINES) $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_fonts.o: mojoui_fonts.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -DSTB_TRUETYPE_IMPLEMENTATION $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_image_loader.o: mojoui_image_loader.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(GDK_PIXBUF_CFLAGS) $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_video.o: mojoui_video.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_system.o: mojoui_system.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

$(OBJ_DIR)/mojoui_audio.o: mojoui_audio.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

$(LIB): $(OBJS)
	$(CC) -shared -o $@ $^ $(LDFLAGS_LINUX)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(LIB)

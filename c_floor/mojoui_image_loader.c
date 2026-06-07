#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <gdk-pixbuf/gdk-pixbuf.h>

#include "mojoui_shim.h"


static char* copy_path_len(const char* path, int path_len) {
    if (path == NULL || path_len <= 0) {
        return NULL;
    }
    char* out = (char*)malloc((size_t)path_len + 1u);
    if (out == NULL) {
        return NULL;
    }
    memcpy(out, path, (size_t)path_len);
    out[path_len] = '\0';
    return out;
}


uint32_t mojoui_load_texture_file_len(
    const char* path,
    int path_len,
    int max_width,
    int max_height,
    int* out_width,
    int* out_height
) {
    if (out_width != NULL) {
        *out_width = 0;
    }
    if (out_height != NULL) {
        *out_height = 0;
    }

    char* owned_path = copy_path_len(path, path_len);
    if (owned_path == NULL) {
        return 0;
    }

    GError* error = NULL;
    GdkPixbuf* pixbuf = NULL;
    if (max_width > 0 && max_height > 0) {
        pixbuf = gdk_pixbuf_new_from_file_at_scale(
            owned_path, max_width, max_height, TRUE, &error
        );
    } else {
        pixbuf = gdk_pixbuf_new_from_file(owned_path, &error);
    }
    free(owned_path);

    if (pixbuf == NULL) {
        if (error != NULL) {
            g_error_free(error);
        }
        return 0;
    }

    int width = gdk_pixbuf_get_width(pixbuf);
    int height = gdk_pixbuf_get_height(pixbuf);
    int channels = gdk_pixbuf_get_n_channels(pixbuf);
    int has_alpha = gdk_pixbuf_get_has_alpha(pixbuf) ? 1 : 0;
    int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
    const guchar* src = gdk_pixbuf_get_pixels(pixbuf);
    if (width <= 0 || height <= 0 || channels < 3 || src == NULL) {
        g_object_unref(pixbuf);
        return 0;
    }

    size_t rgba_len = (size_t)width * (size_t)height * 4u;
    uint8_t* rgba = (uint8_t*)malloc(rgba_len);
    if (rgba == NULL) {
        g_object_unref(pixbuf);
        return 0;
    }

    for (int y = 0; y < height; y++) {
        const guchar* row = src + (size_t)y * (size_t)rowstride;
        for (int x = 0; x < width; x++) {
            const guchar* px = row + (size_t)x * (size_t)channels;
            size_t off = ((size_t)y * (size_t)width + (size_t)x) * 4u;
            rgba[off + 0u] = (uint8_t)px[0];
            rgba[off + 1u] = (uint8_t)px[1];
            rgba[off + 2u] = (uint8_t)px[2];
            rgba[off + 3u] = has_alpha ? (uint8_t)px[3] : 255u;
        }
    }

    uint32_t texture_id = mojoui_make_texture(width, height, rgba);
    free(rgba);
    g_object_unref(pixbuf);

    if (texture_id != 0) {
        if (out_width != NULL) {
            *out_width = width;
        }
        if (out_height != NULL) {
            *out_height = height;
        }
    }
    return texture_id;
}

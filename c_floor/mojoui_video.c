#include <errno.h>
#include <dirent.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "mojoui_shim.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef struct {
    char* path;
    int is_video;
} mojoui_media_item_t;

static mojoui_media_item_t* g_media_items = NULL;
static int g_media_count = 0;
static int g_media_cap = 0;
static int g_media_limit = 0;


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


static int ascii_tolower(int c) {
    if (c >= 'A' && c <= 'Z') {
        return c + ('a' - 'A');
    }
    return c;
}


static int ends_with_ci(const char* s, const char* suffix) {
    size_t sl = strlen(s);
    size_t xl = strlen(suffix);
    if (xl > sl) {
        return 0;
    }
    const char* tail = s + sl - xl;
    for (size_t i = 0; i < xl; ++i) {
        if (ascii_tolower((unsigned char)tail[i]) != ascii_tolower((unsigned char)suffix[i])) {
            return 0;
        }
    }
    return 1;
}


static int is_image_file_path(const char* path) {
    return
        ends_with_ci(path, ".jpg") ||
        ends_with_ci(path, ".jpeg") ||
        ends_with_ci(path, ".png") ||
        ends_with_ci(path, ".webp") ||
        ends_with_ci(path, ".bmp") ||
        ends_with_ci(path, ".tif") ||
        ends_with_ci(path, ".tiff");
}


static int is_video_file_path(const char* path) {
    return
        ends_with_ci(path, ".mp4") ||
        ends_with_ci(path, ".mov") ||
        ends_with_ci(path, ".webm") ||
        ends_with_ci(path, ".mkv") ||
        ends_with_ci(path, ".avi") ||
        ends_with_ci(path, ".m4v") ||
        ends_with_ci(path, ".gif");
}


int mojoui_is_video_file_len(const char* path, int path_len) {
    char* owned_path = copy_path_len(path, path_len);
    if (owned_path == NULL) {
        return 0;
    }
    int result = is_video_file_path(owned_path);
    free(owned_path);
    return result ? 1 : 0;
}


void mojoui_media_scan_clear(void) {
    for (int i = 0; i < g_media_count; ++i) {
        free(g_media_items[i].path);
        g_media_items[i].path = NULL;
    }
    free(g_media_items);
    g_media_items = NULL;
    g_media_count = 0;
    g_media_cap = 0;
    g_media_limit = 0;
}


static int media_item_compare(const void* a, const void* b) {
    const mojoui_media_item_t* ia = (const mojoui_media_item_t*)a;
    const mojoui_media_item_t* ib = (const mojoui_media_item_t*)b;
    if (ia->path == NULL && ib->path == NULL) {
        return 0;
    }
    if (ia->path == NULL) {
        return -1;
    }
    if (ib->path == NULL) {
        return 1;
    }
    return strcmp(ia->path, ib->path);
}


static int media_scan_add_take(char* owned_path, int is_video) {
    if (owned_path == NULL) {
        return 0;
    }
    if (g_media_limit > 0 && g_media_count >= g_media_limit) {
        free(owned_path);
        return 0;
    }
    if (g_media_count >= g_media_cap) {
        int next_cap = g_media_cap == 0 ? 128 : g_media_cap * 2;
        if (g_media_limit > 0 && next_cap > g_media_limit) {
            next_cap = g_media_limit;
        }
        if (next_cap <= g_media_cap) {
            free(owned_path);
            return 0;
        }
        mojoui_media_item_t* next = (mojoui_media_item_t*)realloc(
            g_media_items, (size_t)next_cap * sizeof(mojoui_media_item_t)
        );
        if (next == NULL) {
            free(owned_path);
            return 0;
        }
        g_media_items = next;
        g_media_cap = next_cap;
    }
    g_media_items[g_media_count].path = owned_path;
    g_media_items[g_media_count].is_video = is_video ? 1 : 0;
    g_media_count += 1;
    return 1;
}


static int media_scan_dir_owned(const char* dir_path, int recursive) {
    if (g_media_limit > 0 && g_media_count >= g_media_limit) {
        return 1;
    }
    DIR* dir = opendir(dir_path);
    if (dir == NULL) {
        return 0;
    }
    struct dirent* ent = NULL;
    while ((ent = readdir(dir)) != NULL) {
        const char* name = ent->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
            continue;
        }
        size_t dir_len = strlen(dir_path);
        size_t name_len = strlen(name);
        size_t full_len = dir_len + 1u + name_len;
        if (full_len >= PATH_MAX * 2u) {
            continue;
        }
        char* full = (char*)malloc(full_len + 1u);
        if (full == NULL) {
            continue;
        }
        memcpy(full, dir_path, dir_len);
        if (dir_len > 0 && dir_path[dir_len - 1u] == '/') {
            memcpy(full + dir_len, name, name_len);
            full[dir_len + name_len] = '\0';
        } else {
            full[dir_len] = '/';
            memcpy(full + dir_len + 1u, name, name_len);
            full[full_len] = '\0';
        }

        struct stat st;
        if (stat(full, &st) != 0) {
            free(full);
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            if (recursive) {
                (void)media_scan_dir_owned(full, recursive);
            }
            free(full);
        } else if (S_ISREG(st.st_mode)) {
            int is_video = is_video_file_path(full);
            if (is_video || is_image_file_path(full)) {
                (void)media_scan_add_take(full, is_video);
            } else {
                free(full);
            }
        } else {
            free(full);
        }
        if (g_media_limit > 0 && g_media_count >= g_media_limit) {
            break;
        }
    }
    closedir(dir);
    return 1;
}


int mojoui_media_scan_dir_len(const char* path, int path_len, int recursive, int max_items) {
    mojoui_media_scan_clear();
    char* owned_path = copy_path_len(path, path_len);
    if (owned_path == NULL) {
        return 0;
    }
    g_media_limit = max_items > 0 ? max_items : 4096;
    if (g_media_limit > 50000) {
        g_media_limit = 50000;
    }
    (void)media_scan_dir_owned(owned_path, recursive != 0);
    free(owned_path);
    if (g_media_count > 1) {
        qsort(g_media_items, (size_t)g_media_count, sizeof(mojoui_media_item_t), media_item_compare);
    }
    return g_media_count;
}


int mojoui_media_scan_count(void) {
    return g_media_count;
}


const char* mojoui_media_scan_path(int index) {
    if (index < 0 || index >= g_media_count || g_media_items[index].path == NULL) {
        return NULL;
    }
    return g_media_items[index].path;
}


int mojoui_media_scan_path_len(int index) {
    const char* path = mojoui_media_scan_path(index);
    if (path == NULL) {
        return 0;
    }
    return (int)strlen(path);
}


int mojoui_media_scan_is_video(int index) {
    if (index < 0 || index >= g_media_count) {
        return 0;
    }
    return g_media_items[index].is_video ? 1 : 0;
}


static int wait_success(pid_t pid) {
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}


static int run_ffmpeg_thumbnail(const char* video_path, const char* thumb_path, int seek_first) {
    pid_t pid = fork();
    if (pid < 0) {
        return 0;
    }
    if (pid == 0) {
        if (seek_first) {
            execlp(
                "ffmpeg",
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                "-ss",
                "00:00:01",
                "-i",
                video_path,
                "-frames:v",
                "1",
                thumb_path,
                (char*)NULL
            );
        } else {
            execlp(
                "ffmpeg",
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                "-i",
                video_path,
                "-frames:v",
                "1",
                thumb_path,
                (char*)NULL
            );
        }
        _exit(127);
    }
    return wait_success(pid);
}


uint32_t mojoui_load_video_thumbnail_len(
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

    static unsigned int counter = 0;
    char thumb_path[512];
    snprintf(
        thumb_path,
        sizeof(thumb_path),
        "/tmp/mojoui-video-thumb-%ld-%u.jpg",
        (long)getpid(),
        counter++
    );

    int ok = run_ffmpeg_thumbnail(owned_path, thumb_path, 1);
    if (!ok) {
        ok = run_ffmpeg_thumbnail(owned_path, thumb_path, 0);
    }
    free(owned_path);

    if (!ok) {
        unlink(thumb_path);
        return 0;
    }

    uint32_t texture_id = mojoui_load_texture_file_len(
        thumb_path,
        (int)strlen(thumb_path),
        max_width,
        max_height,
        out_width,
        out_height
    );
    unlink(thumb_path);
    return texture_id;
}


static void exec_video_player(const char* path) {
    execlp("xdg-open", "xdg-open", path, (char*)NULL);
    execlp("gio", "gio", "open", path, (char*)NULL);
    execlp("mpv", "mpv", path, (char*)NULL);
    execlp("vlc", "vlc", path, (char*)NULL);
    _exit(127);
}


int mojoui_open_video_file_len(const char* path, int path_len) {
    char* owned_path = copy_path_len(path, path_len);
    if (owned_path == NULL) {
        return 0;
    }
    pid_t pid = fork();
    if (pid < 0) {
        free(owned_path);
        return 0;
    }
    if (pid == 0) {
        setsid();
        exec_video_player(owned_path);
    }
    free(owned_path);
    return 1;
}

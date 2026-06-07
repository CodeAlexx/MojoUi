#include "mojoui_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char g_gpu_name[128] = "";
static char g_gpu_driver[64] = "";
static char g_cpu_name[160] = "";
static int g_gpu_memory_total_mb = 0;
static int g_gpu_memory_used_mb = 0;
static int g_gpu_util_percent = 0;
static int g_gpu_temperature_c = 0;
static int g_cpu_util_percent = 0;
static int g_ram_total_mb = 0;
static int g_ram_used_mb = 0;
static unsigned long long g_prev_cpu_total = 0;
static unsigned long long g_prev_cpu_idle = 0;

static void trim_line(char* s) {
    if (!s) return;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ')) {
        s[n - 1] = '\0';
        n--;
    }
    while (*s == ' ' || *s == '\t') {
        memmove(s, s + 1, strlen(s));
    }
}

static void copy_trimmed(char* dst, size_t dst_size, const char* src) {
    if (!dst || dst_size == 0) return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, dst_size, "%s", src);
    trim_line(dst);
}

static void refresh_cpu_name(void) {
    if (g_cpu_name[0] != '\0') return;
    FILE* fp = fopen("/proc/cpuinfo", "r");
    if (!fp) return;
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "model name", 10) == 0) {
            char* colon = strchr(line, ':');
            if (colon) {
                copy_trimmed(g_cpu_name, sizeof(g_cpu_name), colon + 1);
                break;
            }
        }
    }
    fclose(fp);
}

static void refresh_ram_metrics(void) {
    FILE* fp = fopen("/proc/meminfo", "r");
    if (!fp) return;
    char key[64];
    unsigned long value = 0;
    char unit[32];
    unsigned long total_kb = 0;
    unsigned long available_kb = 0;
    while (fscanf(fp, "%63s %lu %31s\n", key, &value, unit) == 3) {
        if (strcmp(key, "MemTotal:") == 0) {
            total_kb = value;
        } else if (strcmp(key, "MemAvailable:") == 0) {
            available_kb = value;
        }
        if (total_kb > 0 && available_kb > 0) break;
    }
    fclose(fp);
    if (total_kb > 0) {
        g_ram_total_mb = (int)(total_kb / 1024UL);
        if (available_kb <= total_kb) {
            g_ram_used_mb = (int)((total_kb - available_kb) / 1024UL);
        }
    }
}

static void refresh_cpu_util(void) {
    FILE* fp = fopen("/proc/stat", "r");
    if (!fp) return;
    char cpu[16];
    unsigned long long user = 0, nice = 0, system = 0, idle = 0, iowait = 0;
    unsigned long long irq = 0, softirq = 0, steal = 0;
    int got = fscanf(
        fp,
        "%15s %llu %llu %llu %llu %llu %llu %llu %llu",
        cpu, &user, &nice, &system, &idle, &iowait, &irq, &softirq, &steal
    );
    fclose(fp);
    if (got < 8) return;
    unsigned long long idle_all = idle + iowait;
    unsigned long long total = user + nice + system + idle + iowait + irq + softirq + steal;
    if (g_prev_cpu_total > 0 && total > g_prev_cpu_total) {
        unsigned long long total_delta = total - g_prev_cpu_total;
        unsigned long long idle_delta = idle_all - g_prev_cpu_idle;
        if (total_delta > 0 && idle_delta <= total_delta) {
            g_cpu_util_percent = (int)(((total_delta - idle_delta) * 100ULL) / total_delta);
        }
    }
    g_prev_cpu_total = total;
    g_prev_cpu_idle = idle_all;
}

int mojoui_refresh_system_metrics(void) {
    refresh_cpu_name();
    refresh_ram_metrics();
    refresh_cpu_util();

    FILE* fp = popen(
        "nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu,utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null",
        "r"
    );
    if (!fp) {
        return 0;
    }

    char line[512];
    if (!fgets(line, sizeof(line), fp)) {
        pclose(fp);
        return 0;
    }
    pclose(fp);

    char* fields[6] = {0};
    int count = 0;
    char* saveptr = NULL;
    char* tok = strtok_r(line, ",", &saveptr);
    while (tok && count < 6) {
        trim_line(tok);
        fields[count++] = tok;
        tok = strtok_r(NULL, ",", &saveptr);
    }
    if (count < 6) {
        return 0;
    }

    copy_trimmed(g_gpu_name, sizeof(g_gpu_name), fields[0]);
    copy_trimmed(g_gpu_driver, sizeof(g_gpu_driver), fields[1]);
    g_gpu_memory_total_mb = atoi(fields[2]);
    g_gpu_temperature_c = atoi(fields[3]);
    g_gpu_util_percent = atoi(fields[4]);
    g_gpu_memory_used_mb = atoi(fields[5]);
    return 1;
}

const char* mojoui_system_gpu_name(void) {
    return g_gpu_name;
}

int mojoui_system_gpu_name_len(void) {
    return (int)strlen(g_gpu_name);
}

const char* mojoui_system_gpu_driver(void) {
    return g_gpu_driver;
}

int mojoui_system_gpu_driver_len(void) {
    return (int)strlen(g_gpu_driver);
}

int mojoui_system_gpu_memory_total_mb(void) {
    return g_gpu_memory_total_mb;
}

int mojoui_system_gpu_memory_used_mb(void) {
    return g_gpu_memory_used_mb;
}

int mojoui_system_gpu_util_percent(void) {
    return g_gpu_util_percent;
}

int mojoui_system_gpu_temperature_c(void) {
    return g_gpu_temperature_c;
}

const char* mojoui_system_cpu_name(void) {
    return g_cpu_name;
}

int mojoui_system_cpu_name_len(void) {
    return (int)strlen(g_cpu_name);
}

int mojoui_system_cpu_util_percent(void) {
    return g_cpu_util_percent;
}

int mojoui_system_ram_total_mb(void) {
    return g_ram_total_mb;
}

int mojoui_system_ram_used_mb(void) {
    return g_ram_used_mb;
}

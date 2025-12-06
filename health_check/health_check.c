#include "health_check.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <dirent.h>
#include <errno.h>

static int read_file_line(const char *path, char *buf, size_t bufsize)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, bufsize, f)) {
        fclose(f);
        return -1;
    }
    size_t len = strlen(buf);
    if (len > 0 && buf[len-1] == '\n')
        buf[len-1] = '\0';
    fclose(f);
    return 0;
}

static long read_file_long(const char *path)
{
    char buf[64];
    if (read_file_line(path, buf, sizeof(buf)) < 0)
        return -1;
    return atol(buf);
}

static bool file_exists(const char *path)
{
    struct stat st;
    return (stat(path, &st) == 0);
}

static bool is_char_device(const char *path)
{
    struct stat st;
    if (stat(path, &st) < 0)
        return false;
    return S_ISCHR(st.st_mode);
}

bool health_check_watchdog(struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    if (is_char_device("/dev/watchdog")) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Watchdog device present at /dev/watchdog");
        return true;
    }
    if (is_char_device("/dev/watchdog0")) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Watchdog device present at /dev/watchdog0");
        return true;
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "No watchdog device found");
    return false;
}

bool health_check_ecc(uint32_t threshold, struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    if (!file_exists("/sys/devices/system/edac")) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "EDAC not available, assuming OK");
        return true;
    }
    uint32_t ce_total = 0;
    uint32_t ue_total = 0;
    DIR *edac_dir = opendir("/sys/devices/system/edac/mc");
    if (edac_dir) {
        struct dirent *entry;
        while ((entry = readdir(edac_dir)) != NULL) {
            if (strncmp(entry->d_name, "mc", 2) != 0)
                continue;
            char path[256];
            snprintf(path, sizeof(path),
                     "/sys/devices/system/edac/mc/%s/ce_count", entry->d_name);
            long ce = read_file_long(path);
            if (ce >= 0)
                ce_total += ce;
            snprintf(path, sizeof(path),
                     "/sys/devices/system/edac/mc/%s/ue_count", entry->d_name);
            long ue = read_file_long(path);
            if (ue >= 0)
                ue_total += ue;
        }
        closedir(edac_dir);
    }
    result->value = ce_total;
    if (ue_total > 0) {
        result->ok = false;
        snprintf(result->message, sizeof(result->message),
                 "Uncorrectable ECC errors detected: %u", ue_total);
        return false;
    }
    if (ce_total < threshold) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "ECC errors within threshold: %u < %u", ce_total, threshold);
        return true;
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "ECC errors exceed threshold: %u >= %u", ce_total, threshold);
    return false;
}

bool health_check_storage(uint8_t min_free_pct, struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    struct statvfs vfs;
    if (statvfs("/", &vfs) < 0) {
        result->ok = false;
        snprintf(result->message, sizeof(result->message),
                 "Failed to check storage: %s", strerror(errno));
        return false;
    }
    unsigned long blocks_total = vfs.f_blocks;
    unsigned long blocks_avail = vfs.f_bavail;
    uint8_t free_pct = (blocks_avail * 100) / blocks_total;
    result->value = free_pct;
    if (free_pct >= min_free_pct) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Storage healthy: %u%% free", free_pct);
        return true;
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "Storage low: %u%% free (min: %u%%)", free_pct, min_free_pct);
    return false;
}

bool health_check_network(uint8_t timeout_sec, struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    const char *targets[] = {"8.8.8.8", "1.1.1.1", NULL};
    for (int i = 0; targets[i] != NULL; i++) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
                 "ping -c 1 -W %u %s >/dev/null 2>&1",
                 timeout_sec, targets[i]);
        if (system(cmd) == 0) {
            result->ok = true;
            snprintf(result->message, sizeof(result->message),
                     "Network reachable (tested: %s)", targets[i]);
            return true;
        }
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "Network unreachable");
    return false;
}

bool health_check_memory(uint32_t min_free_kb, struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) {
        result->ok = false;
        snprintf(result->message, sizeof(result->message),
                 "Failed to read /proc/meminfo");
        return false;
    }
    char line[256];
    long mem_available = -1;
    long mem_free = -1;
    long mem_total = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "MemAvailable:", 13) == 0) {
            sscanf(line + 13, "%ld", &mem_available);
        } else if (strncmp(line, "MemFree:", 8) == 0) {
            sscanf(line + 8, "%ld", &mem_free);
        } else if (strncmp(line, "MemTotal:", 9) == 0) {
            sscanf(line + 9, "%ld", &mem_total);
        }
    }
    fclose(f);
    long mem_avail = (mem_available >= 0) ? mem_available : mem_free;
    if (mem_avail < 0 || mem_total < 0) {
        result->ok = false;
        snprintf(result->message, sizeof(result->message),
                 "Failed to parse memory info");
        return false;
    }
    result->value = mem_avail;
    uint8_t mem_pct = (mem_avail * 100) / mem_total;
    if (mem_avail >= (long)min_free_kb) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Memory healthy: %ldKB available (%u%%)", mem_avail, mem_pct);
        return true;
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "Low memory: %ldKB available (%u%%)", mem_avail, mem_pct);
    return false;
}

bool health_check_temperature(uint8_t max_celsius, struct HealthCheckResult *result)
{
    memset(result, 0, sizeof(*result));
    uint8_t max_temp = 0;
    bool temp_found = false;
    DIR *thermal_dir = opendir("/sys/class/thermal");
    if (thermal_dir) {
        struct dirent *entry;
        while ((entry = readdir(thermal_dir)) != NULL) {
            if (strncmp(entry->d_name, "thermal_zone", 12) != 0)
                continue;
            char path[256];
            snprintf(path, sizeof(path),
                     "/sys/class/thermal/%s/temp", entry->d_name);
            long temp_millic = read_file_long(path);
            if (temp_millic > 0) {
                uint8_t temp_c = temp_millic / 1000;
                if (temp_c > max_temp)
                    max_temp = temp_c;
                temp_found = true;
            }
        }
        closedir(thermal_dir);
    }
    DIR *hwmon_dir = opendir("/sys/class/hwmon");
    if (hwmon_dir) {
        struct dirent *entry;
        while ((entry = readdir(thermal_dir)) != NULL) {
            char hwmon_path[256];
            snprintf(hwmon_path, sizeof(hwmon_path),
                     "/sys/class/hwmon/%s", entry->d_name);
            DIR *sensor_dir = opendir(hwmon_path);
            if (!sensor_dir)
                continue;
            struct dirent *sensor;
            while ((sensor = readdir(sensor_dir)) != NULL) {
                if (strstr(sensor->d_name, "temp") && strstr(sensor->d_name, "_input")) {
                    char path[512];
                    snprintf(path, sizeof(path), "%s/%s", hwmon_path, sensor->d_name);
                    long temp_millic = read_file_long(path);
                    if (temp_millic > 0) {
                        uint8_t temp_c = temp_millic / 1000;
                        if (temp_c > max_temp)
                            max_temp = temp_c;
                        temp_found = true;
                    }
                }
            }
            closedir(sensor_dir);
        }
        closedir(hwmon_dir);
    }
    if (!temp_found) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Temperature monitoring not available");
        return true;
    }
    result->value = max_temp;
    if (max_temp <= max_celsius) {
        result->ok = true;
        snprintf(result->message, sizeof(result->message),
                 "Temperature normal: %u°C (max: %u°C)", max_temp, max_celsius);
        return true;
    }
    result->ok = false;
    snprintf(result->message, sizeof(result->message),
             "Temperature critical: %u°C (max: %u°C)", max_temp, max_celsius);
    return false;
}

int health_check_run(const struct HealthConfig *config, struct HealthReport *report)
{
    if (!report)
        return HEALTH_ERROR;
    struct HealthConfig default_config = HEALTH_CONFIG_DEFAULT;
    if (!config)
        config = &default_config;
    health_report_clear(report);
    report->timestamp = time(NULL);
    health_check_watchdog(&report->watchdog);
    health_check_ecc(config->ecc_threshold, &report->ecc);
    health_check_storage(config->storage_min_free_pct, &report->storage);
    health_check_network(config->network_timeout_sec, &report->network);
    health_check_memory(config->mem_min_free_kb, &report->memory);
    health_check_temperature(config->temp_max_celsius, &report->temperature);
    report->overall_score = 0;
    if (report->watchdog.ok) report->overall_score++;
    if (report->ecc.ok) report->overall_score++;
    if (report->storage.ok) report->overall_score++;
    if (report->network.ok) report->overall_score++;
    if (report->memory.ok) report->overall_score++;
    if (report->temperature.ok) report->overall_score++;
    report->max_score = 6;
    const char *status = health_score_to_status(report->overall_score, report->max_score);
    strncpy(report->overall_status, status, sizeof(report->overall_status) - 1);
    if (report->overall_score >= 5)
        return HEALTH_OK;
    else if (report->overall_score >= 3)
        return HEALTH_DEGRADED;
    else
        return HEALTH_CRITICAL;
}

void health_report_print(const struct HealthReport *report)
{
    printf("\n");
    printf("  PAC Health Check Report                                  \n");
    printf("\n\n");
    printf("Timestamp: %ld\n", (long)report->timestamp);
    printf("Overall Status: %s (%u/%u checks passed)\n\n",
           report->overall_status, report->overall_score, report->max_score);
    printf("Individual Checks:\n");
    printf("  [%s] Watchdog:    %s\n",
           report->watchdog.ok ? "" : "", report->watchdog.message);
    printf("  [%s] ECC Memory:  %s\n",
           report->ecc.ok ? "" : "", report->ecc.message);
    printf("  [%s] Storage:     %s\n",
           report->storage.ok ? "" : "", report->storage.message);
    printf("  [%s] Network:     %s\n",
           report->network.ok ? "" : "", report->network.message);
    printf("  [%s] Memory:      %s\n",
           report->memory.ok ? "" : "", report->memory.message);
    printf("  [%s] Temperature: %s\n",
           report->temperature.ok ? "" : "", report->temperature.message);
    printf("\n");
}

int health_report_to_json(const struct HealthReport *report, char *buffer, size_t bufsize)
{
    return snprintf(buffer, bufsize,
        "{\n"
        "  \"timestamp\": %ld,\n"
        "  \"overall_score\": %u,\n"
        "  \"max_score\": %u,\n"
        "  \"overall_status\": \"%s\",\n"
        "  \"checks\": {\n"
        "    \"watchdog\": {\"ok\": %s, \"message\": \"%s\"},\n"
        "    \"ecc\": {\"ok\": %s, \"message\": \"%s\"},\n"
        "    \"storage\": {\"ok\": %s, \"message\": \"%s\"},\n"
        "    \"network\": {\"ok\": %s, \"message\": \"%s\"},\n"
        "    \"memory\": {\"ok\": %s, \"message\": \"%s\"},\n"
        "    \"temperature\": {\"ok\": %s, \"message\": \"%s\"}\n"
        "  },\n"
        "  \"legacy_format\": {\n"
        "    \"wdt_ok\": %d,\n"
        "    \"ecc_ok\": %d,\n"
        "    \"storage_ok\": %d,\n"
        "    \"net_ok\": %d,\n"
        "    \"mem_ok\": %d,\n"
        "    \"temp_ok\": %d\n"
        "  }\n"
        "}\n",
        (long)report->timestamp,
        report->overall_score,
        report->max_score,
        report->overall_status,
        report->watchdog.ok ? "true" : "false", report->watchdog.message,
        report->ecc.ok ? "true" : "false", report->ecc.message,
        report->storage.ok ? "true" : "false", report->storage.message,
        report->network.ok ? "true" : "false", report->network.message,
        report->memory.ok ? "true" : "false", report->memory.message,
        report->temperature.ok ? "true" : "false", report->temperature.message,
        report->watchdog.ok ? 1 : 0,
        report->ecc.ok ? 1 : 0,
        report->storage.ok ? 1 : 0,
        report->network.ok ? 1 : 0,
        report->memory.ok ? 1 : 0,
        report->temperature.ok ? 1 : 0
    );
}

int health_report_to_file(const struct HealthReport *report, const char *filename)
{
    char buffer[4096];
    int len = health_report_to_json(report, buffer, sizeof(buffer));
    if (len < 0 || len >= (int)sizeof(buffer))
        return -1;
    FILE *f = fopen(filename, "w");
    if (!f)
        return -1;
    fputs(buffer, f);
    fclose(f);
    return 0;
}

void health_config_default(struct HealthConfig *config)
{
    struct HealthConfig defaults = HEALTH_CONFIG_DEFAULT;
    memcpy(config, &defaults, sizeof(*config));
}

void health_report_clear(struct HealthReport *report)
{
    memset(report, 0, sizeof(*report));
}

const char *health_score_to_status(uint8_t score, uint8_t max)
{
    if (score >= (max * 5) / 6)  
        return "healthy";
    else if (score >= max / 2)    
        return "degraded";
    else
        return "critical";
}
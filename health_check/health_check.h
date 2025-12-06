#ifndef HEALTH_CHECK_H
#define HEALTH_CHECK_H
#include <stdint.h>
#include <stdbool.h>
#include <time.h>

struct HealthCheckResult {
    bool ok;                    
    char message[256];          
    uint32_t value;             
};

struct HealthReport {
    time_t timestamp;           
    struct HealthCheckResult watchdog;
    struct HealthCheckResult ecc;
    struct HealthCheckResult storage;
    struct HealthCheckResult network;
    struct HealthCheckResult memory;
    struct HealthCheckResult temperature;
    uint8_t  overall_score;     
    uint8_t  max_score;         
    char     overall_status[32];
};

struct HealthConfig {
    uint32_t ecc_threshold;         
    uint32_t mem_min_free_kb;       
    uint8_t  storage_min_free_pct;  
    uint8_t  network_timeout_sec;   
    uint8_t  temp_max_celsius;      
    bool     verbose;               
};

#define HEALTH_CONFIG_DEFAULT { \
    .ecc_threshold = 10, \
    .mem_min_free_kb = 10240, \
    .storage_min_free_pct = 5, \
    .network_timeout_sec = 2, \
    .temp_max_celsius = 85, \
    .verbose = false \
}

#define HEALTH_OK           0
#define HEALTH_DEGRADED     1
#define HEALTH_CRITICAL     2
#define HEALTH_ERROR       -1

int health_check_run(const struct HealthConfig *config, struct HealthReport *report);
bool health_check_watchdog(struct HealthCheckResult *result);
bool health_check_ecc(uint32_t threshold, struct HealthCheckResult *result);
bool health_check_storage(uint8_t min_free_pct, struct HealthCheckResult *result);
bool health_check_network(uint8_t timeout_sec, struct HealthCheckResult *result);
bool health_check_memory(uint32_t min_free_kb, struct HealthCheckResult *result);
bool health_check_temperature(uint8_t max_celsius, struct HealthCheckResult *result);
void health_report_print(const struct HealthReport *report);
int health_report_to_json(const struct HealthReport *report, char *buffer, size_t bufsize);
int health_report_to_file(const struct HealthReport *report, const char *filename);
void health_config_default(struct HealthConfig *config);
void health_report_clear(struct HealthReport *report);
const char *health_score_to_status(uint8_t score, uint8_t max);

#endif 

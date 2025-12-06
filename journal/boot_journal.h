#ifndef BOOT_JOURNAL_H
#define BOOT_JOURNAL_H

#include <stdint.h>
#include <stdbool.h>

#define JOURNAL_MAGIC       0xA771A771  
#define JOURNAL_VERSION     1
#define TIER_1              1
#define TIER_2              2
#define TIER_3              3
#define FLAG_EMERGENCY      (1 << 0)  
#define FLAG_QUARANTINE     (1 << 1)  
#define FLAG_BROWNOUT       (1 << 2)  
#define FLAG_DIRTY          (1 << 3)  
#define FLAG_NETWORK_GATED  (1 << 4)  
#define DEFAULT_TRIES_T2    3
#define DEFAULT_TRIES_T3    3

struct BootRecord {
    uint32_t version;        
    uint8_t  tier;           
    uint8_t  tries_t2;       
    uint8_t  tries_t3;       
    uint8_t  rollback_idx;   
    uint32_t flags;          
    uint64_t boot_count;     
    uint64_t timestamp;      
    uint32_t crc32;          
    uint32_t trailer;        
} __attribute__((packed));

#define JOURNAL_OK           0
#define JOURNAL_ERR_IO      -1
#define JOURNAL_ERR_CORRUPT -2
#define JOURNAL_ERR_INVALID -3
#define JOURNAL_ERR_NOMEM   -4

int journal_init(const char *path);
int journal_read(struct BootRecord *rec);
int journal_write(const struct BootRecord *rec);
int journal_recover(struct BootRecord *rec);
const char *journal_get_path(void);
void journal_close(void);
void journal_create_default(struct BootRecord *rec);
bool journal_validate(const struct BootRecord *rec);
void journal_print(const struct BootRecord *rec);
int journal_decrement_tries(struct BootRecord *rec, uint8_t tier);
void journal_reset_tries(struct BootRecord *rec);
void journal_set_flag(struct BootRecord *rec, uint32_t flag);
void journal_clear_flag(struct BootRecord *rec, uint32_t flag);
bool journal_has_flag(const struct BootRecord *rec, uint32_t flag);

#endif 
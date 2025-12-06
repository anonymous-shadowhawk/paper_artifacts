#include "boot_journal.h"
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>

static uint32_t crc32_table[256];
static bool crc32_table_initialized = false;
static struct {
    char *path;
    int fd;
    bool initialized;
} journal_state = {NULL, -1, false};

#define PAGE_SIZE sizeof(struct BootRecord)
#define PAGE_A_OFFSET 0
#define PAGE_B_OFFSET PAGE_SIZE
#define JOURNAL_FILE_SIZE (PAGE_SIZE * 2)

static void crc32_init_table(void)
{
    uint32_t poly = 0xEDB88320;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++) {
            if (crc & 1)
                crc = (crc >> 1) ^ poly;
            else
                crc >>= 1;
        }
        crc32_table[i] = crc;
    }
    crc32_table_initialized = true;
}

static uint32_t crc32_compute(const void *data, size_t len)
{
    const uint8_t *buf = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFF;
    if (!crc32_table_initialized)
        crc32_init_table();
    for (size_t i = 0; i < len; i++) {
        crc = (crc >> 8) ^ crc32_table[(crc ^ buf[i]) & 0xFF];
    }
    return ~crc;
}

static uint32_t record_calculate_crc(const struct BootRecord *rec)
{
    size_t crc_len = offsetof(struct BootRecord, crc32);
    return crc32_compute(rec, crc_len);
}

static int read_page(int fd, off_t offset, struct BootRecord *rec)
{
    if (lseek(fd, offset, SEEK_SET) != offset) {
        fprintf(stderr, "journal: lseek failed: %s\n", strerror(errno));
        return JOURNAL_ERR_IO;
    }
    ssize_t n = read(fd, rec, PAGE_SIZE);
    if (n != PAGE_SIZE) {
        if (n < 0)
            fprintf(stderr, "journal: read failed: %s\n", strerror(errno));
        else
            fprintf(stderr, "journal: short read: got %zd, expected %zu\n", n, PAGE_SIZE);
        return JOURNAL_ERR_IO;
    }
    return JOURNAL_OK;
}

static int write_page(int fd, off_t offset, const struct BootRecord *rec)
{
    if (lseek(fd, offset, SEEK_SET) != offset) {
        fprintf(stderr, "journal: lseek failed: %s\n", strerror(errno));
        return JOURNAL_ERR_IO;
    }
    ssize_t n = write(fd, rec, PAGE_SIZE);
    if (n != PAGE_SIZE) {
        if (n < 0)
            fprintf(stderr, "journal: write failed: %s\n", strerror(errno));
        else
            fprintf(stderr, "journal: short write: wrote %zd, expected %zu\n", n, PAGE_SIZE);
        return JOURNAL_ERR_IO;
    }
    if (fsync(fd) != 0) {
        fprintf(stderr, "journal: fsync failed: %s\n", strerror(errno));
        return JOURNAL_ERR_IO;
    }
    return JOURNAL_OK;
}

bool journal_validate(const struct BootRecord *rec)
{
    if (rec->trailer != JOURNAL_MAGIC) {
        return false;
    }
    uint32_t calculated_crc = record_calculate_crc(rec);
    if (rec->crc32 != calculated_crc) {
        return false;
    }
    if (rec->version != JOURNAL_VERSION) {
        return false;
    }
    if (rec->tier < TIER_1 || rec->tier > TIER_3) {
        return false;
    }
    return true;
}

void journal_create_default(struct BootRecord *rec)
{
    memset(rec, 0, sizeof(*rec));
    rec->version = JOURNAL_VERSION;
    rec->tier = TIER_1;
    rec->tries_t2 = DEFAULT_TRIES_T2;
    rec->tries_t3 = DEFAULT_TRIES_T3;
    rec->rollback_idx = 0;
    rec->flags = 0;
    rec->boot_count = 0;
    rec->timestamp = (uint64_t)time(NULL);
    rec->trailer = JOURNAL_MAGIC;
    rec->crc32 = record_calculate_crc(rec);
}

int journal_init(const char *path)
{
    if (!path) {
        fprintf(stderr, "journal: path is NULL\n");
        return JOURNAL_ERR_INVALID;
    }
    if (journal_state.initialized) {
        journal_close();
    }
    journal_state.path = strdup(path);
    if (!journal_state.path) {
        fprintf(stderr, "journal: strdup failed\n");
        return JOURNAL_ERR_NOMEM;
    }
    struct stat st;
    bool exists = (stat(path, &st) == 0);
    int flags = O_RDWR | O_CREAT;
    int mode = 0600;  
    journal_state.fd = open(path, flags, mode);
    if (journal_state.fd < 0) {
        fprintf(stderr, "journal: open failed: %s\n", strerror(errno));
        free(journal_state.path);
        journal_state.path = NULL;
        return JOURNAL_ERR_IO;
    }
    if (!exists || st.st_size < JOURNAL_FILE_SIZE) {
        struct BootRecord rec;
        journal_create_default(&rec);
        if (write_page(journal_state.fd, PAGE_A_OFFSET, &rec) != JOURNAL_OK) {
            close(journal_state.fd);
            free(journal_state.path);
            journal_state.path = NULL;
            journal_state.fd = -1;
            return JOURNAL_ERR_IO;
        }
        if (write_page(journal_state.fd, PAGE_B_OFFSET, &rec) != JOURNAL_OK) {
            close(journal_state.fd);
            free(journal_state.path);
            journal_state.path = NULL;
            journal_state.fd = -1;
            return JOURNAL_ERR_IO;
        }
        printf("journal: created new journal at %s\n", path);
    } else {
        printf("journal: opened existing journal at %s\n", path);
    }
    journal_state.initialized = true;
    return JOURNAL_OK;
}

int journal_recover(struct BootRecord *rec)
{
    if (!journal_state.initialized || journal_state.fd < 0) {
        fprintf(stderr, "journal: not initialized\n");
        return JOURNAL_ERR_INVALID;
    }
    struct BootRecord page_a, page_b;
    bool a_valid = false, b_valid = false;
    if (read_page(journal_state.fd, PAGE_A_OFFSET, &page_a) == JOURNAL_OK) {
        a_valid = journal_validate(&page_a);
    }
    if (read_page(journal_state.fd, PAGE_B_OFFSET, &page_b) == JOURNAL_OK) {
        b_valid = journal_validate(&page_b);
    }
    if (a_valid && b_valid) {
        if (page_a.boot_count >= page_b.boot_count) {
            memcpy(rec, &page_a, sizeof(*rec));
            printf("journal: recovered from page A (boot_count=%lu)\n", 
                   (unsigned long)page_a.boot_count);
        } else {
            memcpy(rec, &page_b, sizeof(*rec));
            printf("journal: recovered from page B (boot_count=%lu)\n", 
                   (unsigned long)page_b.boot_count);
        }
        return JOURNAL_OK;
    } else if (a_valid) {
        memcpy(rec, &page_a, sizeof(*rec));
        printf("journal: recovered from page A only\n");
        write_page(journal_state.fd, PAGE_B_OFFSET, &page_a);
        return JOURNAL_OK;
    } else if (b_valid) {
        memcpy(rec, &page_b, sizeof(*rec));
        printf("journal: recovered from page B only\n");
        write_page(journal_state.fd, PAGE_A_OFFSET, &page_b);
        return JOURNAL_OK;
    } else {
        fprintf(stderr, "journal: both pages corrupt, creating default\n");
        journal_create_default(rec);
        write_page(journal_state.fd, PAGE_A_OFFSET, rec);
        write_page(journal_state.fd, PAGE_B_OFFSET, rec);
        return JOURNAL_OK;  
    }
}

int journal_read(struct BootRecord *rec)
{
    if (!rec) {
        fprintf(stderr, "journal: rec is NULL\n");
        return JOURNAL_ERR_INVALID;
    }
    if (!journal_state.initialized || journal_state.fd < 0) {
        fprintf(stderr, "journal: not initialized\n");
        return JOURNAL_ERR_INVALID;
    }
    return journal_recover(rec);
}

int journal_write(const struct BootRecord *rec)
{
    if (!rec) {
        fprintf(stderr, "journal: rec is NULL\n");
        return JOURNAL_ERR_INVALID;
    }
    if (!journal_state.initialized || journal_state.fd < 0) {
        fprintf(stderr, "journal: not initialized\n");
        return JOURNAL_ERR_INVALID;
    }
    struct BootRecord updated;
    memcpy(&updated, rec, sizeof(updated));
    updated.timestamp = (uint64_t)time(NULL);
    updated.trailer = JOURNAL_MAGIC;
    updated.crc32 = record_calculate_crc(&updated);
    if (!journal_validate(&updated)) {
        fprintf(stderr, "journal: record validation failed before write\n");
        return JOURNAL_ERR_INVALID;
    }
    if (write_page(journal_state.fd, PAGE_A_OFFSET, &updated) != JOURNAL_OK) {
        return JOURNAL_ERR_IO;
    }
    if (write_page(journal_state.fd, PAGE_B_OFFSET, &updated) != JOURNAL_OK) {
        fprintf(stderr, "journal: warning - page B write failed\n");
        return JOURNAL_ERR_IO;
    }
    return JOURNAL_OK;
}

const char *journal_get_path(void)
{
    return journal_state.path;
}

void journal_close(void)
{
    if (journal_state.fd >= 0) {
        close(journal_state.fd);
        journal_state.fd = -1;
    }
    if (journal_state.path) {
        free(journal_state.path);
        journal_state.path = NULL;
    }
    journal_state.initialized = false;
}

void journal_print(const struct BootRecord *rec)
{
    printf("=== Boot Record ===\n");
    printf("  Version:       %u\n", rec->version);
    printf("  Tier:          %u\n", rec->tier);
    printf("  Tries T2:      %u\n", rec->tries_t2);
    printf("  Tries T3:      %u\n", rec->tries_t3);
    printf("  Rollback IDX:  %u\n", rec->rollback_idx);
    printf("  Flags:         0x%08X", rec->flags);
    if (rec->flags) {
        printf(" (");
        if (rec->flags & FLAG_EMERGENCY) printf("EMERGENCY ");
        if (rec->flags & FLAG_QUARANTINE) printf("QUARANTINE ");
        if (rec->flags & FLAG_BROWNOUT) printf("BROWNOUT ");
        if (rec->flags & FLAG_DIRTY) printf("DIRTY ");
        if (rec->flags & FLAG_NETWORK_GATED) printf("NETWORK_GATED ");
        printf(")");
    }
    printf("\n");
    printf("  Boot Count:    %lu\n", (unsigned long)rec->boot_count);
    printf("  Timestamp:     %lu (%s", (unsigned long)rec->timestamp,
           ctime((time_t *)&rec->timestamp));  
    printf("  CRC32:         0x%08X\n", rec->crc32);
    printf("  Trailer:       0x%08X %s\n", rec->trailer,
           rec->trailer == JOURNAL_MAGIC ? "(OK)" : "(INVALID)");
    printf("  Valid:         %s\n", journal_validate(rec) ? "YES" : "NO");
    printf("===================\n");
}

int journal_decrement_tries(struct BootRecord *rec, uint8_t tier)
{
    if (tier == TIER_2) {
        if (rec->tries_t2 > 0) {
            rec->tries_t2--;
        }
        return rec->tries_t2;
    } else if (tier == TIER_3) {
        if (rec->tries_t3 > 0) {
            rec->tries_t3--;
        }
        return rec->tries_t3;
    }
    return -1;
}

void journal_reset_tries(struct BootRecord *rec)
{
    rec->tries_t2 = DEFAULT_TRIES_T2;
    rec->tries_t3 = DEFAULT_TRIES_T3;
}

void journal_set_flag(struct BootRecord *rec, uint32_t flag)
{
    rec->flags |= flag;
}

void journal_clear_flag(struct BootRecord *rec, uint32_t flag)
{
    rec->flags &= ~flag;
}

bool journal_has_flag(const struct BootRecord *rec, uint32_t flag)
{
    return (rec->flags & flag) != 0;
}

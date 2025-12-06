#include "boot_journal.h"
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#define TEST_JOURNAL_PATH "/tmp/test_boot_journal.dat"

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST_START(name) \
    printf("\n[TEST] %s...\n", name)
#define TEST_ASSERT(condition, msg) \
    do { \
        if (condition) { \
            printf("   %s\n", msg); \
            tests_passed++; \
        } else { \
            printf("   FAILED: %s\n", msg); \
            tests_failed++; \
        } \
    } while(0)
#define TEST_END() \
    printf("  Done.\n")

static void cleanup_test_journal(void)
{
    journal_close();
    unlink(TEST_JOURNAL_PATH);
}

static void test_init(void)
{
    TEST_START("Journal Initialization");
    cleanup_test_journal();
    int ret = journal_init(TEST_JOURNAL_PATH);
    TEST_ASSERT(ret == JOURNAL_OK, "Initialize new journal");
    const char *path = journal_get_path();
    TEST_ASSERT(path != NULL, "Get journal path");
    TEST_ASSERT(strcmp(path, TEST_JOURNAL_PATH) == 0, "Path matches");
    journal_close();
    ret = journal_init(TEST_JOURNAL_PATH);
    TEST_ASSERT(ret == JOURNAL_OK, "Re-open existing journal");
    TEST_END();
}

static void test_default_record(void)
{
    TEST_START("Default Record Creation");
    struct BootRecord rec;
    journal_create_default(&rec);
    TEST_ASSERT(rec.version == JOURNAL_VERSION, "Version is correct");
    TEST_ASSERT(rec.tier == TIER_1, "Default tier is 1");
    TEST_ASSERT(rec.tries_t2 == DEFAULT_TRIES_T2, "T2 tries initialized");
    TEST_ASSERT(rec.tries_t3 == DEFAULT_TRIES_T3, "T3 tries initialized");
    TEST_ASSERT(rec.rollback_idx == 0, "Rollback index is 0");
    TEST_ASSERT(rec.flags == 0, "No flags set");
    TEST_ASSERT(rec.trailer == JOURNAL_MAGIC, "Magic trailer present");
    TEST_ASSERT(journal_validate(&rec), "Record is valid");
    TEST_END();
}

static void test_read_write(void)
{
    TEST_START("Read/Write Operations");
    cleanup_test_journal();
    journal_init(TEST_JOURNAL_PATH);
    struct BootRecord write_rec;
    journal_create_default(&write_rec);
    write_rec.tier = TIER_2;
    write_rec.tries_t2 = 2;
    write_rec.boot_count = 42;
    write_rec.flags = FLAG_EMERGENCY | FLAG_BROWNOUT;
    int ret = journal_write(&write_rec);
    TEST_ASSERT(ret == JOURNAL_OK, "Write record");
    struct BootRecord read_rec;
    ret = journal_read(&read_rec);
    TEST_ASSERT(ret == JOURNAL_OK, "Read record");
    TEST_ASSERT(read_rec.tier == TIER_2, "Tier matches");
    TEST_ASSERT(read_rec.tries_t2 == 2, "T2 tries matches");
    TEST_ASSERT(read_rec.boot_count == 42, "Boot count matches");
    TEST_ASSERT(read_rec.flags & FLAG_EMERGENCY, "Emergency flag set");
    TEST_ASSERT(read_rec.flags & FLAG_BROWNOUT, "Brownout flag set");
    TEST_ASSERT(journal_validate(&read_rec), "Read record is valid");
    TEST_END();
}

static void test_flags(void)
{
    TEST_START("Flag Operations");
    struct BootRecord rec;
    journal_create_default(&rec);
    journal_set_flag(&rec, FLAG_EMERGENCY);
    TEST_ASSERT(journal_has_flag(&rec, FLAG_EMERGENCY), "Emergency flag set");
    TEST_ASSERT(!journal_has_flag(&rec, FLAG_QUARANTINE), "Quarantine flag not set");
    journal_set_flag(&rec, FLAG_QUARANTINE);
    TEST_ASSERT(journal_has_flag(&rec, FLAG_EMERGENCY), "Emergency flag still set");
    TEST_ASSERT(journal_has_flag(&rec, FLAG_QUARANTINE), "Quarantine flag set");
    journal_clear_flag(&rec, FLAG_EMERGENCY);
    TEST_ASSERT(!journal_has_flag(&rec, FLAG_EMERGENCY), "Emergency flag cleared");
    TEST_ASSERT(journal_has_flag(&rec, FLAG_QUARANTINE), "Quarantine flag still set");
    TEST_END();
}

static void test_try_counters(void)
{
    TEST_START("Try Counter Operations");
    struct BootRecord rec;
    journal_create_default(&rec);
    TEST_ASSERT(rec.tries_t2 == DEFAULT_TRIES_T2, "Initial T2 tries");
    TEST_ASSERT(rec.tries_t3 == DEFAULT_TRIES_T3, "Initial T3 tries");
    int remaining = journal_decrement_tries(&rec, TIER_2);
    TEST_ASSERT(remaining == DEFAULT_TRIES_T2 - 1, "T2 decremented");
    TEST_ASSERT(rec.tries_t2 == DEFAULT_TRIES_T2 - 1, "T2 counter updated");
    remaining = journal_decrement_tries(&rec, TIER_3);
    TEST_ASSERT(remaining == DEFAULT_TRIES_T3 - 1, "T3 decremented");
    TEST_ASSERT(rec.tries_t3 == DEFAULT_TRIES_T3 - 1, "T3 counter updated");
    rec.tries_t2 = 1;
    remaining = journal_decrement_tries(&rec, TIER_2);
    TEST_ASSERT(remaining == 0, "T2 exhausted");
    remaining = journal_decrement_tries(&rec, TIER_2);
    TEST_ASSERT(remaining == 0, "T2 stays at 0");
    journal_reset_tries(&rec);
    TEST_ASSERT(rec.tries_t2 == DEFAULT_TRIES_T2, "T2 reset");
    TEST_ASSERT(rec.tries_t3 == DEFAULT_TRIES_T3, "T3 reset");
    TEST_END();
}

static void test_corruption_recovery(void)
{
    TEST_START("Corruption Recovery");
    cleanup_test_journal();
    journal_init(TEST_JOURNAL_PATH);
    struct BootRecord good_rec;
    journal_create_default(&good_rec);
    good_rec.tier = TIER_3;
    good_rec.boot_count = 100;
    journal_write(&good_rec);
    journal_close();
    FILE *f = fopen(TEST_JOURNAL_PATH, "r+b");
    TEST_ASSERT(f != NULL, "Open journal for corruption");
    if (f) {
        fseek(f, offsetof(struct BootRecord, crc32), SEEK_SET);
        uint32_t bad_crc = 0xDEADBEEF;
        fwrite(&bad_crc, sizeof(bad_crc), 1, f);
        fclose(f);
    }
    journal_init(TEST_JOURNAL_PATH);
    struct BootRecord recovered;
    int ret = journal_read(&recovered);
    TEST_ASSERT(ret == JOURNAL_OK, "Recovery succeeded");
    TEST_ASSERT(recovered.tier == TIER_3, "Recovered tier correct");
    TEST_ASSERT(recovered.boot_count == 100, "Recovered boot count correct");
    TEST_ASSERT(journal_validate(&recovered), "Recovered record valid");
    TEST_END();
}

static void test_persistence(void)
{
    TEST_START("Multiple Write Persistence");
    cleanup_test_journal();
    journal_init(TEST_JOURNAL_PATH);
    for (int i = 0; i < 5; i++) {
        struct BootRecord rec;
        journal_read(&rec);
        rec.boot_count++;
        rec.tier = (i % 3) + 1;  
        int ret = journal_write(&rec);
        TEST_ASSERT(ret == JOURNAL_OK, "Write iteration succeeded");
        journal_close();
        journal_init(TEST_JOURNAL_PATH);
        struct BootRecord read_back;
        journal_read(&read_back);
        TEST_ASSERT(read_back.boot_count == i + 1, "Boot count persisted");
        TEST_ASSERT(read_back.tier == rec.tier, "Tier persisted");
    }
    TEST_END();
}

static void test_boot_scenario(void)
{
    TEST_START("Simulated Boot Scenario");
    cleanup_test_journal();
    journal_init(TEST_JOURNAL_PATH);
    struct BootRecord rec;
    journal_read(&rec);
    TEST_ASSERT(rec.tier == TIER_1, "Start in Tier 1");
    rec.boot_count++;
    journal_decrement_tries(&rec, TIER_2);
    journal_set_flag(&rec, FLAG_DIRTY);
    journal_write(&rec);
    TEST_ASSERT(rec.tries_t2 == DEFAULT_TRIES_T2 - 1, "T2 try consumed");
    journal_read(&rec);
    rec.boot_count++;
    rec.tier = TIER_2;
    journal_clear_flag(&rec, FLAG_DIRTY);
    journal_reset_tries(&rec);  
    journal_write(&rec);
    TEST_ASSERT(rec.tier == TIER_2, "Promoted to Tier 2");
    journal_read(&rec);
    rec.boot_count++;
    journal_set_flag(&rec, FLAG_BROWNOUT);
    journal_decrement_tries(&rec, TIER_3);
    journal_write(&rec);
    TEST_ASSERT(journal_has_flag(&rec, FLAG_BROWNOUT), "Brownout detected");
    journal_read(&rec);
    rec.boot_count++;
    rec.tier = TIER_1;  
    journal_clear_flag(&rec, FLAG_BROWNOUT);
    journal_write(&rec);
    TEST_ASSERT(rec.tier == TIER_1, "Dropped back to Tier 1");
    journal_read(&rec);
    rec.boot_count++;
    journal_set_flag(&rec, FLAG_EMERGENCY);
    journal_write(&rec);
    TEST_ASSERT(journal_has_flag(&rec, FLAG_EMERGENCY), "Emergency mode active");
    printf("  -> Boot count reached: %lu\n", (unsigned long)rec.boot_count);
    journal_print(&rec);
    TEST_END();
}

int main(void)
{
    printf("\n");
    printf("  PAC Boot Journal Test Suite                              \n");
    printf("\n");
    test_init();
    test_default_record();
    test_read_write();
    test_flags();
    test_try_counters();
    test_corruption_recovery();
    test_persistence();
    test_boot_scenario();
    cleanup_test_journal();
    printf("\n\n");
    printf("  TEST SUMMARY                                              \n");
    printf("\n");
    printf("  Passed: %3d                                               \n", tests_passed);
    printf("  Failed: %3d                                               \n", tests_failed);
    printf("\n");
    if (tests_failed == 0) {
        printf("\n All tests PASSED! Boot journal is working correctly.\n\n");
        return 0;
    } else {
        printf("\n Some tests FAILED. Please review the output above.\n\n");
        return 1;
    }
}
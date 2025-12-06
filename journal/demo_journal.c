#include "boot_journal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define DEMO_JOURNAL_PATH "/tmp/demo_journal.dat"

static void print_separator(void)
{
    printf("\n");
    printf("\n");
}

static void simulate_boot(int boot_num, const char *scenario)
{
    printf("\n Boot #%d: %s\n", boot_num, scenario);
    print_separator();
}

int main(void)
{
    int ret;
    struct BootRecord rec;
    printf("\n");
    printf("  PAC Boot Journal - Interactive Demo                      \n");
    printf("  Simulating realistic boot scenarios                      \n");
    printf("\n");
    unlink(DEMO_JOURNAL_PATH);
    simulate_boot(1, "First boot - fresh system");
    ret = journal_init(DEMO_JOURNAL_PATH);
    if (ret != JOURNAL_OK) {
        fprintf(stderr, "Failed to initialize journal\n");
        return 1;
    }
    
    journal_read(&rec);
    rec.boot_count++;
    printf("-> System starts in Tier %d (safe minimal mode)\n", rec.tier);
    printf("-> Performing basic health checks...\n");
    printf("-> Health OK: attempting promotion to Tier 2\n");
    rec.tier = TIER_2;
    journal_reset_tries(&rec);
    journal_write(&rec);
    printf(" Successfully reached Tier 2\n");
    journal_print(&rec);
    journal_close();
    simulate_boot(2, "Boot interrupted by brownout");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    printf("-> Starting from Tier %d\n", rec.tier);
    printf("-> Attempting to reach Tier 3 (full features)...\n");
    printf(" Brownout detected! Voltage dropped below threshold\n");
    journal_set_flag(&rec, FLAG_BROWNOUT);
    rec.tier = TIER_1;  
    journal_write(&rec);
    printf("-> System dropped to Tier 1 for safety\n");
    journal_print(&rec);
    journal_close();
    simulate_boot(3, "Recovery from brownout");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    if (journal_has_flag(&rec, FLAG_BROWNOUT)) {
        printf("-> Brownout flag detected from previous boot\n");
        printf("-> Performing extended power stability checks...\n");
        printf("-> Power stable - clearing brownout flag\n");
        journal_clear_flag(&rec, FLAG_BROWNOUT);
    }
    printf("-> Cautiously attempting Tier 2...\n");
    rec.tier = TIER_2;
    journal_write(&rec);
    printf(" Successfully reached Tier 2\n");
    journal_print(&rec);
    journal_close();
    simulate_boot(4, "Tier-2 image corruption detected");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    printf("-> Attempting Tier 2 boot...\n");
    printf(" Signature verification failed for Tier-2 image!\n");
    printf("-> Decrementing Tier-2 attempt counter\n");
    int remaining = journal_decrement_tries(&rec, TIER_2);
    printf("-> Remaining Tier-2 attempts: %d\n", remaining);
    rec.tier = TIER_1;  
    journal_set_flag(&rec, FLAG_DIRTY);
    journal_write(&rec);
    printf("-> Falling back to Tier 1\n");
    journal_print(&rec);
    journal_close();
    simulate_boot(5, "Another Tier-2 failure");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    printf("-> Retrying Tier 2 (attempts remaining: %d)\n", rec.tries_t2);
    printf(" Tier-2 still failing verification\n");
    remaining = journal_decrement_tries(&rec, TIER_2);
    printf("-> Remaining Tier-2 attempts: %d\n", remaining);
    if (remaining == 0) {
        printf(" Tier-2 attempts exhausted!\n");
        printf("-> Entering quarantine mode - manual intervention needed\n");
        journal_set_flag(&rec, FLAG_QUARANTINE);
    }
    rec.tier = TIER_1;
    journal_write(&rec);
    journal_print(&rec);
    journal_close();
    simulate_boot(6, "Emergency mode activated");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    if (journal_has_flag(&rec, FLAG_QUARANTINE)) {
        printf("-> System in quarantine mode\n");
        printf("-> Activating emergency diagnostics...\n");
        journal_set_flag(&rec, FLAG_EMERGENCY);
        printf("-> Emergency actions:\n");
        printf("  --- Enable serial console access\n");
        printf("  --- Start SSH with emergency credentials\n");
        printf("  --- Log extended diagnostics\n");
        printf("  --- Await remote attestation and recovery commands\n");
    }
    rec.tier = TIER_1;
    journal_write(&rec);
    journal_print(&rec);
    journal_close();
    simulate_boot(7, "Administrator recovery");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    printf("-> Remote administrator connected via SSH\n");
    printf("-> Tier-2 image replaced with known-good version\n");
    printf("-> Clearing quarantine and emergency flags\n");
    journal_clear_flag(&rec, FLAG_QUARANTINE);
    journal_clear_flag(&rec, FLAG_EMERGENCY);
    journal_clear_flag(&rec, FLAG_DIRTY);
    journal_reset_tries(&rec);
    printf("-> Resetting attempt counters\n");
    printf("-> Testing new Tier-2 image...\n");
    rec.tier = TIER_2;
    journal_write(&rec);
    printf(" Tier-2 verification successful!\n");
    printf(" System recovered and operating normally\n");
    journal_print(&rec);
    journal_close();
    simulate_boot(8, "Normal operation resumed");
    journal_init(DEMO_JOURNAL_PATH);
    journal_read(&rec);
    rec.boot_count++;
    printf("-> System healthy, attempting Tier 3 (full features)\n");
    printf("-> Network available, passing remote attestation\n");
    rec.tier = TIER_3;
    journal_write(&rec);
    printf(" Reached Tier 3 - all features enabled\n");
    journal_print(&rec);
    print_separator();
    printf("\n FINAL SYSTEM STATE\n");
    print_separator();
    printf("Total boots:     %lu\n", (unsigned long)rec.boot_count);
    printf("Current tier:    %d (Full functionality)\n", rec.tier);
    printf("T2 tries left:   %d\n", rec.tries_t2);
    printf("T3 tries left:   %d\n", rec.tries_t3);
    printf("Flags:           %s\n", rec.flags == 0 ? "None (healthy)" : "See above");
    journal_close();
    print_separator();
    printf("\n Demo complete!\n");
    printf("  Journal file: %s\n", DEMO_JOURNAL_PATH);
    printf("  This demonstrates PAC's resilience through:\n");
    printf("    --- Brownout detection and recovery\n");
    printf("    --- Graceful degradation on failures\n");
    printf("    --- Attempt exhaustion handling\n");
    printf("    --- Emergency mode activation\n");
    printf("    --- Administrative recovery\n");
    printf("\n");
    return 0;
}
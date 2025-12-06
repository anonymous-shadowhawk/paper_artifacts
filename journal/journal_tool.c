#include "boot_journal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(const char *prog)
{
    printf("PAC Boot Journal Tool\n\n");
    printf("Usage: %s <command> [args...] <journal_file>\n\n", prog);
    printf("Commands:\n");
    printf("  read <file>                    - Display journal contents\n");
    printf("  set-tier <tier> <file>         - Set boot tier (1, 2, or 3)\n");
    printf("  dec-tries <tier> <file>        - Decrement tier attempt counter\n");
    printf("  reset-tries <file>             - Reset all attempt counters\n");
    printf("  set-flag <flag> <file>         - Set status flag\n");
    printf("  clear-flag <flag> <file>       - Clear status flag\n");
    printf("  inc-boot <file>                - Increment boot counter\n");
    printf("  init <file>                    - Initialize new journal\n");
    printf("\n");
    printf("Flags: emergency, quarantine, brownout, dirty, network_gated\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s read /var/pac/journal.dat\n", prog);
    printf("  %s set-tier 2 /var/pac/journal.dat\n", prog);
    printf("  %s set-flag brownout /var/pac/journal.dat\n", prog);
    printf("\n");
}

static uint32_t parse_flag(const char *flag_str)
{
    if (strcmp(flag_str, "emergency") == 0)
        return FLAG_EMERGENCY;
    if (strcmp(flag_str, "quarantine") == 0)
        return FLAG_QUARANTINE;
    if (strcmp(flag_str, "brownout") == 0)
        return FLAG_BROWNOUT;
    if (strcmp(flag_str, "dirty") == 0)
        return FLAG_DIRTY;
    if (strcmp(flag_str, "network_gated") == 0)
        return FLAG_NETWORK_GATED;
    fprintf(stderr, "Unknown flag: %s\n", flag_str);
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }
    const char *cmd = argv[1];
    if (strcmp(cmd, "init") == 0) {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s init <file>\n", argv[0]);
            return 1;
        }
        const char *path = argv[2];
        if (journal_init(path) != JOURNAL_OK) {
            fprintf(stderr, "Failed to initialize journal\n");
            return 1;
        }
        struct BootRecord rec;
        journal_read(&rec);
        printf("Initialized journal at %s\n", path);
        journal_print(&rec);
        journal_close();
        return 0;
    }
    if (argc < 3) {
        usage(argv[0]);
        return 1;
    }
    const char *path = argv[argc - 1];
    if (journal_init(path) != JOURNAL_OK) {
        fprintf(stderr, "Failed to open journal: %s\n", path);
        return 1;
    }
    struct BootRecord rec;
    if (journal_read(&rec) != JOURNAL_OK) {
        fprintf(stderr, "Failed to read journal\n");
        journal_close();
        return 1;
    }
    if (strcmp(cmd, "read") == 0) {
        journal_print(&rec);
    }
    else if (strcmp(cmd, "set-tier") == 0) {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s set-tier <tier> <file>\n", argv[0]);
            journal_close();
            return 1;
        }
        int tier = atoi(argv[2]);
        if (tier < 1 || tier > 3) {
            fprintf(stderr, "Invalid tier: %d (must be 1, 2, or 3)\n", tier);
            journal_close();
            return 1;
        }
        rec.tier = (uint8_t)tier;
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Set tier to %d\n", tier);
    }
    else if (strcmp(cmd, "dec-tries") == 0) {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s dec-tries <tier> <file>\n", argv[0]);
            journal_close();
            return 1;
        }
        int tier = atoi(argv[2]);
        int remaining = journal_decrement_tries(&rec, (uint8_t)tier);
        if (remaining < 0) {
            fprintf(stderr, "Invalid tier: %d\n", tier);
            journal_close();
            return 1;
        }
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Tier-%d attempts remaining: %d\n", tier, remaining);
    }
    else if (strcmp(cmd, "reset-tries") == 0) {
        journal_reset_tries(&rec);
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Reset attempt counters\n");
    }
    else if (strcmp(cmd, "set-flag") == 0) {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s set-flag <flag> <file>\n", argv[0]);
            journal_close();
            return 1;
        }
        uint32_t flag = parse_flag(argv[2]);
        if (flag == 0) {
            journal_close();
            return 1;
        }
        journal_set_flag(&rec, flag);
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Set flag: %s\n", argv[2]);
    }
    else if (strcmp(cmd, "clear-flag") == 0) {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s clear-flag <flag> <file>\n", argv[0]);
            journal_close();
            return 1;
        }
        uint32_t flag = parse_flag(argv[2]);
        if (flag == 0) {
            journal_close();
            return 1;
        }
        journal_clear_flag(&rec, flag);
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Cleared flag: %s\n", argv[2]);
    }
    else if (strcmp(cmd, "inc-boot") == 0) {
        rec.boot_count++;
        if (journal_write(&rec) != JOURNAL_OK) {
            fprintf(stderr, "Failed to write journal\n");
            journal_close();
            return 1;
        }
        printf("Boot count: %lu\n", (unsigned long)rec.boot_count);
    }
    else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        usage(argv[0]);
        journal_close();
        return 1;
    }
    journal_close();
    return 0;
}
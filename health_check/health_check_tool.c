#include "health_check.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>

static void usage(const char *prog)
{
    printf("PAC Health Check Tool\n\n");
    printf("Usage: %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  -o FILE    Output JSON to file (default: /tmp/health.json)\n");
    printf("  -v         Verbose output (print to stdout)\n");
    printf("  -q         Quiet mode (no output, exit code only)\n");
    printf("  -h         Show this help\n\n");
    printf("Exit Codes:\n");
    printf("  0  - Healthy (5-6/6 checks pass)\n");
    printf("  1  - Degraded (3-4/6 checks pass)\n");
    printf("  2  - Critical (0-2/6 checks pass)\n");
    printf("  255 - Error\n\n");
}
int main(int argc, char *argv[])
{
    const char *output_file = "/tmp/health.json";
    bool verbose = false;
    bool quiet = false;
    struct HealthConfig config = HEALTH_CONFIG_DEFAULT;
    int opt;
    while ((opt = getopt(argc, argv, "o:vqh")) != -1) {
        switch (opt) {
        case 'o':
            output_file = optarg;
            break;
        case 'v':
            verbose = true;
            config.verbose = true;
            break;
        case 'q':
            quiet = true;
            verbose = false;
            break;
        case 'h':
            usage(argv[0]);
            return 0;
        default:
            usage(argv[0]);
            return 255;
        }
    }
    struct HealthReport report;
    int result = health_check_run(&config, &report);
    if (result == HEALTH_ERROR) {
        fprintf(stderr, "Error: Health check failed\n");
        return 255;
    }
    if (health_report_to_file(&report, output_file) < 0) {
        fprintf(stderr, "Error: Failed to write output file: %s\n", output_file);
        return 255;
    }
    if (verbose) {
        health_report_print(&report);
    } else if (!quiet) {
        printf("Health check complete: %s (%u/%u checks passed)\n",
               report.overall_status, report.overall_score, report.max_score);
        printf("Report written to: %s\n", output_file);
    }
    return result;
}

/**
 * @file main.c
 * @brief {{PROJECT_NAME}} - A modern C17 application
 *
 * This template demonstrates modern C17 features and best practices.
 *
 * Build: ovo build
 * Run:   ovo run
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/// Application name
#define APP_NAME "{{PROJECT_NAME}}"

/// Application version
#define APP_VERSION "0.1.0"

/**
 * @brief Application configuration
 */
typedef struct {
    const char* name;
    const char* version;
    bool verbose;
    bool help_requested;
} Config;

/**
 * @brief Result codes for operations
 */
typedef enum {
    RESULT_OK = 0,
    RESULT_ERROR = 1,
    RESULT_HELP_SHOWN = 2,
} Result;

/**
 * @brief Print usage information
 */
static void print_usage(void) {
    printf("Usage: %s [OPTIONS]\n\n", APP_NAME);
    printf("Options:\n");
    printf("  -h, --help     Show this help message\n");
    printf("  -v, --verbose  Enable verbose output\n");
    printf("  -V, --version  Show version information\n");
}

/**
 * @brief Print version information
 */
static void print_version(void) {
    printf("%s version %s\n", APP_NAME, APP_VERSION);
}

/**
 * @brief Parse command line arguments
 *
 * @param argc Argument count
 * @param argv Argument values
 * @param config Output configuration
 * @return Result code
 */
static Result parse_args(int argc, char* argv[], Config* config) {
    // Initialize config with defaults using designated initializers (C99+)
    *config = (Config){
        .name = APP_NAME,
        .version = APP_VERSION,
        .verbose = false,
        .help_requested = false,
    };

    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            config->help_requested = true;
            return RESULT_HELP_SHOWN;
        }

        if (strcmp(arg, "-V") == 0 || strcmp(arg, "--version") == 0) {
            print_version();
            return RESULT_HELP_SHOWN;
        }

        if (strcmp(arg, "-v") == 0 || strcmp(arg, "--verbose") == 0) {
            config->verbose = true;
            continue;
        }

        // Unknown argument
        fprintf(stderr, "Error: Unknown argument '%s'\n\n", arg);
        print_usage();
        return RESULT_ERROR;
    }

    return RESULT_OK;
}

/**
 * @brief Demonstrate modern C17 features
 *
 * @param config Application configuration
 */
static void demonstrate_features(const Config* config) {
    // Compound literals (C99+)
    int numbers[] = {1, 2, 3, 4, 5};
    size_t count = sizeof(numbers) / sizeof(numbers[0]);

    printf("Numbers: ");
    for (size_t i = 0; i < count; ++i) {
        printf("%d ", numbers[i]);
    }
    printf("\n");

    // Calculate squares using anonymous struct with designated initializers
    struct { int value; int square; } squares[5];
    for (size_t i = 0; i < count; ++i) {
        squares[i] = (typeof(squares[0])){
            .value = numbers[i],
            .square = numbers[i] * numbers[i],
        };
    }

    printf("Squares: ");
    for (size_t i = 0; i < count; ++i) {
        printf("%d ", squares[i].square);
    }
    printf("\n");

    if (config->verbose) {
        printf("\nVerbose output enabled.\n");
        printf("Demonstrating C17 features:\n");
        printf("  - Designated initializers (C99)\n");
        printf("  - Compound literals (C99)\n");
        printf("  - _Static_assert (C11)\n");
        printf("  - Boolean type from stdbool.h (C99)\n");
        printf("  - Fixed-width integers from stdint.h (C99)\n");
        printf("  - Anonymous structs and unions (C11)\n");
    }
}

/**
 * @brief Application entry point
 *
 * @param argc Argument count
 * @param argv Argument values
 * @return Exit code
 */
int main(int argc, char* argv[]) {
    // Compile-time assertion (C11)
    _Static_assert(sizeof(int) >= 4, "int must be at least 32 bits");

    Config config;
    Result result = parse_args(argc, argv, &config);

    if (result == RESULT_HELP_SHOWN) {
        if (config.help_requested) {
            print_usage();
        }
        return EXIT_SUCCESS;
    }

    if (result != RESULT_OK) {
        return EXIT_FAILURE;
    }

    printf("Welcome to %s!\n", config.name);
    printf("Version: %s\n\n", config.version);

    demonstrate_features(&config);

    return EXIT_SUCCESS;
}

/**
 * @file main.cpp
 * @brief {{PROJECT_NAME}} - A modern C++23 application
 *
 * This template demonstrates modern C++23 features and best practices.
 *
 * Build: ovo build
 * Run:   ovo run
 * Test:  ovo test
 */

#include <print>
#include <string>
#include <string_view>
#include <vector>
#include <ranges>
#include <expected>
#include <format>
#include <span>

namespace app {

/// Application version
inline constexpr std::string_view VERSION = "0.1.0";

/// Application configuration
struct Config {
    std::string_view name{"{{PROJECT_NAME}}"};
    std::string_view version{VERSION};
    bool verbose{false};
};

/// Result type for operations that can fail
template<typename T>
using Result = std::expected<T, std::string>;

/// Parse command line arguments
[[nodiscard]] auto parse_args(std::span<char*> args) -> Result<Config> {
    Config config;

    for (auto it = args.begin() + 1; it != args.end(); ++it) {
        std::string_view arg{*it};

        if (arg == "--verbose" || arg == "-v") {
            config.verbose = true;
        } else if (arg == "--help" || arg == "-h") {
            return std::unexpected(
                std::format("Usage: {} [--verbose|-v] [--help|-h]\n", config.name)
            );
        } else if (arg == "--version" || arg == "-V") {
            return std::unexpected(
                std::format("{} version {}\n", config.name, config.version)
            );
        }
    }

    return config;
}

/// Run the application
[[nodiscard]] auto run(const Config& config) -> int {
    std::println("Welcome to {}!", config.name);
    std::println("Version: {}", config.version);

    if (config.verbose) {
        std::println("\nRunning in verbose mode");
    }

    // Demonstrate C++23 ranges
    auto numbers = std::vector{1, 2, 3, 4, 5};
    auto squares = numbers
        | std::views::transform([](int n) { return n * n; });

    std::print("\nSquares of 1-5: ");
    for (auto sq : squares) {
        std::print("{} ", sq);
    }
    std::println("");

    return 0;
}

} // namespace app

int main(int argc, char* argv[]) {
    auto args = std::span(argv, static_cast<std::size_t>(argc));
    auto config_result = app::parse_args(args);

    if (!config_result) {
        std::print("{}", config_result.error());
        return config_result.error().find("Usage:") != std::string::npos ? 1 : 0;
    }

    return app::run(*config_result);
}

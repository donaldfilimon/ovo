/**
 * @file lib.cppm
 * @brief {{PROJECT_NAME}} - C++20 Module Interface
 *
 * This module interface demonstrates modern C++20 module syntax.
 * Modules provide better encapsulation and faster compilation than headers.
 *
 * Use either this module or the header, not both.
 */

module;

// Global module fragment - include traditional headers here
#include <string>
#include <string_view>
#include <memory>
#include <optional>
#include <concepts>
#include <vector>

export module {{PROJECT_NAME_SNAKE}};

export namespace {{PROJECT_NAME_SNAKE}} {

/// Library version information
struct Version {
    int major{0};
    int minor{1};
    int patch{0};

    [[nodiscard]] constexpr auto to_string() const -> std::string {
        return std::to_string(major) + "." +
               std::to_string(minor) + "." +
               std::to_string(patch);
    }
};

/// Get the library version
[[nodiscard]] constexpr auto version() noexcept -> Version {
    return {0, 1, 0};
}

/// Concept for types that can be processed
template<typename T>
concept Processable = requires(T t) {
    { t.process() } -> std::convertible_to<bool>;
};

/// Generic container for holding processable items
template<Processable T>
class Container {
public:
    using value_type = T;
    using pointer = std::unique_ptr<T>;

    /// Add an item to the container
    auto add(pointer item) -> void {
        items_.push_back(std::move(item));
    }

    /// Process all items in the container
    [[nodiscard]] auto process_all() -> bool {
        for (auto& item : items_) {
            if (!item->process()) {
                return false;
            }
        }
        return true;
    }

    /// Get the number of items
    [[nodiscard]] auto size() const noexcept -> std::size_t {
        return items_.size();
    }

    /// Check if container is empty
    [[nodiscard]] auto empty() const noexcept -> bool {
        return items_.empty();
    }

    /// Clear all items
    auto clear() noexcept -> void {
        items_.clear();
    }

private:
    std::vector<pointer> items_;
};

/// Example processable item
class Item {
public:
    Item() = default;
    explicit Item(std::string_view name) : name_{name} {}

    [[nodiscard]] auto process() -> bool {
        processed_ = true;
        return true;
    }

    [[nodiscard]] auto name() const noexcept -> std::string_view {
        return name_;
    }

    [[nodiscard]] auto is_processed() const noexcept -> bool {
        return processed_;
    }

private:
    std::string name_{"unnamed"};
    bool processed_{false};
};

/// Factory function to create items
[[nodiscard]] inline auto make_item(std::string_view name) -> std::unique_ptr<Item> {
    return std::make_unique<Item>(name);
}

/// Greets the given name
[[nodiscard]] inline auto greet(std::string_view name) -> std::string {
    return std::string{"Hello, "} + std::string{name} + "!";
}

} // namespace {{PROJECT_NAME_SNAKE}}

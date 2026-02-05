/**
 * @file lib.hpp
 * @brief {{PROJECT_NAME}} - Traditional header interface
 *
 * This header provides a traditional C++ interface for compilers
 * that don't yet support C++20 modules, or for interoperability.
 */

#ifndef {{PROJECT_NAME_UPPER}}_HPP
#define {{PROJECT_NAME_UPPER}}_HPP

#include <string>
#include <string_view>
#include <memory>
#include <vector>

// DLL export/import macros
#if defined(_WIN32) || defined(_WIN64)
    #ifdef {{PROJECT_NAME_UPPER}}_BUILDING
        #define {{PROJECT_NAME_UPPER}}_API __declspec(dllexport)
    #else
        #ifdef {{PROJECT_NAME_UPPER}}_SHARED
            #define {{PROJECT_NAME_UPPER}}_API __declspec(dllimport)
        #else
            #define {{PROJECT_NAME_UPPER}}_API
        #endif
    #endif
#else
    #ifdef {{PROJECT_NAME_UPPER}}_BUILDING
        #define {{PROJECT_NAME_UPPER}}_API __attribute__((visibility("default")))
    #else
        #define {{PROJECT_NAME_UPPER}}_API
    #endif
#endif

namespace {{PROJECT_NAME_SNAKE}} {

/**
 * @brief Library version information
 */
struct {{PROJECT_NAME_UPPER}}_API Version {
    int major;
    int minor;
    int patch;

    /**
     * @brief Convert version to string format "major.minor.patch"
     */
    [[nodiscard]] std::string to_string() const;
};

/**
 * @brief Get the library version
 * @return Version struct containing major, minor, patch numbers
 */
[[nodiscard]] {{PROJECT_NAME_UPPER}}_API Version version() noexcept;

/**
 * @brief Abstract base class for processable items
 */
class {{PROJECT_NAME_UPPER}}_API IProcessable {
public:
    virtual ~IProcessable() = default;

    /**
     * @brief Process this item
     * @return true if processing succeeded, false otherwise
     */
    [[nodiscard]] virtual bool process() = 0;
};

/**
 * @brief Container for holding processable items
 */
class {{PROJECT_NAME_UPPER}}_API Container {
public:
    Container();
    ~Container();

    // Non-copyable
    Container(const Container&) = delete;
    Container& operator=(const Container&) = delete;

    // Movable
    Container(Container&&) noexcept;
    Container& operator=(Container&&) noexcept;

    /**
     * @brief Add an item to the container
     * @param item Unique pointer to a processable item
     */
    void add(std::unique_ptr<IProcessable> item);

    /**
     * @brief Process all items in the container
     * @return true if all items processed successfully
     */
    [[nodiscard]] bool process_all();

    /**
     * @brief Get the number of items in the container
     */
    [[nodiscard]] std::size_t size() const noexcept;

    /**
     * @brief Check if container is empty
     */
    [[nodiscard]] bool empty() const noexcept;

    /**
     * @brief Clear all items from the container
     */
    void clear() noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * @brief Example processable item
 */
class {{PROJECT_NAME_UPPER}}_API Item : public IProcessable {
public:
    Item();

    /**
     * @brief Construct an item with a name
     * @param name The item's name
     */
    explicit Item(std::string_view name);

    ~Item() override;

    /**
     * @brief Process this item
     * @return Always returns true
     */
    [[nodiscard]] bool process() override;

    /**
     * @brief Get the item's name
     */
    [[nodiscard]] std::string_view name() const noexcept;

    /**
     * @brief Check if this item has been processed
     */
    [[nodiscard]] bool is_processed() const noexcept;

private:
    std::string name_;
    bool processed_{false};
};

/**
 * @brief Factory function to create items
 * @param name The item's name
 * @return Unique pointer to the created item
 */
[[nodiscard]] {{PROJECT_NAME_UPPER}}_API std::unique_ptr<Item> make_item(std::string_view name);

/**
 * @brief Greet the given name
 * @param name The name to greet
 * @return A greeting message
 */
[[nodiscard]] {{PROJECT_NAME_UPPER}}_API std::string greet(std::string_view name);

} // namespace {{PROJECT_NAME_SNAKE}}

#endif // {{PROJECT_NAME_UPPER}}_HPP

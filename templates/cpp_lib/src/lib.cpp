#include "lib.hpp"
#include <format>

namespace {{PROJECT_NAME}} {

std::string greet(std::string_view name) {
    return std::format("Hello, {}!", name);
}

Example::Example(std::string name) : m_name(std::move(name)) {}

std::string Example::describe() const {
    return std::format("Example(name=\"{}\")", m_name);
}

} // namespace {{PROJECT_NAME}}

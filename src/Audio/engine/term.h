// Control messages in Erlang's external term format (OTP ei).
#pragma once
#include <cstdint>
#include <string>
#include <vector>

#include "engine.h"

namespace ba {
void term_init();                                // once, before any other ei call
json decode(const std::vector<uint8_t> &frame);  // term_to_binary(Map) -> object
std::string encode(const json &value);           // -> binary_to_term-able bytes
}  // namespace ba

// Copyright (C) 2026 Toit contributors.

#include "../../../../src/utf_8_validator.h"
#include "../../../../src/encoder_string_prefix.h"

// The readable slice and frame imported by validator.render. A stronger
// precondition on the VM function must also be justified here.
/*@ requires 0 <= length;
    requires \valid_read(buffer + (0 .. length - 1));
    assigns \nothing;
*/
bool check_utf8_contract(const uint8_t *buffer, intptr_t length) {
  return utf8_is_valid(buffer, length);
}

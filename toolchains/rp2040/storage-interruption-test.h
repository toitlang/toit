// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <stdint.h>

namespace toit {
void rp2040_storage_test_arm(const void* bytes, unsigned size);
void rp2040_storage_test_before_program(uint32_t offset, uint8_t* page, bool header);
void rp2040_storage_test_after_program(bool header);
void rp2040_storage_test_before_erase(uint32_t offset);
}

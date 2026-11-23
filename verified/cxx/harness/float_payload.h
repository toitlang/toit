// Copyright (C) 2026 Toit contributors.
#pragma once

// Crossing a C++ double argument or return can change a NaN representation.
// Both signed zeros, both infinities and every finite value must match bitwise.
static bool is_nan_encoding(uint64 bits) {
  return (bits & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000);
}

static bool same_double_payload(uint64 a, uint64 b) {
  return a == b || (is_nan_encoding(a) && is_nan_encoding(b));
}

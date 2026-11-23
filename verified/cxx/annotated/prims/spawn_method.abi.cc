// Copyright (C) 2026 Toit contributors.
#include "objects.h"
#include <type_traits>

static_assert(std::is_trivially_copyable<toit::Method>::value, "Method can be copied as a value");
static_assert(std::is_standard_layout<toit::Method>::value, "Method has a standard layout");
static_assert(sizeof(toit::Method) == sizeof(void*), "Method contains one bytecode pointer");
static_assert(std::is_same<decltype(toit::Method::bytes_), uint8*>::value, "Method stores the modeled pointer");
static_assert(offsetof(toit::Method, bytes_) == 0, "Method header pointer is the first field");
static_assert(std::is_same<uint8, unsigned char>::value, "bytecode pointer differences count bytes");

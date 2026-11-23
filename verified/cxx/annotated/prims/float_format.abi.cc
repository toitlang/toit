// Copyright (C) 2026 Toit contributors.

#include <math.h>

constexpr int native_nan = FP_NAN;
constexpr int native_infinite = FP_INFINITE;
constexpr int native_zero = FP_ZERO;
#undef FP_NAN
#undef FP_INFINITE
#undef FP_ZERO
#include "../model/constants.h"

static_assert(FP_NAN == native_nan, "fpclassify NaN category");
static_assert(FP_INFINITE == native_infinite, "fpclassify infinity category");
static_assert(FP_ZERO == native_zero, "fpclassify zero category");

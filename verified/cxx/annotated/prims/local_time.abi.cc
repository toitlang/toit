// Copyright (C) 2026 Toit contributors.

#include <climits>
#include <ctime>
#include <type_traits>

// The scalar types used by the local time proof on the two Linux targets.
static_assert(std::is_same<time_t, long>::value, "time_t matches the proof model");
static_assert(INT_MAX == 2147483647 && INT_MIN == -2147483647 - 1, "calendar argument range");
#define CHECK_TM_FIELD(name) static_assert(std::is_same<decltype(tm::name), int>::value, #name)
CHECK_TM_FIELD(tm_year);
CHECK_TM_FIELD(tm_mon);
CHECK_TM_FIELD(tm_mday);
CHECK_TM_FIELD(tm_hour);
CHECK_TM_FIELD(tm_min);
CHECK_TM_FIELD(tm_sec);
CHECK_TM_FIELD(tm_isdst);
CHECK_TM_FIELD(tm_wday);
CHECK_TM_FIELD(tm_yday);
#undef CHECK_TM_FIELD

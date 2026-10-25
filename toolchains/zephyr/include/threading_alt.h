// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <zephyr/kernel.h>
typedef struct mbedtls_threading_mutex_t {
  struct k_mutex mutex;
  bool is_valid;
} mbedtls_threading_mutex_t;

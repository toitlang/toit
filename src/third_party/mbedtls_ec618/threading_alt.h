// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

// Threading alt implementation for mbedTLS on FreeRTOS/EC618.
// Provides mutex types backed by FreeRTOS semaphores.

#ifndef THREADING_ALT_H
#define THREADING_ALT_H

#include "FreeRTOS.h"
#include "semphr.h"

typedef struct mbedtls_threading_mutex_t {
  SemaphoreHandle_t mutex;
  char is_valid;
} mbedtls_threading_mutex_t;

#endif // THREADING_ALT_H

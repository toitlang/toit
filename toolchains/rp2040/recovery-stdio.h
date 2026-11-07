// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <stdbool.h>

// Sends a bounded protocol reply without the USB console's lossy timeout.
// Returns false on disconnect, timeout, or an oversized formatted reply.
// Used only by the single-threaded recovery main loop, never a primitive.
bool recovery_reply(const char* format, ...) __attribute__((format(printf, 1, 2)));

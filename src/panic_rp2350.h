// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include <stdarg.h>

// Arm recovery before attempting diagnostics, which may block in a failed VM.
extern "C" void __attribute__((noreturn))
toit_rp2350_vpanic(const char* file, int line, const char* format, va_list arguments);

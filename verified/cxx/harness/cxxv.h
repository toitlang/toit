// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Tool-neutral verification primitives of the harnesses (ESBMC by default,
// CBMC with -DCXXV_CBMC).
#pragma once

#include <stdint.h>
#include <stddef.h>

extern "C" {
int nondet_int();
unsigned nondet_uint();
long nondet_long();
int64_t nondet_int64();
unsigned long nondet_ulong();
unsigned char nondet_uchar();
unsigned short nondet_ushort();
bool nondet_bool();
}

// ESBMC's C library model lacks strnlen (POSIX), which src/messaging.cc
// uses on a path the harnesses don't reach (RPC replies). Declared only;
// a call would return a nondeterministic value.
// Likewise for the glibc and POSIX functions src/primitive_core.cc uses in
// primitives the harnesses don't call (printing, environment), and the C99
// classification macros it uses unqualified.
#ifndef CXXV_CBMC
#include <stdio.h>
#include <cmath>
extern "C" {
size_t strnlen(const char* s, size_t max);
void flockfile(FILE* stream);
void funlockfile(FILE* stream);
size_t fwrite_unlocked(const void* data, size_t size, size_t count, FILE* stream);
int fputc_unlocked(int c, FILE* stream);
int fflush_unlocked(FILE* stream);
int putenv(char* assignment);
}
using std::isfinite;
using std::signbit;
#endif

#ifdef CXXV_CBMC
#define CXXV_ASSUME(c) __CPROVER_assume(c)
#define CXXV_ASSERT(c, msg) __CPROVER_assert((c), msg)
#else
#define CXXV_ASSUME(c) __ESBMC_assume(c)
#define CXXV_ASSERT(c, msg) __ESBMC_assert((c), msg)
#endif

// A nondeterministic word on LP64 and ILP32.
static inline intptr_t nondet_word() { return static_cast<intptr_t>(nondet_long()); }

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

// First include of every ESBMC harness, before any VM source.
//
// Work-around for ESBMC 8.6 defect T1 (pilot write-up, "Tool findings"):
// in translation units that include the heap headers, ESBMC orders the
// initialization of class static constants (HeapObject::SIZE,
// Smi::MAX_SMI_VALUE, every layout offset) before the namespace constants
// of src/top.h they use (WORD_SIZE, ...), so the class constants start out
// unconstrained: every layout offset becomes symbolic (false alarms, and
// formulas that exhaust memory). In C++ all of them are constant-
// initialized; there is no order.
//
// After top.h has defined the namespace constants, each one the class
// constants use is redefined as a macro with the same constant expression
// as its definition (the static_asserts check the agreement), so the class
// constants' initializers no longer read a variable. Semantics-preserving:
// every use sees the same value. (An earlier work-around, an overload of
// swap for DoubleLinkedList, fixed only some translation units.)
// constants.h asserts the resulting layout constants at the start of a
// harness (a sentinel for T1).
#pragma once

#include "cxxv.h"
#include "top.h"
#include "uuid.h"

static_assert(WORD_SIZE == static_cast<int>(sizeof(word)), "prelude");
static_assert(HALF_WORD_SIZE == (WORD_SIZE >> 1), "prelude");
static_assert(WORD_BIT_SIZE == WORD_SIZE * 8, "prelude");
static_assert(POINTER_SIZE == static_cast<int>(sizeof(void*)), "prelude");
static_assert(BYTE_SIZE == 1 && BYTE_BIT_SIZE == 8, "prelude");
static_assert(DOUBLE_SIZE == 8 && INT64_SIZE == 8 && INT32_SIZE == 4 && UINT32_SIZE == 4, "prelude");
static_assert(KB == 1024 && MB == 1024 * 1024 && GB == 1024 * 1024 * 1024, "prelude");
static_assert(TOIT_PAGE_SIZE == (1 << TOIT_PAGE_SIZE_LOG2), "prelude");
static_assert(TOIT_PAGE_SIZE_32 == (1 << 12) && TOIT_PAGE_SIZE_64 == (1 << 15), "prelude");
static_assert(LARGE_INT_BIT_SIZE == 64, "prelude");
static_assert(WORD_SHIFT == (WORD_SIZE == 8 ? 3 : 2), "prelude");
static_assert(toit::UUID_SIZE == 16, "prelude");
#if defined(BUILD_64) || !defined(TOIT_FREERTOS)
static_assert(TOIT_PAGE_SIZE_LOG2 == 15, "prelude");
#define CXXV_PAGE_SIZE_LOG2 15
#else
static_assert(TOIT_PAGE_SIZE_LOG2 == 12, "prelude");
#define CXXV_PAGE_SIZE_LOG2 12
#endif

#define WORD_SIZE (static_cast<int>(sizeof(word)))
#define HALF_WORD_SIZE (WORD_SIZE >> 1)
#define WORD_BIT_SIZE (WORD_SIZE * 8)
#define POINTER_SIZE (static_cast<int>(sizeof(void*)))
#define BYTE_SIZE 1
#define BYTE_BIT_SIZE 8
#define DOUBLE_SIZE 8
#define INT64_SIZE 8
#define INT32_SIZE 4
#define UINT32_SIZE 4
#define KB (1 << 10)
#define MB (1 << 20)
#define GB (1 << 30)
#define TOIT_PAGE_SIZE_LOG2 CXXV_PAGE_SIZE_LOG2
#define TOIT_PAGE_SIZE (1 << CXXV_PAGE_SIZE_LOG2)
#define TOIT_PAGE_SIZE_32 (1 << 12)
#define TOIT_PAGE_SIZE_64 (1 << 15)
#define LARGE_INT_BIT_SIZE 64
#define WORD_SHIFT (WORD_SIZE == 8 ? 3 : 2)
#define UUID_SIZE 16

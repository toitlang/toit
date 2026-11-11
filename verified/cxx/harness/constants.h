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

// Sentinel for ESBMC defect T1 (see prelude.h): the layout constants the
// harnesses depend on must have their compile-time values in the model
// checker too. The static_asserts are proven by the C++ compiler (clang
// inside ESBMC); cxxv_constants() asserts the same values in the model, so
// a harness whose translation unit triggers T1 fails right at its start
// instead of silently exploring unconstrained layouts.
#pragma once

#include "objects.h"

namespace cxxv {

using ::word;
using toit::Smi;
using toit::HeapObject;

#ifdef BUILD_64
static const word SMI_MAX = (static_cast<word>(1) << 62) - 1;
static const word SMI_MIN = -(static_cast<word>(1) << 62);
#else
static const word SMI_MAX = (static_cast<word>(1) << 30) - 1;
static const word SMI_MIN = -(static_cast<word>(1) << 30);
#endif
static_assert(Smi::MAX_SMI_VALUE == SMI_MAX, "smi range");
static_assert(Smi::MIN_SMI_VALUE == SMI_MIN, "smi range");
static_assert(HeapObject::SIZE == WORD_SIZE, "header size");

static inline void cxxv_constants() {
  CXXV_ASSERT(Smi::MAX_SMI_VALUE == SMI_MAX, "T1 sentinel: Smi::MAX_SMI_VALUE");
  CXXV_ASSERT(Smi::MIN_SMI_VALUE == SMI_MIN, "T1 sentinel: Smi::MIN_SMI_VALUE");
  CXXV_ASSERT(HeapObject::SIZE == WORD_SIZE, "T1 sentinel: HeapObject::SIZE");
}

}  // namespace cxxv

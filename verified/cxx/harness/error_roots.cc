// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "primitive.cc"

using namespace toit;

// The boundary borrows an already loaded program. Give each of its root
// slots an independent value so the check also distinguishes wrong indices.
extern Program loaded_program;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Object** roots = const_cast<Object**>(loaded_program.roots());
  for (int i = 0; i < Program::ROOT_COUNT; i++) {
    roots[i] = reinterpret_cast<Object*>(nondet_ulong());
  }

  uword raw = nondet_ulong();
  CXXV_ASSUME(raw % 4 == 3);
  Object* result = Primitive::unmark_from_error(&loaded_program, reinterpret_cast<Object*>(raw));
  if (raw >= Error::MAX_TAGGED_ERROR) {
    CXXV_ASSERT(reinterpret_cast<uword>(result) == raw - 2, "unmark preserves the heap address");
  } else if (raw / 4 < Program::ROOT_COUNT) {
    CXXV_ASSERT(result == roots[raw / 4], "an immediate selects its root");
  } else {
    CXXV_ASSERT(result == loaded_program.invalid_argument(), "an unused immediate yields INVALID_ARGUMENT");
  }

#define CHECK_ROOT(name, upper) \
  CXXV_ASSERT(loaded_program.name() == roots[Program::upper##_INDEX], #name);
  ERROR_STRINGS(CHECK_ROOT)
#undef CHECK_ROOT
}

// The three roots used by the verified retry protocol. Include the model
// constants after the VM headers so their short C names do not shadow C++.
#undef WORD_SIZE
#undef HALF_WORD_SIZE
#undef WORD_BIT_SIZE
#include "../annotated/model/constants.h"
static_assert(Program::ALLOCATION_FAILED_INDEX == Program_ALLOCATION_FAILED_INDEX, "allocation_failed");
static_assert(Program::MALLOC_FAILED_INDEX == Program_MALLOC_FAILED_INDEX, "malloc_failed");
static_assert(Program::CROSS_PROCESS_GC_INDEX == Program_CROSS_PROCESS_GC_INDEX, "cross_process_gc");

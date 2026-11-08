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

// Layout contract check for the verified interpreter core.
//
// Every constant the Rust core assumes (verified/core/src/layout.rs) is
// exported by name. This program compares each one against the value derived
// from the C++ headers, and additionally checks the Rust core's derived
// computations (Method::max_height, covered opcodes) behaviorally. It fails
// (non-zero exit) on any mismatch, on any Rust constant it does not know, and
// on any expected constant the Rust side does not export.

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define TOIT_VERIFIED_CORE 1
#include "top.h"
#include "bytecodes.h"
#include "objects.h"
#include "interpreter.h"
#include "verified_core.h"

using namespace toit;

namespace {

struct Expected {
  const char* name;
  uword value;
  bool seen;
};

uword smi_bits(word value) {
  return reinterpret_cast<uword>(Smi::from(value));
}

// Method::max_height() for a header whose kind/height byte is `b`. Only one
// header byte is non-zero, so a wrong KIND_HEIGHT_OFFSET on the Rust side is
// detected as well.
uword cxx_max_height(uint8 b, uword rust_offset) {
  uint8 header[16];
  memset(header, 0, sizeof(header));
  header[rust_offset < 8 ? rust_offset : 0] = b;
  return Method(header).max_height();
}

}  // namespace

int main() {
  int failures = 0;

  Expected expected[] = {
    { "FRAME_SIZE", static_cast<uword>(Interpreter::FRAME_SIZE), false },
    // CALL_METHOD pushes the return address first, then the frame marker,
    // so after the call the marker is at sp[0] and the return address at
    // sp[1] (interpreter_run.cc: CALL_METHOD_WITH_RETURN_ADDRESS, RETURN).
    { "FRAME_MARKER_SLOT", 0, false },
    { "RETURN_ADDRESS_SLOT", 1, false },
    { "LINK_REASON_SLOT", static_cast<uword>(Interpreter::LINK_REASON_SLOT), false },
    { "LINK_TARGET_SLOT", static_cast<uword>(Interpreter::LINK_TARGET_SLOT), false },
    { "LINK_RESULT_SLOT", static_cast<uword>(Interpreter::LINK_RESULT_SLOT), false },
    { "LINK_WORDS", static_cast<uword>(Interpreter::LINK_RESULT_SLOT + 1), false },
    { "SMI_TAG_SIZE", static_cast<uword>(Object::SMI_TAG_SIZE), false },
    { "SMI_TAG_MASK", static_cast<uword>(Object::SMI_TAG_MASK), false },
    { "SMI_TAG", static_cast<uword>(Object::SMI_TAG), false },
    { "SMI_SCALE", smi_bits(1), false },
    // The LINK opcode's initial words (literals in interpreter_run.cc).
    { "SMI_LINK_RESULT_INIT", smi_bits(0xbeef), false },
    { "SMI_LINK_TARGET_INIT", smi_bits(-0xdead), false },
    { "SMI_LINK_REASON_INIT", smi_bits(-1), false },
    { "BLOCK_SALT", static_cast<uword>(BLOCK_SALT), false },
    // Checked behaviorally below; listed so the names are accounted for.
    { "METHOD_KIND_HEIGHT_OFFSET", 0, false },
    { "METHOD_KIND_BITS_DIVISOR", 0, false },
    { "METHOD_HEIGHT_SCALE", 0, false },
    { "METHOD_ENTRY_OFFSET", static_cast<uword>(Method::entry_offset()), false },
#define OP(name) \
    { "OP_" #name, static_cast<uword>(name), false },
    OP(LOAD_LOCAL) OP(LOAD_LOCAL_WIDE) OP(STORE_LOCAL) OP(LOAD_OUTER) OP(STORE_OUTER)
    OP(LOAD_LOCAL_0) OP(LOAD_LOCAL_1) OP(LOAD_LOCAL_2) OP(LOAD_LOCAL_3) OP(LOAD_LOCAL_4)
    OP(LOAD_LOCAL_5) OP(LOAD_SMI_U8) OP(POP) OP(POP_1) OP(INVOKE_STATIC) OP(RETURN)
    OP(NON_LOCAL_RETURN) OP(NON_LOCAL_RETURN_WIDE) OP(LINK) OP(UNLINK)
#undef OP
#define LEN(name) \
    { "LEN_" #name, static_cast<uword>(name##_LENGTH), false },
    LEN(LOAD_LOCAL) LEN(LOAD_LOCAL_WIDE) LEN(STORE_LOCAL) LEN(LOAD_OUTER) LEN(STORE_OUTER)
    LEN(LOAD_SMI_U8) LEN(POP) LEN(POP_1) LEN(INVOKE_STATIC) LEN(RETURN)
    LEN(NON_LOCAL_RETURN) LEN(NON_LOCAL_RETURN_WIDE) LEN(LINK) LEN(UNLINK)
#undef LEN
    { "LEN_LOAD_LOCAL_N", static_cast<uword>(LOAD_LOCAL_0_LENGTH), false },
    // The FFI state struct (src/verified_core.h vs verified/core/src/ffi.rs).
    { "STATE_SIZE", sizeof(toit_vcore_state), false },
#define FIELD(name) \
    { "STATE_OFFSET_" #name, offsetof(toit_vcore_state, name), false },
    FIELD(stack_limit) FIELD(stack_len) FIELD(sp) FIELD(try_sp) FIELD(code) FIELD(code_len)
    FIELD(bcp) FIELD(dispatch) FIELD(dispatch_len) FIELD(frame_marker) FIELD(watermark)
    FIELD(preempt_a_lot) FIELD(fuel) FIELD(steps)
#undef FIELD
    { "VCORE_STOP", TOIT_VCORE_STOP, false },
    { "VCORE_TRAP", TOIT_VCORE_TRAP, false },
    { "WORD_SIZE", sizeof(uword), false },
  };
  const int expected_count = sizeof(expected) / sizeof(expected[0]);

  // All LOAD_LOCAL_n share one length on the Rust side.
  if (LOAD_LOCAL_1_LENGTH != LOAD_LOCAL_0_LENGTH || LOAD_LOCAL_2_LENGTH != LOAD_LOCAL_0_LENGTH ||
      LOAD_LOCAL_3_LENGTH != LOAD_LOCAL_0_LENGTH || LOAD_LOCAL_4_LENGTH != LOAD_LOCAL_0_LENGTH ||
      LOAD_LOCAL_5_LENGTH != LOAD_LOCAL_0_LENGTH) {
    printf("FAIL: LOAD_LOCAL_n lengths differ\n");
    failures++;
  }
  // LOAD_LOCAL_n must be consecutive (the core decodes n = op - LOAD_LOCAL_0).
  if (LOAD_LOCAL_5 - LOAD_LOCAL_0 != 5) {
    printf("FAIL: LOAD_LOCAL_0..5 are not consecutive\n");
    failures++;
  }
  // The core assumes 64-bit words (usize) and pointer-sized stack slots.
  if (sizeof(uword) != sizeof(void*) || sizeof(Object*) != sizeof(uword)) {
    printf("FAIL: word size\n");
    failures++;
  }

  uword kind_height_offset = 0;
  uword count = toit_vcore_layout_count();
  for (uword i = 0; i < count; i++) {
    const char* name;
    uword value;
    if (!toit_vcore_layout_entry(i, &name, &value)) {
      printf("FAIL: entry %lu unreadable\n", static_cast<unsigned long>(i));
      failures++;
      continue;
    }
    if (strcmp(name, "METHOD_KIND_HEIGHT_OFFSET") == 0) kind_height_offset = value;
    bool found = false;
    for (int j = 0; j < expected_count; j++) {
      if (strcmp(expected[j].name, name) != 0) continue;
      found = true;
      expected[j].seen = true;
      bool behavioral = strncmp(name, "METHOD_", 7) == 0 && strcmp(name, "METHOD_ENTRY_OFFSET") != 0;
      if (!behavioral && expected[j].value != value) {
        printf("FAIL: %s: Rust %lu, C++ %lu\n", name,
               static_cast<unsigned long>(value), static_cast<unsigned long>(expected[j].value));
        failures++;
      }
    }
    if (!found) {
      printf("FAIL: Rust constant %s has no C++ counterpart in the check\n", name);
      failures++;
    }
  }
  for (int j = 0; j < expected_count; j++) {
    if (!expected[j].seen) {
      printf("FAIL: %s not exported by the Rust core\n", expected[j].name);
      failures++;
    }
  }

  // Method header: max_height for every value of the kind/height byte.
  for (int b = 0; b < 256; b++) {
    uword rust = toit_vcore_max_height(static_cast<uint8>(b));
    uword cxx = cxx_max_height(static_cast<uint8>(b), kind_height_offset);
    if (rust != cxx) {
      printf("FAIL: max_height(0x%02x): Rust %lu, C++ %lu\n", b,
             static_cast<unsigned long>(rust), static_cast<unsigned long>(cxx));
      failures++;
      break;
    }
  }

  // Covered opcodes: the C++ hook and the Rust core must agree.
  for (int op = 0; op < 256; op++) {
    bool rust = toit_vcore_covers(static_cast<uint8>(op));
    bool cxx = verified_core_covers(static_cast<uint8>(op));
    if (rust != cxx) {
      printf("FAIL: covers(%d): Rust %d, C++ %d\n", op, rust, cxx);
      failures++;
    }
  }

  // Block references: to_block(p) is Smi::from(base - p + BLOCK_SALT) and
  // the Rust core computes it as (base - p + BLOCK_SALT) * SMI_SCALE.
  for (word distance = 0; distance < 1024; distance += 7) {
    if (smi_bits(distance + BLOCK_SALT) != static_cast<uword>(distance + BLOCK_SALT) * smi_bits(1)) {
      printf("FAIL: block reference encoding\n");
      failures++;
      break;
    }
  }

  if (failures != 0) {
    printf("verified core layout check: %d failure(s)\n", failures);
    return 1;
  }
  printf("verified core layout check: %lu constants, OK\n", static_cast<unsigned long>(count));
  return 0;
}

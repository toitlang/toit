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

#pragma once

// Interface to the Verus-verified interpreter core (verified/core).
//
// When TOIT_VERIFIED_CORE is defined, the interpreter's DISPATCH macro calls
// VERIFIED_CORE_HOOK() before dispatching. If the next opcode is one the
// verified core executes, the hook hands the interpreter state to the core,
// which runs covered opcodes until it reaches one it does not cover (or
// declines one, e.g. a call that needs a stack-overflow check), and then
// writes back sp, try_sp_ and bcp. The C++ handler then runs as usual.

#include "top.h"
#include "bytecodes.h"

#if defined(TOIT_VERIFIED_CORE) && !defined(TOIT_CHECK_PROPAGATED_TYPES)

extern "C" {

// Must match verified/core/src/ffi.rs (VcoreState).
struct toit_vcore_state {
  uword* stack_limit;    // Interpreter::limit_.
  uword stack_len;       // base_ - limit_, in words.
  uword sp;              // Index relative to limit_.
  uword try_sp;          // Index relative to limit_.
  const uint8* code;     // program->bytecodes.data().
  uword code_len;
  uword bcp;             // Index into code.
  const int32* dispatch; // program->dispatch_table.data().
  uword dispatch_len;
  uword frame_marker;    // program->frame_marker().
  const void* watermark; // &Interpreter::watermark_.
  uword preempt_a_lot;
  uword fuel;            // Maximum number of instructions per call.
  uword steps;           // Out: number of instructions the core executed.
};

static const uword TOIT_VCORE_STOP = 0;
static const uword TOIT_VCORE_TRAP = 1;

uword toit_vcore_run(toit_vcore_state* state);
bool toit_vcore_covers(uint8 op);
uword toit_vcore_max_height(uint8 kind_height);
uword toit_vcore_layout_count();
bool toit_vcore_layout_entry(uword i, const char** name, uword* value);

}  // extern "C"

namespace toit {

// The opcodes the verified core executes. Cross-checked against
// toit_vcore_covers by the layout check.
inline bool verified_core_covers(uint8 op) {
  switch (op) {
    case LOAD_LOCAL:
    case LOAD_LOCAL_WIDE:
    case LOAD_LOCAL_0:
    case LOAD_LOCAL_1:
    case LOAD_LOCAL_2:
    case LOAD_LOCAL_3:
    case LOAD_LOCAL_4:
    case LOAD_LOCAL_5:
    case STORE_LOCAL:
    case POP:
    case POP_1:
    case LOAD_SMI_U8:
    case INVOKE_STATIC:
    case RETURN:
    case LOAD_OUTER:
    case STORE_OUTER:
    case NON_LOCAL_RETURN:
    case NON_LOCAL_RETURN_WIDE:
    case LINK:
    case UNLINK:
      return true;
    default:
      return false;
  }
}

static const uword VERIFIED_CORE_FUEL = 1024;

#ifdef TOIT_VERIFIED_CORE_STATS
}  // namespace toit
#include <stdio.h>
namespace toit {
// Instruction counts, printed at exit. Build with
// -DTOIT_VERIFIED_CORE_STATS to see how much the core executes.
struct VerifiedCoreStats {
  unsigned long long dispatches = 0;  // Instructions dispatched to C++.
  unsigned long long calls = 0;       // Calls into the core.
  unsigned long long steps = 0;       // Instructions executed by the core.
  ~VerifiedCoreStats() {
    fprintf(stderr, "[verified core] C++ instructions %llu, core instructions %llu (%.1f%%), core calls %llu\n",
            dispatches, steps, 100.0 * steps / (steps + dispatches + 1), calls);
  }
};
static VerifiedCoreStats verified_core_stats;
#define VERIFIED_CORE_STATS(calls_delta, steps_delta) \
  (verified_core_stats.calls += (calls_delta), verified_core_stats.steps += (steps_delta))
#define VERIFIED_CORE_COUNT_DISPATCH() (verified_core_stats.dispatches++)
#else
#define VERIFIED_CORE_STATS(calls_delta, steps_delta)
#define VERIFIED_CORE_COUNT_DISPATCH()
#endif

}  // namespace toit

// Used inside Interpreter::run (needs sp, bcp, program and the
// interpreter's private stack fields).
#define VERIFIED_CORE_HOOK()                                                        \
  if (verified_core_covers(*bcp) && !Flags::trace) {                                \
    toit_vcore_state _vs_;                                                          \
    _vs_.stack_limit = reinterpret_cast<uword*>(limit_);                            \
    _vs_.stack_len = base_ - limit_;                                                \
    _vs_.sp = sp - limit_;                                                          \
    _vs_.try_sp = try_sp_ - limit_;                                                 \
    _vs_.code = program->bytecodes.data();                                          \
    _vs_.code_len = program->bytecodes.length();                                    \
    _vs_.bcp = bcp - program->bytecodes.data();                                     \
    _vs_.dispatch = program->dispatch_table.data();                                 \
    _vs_.dispatch_len = program->dispatch_table.length();                           \
    _vs_.frame_marker = reinterpret_cast<uword>(program->frame_marker());           \
    _vs_.watermark = &watermark_;                                                   \
    _vs_.preempt_a_lot = Flags::preempt_a_lot;                                      \
    _vs_.fuel = VERIFIED_CORE_FUEL;                                                 \
    _vs_.steps = 0;                                                                 \
    uword _vr_ = toit_vcore_run(&_vs_);                                             \
    VERIFIED_CORE_STATS(1, _vs_.steps);                                             \
    sp = limit_ + _vs_.sp;                                                          \
    try_sp_ = limit_ + _vs_.try_sp;                                                 \
    bcp = program->bytecodes.data() + _vs_.bcp;                                     \
    if (_vr_ == TOIT_VCORE_TRAP) {                                                  \
      FATAL("verified core: safety check failed at bcp %p (opcode %d)", bcp, *bcp); \
    }                                                                               \
  }                                                                                 \
  VERIFIED_CORE_COUNT_DISPATCH();

#else

#define VERIFIED_CORE_HOOK()

#endif

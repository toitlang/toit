// Copyright (C) 2018 Toitware ApS.
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

#include <atomic>

#include "objects.h"
#include "primitive.h"

#ifdef ESP32
#include <esp_attr.h>
// We put the core interpreter functionality in the IRAM section to avoid
// spending time on re-reading the code from flash.
#define INTERPRETER_CORE IRAM_ATTR
#else
#define INTERPRETER_CORE
#endif

namespace toit {

class Interpreter {
 public:
  // Number of words that are pushed onto the stack whenever there is a call.
  static const int FRAME_SIZE = 2;

  // Layout for unwind-protect frames used in try-finally.
  static const int LINK_REASON_SLOT = 1;
  static const int LINK_TARGET_SLOT = 2;
  static const int LINK_RESULT_SLOT = 3;
  static const int UNWIND_REASON_WHEN_THROWING_EXCEPTION = -2;

  // Return values for the fast compare_to test for numbers.
  static const int COMPARE_TO_BIAS    = -2;
  static const int COMPARE_FAILED     = 0;
  static const int COMPARE_TO_MINUS_1 = 1;
  static const int COMPARE_TO_ZERO    = 2;
  static const int COMPARE_TO_PLUS_1  = 3;
  static const int COMPARE_TO_MASK    = 3;

  // Special flag used to signal to the `min` function that lhs <= rhs,
  // but with the special rule that NaN < anything else.  This allows
  // `min` to efficiently propagate NaN.  (`max` automatically does this
  // without special code because NaN is the highest value in compare_to.)
  static const int COMPARE_TO_LESS_FOR_MIN = 4;

  static const int STRICTLY_LESS      = 8;
  static const int LESS_EQUAL         = 16;
  static const int EQUAL              = 32;
  static const int GREATER_EQUAL      = 64;
  static const int STRICTLY_GREATER   = 128;

  class Result {
   public:
    enum State {
      PREEMPTED,
      YIELDED,
      TERMINATED,
      DEEP_SLEEP,
    };

    explicit Result(State state) : _state(state), _value(0) {}
    explicit Result(int64 value) : _state(TERMINATED), _value(value) {}
    Result(State state, int64 value) : _state(state), _value(value) {}

    State state() { return _state; }
    int64 value() { return _value; }

   private:
    State _state;
    int64 _value;
  };

  Interpreter();

  Process* process() { return _process; }
  void activate(Process* process);
  void deactivate();

  // Garbage collection support.
  Object** scavenge(Object** sp, bool malloc_failed, int attempts);

  // Boot the interpreter on the current process.
  void prepare_process();

  // Run the interpreter. Returns a result that indicates if the process was
  // terminated or stopped for other reasons.
  Result run() INTERPRETER_CORE;

  // Fast helpers for indexing and number comparisons.
  static bool fast_at(Process* process, Object* receiver, Object* args, bool is_put, Object** value) INTERPRETER_CORE;
  static int compare_numbers(Object* lhs, Object *rhs) INTERPRETER_CORE;

  // Load stack info from process's stack.
  Object** load_stack();

  // Store stack into to process's stack.
  void store_stack(Object** sp = null);

  void prepare_task(Method entry, Instance* code);

  void preempt();

  // Called by the [task_reset_stack_limit] primitive as we're unwinding from
  // having thrown a stack overflow exception.
  void reset_stack_limit();

 private:
  Object** const PREEMPTION_MARKER = reinterpret_cast<Object**>(UINTPTR_MAX);
  Process* _process;

  // Cached pointers into the stack object.
  Object** _limit;
  Object** _base;
  Object** _sp;
  Object** _try_sp;

  // Stack overflow handling.
  std::atomic<Object**> _watermark;
  bool _in_stack_overflow;

  void trace(uint8* bcp);
  Method lookup_entry();

#ifdef PROFILER
  bool _is_profiler_active;
  void profile_register_method(Method method);
  void profile_increment(uint8* bcp);
  void set_profiler_state();
#endif

  enum OverflowState {
    OVERFLOW_RESUME,
    OVERFLOW_PREEMPT,
    OVERFLOW_EXCEPTION,
    OVERFLOW_WATCHDOG,
    OVERFLOW_OOM,
  };

  Object** check_stack_overflow(Object** sp, OverflowState* state, Method target);
  Method handle_stack_overflow(OverflowState state);
  Method handle_watchdog();

  Object* hash_do(Program* program, Object* current, Object* backing, int step, Object* block, Object** entry_return);

  inline Object* boolean(Program* program, bool x) const;
  inline bool is_true_value(Program* program, Object* value) const;

  inline bool typecheck_class(Program* program, Object* value, int class_index, bool is_nullable) const;
  inline bool typecheck_interface(Program* program, Object* value, int interface_selector_index, bool is_nullable) const;

  bool is_stack_empty() const {
    return _sp == _base;
  }

  void push(Object* object) {
    ASSERT(_sp > _limit);
    *(--_sp) = object;
  }

  Object** from_block(Smi* block) const {
    return _base - (block->value() - BLOCK_SALT);
  }

  Smi* to_block(Object** pointer) const {
    return Smi::from(_base - pointer + BLOCK_SALT);
  }

  friend class Stack;
};

#undef INTERPRETER_CORE

} // namespace toit

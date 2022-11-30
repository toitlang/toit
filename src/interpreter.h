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
  static const int COMPARE_FAILED = 0;
  // The succesful compare results are communicated in the low bits.
  static const int COMPARE_RESULT_MINUS_1 = 1;
  static const int COMPARE_RESULT_ZERO    = 2;
  static const int COMPARE_RESULT_PLUS_1  = 3;
  static const int COMPARE_RESULT_MASK    = 3;
  static const int COMPARE_RESULT_BIAS    = -2;

  // Special flag used to signal to the `min` function that lhs <= rhs,
  // but with the special rule that NaN < anything else.  This allows
  // `min` to efficiently propagate NaN.  (`max` automatically does this
  // without special code because NaN is the highest value in compare_to.)
  static const int COMPARE_FLAG_LESS_FOR_MIN       = 4;
  // Other returned comparison flags.
  static const int COMPARE_FLAG_STRICTLY_LESS      = 8;
  static const int COMPARE_FLAG_LESS_EQUAL         = 16;
  static const int COMPARE_FLAG_EQUAL              = 32;
  static const int COMPARE_FLAG_GREATER_EQUAL      = 64;
  static const int COMPARE_FLAG_STRICTLY_GREATER   = 128;

  class Result {
   public:
    enum State {
      PREEMPTED,
      YIELDED,
      TERMINATED,
      DEEP_SLEEP,
    };

    explicit Result(State state) : state_(state), value_(0) {}
    explicit Result(int64 value) : state_(TERMINATED), value_(value) {}
    Result(State state, int64 value) : state_(state), value_(value) {}

    State state() { return state_; }
    int64 value() { return value_; }

   private:
    State state_;
    int64 value_;
  };

  enum HashFindAction {
    kBail,
    kRestartBytecode,
    kReturnValue,
    kCallBlockThenRestartBytecode
  };

  Interpreter();

  Process* process() { return process_; }
  void activate(Process* process);
  void deactivate();

  // Garbage collection support.
  Object** gc(Object** sp, bool malloc_failed, int attempts, bool force_cross_process);

  // Boot the interpreter on the current process.
  void prepare_process();

  // Run the interpreter. Returns a result that indicates if the process was
  // terminated or stopped for other reasons.
  Result run() INTERPRETER_CORE;

  // Fast helpers for indexing and number comparisons.
  static bool fast_at(Process* process, Object* receiver, Object* args, bool is_put, Object** value) INTERPRETER_CORE;
  static int compare_numbers(Object* lhs, Object *rhs) INTERPRETER_CORE;

  // Load stack info from process's stack.
  Object** load_stack(Method* pending = null);

  // Store stack into to process's stack.
  void store_stack(Object** sp = null, Method pending = Method::invalid());

  void prepare_task(Method entry, Instance* code);

  void preempt();
  uint8* preemption_method_header_bcp() const { return preemption_method_header_bcp_; }

 private:
  Object** const PREEMPTION_MARKER = reinterpret_cast<Object**>(UINTPTR_MAX);
  Process* process_;

  // Cached pointers into the stack object.
  Object** limit_;
  Object** base_;
  Object** sp_;
  Object** try_sp_;

  // Stack overflow handling.
  std::atomic<Object**> watermark_;

  // Preemption method.
  uint8* preemption_method_header_bcp_;

  void trace(uint8* bcp);
  Method lookup_entry();

  enum OverflowState {
    OVERFLOW_RESUME,
    OVERFLOW_PREEMPT,
    OVERFLOW_EXCEPTION,
  };

  Object** handle_stack_overflow(Object** sp, OverflowState* state, Method target);

  Object** push_error(Object** sp, Object* type, const char* message);
  Object** push_out_of_memory_error(Object** sp);

  Object* hash_do(Program* program, Object* current, Object* backing, int step, Object* block, Object** entry_return);
  Object** hash_find(Object** sp, Program* program, HashFindAction* action_return, Method* block_return, Object** result_return);

  inline bool is_true_value(Program* program, Object* value) const;

  inline bool typecheck_class(Program* program, Object* value, int class_index, bool is_nullable) const;
  inline bool typecheck_interface(Program* program, Object* value, int interface_selector_index, bool is_nullable) const;

  bool is_stack_empty() const {
    return sp_ == base_;
  }

  void push(Object* object) {
    ASSERT(sp_ > limit_);
    *(--sp_) = object;
  }

  Object** from_block(Smi* block) const {
    return base_ - (block->value() - BLOCK_SALT);
  }

  Smi* to_block(Object** pointer) const {
    return Smi::from(base_ - pointer + BLOCK_SALT);
  }

  friend class Stack;
};

class ProcessRunner {
 public:
  virtual Interpreter::Result run() = 0;
};

} // namespace toit

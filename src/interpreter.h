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

#include "method_entries.h"
#include "objects.h"
#include "primitive.h"

#if defined(ESP32)
#include <esp_attr.h>
#endif

#if defined(ESP32) && defined(CONFIG_TOIT_INTERPRETER_IN_IRAM)
// We put the core interpreter functionality in the IRAM section to avoid
// spending time on re-reading the code from flash.
#define INTERPRETER_CORE IRAM_ATTR
#else
#define INTERPRETER_CORE
#endif

#if defined(ESP32) && defined(CONFIG_TOIT_INTERPRETER_HELPERS_IN_IRAM)
// We put the interpreter helper functions in the IRAM section to
// avoid spending time on re-reading the code from flash.
#define INTERPRETER_HELPER IRAM_ATTR
#else
#define INTERPRETER_HELPER
#endif

namespace toit {

typedef double (double_op)(double a, double b);

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

  static const int SIMPLE_LESS = COMPARE_RESULT_MINUS_1 | COMPARE_FLAG_STRICTLY_LESS | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_LESS_FOR_MIN;
  static const int SIMPLE_EQUAL = COMPARE_RESULT_ZERO | COMPARE_FLAG_LESS_EQUAL | COMPARE_FLAG_EQUAL | COMPARE_FLAG_GREATER_EQUAL;
  static const int SIMPLE_GREATER = COMPARE_RESULT_PLUS_1 | COMPARE_FLAG_STRICTLY_GREATER | COMPARE_FLAG_GREATER_EQUAL;

  class Result {
   public:
    enum State {
      PREEMPTED,
      YIELDED,
      TERMINATED,
      RESET,
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
  Object** gc(
      Object** sp,
      bool malloc_failed,
      int attempts,
      bool force_cross_process,
      const char* reason,
      int parameter1 = 0,
      int parameter2 = 0);

  // Boot the interpreter on the current process.
  void prepare_process();

  // Run the interpreter. Returns a result that indicates if the process was
  // terminated or stopped for other reasons.
  Result run() INTERPRETER_CORE;

  // Fast helpers for indexing and number comparisons.
  static bool fast_at(Process* process, Object* receiver, Object* args, bool is_put, Object** value) INTERPRETER_HELPER;
  static bool fast_size(Process* process, Object* receiver, Smi** result) INTERPRETER_HELPER;
  static int compare_numbers(Object* lhs, Object* rhs) INTERPRETER_HELPER;
  static int compare_ints(int64 lhs, int64 rhs) INTERPRETER_HELPER;

  // Load stack info from process's stack.
  Object** load_stack(Method* pending = null);

  // Store stack into to process's stack.
  void store_stack(Object** sp = null, Method pending = Method::invalid());

  void prepare_task(Method entry, Instance* code);

  void preempt();
  uint8* preemption_method_header_bcp() const { return preemption_method_header_bcp_; }

  static bool are_smis(Object* a, Object* b);
  static bool are_floats(Object* a, Object* b);

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

  // The legal method entries of the current program. Set in 'run'.
  const MethodEntryTable* method_entries_ = null;

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

  Object* hash_do(Program* program, Object** sp, Object* current, Object* backing, int step, Object* block, Object** entry_return) INTERPRETER_HELPER;
  Object** hash_find(Object** sp, Program* program, HashFindAction* action_return, Method* block_return, Object** result_return) INTERPRETER_HELPER;

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
    return base_ - (Smi::value(block) - BLOCK_SALT);
  }

  Smi* to_block(Object** pointer) const {
    return Smi::from(base_ - pointer + BLOCK_SALT);
  }

  // Block references, try-link chains and unwind targets are stack pointers
  // encoded as smis relative to the stack base. A malformed program can put
  // any value into the slots that hold them, so the interpreter decodes them
  // with these checked variants.

  // Decodes a block reference. Returns null if the value is not a smi or if
  // the pointer and the 'extra' words above it are not inside the live part
  // of the stack, [sp, base_).
  Object** checked_from_block(Object* block, Object** sp, word extra = 0) const {
    if (!is_smi(block)) return null;
    word distance = Smi::value(block) - BLOCK_SALT;  // base_ - pointer.
    if (distance <= extra || distance > base_ - sp) return null;
    return base_ - distance;
  }

  // Decodes an unwind target, which may also be the base of the stack.
  // Returns null if the value is not a smi or the pointer is outside of
  // [sp, base_].
  Object** checked_unwind_target(Object* block, Object** sp) const {
    if (!is_smi(block)) return null;
    word distance = Smi::value(block) - BLOCK_SALT;  // base_ - pointer.
    if (distance < 0 || distance > base_ - sp) return null;
    return base_ - distance;
  }

  // Returns the method that the given method id refers to, if the id is a
  // legal method entry of the current program. Otherwise returns an invalid
  // method.
  Method checked_method(Program* program, Object* id) const {
    if (!is_smi(id)) return Method::invalid();
    word value = Smi::value(id);
    if (!method_entries_->is_entry(value)) return Method::invalid();
    return Method(program->bytecodes, value);
  }

  // Returns the block method of the given block reference, or an invalid
  // method if the reference or the method id in the referenced slot is
  // not legal.
  Method checked_block_method(Program* program, Object* block, Object** sp) const {
    Object** block_ptr = checked_from_block(block, sp);
    if (block_ptr == null) return Method::invalid();
    Method result = checked_method(program, *block_ptr);
    if (!result.is_valid() || !result.is_block_method()) return Method::invalid();
    return result;
  }

  static Object* float_op(Process* process, Object* a, Object* b, double_op* op);


  friend class Stack;
};

// We push the exception and two elements for the unwinding implementation
// on the stack when we handle stack overflows. This is in addition to the
// extra frame information we store for the call, because those are not
// reflected in the max-height of the called method. We do not keep track
// of where in a method we might do a call, so we conservatively assume
// that it will happen at max-height and reserve space for that.
const int RESERVED_STACK_FOR_CALLS = Interpreter::FRAME_SIZE + 3;

class ProcessRunner {
 public:
  virtual Interpreter::Result run() = 0;
  virtual void set_process(Process* process) = 0;
};

double double_add(double a, double b);
double double_sub(double a, double b);
double double_mul(double a, double b);

} // namespace toit

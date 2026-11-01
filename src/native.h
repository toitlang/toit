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

#include "interpreter.h"
#include "objects.h"
#include "objects_inline.h"
#include "process.h"
#include "program.h"

// Support for programs that have been compiled to C++.
//
// Native code uses the same stack and the same frame layout as the
// interpreter. All Toit frames live on the Toit stack and the C stack stays
// flat, because calls, returns and branches between basic blocks are tail
// calls. This means that the garbage collector, stack growth, tasks and
// unwinding work the way they do for bytecodes. Return addresses are
// addresses of functions, which have their low bit clear, so they look like
// smis to the garbage collector.
//
// A process runs either bytecodes or native code; never both.

namespace toit {

struct NativeContext;

// Used for checking that generated code and the runtime agree on the layouts.
constexpr uint32 native_abi() {
  return static_cast<uint32>((sizeof(Interpreter) << 20) ^ (sizeof(Process) << 10) ^
      sizeof(Program) ^ (sizeof(Stack) << 26) ^ (sizeof(word) << 16));
}

// Used for checking that the running program is the one that was compiled.
inline uint32 native_fingerprint(const uint8* bytes, word length) {
  uint32 hash = 2166136261u;
  for (word i = 0; i < length; i++) hash = (hash ^ bytes[i]) * 16777619u;
  return hash;
}

// The 'x' and 'y' parameters are scratch values: The meaning depends on what
// is being called. Generated code passes them on untouched when they aren't
// used, because clearing them would take up code on every jump.
#define NATIVE_PARAMS Object** sp, NativeContext* c, void* x, word y
#define NATIVE_ARGS sp, c, x, y

typedef void (*NativeFn)(NATIVE_PARAMS);

#if defined(__clang__)
#define NATIVE_TAIL [[clang::musttail]] return
#else
#define NATIVE_TAIL return
#endif

// Most code runs rarely, so it is optimized for size. Hot code is left alone.
#if defined(__clang__) && !defined(NATIVE_ALL_HOT)
#define NATIVE_COLD __attribute__((minsize, noinline))
#else
#define NATIVE_COLD
#endif

#define NATIVE_LIKELY(x) __builtin_expect(!!(x), 1)
#define NATIVE_UNLIKELY(x) __builtin_expect(!!(x), 0)

// Code that can be entered from the outside: method entries, the targets of
// non-local branches and the place where tasks start. Sorted by bci.
struct NativeEntry {
  int bci;
  NativeFn fn;
};

struct NativeProgram {
  // Generated code knows about the layout of the objects in the runtime.
  uint32 abi;
  uint32 fingerprint;
  word bytecodes_length;
  const NativeEntry* entries;
  int entry_count;
  // The places calls return to. Used for stack traces.
  const NativeEntry* returns;
  int return_count;
};

struct NativeContext {
  Interpreter* interpreter;
  Process* process;
  Program* program;
  const NativeProgram* native;
  Object* null_object;
  Object* true_object;
  Object* false_object;
  Object* frame_marker;
  Object** literals;
  Object** globals;
  Interpreter::Result result;
};

// The out-of-line parts of native code. Each one finishes by tail calling
// the code that should run next. Returning means that the process has
// stopped running and that the result is in the context.
class NativeRuntime {
 public:
  // Registers the program that this executable has been compiled from.
  static int register_program(const NativeProgram* program);

  // Runs the current process if it is running the registered program.
  static bool run(Interpreter* interpreter, Interpreter::Result* result);

  static void stack_overflow(NATIVE_PARAMS);
  static void preempt(NATIVE_PARAMS);
  static void primitive(NATIVE_PARAMS);
  static void throw_exception(NATIVE_PARAMS);
  static void unwind(NATIVE_PARAMS);
  static void non_local_return(NATIVE_PARAMS);
  static void non_local_branch(NATIVE_PARAMS);
  static void allocate(NATIVE_PARAMS);
  static void binary(NATIVE_PARAMS);
  static void at(NATIVE_PARAMS);
  static void at_put(NATIVE_PARAMS);
  static void size(NATIVE_PARAMS);
  static void virtual_fallback(NATIVE_PARAMS);
  static void as_failure(NATIVE_PARAMS);
  static void code_failure(NATIVE_PARAMS);
  static void block_failure(NATIVE_PARAMS);
  static void program_failure(NATIVE_PARAMS);
  static void primitive_failure(NATIVE_PARAMS);
  static void lambda_tail(NATIVE_PARAMS);
  static void initializer_tail(NATIVE_PARAMS);
  static void load_global_dynamic(NATIVE_PARAMS);
  static void store_global_dynamic(NATIVE_PARAMS);
  static void smi_repeat(NATIVE_PARAMS);
  static void array_do(NATIVE_PARAMS);
  static void halt(NATIVE_PARAMS);
  static void illegal(NATIVE_PARAMS);

  static Object* identical(NativeContext* c, Object* a, Object* b);
  static bool is_interface(NativeContext* c, Object* value, word offset);

  static Object** from_block(NativeContext* c, Object* block) {
    return c->interpreter->from_block(Smi::cast(block));
  }

  static Object* to_block(NativeContext* c, Object** pointer) {
    return c->interpreter->to_block(pointer);
  }

  static bool needs_stack_check(NativeContext* c, Object** sp, int height) {
    // We only need to see preemption requests eventually.
    return sp - height < c->interpreter->watermark_.load(std::memory_order_relaxed);
  }

  static bool is_preempted(NativeContext* c) {
    return c->interpreter->watermark_.load(std::memory_order_relaxed) == c->interpreter->PREEMPTION_MARKER;
  }

  static void link(NativeContext* c, Object** sp) {
    Interpreter* interpreter = c->interpreter;
    // The result, the target, the reason, and the chain.
    sp[3] = Smi::from(0xbeef);
    sp[2] = Smi::from(-0xdead);
    sp[1] = Smi::from(-1);
    sp[0] = Smi::from(interpreter->base_ - interpreter->try_sp_);
    interpreter->try_sp_ = sp;
  }

  static void unlink(NativeContext* c, Object* chain) {
    Interpreter* interpreter = c->interpreter;
    interpreter->try_sp_ = interpreter->base_ - Smi::value(chain);
  }

 private:
  static NativeFn find_entry(const NativeProgram* native, int bci);
  static Object* start_address(Program* program, uint8* bcp);
  static int return_bci(Program* program, uint8* address);
  static void call(NativeContext* c, Object** sp, void* next, Method target);
};

// Define NATIVE_DEBUG when compiling generated code to check
// the targets of all indirect jumps. The bci says where they are.
#ifdef NATIVE_DEBUG
#define NATIVE_CHECK_TARGET(c, target, bci)                                                    \
  do {                                                                                         \
    uint8* _bcp_ = reinterpret_cast<uint8*>(target);                                           \
    if ((c)->program->bytecodes.is_inside(_bcp_)) {                                            \
      FATAL("jump to bytecode %d from %d", (c)->program->absolute_bci_from_bcp(_bcp_), bci);   \
    }                                                                                          \
    if ((reinterpret_cast<uword>(target) & 3) != 0 ||                                          \
        reinterpret_cast<uword>(target) < 0x100000000 ||                                       \
        reinterpret_cast<uword>(target) > 0x200000000) {                                       \
      FATAL("jump to %p from %d", reinterpret_cast<void*>(target), bci);                       \
    }                                                                                          \
  } while (false)
#else
#define NATIVE_CHECK_TARGET(c, target, bci)
#endif

#define PUSH(o)            ({ Object* _o_ = (o); *(--sp) = _o_; })
#define POP()              (*(sp++))
#define DROP(n)            (sp += (n))
#define STACK_AT(n)        (*(sp + (n)))
#define STACK_AT_PUT(n, o) ({ Object* _o_ = (o); *(sp + (n)) = _o_; })

inline bool native_are_smis(Object* a, Object* b) {
  return is_smi(reinterpret_cast<Object*>(reinterpret_cast<uword>(a) | reinterpret_cast<uword>(b)));
}

// These expect smis and return false if the result doesn't fit in a smi.
inline bool native_add(Object* a, Object* b, Object** result) {
  word sum;
  if (__builtin_add_overflow(reinterpret_cast<word>(a), reinterpret_cast<word>(b), &sum)) return false;
  *result = reinterpret_cast<Object*>(sum);
  return true;
}

inline bool native_sub(Object* a, Object* b, Object** result) {
  word difference;
  if (__builtin_sub_overflow(reinterpret_cast<word>(a), reinterpret_cast<word>(b), &difference)) return false;
  *result = reinterpret_cast<Object*>(difference);
  return true;
}

inline bool native_mul(Object* a, Object* b, Object** result) {
  word product;
  if (__builtin_mul_overflow(reinterpret_cast<word>(a), reinterpret_cast<word>(b) >> 1, &product)) return false;
  *result = reinterpret_cast<Object*>(product);
  return true;
}

// Reading an integer doesn't involve any calls. Calls are expensive in native
// code, even if they are rarely made, because the compiler saves the return
// address on the hot paths of the functions that make them.
inline int64 native_int_value(Object* object) {
  return is_smi(object) ? Smi::value(object) : LargeInteger::cast(object)->value();
}

inline unsigned native_class_id(Object* object, unsigned smi_class_id) {
  return is_smi(object) ? smi_class_id : Smi::value(HeapObject::cast(object)->class_id());
}

// For objects that are known not to be smis.
inline unsigned native_heap_class_id(Object* object) {
  return Smi::value(HeapObject::cast(object)->class_id());
}

// Decides the cases of == that don't need to look at the objects. Returns
// 1 or 0 for the result, and -1 if the slow path has to figure it out.
inline int native_equals(NativeContext* c, Object* a, Object* b);

inline bool native_is_true(NativeContext* c, Object* value) {
  return value != c->false_object && value != c->null_object;
}

inline int native_equals(NativeContext* c, Object* a, Object* b) {
  if (native_are_smis(a, b)) return a == b;
  if (a == c->null_object || b == c->null_object) return a == b;
  // The same object is equal to itself, except for NaNs.
  if (a == b && !is_smi(a) && !is_double(a)) return 1;
  return -1;
}

}  // namespace toit

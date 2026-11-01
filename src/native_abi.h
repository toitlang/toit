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

// The interface between generated native code and the runtime.
//
// This file is the start of every generated C++ file, so it can't depend on
// anything else in the VM sources. It is used by the VM too, and native.cc
// checks that the layouts in here are the ones the VM uses.
//
// Native code uses the same stack and the same frame layout as the
// interpreter. All Toit frames live on the Toit stack and the C stack stays
// flat, because calls, returns and branches between basic blocks are tail
// calls. This means that the garbage collector, stack growth, tasks and
// unwinding work the way they do for bytecodes. Return addresses are
// addresses of functions, which have their low bit clear, so they look like
// smis to the garbage collector.
//
// Compile with -falign-functions=4 and a compiler that guarantees tail calls.

#ifndef TOIT_NATIVE_ABI_H_
#define TOIT_NATIVE_ABI_H_

#include <stdint.h>
#include <string.h>

namespace toit {

class Interpreter;
class Method;
class Object;
class Process;
class Program;
class ProgramImage;

struct NativeContext;

// The 'x' and 'y' parameters are scratch values: The meaning depends on what
// is being called. Generated code passes them on untouched when they aren't
// used, because clearing them would take up code on every jump.
#define NATIVE_PARAMS toit::Object** sp, toit::NativeContext* c, void* x, intptr_t y
#define NATIVE_ARGS sp, c, x, y

typedef void (*NativeFn)(NATIVE_PARAMS);

#if defined(__clang__)
#define NATIVE_TAIL [[clang::musttail]] return
#else
#define NATIVE_TAIL return
#endif

// Most code runs rarely, so it is optimized for size. Hot code is left alone.
#if defined(__clang__)
#define NATIVE_COLD __attribute__((minsize, noinline))
#else
#define NATIVE_COLD
#endif

#define NATIVE_LIKELY(x) __builtin_expect(!!(x), 1)
#define NATIVE_UNLIKELY(x) __builtin_expect(!!(x), 0)

// Keeps a function around for the tables, which are written in assembler
// to use offsets. Pointers would take up twice the space, and the executable
// would need a relocation for each of them when it is loaded.
#define NATIVE_USED(fn) static void fn(NATIVE_PARAMS) __attribute__((used))

#if defined(__APPLE__)
#define NATIVE_TABLE_SECTION ".section __TEXT,__const\n"
#else
#define NATIVE_TABLE_SECTION ".section .rodata\n"
#endif

// Code that can be entered from the outside: method entries, the targets of
// non-local branches and the place where tasks start. Sorted by bci. The
// offset is relative to the field itself.
struct NativeEntry {
  int32_t bci;
  int32_t offset;

  NativeFn fn() const {
    return reinterpret_cast<NativeFn>(reinterpret_cast<intptr_t>(&offset) + offset);
  }
};

struct NativeProgram {
  uint32_t abi;
  uint32_t fingerprint;
  intptr_t bytecodes_length;
  const NativeEntry* entries;
  int entry_count;
  // The places calls return to, used for stack traces. They are sorted by
  // bci, and the entries are offsets, relative to themselves, to the code.
  const int32_t* returns;
  // The distance from one bci to the next, as LEB128 encoded numbers.
  const uint8_t* return_deltas;
  int return_count;
  // The program is an image that has to be relocated when it is loaded. Most
  // of it is padding, so the chunks that are all zeros aren't stored. The ranges
  // are pairs with the number of chunks to skip and the number to read. The
  // uuid is the id of the program. The bundle only has what stack traces need.
  const uint8_t* uuid;
  const uint8_t* image;
  int image_size;
  const int32_t* image_ranges;
  int image_range_count;
  const uint8_t* bundle;
  int bundle_size;
  // Whether this is the system program that the executable boots from.
  bool is_system;
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
  // These are fields in the interpreter. It's just as
  // fast to go through them, because they are indirect anyway.
  Object*** watermark;
  Object*** base;
  Object*** try_sp;
  uintptr_t remembered_set_bias;
  int lazy_initializer_class_id;
  void* result;
};

static const int NATIVE_SMI_TAG_SIZE = 1;
static const uintptr_t NATIVE_HEAP_TAG = 1;
static const uintptr_t NATIVE_NON_SMI_TAG_MASK = 3;
static const int NATIVE_CLASS_TAG_MASK = 15;
static const int NATIVE_CLASS_ID_OFFSET = 5;
static const int NATIVE_INSTANCE_TAG = 2;
static const int NATIVE_DOUBLE_TAG = 4;
static const int NATIVE_BLOCK_SALT = 0x01020304;
static const int NATIVE_CARD_SIZE_LOG_2 = 5 + (sizeof(void*) == 8 ? 3 : 2);
static const uint8_t NATIVE_NEW_SPACE_POINTERS = 1;

inline uintptr_t native_bits(Object* object) { return reinterpret_cast<uintptr_t>(object); }

inline bool native_is_smi(Object* object) { return (native_bits(object) & 1) == 0; }

inline Object* native_smi(intptr_t value) {
  return reinterpret_cast<Object*>(static_cast<uintptr_t>(value) << NATIVE_SMI_TAG_SIZE);
}

inline intptr_t native_smi_value(Object* smi) {
  return reinterpret_cast<intptr_t>(smi) >> NATIVE_SMI_TAG_SIZE;
}

inline Object** native_word_address(Object* object, int index) {
  return reinterpret_cast<Object**>(native_bits(object) - NATIVE_HEAP_TAG + index * sizeof(void*));
}

inline bool native_is_heap_object(Object* object) {
  return (native_bits(object) & NATIVE_NON_SMI_TAG_MASK) == NATIVE_HEAP_TAG;
}

inline intptr_t native_header(Object* object) { return native_smi_value(*native_word_address(object, 0)); }

inline bool native_has_class_tag(Object* object, int tag) {
  return native_is_heap_object(object) && (native_header(object) & NATIVE_CLASS_TAG_MASK) == tag;
}

inline bool native_is_instance(Object* object) { return native_has_class_tag(object, NATIVE_INSTANCE_TAG); }
inline bool native_is_double(Object* object) { return native_has_class_tag(object, NATIVE_DOUBLE_TAG); }

// For objects that are known not to be smis.
inline unsigned native_heap_class_id(Object* object) {
  return static_cast<unsigned>(native_header(object) >> NATIVE_CLASS_ID_OFFSET);
}

inline unsigned native_class_id(Object* object, unsigned smi_class_id) {
  return native_is_smi(object) ? smi_class_id : native_heap_class_id(object);
}

inline Object* native_field(Object* instance, int index) {
  return *native_word_address(instance, index + 1);
}

inline void native_set_field(NativeContext* c, Object* instance, int index, Object* value) {
  uintptr_t card = native_bits(instance) >> NATIVE_CARD_SIZE_LOG_2;
  *reinterpret_cast<uint8_t*>(card + c->remembered_set_bias) = NATIVE_NEW_SPACE_POINTERS;
  *native_word_address(instance, index + 1) = value;
}

// The out-of-line parts of native code. Each one finishes by tail calling
// the code that should run next. Returning means that the process has
// stopped running and that the result is in the context.
class NativeRuntime {
 public:
  // Registers the program that this executable has been compiled from.
  static int register_program(const NativeProgram* program);
  static const NativeProgram* registered_program(bool is_system);

  // Runs the current process if it is running the registered program.
  // The result is an Interpreter::Result, which is not known in here.
  static bool run(Interpreter* interpreter, void* result);

  // Relocates the image of the program into new memory.
  static ProgramImage load_image(const NativeProgram* program);
  // Returns the image of the program with the given id. It is
  // invalid if the id isn't for one of the programs in this executable.
  static ProgramImage load_image_with_id(const uint8_t* id);

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
  static bool is_interface(NativeContext* c, Object* value, intptr_t offset);

  static Object** from_block(NativeContext* c, Object* block) {
    return *c->base - (native_smi_value(block) - NATIVE_BLOCK_SALT);
  }

  static Object* to_block(NativeContext* c, Object** pointer) {
    return native_smi(*c->base - pointer + NATIVE_BLOCK_SALT);
  }

  static Object** watermark(NativeContext* c) {
    return __atomic_load_n(c->watermark, __ATOMIC_RELAXED);
  }

  static bool needs_stack_check(NativeContext* c, Object** sp, int height) {
    // We only need to see preemption requests eventually.
    return sp - height < watermark(c);
  }

  static bool is_preempted(NativeContext* c) {
    return watermark(c) == reinterpret_cast<Object**>(UINTPTR_MAX);
  }

  static void link(NativeContext* c, Object** sp) {
    // The result, the target, the reason, and the chain.
    sp[3] = native_smi(0xbeef);
    sp[2] = native_smi(-0xdead);
    sp[1] = native_smi(-1);
    sp[0] = native_smi(*c->base - *c->try_sp);
    *c->try_sp = sp;
  }

  static void unlink(NativeContext* c, Object* chain) {
    *c->try_sp = *c->base - native_smi_value(chain);
  }

 private:
  static NativeFn find_entry(const NativeProgram* native, int bci);
  static Object* start_address(Program* program, uint8_t* bcp);
  static int return_bci(Program* program, uint8_t* address);
  static void call(NativeContext* c, Object** sp, void* next, Method target);
};

#define PUSH(o)            ({ Object* _o_ = (o); *(--sp) = _o_; })
#define POP()              (*(sp++))
#define DROP(n)            (sp += (n))
#define STACK_AT(n)        (*(sp + (n)))
#define STACK_AT_PUT(n, o) ({ Object* _o_ = (o); *(sp + (n)) = _o_; })

inline bool native_are_smis(Object* a, Object* b) {
  return ((native_bits(a) | native_bits(b)) & 1) == 0;
}

// These expect smis and return false if the result doesn't fit in a smi.
inline bool native_add(Object* a, Object* b, Object** result) {
  intptr_t sum;
  if (__builtin_add_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b), &sum)) return false;
  *result = reinterpret_cast<Object*>(sum);
  return true;
}

inline bool native_sub(Object* a, Object* b, Object** result) {
  intptr_t difference;
  if (__builtin_sub_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b), &difference)) return false;
  *result = reinterpret_cast<Object*>(difference);
  return true;
}

inline bool native_mul(Object* a, Object* b, Object** result) {
  intptr_t product;
  if (__builtin_mul_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b) >> 1, &product)) return false;
  *result = reinterpret_cast<Object*>(product);
  return true;
}

// Reading an integer doesn't involve any calls. Calls are expensive in native
// code, even if they are rarely made, because the compiler saves the return
// address on the hot paths of the functions that make them.
inline int64_t native_int_value(Object* object) {
  if (native_is_smi(object)) return native_smi_value(object);
  int64_t value;
  memcpy(&value, native_word_address(object, 1), sizeof(value));
  return value;
}

inline bool native_is_true(NativeContext* c, Object* value) {
  return value != c->false_object && value != c->null_object;
}

// Decides the cases of == that don't need to look at the objects. Returns
// 1 or 0 for the result, and -1 if the slow path has to figure it out.
inline int native_equals(NativeContext* c, Object* a, Object* b) {
  if (native_are_smis(a, b)) return a == b;
  if (a == c->null_object || b == c->null_object) return a == b;
  // The same object is equal to itself, except for NaNs.
  if (a == b && !native_is_smi(a) && !native_is_double(a)) return 1;
  return -1;
}

}  // namespace toit

#endif  // TOIT_NATIVE_ABI_H_

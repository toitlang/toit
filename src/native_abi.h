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
// unwinding work the way they do for bytecodes. Return addresses are addresses
// of functions, which are declared to have their low bit clear, so they look
// like smis to the garbage collector.
//
// Compile with a compiler that guarantees tail calls.

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
// The top of the stack is always in 't' and the rest is in memory from 'sp' and
// up. This is why the runtime and the stack traces can't look at the stack
// before it has been spilled, and generated code does that before it calls them.
// All the code has the same signature, so not all of it needs everything.
#pragma GCC diagnostic ignored "-Wunused-parameter"
#define NATIVE_PARAMS \
  toit::Object **sp, toit::NativeContext *c, void *x, intptr_t y, toit::Object *t
#define NATIVE_ARGS sp, c, x, y, t

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

// All the functions that have their address on the stack.
#define NATIVE_ON_STACK __attribute__((aligned(2)))

// Code addresses and tagged values are all words to the generated code.
#define NATIVE_ADDRESS(label) reinterpret_cast<void*>(&label)
#define NATIVE_OBJECT(value) reinterpret_cast<toit::Object*>(value)
#define NATIVE_WORD(object) reinterpret_cast<intptr_t>(object)
#define NATIVE_FN(object) reinterpret_cast<toit::NativeFn>(object)

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
  unsigned lazy_initializer_class_id;
  int large_array_class_id;
  void* result;
};

static const int NATIVE_SMI_TAG_SIZE = 1;
static const uintptr_t NATIVE_HEAP_TAG = 1;
static const uintptr_t NATIVE_NON_SMI_TAG_MASK = 3;
static const int NATIVE_CLASS_TAG_MASK = 15;
static const int NATIVE_CLASS_ID_OFFSET = 5;
static const int NATIVE_INSTANCE_TAG = 2;
static const int NATIVE_DOUBLE_TAG = 4;
static const int NATIVE_ARRAY_TAG = 0;
static const int NATIVE_ARRAYLET_SIZE = 500;
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
  return reinterpret_cast<Object**>(native_bits(object) - NATIVE_HEAP_TAG +
                                    static_cast<uintptr_t>(index) * sizeof(void*));
}

inline bool native_is_heap_object(Object* object) {
  return (native_bits(object) & NATIVE_NON_SMI_TAG_MASK) == NATIVE_HEAP_TAG;
}

inline intptr_t native_header(Object* object) {
  return native_smi_value(*native_word_address(object, 0));
}

inline bool native_has_class_tag(Object* object, int tag) {
  return native_is_heap_object(object) && (native_header(object) & NATIVE_CLASS_TAG_MASK) == tag;
}

inline bool native_is_instance(Object* object) {
  return native_has_class_tag(object, NATIVE_INSTANCE_TAG);
}
inline bool native_is_double(Object* object) {
  return native_has_class_tag(object, NATIVE_DOUBLE_TAG);
}

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
  struct OverflowResult {
    Object** sp;
    int state;
  };
  static OverflowResult handle_overflow(NativeContext* c, Object** sp, Method target);
  static Object* binary_result(NativeContext* c, Object* a0, Object* a1, int bytecode);
  static Object* at_result(NativeContext* c, Object* receiver, Object* index, Object* value,
                           bool is_put);
  static Object* size_result(NativeContext* c, Object* receiver);
  static NativeFn find_entry(const NativeProgram* native, int bci);
  static Object* start_address(Program* program, uint8_t* bcp);
  static int return_bci(Program* program, uint8_t* address);
  static void call(NativeContext* c, Object** sp, void* next, Method target);
};

inline Object* native_pop(Object*** sp, Object** t) {
  Object* result = *t;
  *t = *((*sp)++);
  return result;
}

#define PUSH(o)        \
  do {                 \
    Object* _o_ = (o); \
    *(--sp) = t;       \
    t = _o_;           \
  } while (false)
#define POP() native_pop(&sp, &t)
#define DROP(n)        \
  do {                 \
    if ((n) != 0) {    \
      t = sp[(n) - 1]; \
      sp += (n);       \
    }                  \
  } while (false)
#define STACK_AT(n) ((n) == 0 ? t : sp[(n) - 1])
#define STACK_AT_PUT(n, o) \
  do {                     \
    Object* _o_ = (o);     \
    if ((n) == 0)          \
      t = _o_;             \
    else                   \
      sp[(n) - 1] = _o_;   \
  } while (false)
// Removes n elements and pushes a new one.
#define DROP_PUSH(n, o) \
  do {                  \
    Object* _o_ = (o);  \
    sp += (n) - 1;      \
    t = _o_;            \
  } while (false)
// Moves the top of the stack to memory and back.
#define SPILL() (*(--sp) = t)
#define RELOAD() (t = *(sp++))

#define NATIVE_COMPARE_SMIS(a, op, b) (NATIVE_WORD(a) op NATIVE_WORD(b))
#define NATIVE_COMPARE_INTS(are_smis, a, op, b) \
  (NATIVE_LIKELY(are_smis) ? NATIVE_COMPARE_SMIS(a, op, b) : (native_int_value(a) op native_int_value(b)))
#define NATIVE_BOOLEAN(condition) ((condition) ? c->true_object : c->false_object)

inline bool native_are_smis(Object* a, Object* b) {
  return ((native_bits(a) | native_bits(b)) & 1) == 0;
}

// These expect smis and return false if the result doesn't fit in a smi.
inline bool native_add(Object* a, Object* b, Object** result) {
  intptr_t sum = 0;
  if (__builtin_add_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b), &sum))
    return false;
  *result = reinterpret_cast<Object*>(sum);
  return true;
}

inline bool native_sub(Object* a, Object* b, Object** result) {
  intptr_t difference;
  if (__builtin_sub_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b),
                             &difference))
    return false;
  *result = reinterpret_cast<Object*>(difference);
  return true;
}

inline bool native_mul(Object* a, Object* b, Object** result) {
  intptr_t product = 0;
  if (__builtin_mul_overflow(reinterpret_cast<intptr_t>(a), reinterpret_cast<intptr_t>(b) >> 1,
                             &product))
    return false;
  *result = reinterpret_cast<Object*>(product);
  return true;
}

inline bool native_bit_and(Object* a, Object* b, Object** result) {
  *result = reinterpret_cast<Object*>(native_bits(a) & native_bits(b));
  return true;
}

inline bool native_bit_or(Object* a, Object* b, Object** result) {
  *result = reinterpret_cast<Object*>(native_bits(a) | native_bits(b));
  return true;
}

inline bool native_bit_xor(Object* a, Object* b, Object** result) {
  *result = reinterpret_cast<Object*>(native_bits(a) ^ native_bits(b));
  return true;
}

inline bool native_shift_is_small(Object* bits) {
  return static_cast<uintptr_t>(native_smi_value(bits)) < sizeof(void*) * 8;
}

inline bool native_shl(Object* a, Object* b, Object** result) {
  if (!native_shift_is_small(b)) return false;
  intptr_t bits = native_smi_value(b);
  intptr_t shifted = static_cast<intptr_t>(native_bits(a) << bits);
  if ((shifted >> bits) != reinterpret_cast<intptr_t>(a)) return false;
  *result = reinterpret_cast<Object*>(shifted);
  return true;
}

inline bool native_shr(Object* a, Object* b, Object** result) {
  if (!native_shift_is_small(b)) return false;
  *result = native_smi(native_smi_value(a) >> native_smi_value(b));
  return true;
}

inline bool native_ushr(Object* a, Object* b, Object** result) {
  if (!native_shift_is_small(b) || native_smi_value(a) < 0) return false;
  *result = native_smi(native_smi_value(a) >> native_smi_value(b));
  return true;
}

// Dividing by -1 can overflow, so that is left to the slow case.
inline bool native_div(Object* a, Object* b, Object** result) {
  intptr_t divisor = native_smi_value(b);
  if (divisor == 0 || divisor == -1) return false;
  *result = native_smi(native_smi_value(a) / divisor);
  return true;
}

inline bool native_mod(Object* a, Object* b, Object** result) {
  intptr_t divisor = native_smi_value(b);
  if (divisor == 0 || divisor == -1) return false;
  *result = native_smi(native_smi_value(a) % divisor);
  return true;
}

// Arrays have their length as a raw word and then the elements.
inline Object** native_array_slot(Object* array, uintptr_t n) {
  if (n >= native_bits(*native_word_address(array, 1))) return nullptr;
  return native_word_address(array, 2 + static_cast<int>(n));
}

inline Object** native_array_element(Object* array, Object* index) {
  if (!native_is_smi(index)) return nullptr;
  return native_array_slot(array, static_cast<uintptr_t>(native_smi_value(index)));
}

// Lists have their backing as the first field and their size as the second.
// The runtime doesn't trust either of them, so we can't do that here either.
// Returns false if the size isn't a smi or if the index is out of range.
inline bool native_list_index(Object* list, Object* index, uintptr_t* n) {
  Object* size = native_field(list, 1);
  if (!native_are_smis(index, size)) return false;
  *n = static_cast<uintptr_t>(native_smi_value(index));
  return *n < static_cast<uintptr_t>(native_smi_value(size));
}

// Returns null if the backing isn't a plain array, or if the index isn't a smi
// that is in range. The container is what the write barrier needs.
inline Object** native_list_element(Object* list, Object* index, Object** container) {
  uintptr_t n = 0;
  if (!native_list_index(list, index, &n)) return nullptr;
  Object* backing = native_field(list, 0);
  if (!native_has_class_tag(backing, NATIVE_ARRAY_TAG)) return nullptr;
  *container = backing;
  return native_array_slot(backing, n);
}

// Big lists have a large array as their backing. It has a vector of arraylets
// as its second field. Very large arrays have more levels, which are left to
// the runtime.
inline Object** native_large_list_element(NativeContext* c, Object* list, Object* index,
                                          Object** container) {
  uintptr_t n = 0;
  if (!native_list_index(list, index, &n)) return nullptr;
  Object* backing = native_field(list, 0);
  if (native_has_class_tag(backing, NATIVE_ARRAY_TAG)) {
    *container = backing;
    return native_array_slot(backing, n);
  }
  if (!native_is_instance(backing) ||
      static_cast<int>(native_heap_class_id(backing)) != c->large_array_class_id) {
    return nullptr;
  }
  Object* vector = native_field(backing, 1);
  if (!native_has_class_tag(vector, NATIVE_ARRAY_TAG)) return nullptr;
  Object** slot = native_array_slot(vector, n / NATIVE_ARRAYLET_SIZE);
  if (slot == nullptr) return nullptr;
  Object* arraylet = *slot;
  if (!native_has_class_tag(arraylet, NATIVE_ARRAY_TAG)) return nullptr;
  *container = arraylet;
  return native_array_slot(arraylet, n % NATIVE_ARRAYLET_SIZE);
}

inline void native_store_element(NativeContext* c, Object* container, Object** element,
                                 Object* value) {
  uintptr_t card = native_bits(container) >> NATIVE_CARD_SIZE_LOG_2;
  *reinterpret_cast<uint8_t*>(card + c->remembered_set_bias) = NATIVE_NEW_SPACE_POINTERS;
  *element = value;
}

inline bool native_array_at(NativeContext* /*c*/, Object* array, Object* index, Object** result) {
  Object** element = native_array_element(array, index);
  if (element == nullptr) return false;
  *result = *element;
  return true;
}

inline bool native_array_at_put(NativeContext* c, Object* array, Object* index, Object* value) {
  Object** element = native_array_element(array, index);
  if (element == nullptr) return false;
  native_store_element(c, array, element, value);
  return true;
}

inline bool native_list_at(NativeContext* /*c*/, Object* list, Object* index, Object** result) {
  Object* container = nullptr;
  Object** element = native_list_element(list, index, &container);
  if (element == nullptr) return false;
  *result = *element;
  return true;
}

inline bool native_large_list_at(NativeContext* c, Object* list, Object* index, Object** result) {
  Object* container = nullptr;
  Object** element = native_large_list_element(c, list, index, &container);
  if (element == nullptr) return false;
  *result = *element;
  return true;
}

inline bool native_list_at_put(NativeContext* c, Object* list, Object* index, Object* value) {
  Object* container = nullptr;
  Object** element = native_list_element(list, index, &container);
  if (element == nullptr) return false;
  native_store_element(c, container, element, value);
  return true;
}

inline bool native_large_list_at_put(NativeContext* c, Object* list, Object* index, Object* value) {
  Object* container = nullptr;
  Object** element = native_large_list_element(c, list, index, &container);
  if (element == nullptr) return false;
  native_store_element(c, container, element, value);
  return true;
}

// Byte arrays have their length as a raw word, which is
// negative if the bytes are somewhere else. Those are left to the runtime.
inline uint8_t* native_byte_element(Object* bytes, Object* index) {
  if (!native_is_smi(index)) return nullptr;
  intptr_t length = reinterpret_cast<intptr_t>(*native_word_address(bytes, 1));
  if (length < 0) return nullptr;
  uintptr_t n = static_cast<uintptr_t>(native_smi_value(index));
  if (n >= static_cast<uintptr_t>(length)) return nullptr;
  return reinterpret_cast<uint8_t*>(native_word_address(bytes, 2)) + n;
}

inline bool native_byte_array_at(NativeContext* /*c*/, Object* bytes, Object* index, Object** result) {
  uint8_t* element = native_byte_element(bytes, index);
  if (element == nullptr) return false;
  *result = native_smi(*element);
  return true;
}

inline bool native_byte_array_at_put(Object* bytes, Object* index, Object* value, Object** result) {
  if (!native_is_smi(value)) return false;
  uint8_t* element = native_byte_element(bytes, index);
  if (element == nullptr) return false;
  uint8_t byte = static_cast<uint8_t>(native_smi_value(value));
  *element = byte;
  *result = native_smi(byte);
  return true;
}

// Reading an integer doesn't involve any calls. Calls are expensive in native
// code, even if they are rarely made, because the compiler saves the return
// address on the hot paths of the functions that make them.
inline int64_t native_int_value(Object* object) {
  if (native_is_smi(object)) return native_smi_value(object);
  int64_t value = 0;
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

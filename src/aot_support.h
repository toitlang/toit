#pragma once

#include "objects.h"
#include "objects_inline.h"
#include "process.h"

using namespace toit;

#define PUSH(o)            ({ Object* _o_ = o; *(--sp) = _o_; })
#define POP()              (*(sp++))
#define DROP1()            (sp++)
#define DROP(n)            ({ int _n_ = n; sp += _n_; })
#define STACK_AT(n)        ({ int _n_ = n; (*(sp + _n_)); })
#define STACK_AT_PUT(n, o) ({ int _n_ = n; Object* _o_ = o; *(sp + _n_) = _o_; })

#undef BOOL
#define BOOL(x)            ((x) ? true_object : false_object)
#define IS_TRUE_VALUE(x)   ((x != false_object) && (x != null_object))

struct Wonk {
  Process* process;
  ObjectHeap* heap;
  Object** globals;
  Object** literals;
  Object** base;
  Object** limit;
};

#define RUN_PARAMS       \
    Object** sp,         \
    Wonk* wonk,          \
    void* extra,         \
    void* x2,            \
    Object* __restrict__  null_object, \
    Object* __restrict__ true_object,  \
    Object* __restrict__ false_object

#define RUN_ARGS_XX(x, x2)       \
    sp,                          \
    wonk,                        \
    reinterpret_cast<void*>(x),  \
    reinterpret_cast<void*>(x2), \
    null_object,                 \
    true_object,                 \
    false_object

#define RUN_ARGS_X(x) RUN_ARGS_XX(x, x2)
#define RUN_ARGS      RUN_ARGS_X(extra)

typedef void (*run_func)(RUN_PARAMS);

#if __has_attribute(musttail)
#define TAILCALL __attribute__((musttail))
#else
#define TAILCALL
#endif

#define LIKELY(x) __builtin_expect((x), 1)
#define UNLIKELY(x) __builtin_expect((x), 0)
#define SLOWCASE __attribute__((cold, preserve_most))

static INLINE bool are_smis(Object* a, Object* b) {
  uword bits = reinterpret_cast<uword>(a) | reinterpret_cast<uword>(b);
  bool result = is_smi(reinterpret_cast<Object*>(bits));
  // The or-trick only works if smis are tagged with a zero-bit.
  // The following ASSERT makes sure we catch any change to this scheme.
  ASSERT(!result || (is_smi(a) && is_smi(b)));
  return result;
}

#define AOT_RELATIONAL(mnemonic, op)                                      \
static INLINE bool aot_##mnemonic(Object* a, Object* b, bool* result) {   \
  if (!are_smis(a, b)) return false;                                      \
  *result = reinterpret_cast<word>(a) op reinterpret_cast<word>(b);       \
  return true;                                                            \
}                                                                         \
static INLINE bool aot_##mnemonic(Smi* a, Object* b, bool* result) {      \
  if (!is_smi(b)) return false;                                           \
  *result = reinterpret_cast<word>(a) op reinterpret_cast<word>(b);       \
  return true;                                                            \
}                                                                         \
static INLINE bool aot_##mnemonic(Object* a, Smi* b, bool* result) {      \
  if (!is_smi(a)) return false;                                           \
  *result = reinterpret_cast<word>(a) op reinterpret_cast<word>(b);       \
  return true;                                                            \
}                                                                         \
static INLINE bool aot_##mnemonic(Smi* a, Smi* b, bool* result) {         \
  *result = reinterpret_cast<word>(a) op reinterpret_cast<word>(b);       \
  return true;                                                            \
}                                                                         \
bool aot_##mnemonic(Object* a, Object* b) SLOWCASE;                       \
void aot_##mnemonic(RUN_PARAMS);

AOT_RELATIONAL(lt,  < )
AOT_RELATIONAL(lte, <=)
AOT_RELATIONAL(gt,  > )
AOT_RELATIONAL(gte, >=)
#undef AOT_RELATIONAL

#ifdef BUILD_32

#define AOT_SMI_ADD(a, b, result) \
  !__builtin_sadd_overflow((word) a, (word) b, (word*) result)
#define AOT_SMI_SUB(a, b, result) \
  !__builtin_ssub_overflow((word) a, (word) b, (word*) result)

#elif BUILD_64

#define AOT_SMI_ADD(a, b, result) \
  !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result)
#define AOT_SMI_SUB(a, b, result) \
  !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result)

#endif

#define AOT_ARITHMETIC(mnemonic, builtin)                                  \
static INLINE bool aot_##mnemonic(Object* a, Object* b, Object** result) { \
  return are_smis(a, b) && builtin(a, b, result);                          \
}                                                                          \
static INLINE bool aot_##mnemonic(Smi* a, Object* b, Object** result) {    \
  return is_smi(b) && builtin(a, b, result);                               \
}                                                                          \
static INLINE bool aot_##mnemonic(Object* a, Smi* b, Object** result) {    \
  return is_smi(a) && builtin(a, b, result);                               \
}                                                                          \
static INLINE bool aot_##mnemonic(Smi* a, Smi* b, Object** result) {       \
  return builtin(a, b, result);                                            \
}                                                                          \
Object** aot_##mnemonic(Object** sp, Wonk* wonk) SLOWCASE;                 \
void aot_##mnemonic(RUN_PARAMS);

AOT_ARITHMETIC(add, AOT_SMI_ADD)
AOT_ARITHMETIC(sub, AOT_SMI_SUB)
#undef AOT_ARITHMETIC

static INLINE Object* convert_to_block(Object** sp, Object** base) {
  return reinterpret_cast<Object*>(reinterpret_cast<word>(sp) - reinterpret_cast<word>(base));
}

static INLINE Object** convert_from_block(Object* value, Object** base) {
  return reinterpret_cast<Object**>(reinterpret_cast<word>(base) + reinterpret_cast<word>(value));
}

void allocate(RUN_PARAMS);
void invoke_primitive(RUN_PARAMS);

void load_global(RUN_PARAMS);

void store_field(RUN_PARAMS);
void store_field_pop(RUN_PARAMS);
void store_global(RUN_PARAMS);

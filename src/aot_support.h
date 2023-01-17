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

#define RUN_PARAMS       \
    Object** sp,         \
    void* extra,         \
    void* x2,            \
    Process* process,    \
    Object* null_object, \
    Object* true_object, \
    Object* false_object


#define RUN_ARGS_XX(x, x2)       \
    sp,                          \
    reinterpret_cast<void*>(x),  \
    reinterpret_cast<void*>(x2), \
    process,                     \
    null_object,                 \
    true_object,                 \
    false_object

#define RUN_ARGS_X(x) RUN_ARGS_XX(x, x2)
#define RUN_ARGS RUN_ARGS_X(extra)

typedef void (*run_func)(RUN_PARAMS);

#if __has_attribute(musttail)
#define TAILCALL __attribute__((musttail))
#else
#define TAILCALL
#endif

#define LIKELY(x) __builtin_expect((x), 1)
#define UNLIKELY(x) __builtin_expect((x), 0)

static INLINE bool are_smis(Object* a, Object* b) {
  uword bits = reinterpret_cast<uword>(a) | reinterpret_cast<uword>(b);
  bool result = is_smi(reinterpret_cast<Object*>(bits));
  // The or-trick only works if smis are tagged with a zero-bit.
  // The following ASSERT makes sure we catch any change to this scheme.
  ASSERT(!result || (is_smi(a) && is_smi(b)));
  return result;
}

void sub_int_int(RUN_PARAMS);
void lte_int_int(RUN_PARAMS);

bool aot_lt(Object* a, Object* b) __attribute__((preserve_most));
void aot_lt(RUN_PARAMS);

Object** aot_add(Object** sp) __attribute__((preserve_most));
void aot_add(RUN_PARAMS);

void allocate(RUN_PARAMS);
void invoke_primitive(RUN_PARAMS);

void load_global(RUN_PARAMS);

void store_field(RUN_PARAMS);
void store_field_pop(RUN_PARAMS);
void store_global(RUN_PARAMS);

static INLINE bool aot_add(Object* a, Object* b, Object** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool aot_add(Smi* a, Object* b, Object** result) {
  return is_smi(b) &&
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool aot_add(Object* a, Smi* b, Object** result) {
  return is_smi(a) &&
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool aot_add(Smi* a, Smi* b, Object** result) {
  return
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool sub_smis(Object* a, Object* b, Object** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool sub_smis(Object* a, Smi* b, Object** result) {
  return is_smi(a) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static INLINE bool aot_lt(Object* a, Object* b, bool* result) {
  if (!are_smis(a, b)) return false;
  *result = reinterpret_cast<word>(a) < reinterpret_cast<word>(b);
  return true;
}

static INLINE bool aot_lt(Smi* a, Object* b, bool* result) {
  if (!is_smi(b)) return false;
  *result = reinterpret_cast<word>(a) < reinterpret_cast<word>(b);
  return true;
}

static INLINE bool aot_lt(Object* a, Smi* b, bool* result) {
  if (!is_smi(a)) return false;
  *result = reinterpret_cast<word>(a) < reinterpret_cast<word>(b);
  return true;
}

static INLINE bool aot_lt(Smi* a, Smi* b, bool* result) {
  *result = reinterpret_cast<word>(a) < reinterpret_cast<word>(b);
  return true;
}

static INLINE bool lte_smis(Object* a, Object* b, bool* result) {
  if (!are_smis(a, b)) return false;
  *result = a <= b;
  return true;
}

static INLINE bool lte_smis(Object* a, Smi* b, bool* result) {
  if (!is_smi(a)) return false;
  *result = a <= b;
  return true;
}

#pragma once

#include "objects.h"
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

static inline bool are_smis(Object* a, Object* b) {
  uword bits = reinterpret_cast<uword>(a) | reinterpret_cast<uword>(b);
  bool result = is_smi(reinterpret_cast<Object*>(bits));
  // The or-trick only works if smis are tagged with a zero-bit.
  // The following ASSERT makes sure we catch any change to this scheme.
  ASSERT(!result || (is_smi(a) && is_smi(b)));
  return result;
}

Object** add_int_int(Object** sp);
Object** sub_int_int(Object** sp);
Object** sub_int_smi(Object** sp);

static inline bool add_smis(Object* a, Object* b, Object** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_sadd_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_sadd,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static inline bool add_smis(Object* a, Smi* b, Object** result) {
  return is_smi(a) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static inline bool sub_smis(Object* a, Object* b, Object** result) {
  return are_smis(a, b) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

static inline bool sub_smis(Object* a, Smi* b, Object** result) {
  return is_smi(a) &&
#ifdef BUILD_32
    !__builtin_ssub_overflow((word) a, (word) b, (word*) result);
#elif BUILD_64
    !LP64(__builtin_ssub,_overflow)((word) a, (word) b, (word*) result);
#endif
}

bool lte_ints_slow(Object* a, Object* b);

static inline bool lte_ints(Object* a, Object* b) {
  return are_smis(a, b)
      ? Smi::cast(a)->value() <= Smi::cast(b)->value()
      : lte_ints_slow(a, b);
}

static inline bool lte_ints(Object* a, Smi* b) {
  return is_smi(a)
      ? Smi::cast(a)->value() <= b->value()
      : lte_ints_slow(a, b);
}

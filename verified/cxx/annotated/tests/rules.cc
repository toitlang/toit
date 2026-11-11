// Copyright (C) 2026 Toit contributors.
//
// The translator's self-test (verified/tools/cxx_render.toit): one small
// function per rendering rule added after the first pilot, rendered by
// rules.render; run.sh checks the rendering against the committed
// rules.gen.c (render.sh --check), its constants, and verifies it.

#include "top.h"

namespace toit {

// Rule: a nested class A::B is the C struct A_B; its constructor is
// A_B_ctor; an unqualified constant of the enclosing class is A_N.
class Outer {
 public:
  static const word K = 3;
  class Inner {
   public:
    explicit Inner(word x) : v_(x + K) {}
    word v() { return v_; }

   private:
    word v_;
  };
};

// Rule: `a = C(x)` with the implicit assignment operator is a temporary
// constructed in place and a member-wise copy.
class Pair {
 public:
  Pair(word x, word y) : a_(x), b_(y) {}
  word a_;
  word b_;
};

inline void assign_pair(Pair* p, word x) {
  *p = Pair(x, x + 1);
}

// Rule: @expand-typedef: `uhalf_word` is unsigned int (LP64) or unsigned
// short (ILP32).
inline uhalf_word low_half(uhalf_word h) {
  return h;
}

// Rule: a default argument is written out (literals only).
inline word with_default(word x, bool flag = false) {
  return flag ? x : x + 1;
}

inline word call_default(word x) {
  return with_default(x);
}

// Rule: an overloaded member is named by its declared parameter types,
// also at a call that refers to its out-of-line definition.
class Over {
 public:
  word f(word x);
  word f(Pair* p) { return p->a_; }
  char unused_;
};

inline word Over::f(word x) {
  return x;
}

inline word call_over(Over* o) {
  return o->f(1);
}

inline word use_inner(word x) {
  Outer::Inner inner(x);
  return inner.v();
}

}  // namespace toit

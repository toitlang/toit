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

// Rule: `@render ... truncating`: a word-to-int conversion is the modular
// one (the round trip is checked, as ARGS does for int arguments).
inline int narrow(word x) {
  int n = x;
  if (n != x) return -1;
  return n;
}

// Rule: `@render ... truncating`: a uword-to-word conversion is the
// modular one too (the decoder's cardinals: the sign is checked).
inline word signed_length(uword u) {
  word length = u;
  if (length < 0) return -1;
  return length;
}

// Rule: a switch is rendered as written (labels, a label's statement and
// the statements after it, fall-through, default).
inline word classify(int tag) {
  switch (tag) {
    case 1:
    case 2:
      return 10;
    case 3: {
      word x = 7;
      return x;
    }
    default:
      break;
  }
  return 0;
}

inline word use_inner(word x) {
  Outer::Inner inner(x);
  return inner.v();
}

// Rule: `a op= b` computed in another type than a's is
// `a = (A)((C)a op b)` (here an unsigned sum for a word; sizeof's type is
// Clang's `__size_t`, written `size_t`).
inline word advance(word cursor) {
  cursor += sizeof(uint32);
  return cursor;
}

// Rule: `@modular-arguments C::C`: the integral conversion of a
// constructor argument to an unsigned parameter is the modular one.
class Tagged {
 public:
  explicit Tagged(uword tag) : tag_(tag) {}
  uword tag_;
};

inline uword negative_tag(word offset) {
  Tagged t(-100 + offset);
  return t.tag_;
}

// Rule: `do S while (false)` (the wrapper of a macro's statements) is S as
// a block.
#define CLAMP_TO_ZERO(x) do { if ((x) < 0) (x) = 0; } while (false)

inline word clamp(word x) {
  CLAMP_TO_ZERO(x);
  return x;
}

// Rule: `@render ... truncating`: an explicit static_cast narrowing a
// signed integer (here to a typedef: Clang's NoOp over an IntegralCast) is
// the modular conversion too (the round trip is checked).
typedef short narrow_t;
inline bool fits_narrow(int x) {
  narrow_t n = static_cast<narrow_t>(x);
  return static_cast<int>(n) == x;
}

// Rule: an object of a struct spelled with its tag (a C header's struct)
// is constructed by `tag_ctor`.
struct plain_c { int a; };

inline int use_plain() {
  struct plain_c p;
  p.a = 1;
  return p.a;
}

}  // namespace toit

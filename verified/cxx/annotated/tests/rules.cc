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

// Rule: `@render ... truncating`: a uword-to-int conversion is the modular
// one too (an id read as a cardinal).
inline int narrow_unsigned(uword u) {
  int n = u;
  if (n < 0) return -1;
  return n;
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

// Rules (wave 5, the message decoder's constructors): a default member
// initializer is written out from its value (literals, null, enumerators
// of the constant table); a delegating constructor calls the target
// constructor on `self`.
enum RuleMode { RULE_MODE_A, RULE_MODE_B };

class Defaults {
 public:
  explicit Defaults(word x) : Defaults(x, RULE_MODE_B) {}
  Defaults(word x, RuleMode mode) : x_(x), mode_(mode) {}

  word x_;
  RuleMode mode_ = RULE_MODE_A;
  word count_ = 7;
  bool flag_ = false;
  Defaults* next_ = null;
};

inline word use_defaults(word x) {
  Defaults d(x);
  return d.x_ + d.count_;
}

// Rule: an out-of-line constructor `C::C` (found although it is named like
// its class).
class Later {
 public:
  explicit Later(word x);
  word x_;
};

inline Later::Later(word x) : x_(x) {}

// Rule: the invariant of a loop whose body has no braces is the annotation
// anchored at the body's first token.
inline word count_up(word n) {
  word total = 0;
  for (word i = 0; i < n; i++) total++;
  return total;
}

// The closure rules (wave 6, the allocation entry points of
// interpreter_v2.cc): a lambda is a struct of its captures and a function
// of it; a function template instance taking it is one C function per
// instance, named after the lambda, which calls the lambda's function.
template <typename F>
static word retry_once(word n, F produce) {
  word result = produce();
  if (result < 0) result = produce();
  return result + n;
}

// Rules (wave 8): with unsigned-word-conversion an int converted to
// unsigned is modulo 2^32 (a literal stays a literal); with truncating a
// uint64 `<<=` by a literal is the modular shift.
inline bool small_unsigned(int x) {
  unsigned u = x;
  return u <= 8;
}

inline uint64 shift_in(uint64 v) {
  v <<= 8;
  return v;
}

inline word use_lambdas(word a, word b) {
  word base = a;
  word first = retry_once(1, [&]() -> word { return base + b; });
  base = first;
  return retry_once(2, [&]() -> word { return base; });
}

}  // namespace toit

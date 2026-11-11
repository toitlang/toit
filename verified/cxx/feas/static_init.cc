// Copyright (C) 2026 Toit contributors.
//
// Reproducer attempt for ESBMC 8.6 defect T1 (pilot write-up, "Tool
// findings"): a static data member whose in-class constant initializer uses
// a namespace-scope constant (Smi::MAX_SMI_VALUE in src/objects.h, through
// top.h's WORD_BIT_SIZE) is initialized before that constant. In C++ both
// are constant-initialized: no order, no UB.
//
// Run: esbmc static_init.cc --std c++11 --multi-property [-DVARIANT=n]

class Smi;  // top.h forward-declares the object classes before its constants.

static const int WORD_SIZE = sizeof(long);
static const int WORD_BIT_SIZE = WORD_SIZE * 8;

template <typename T> static T max(const T& a, const T& b) { return a > b ? a : b; }

class Object {
 public:
  static const int SMI_TAG_SIZE = 1;
};

class Smi : public Object {
 public:
  static const long MAX_SMI_VALUE = (((long)1) << (WORD_BIT_SIZE - (SMI_TAG_SIZE + 1))) - 1;
};

#if VARIANT >= 1
// ODR-uses of the constants through references (Utils::max in the VM).
inline long use() { return max(Smi::MAX_SMI_VALUE, static_cast<long>(WORD_BIT_SIZE)); }
#endif

#if VARIANT >= 2
#include <utility>
struct Space {
  int* a;
  long b;
  void swap(Space& other) {
    using std::swap;
    swap(a, other.a);
    swap(b, other.b);
  }
};
#endif

int main() {
  __ESBMC_assert(Smi::MAX_SMI_VALUE == 0x3fffffffffffffffL, "MAX_SMI_VALUE is 2^62 - 1");
  return 0;
}

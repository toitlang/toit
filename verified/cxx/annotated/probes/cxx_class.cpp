// Copyright (C) 2026 Toit contributors.
// Probe: VeriFast's C++ front end on the shape of objects.h: an empty class
// whose `this` is a tagged pointer, inline members that cast `this` to an
// integer and back, static constants, static member functions.
#include <stdint.h>

typedef long word;  // VeriFast's C++ stdint.h has no intptr_t (LP64)
typedef unsigned long uword;

class Object {
 public:
  static const uword HEAP_TAG = 1;
};

class HeapObject : public Object {
 public:
  uword* _raw_at()
  //@ requires 1 <= (uword)this;
  //@ ensures result == (uword *)((uword)this - 1);
  {
    return reinterpret_cast<uword*>(reinterpret_cast<uword>(this) - HEAP_TAG);
  }

  uword _word_at(word offset)
  //@ requires 1 <= (uword)this &*& offset == 0 &*& [?f]ulong_integer((uword *)((uword)this - 1), ?v);
  //@ ensures [f]ulong_integer((uword *)((uword)this - 1), v) &*& result == v;
  {
    return _raw_at()[offset / 8];
  }
};

// Copyright (C) 2026 Toit contributors.
// Probe: VeriFast's C++ front end with the integer/pointer conversions of
// the object model routed through two functions (the "shim" of
// verified/cxx/annotated/README.md, "In-place annotations"). Their bodies
// are not seen by VeriFast; their contracts are the trusted lemmas.
#include <stdint.h>

typedef long word;  // VeriFast's C++ stdint.h has no intptr_t (LP64)
typedef unsigned long uword;

// The two places where an integer and a pointer meet.
uword vm_ptr_to_word(const void* p);
//@ requires true;
//@ ensures result == (uintptr_t)p;
uword* vm_word_to_uword_ptr(uword w);
//@ requires true;
//@ ensures result == (unsigned long *)w;

class Object {
 public:
  static constexpr uword HEAP_TAG = 1;
};

class HeapObject : public Object {
 public:
  uword* _raw_at() const
  //@ requires 1 <= (uintptr_t)this &*& [_]HeapObject_bases_constructed(this);
  //@ ensures result == (unsigned long *)((uintptr_t)this - 1);
  {
    return vm_word_to_uword_ptr(vm_ptr_to_word(this) - HEAP_TAG);
  }

  uword _word_at(word offset) const
  //@ requires 1 <= (uintptr_t)this &*& [_]HeapObject_bases_constructed(this) &*& offset == 8 &*& [?f]ulong_integer((unsigned long *)((uintptr_t)this - 1) + 1, ?v);
  //@ ensures [f]ulong_integer((unsigned long *)((uintptr_t)this - 1) + 1, v) &*& result == v;
  {
    return _raw_at()[offset / 8];
  }
};

bool is_smi(const Object* o)
//@ requires true;
//@ ensures true;
{
  return (vm_ptr_to_word(o) & 1) == 0;
}

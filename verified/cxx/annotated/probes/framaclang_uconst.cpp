// Copyright (C) 2026 Toit contributors.
// Probe: frama-clang on a class constant that does not fit in int64
// (HeapObject::CLASS_ID_MASK in src/objects.h is `static const uword = -1`).
typedef unsigned long uword;

class C {
 public:
  static const uword MASK = -1;
};

/*@ assigns \nothing; */
uword probe(uword x) {
  return x & C::MASK;
}

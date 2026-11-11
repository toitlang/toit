// Copyright (C) 2026 Toit contributors.
// Probe: frama-clang on a minimal C++ class over a tagged `this`.
typedef unsigned long uword;
typedef long word;

class HeapObject {
 public:
  /*@ requires (uword)this >= 1;
      requires \valid_read((uword*)((uword)this - 1));
      assigns \nothing;
      ensures \result == *(uword*)((uword)this - 1); */
  uword header_word() const {
    return *reinterpret_cast<const uword*>(reinterpret_cast<uword>(this) - 1);
  }
};

/*@ requires (uword)o >= 1;
    requires \valid_read((uword*)((uword)o - 1));
    assigns \nothing;
    ensures \result == *(uword*)((uword)o - 1); */
uword probe(HeapObject* o) {
  return o->header_word();
}

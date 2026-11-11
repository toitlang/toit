// Copyright (C) 2026 Toit contributors.
// Probe: frama-clang + WP on a C++ copy of the HeapObject/Array accessors
// of src/objects.h (member bodies verbatim; constants inlined for 64-bit),
// with ACSL++ contracts. No heap predicates: WP has no separation logic, so
// an object is stated as a valid range at the address the code computes.
typedef unsigned long uword;
typedef long word;
static const int WORD_SIZE = 8;

class Object {
 public:
  static const uword HEAP_TAG = 0x1;
};

class HeapObject : public Object {
 public:
  static const word SIZE = WORD_SIZE;
 protected:
  const uword* _raw_at() const { return reinterpret_cast<const uword*>(reinterpret_cast<uword>(this) - HEAP_TAG); }
  Object* _at(word offset) const { return reinterpret_cast<Object* const*>(_raw_at())[offset / WORD_SIZE]; }
  uword _word_at(word offset) const { return _raw_at()[offset / WORD_SIZE]; }
};

/*@ predicate array_ok(uword o, integer len) =
      o >= 1 && o % 4 == 1 && 0 <= len < 0x100000 &&
      \valid_read((uword*)(o - 1) + (0 .. len + 1)) &&
      *((uword*)(o - 1) + 1) == len;
*/

class Array : public HeapObject {
 public:
  /*@ requires 1 <= (uword)this && (uword)this % 4 == 1;
      requires \valid_read((uword*)((uword)this - 1) + 1);
      assigns \nothing;
      ensures \result == *((uword*)((uword)this - 1) + 1); */
  word length() const { return _word_at(LENGTH_OFFSET); }

  /*@ requires 1 <= (uword)this && (uword)this % 4 == 1;
      requires \valid_read((uword*)((uword)this - 1) + (0 .. 1 + *((uword*)((uword)this - 1) + 1)));
      requires *((uword*)((uword)this - 1) + 1) < 0x100000;
      requires 0 <= index < *((uword*)((uword)this - 1) + 1);
      assigns \nothing; */
  Object* at(word index) const {
    return _at(_offset_from(index));
  }

 private:
  static const word LENGTH_OFFSET = HeapObject::SIZE;
  static const word HEADER_SIZE = LENGTH_OFFSET + WORD_SIZE;
  /*@ requires 0 <= index < 0x100000;
      assigns \nothing;
      ensures \result == 16 + index * 8; */
  static word _offset_from(word index) { return HEADER_SIZE + index * WORD_SIZE; }
};

// Copyright (C) 2026 Toit contributors.
//
// The accessors of src/objects.h, rendered in C (see objects.h for the
// correspondence), verified by VeriFast against the contracts of objects.h.
// Each body is the C++ body with the member calls spelled as functions; the
// comment above each gives the C++ line it renders.

#include "objects.h"
//@ #include "arith.gh"

/*@

lemma void good_nth(list<void *> objs, list<void *> ws, int i)
  requires forall(ws, (good)(objs)) == true &*& 0 <= i &*& i < length(ws);
  ensures good(objs, nth(i, ws)) == true;
{
  switch (ws) {
    case nil:
    case cons(w, ws0):
      if (i > 0) good_nth(objs, ws0, i - 1);
  }
}

lemma void array_body_facts(void *o)
  requires [?f]array_body(o, ?len, ?es);
  ensures [f]array_body(o, len, es) &*& 0 <= len &*& len <= MAX_OBJECT_WORDS &*& length(es) == len;
{
  open [f]array_body(o, len, es);
  close [f]array_body(o, len, es);
}

lemma void good_mem(list<void *> objs, void *w)
  requires good(objs, w) == true &*& is_smi_w((uword)w) == false;
  ensures mem(w, objs) == true;
{
}

lemma void good_heap(list<void *> objs, void *w)
  requires good(objs, w) == true &*& is_heap_w((uword)w) == true &*& 0 <= (uword)w;
  ensures mem(w, objs) == true;
{
  div_rem_nonneg((uword)w, 4);
  div_rem_nonneg_unique((uword)w, 2, 2 * ((uword)w / 4), 1);
}

lemma void foreach_remove_frac<t>(t x, list<t> xs)
  requires [?f]foreach(xs, ?p) &*& mem(x, xs) == true;
  ensures [f]foreach(remove(x, xs), p) &*& [f]p(x);
{
  open [f]foreach(xs, p);
  switch (xs) {
    case nil:
    case cons(x0, xs0):
      if (x0 != x) {
        foreach_remove_frac(x, xs0);
        close [f]foreach(remove(x, xs), p);
      }
  }
}

lemma void foreach_unremove_frac<t>(t x, list<t> xs)
  requires [?f]foreach(remove(x, xs), ?p) &*& mem(x, xs) == true &*& [f]p(x);
  ensures [f]foreach(xs, p);
{
  switch (xs) {
    case nil:
    case cons(x0, xs0):
      if (x0 == x) {
        close [f]foreach(xs, p);
      } else {
        open [f]foreach(remove(x, xs), p);
        foreach_unremove_frac(x, xs0);
        close [f]foreach(xs, p);
      }
  }
}

lemma void heap_open(void *o)
  requires [?f]heap(?objs, ?H) &*& mem(o, objs) == true;
  ensures [f]heap_rest(objs, H, o) &*& [f]header(o, o_hw(H(o))) &*&
          [f]body(o, header_tag2(o_hw(H(o))), o_len(H(o)), o_words(H(o))) &*&
          obj_facts(objs, H, o) == true &*& addr_ok(o) == true;
{
  open [f]heap(objs, H);
  foreach_remove_frac(o, objs);
  open [f]heap_obj(objs, H)(o);
  open [f]header(o, o_hw(H(o)));
  close [f]header(o, o_hw(H(o)));
  close [f]heap_rest(objs, H, o);
}

lemma void heap_close(void *o)
  requires [?f]heap_rest(?objs, ?H, o) &*& [f]header(o, o_hw(H(o))) &*&
           [f]body(o, header_tag2(o_hw(H(o))), o_len(H(o)), o_words(H(o))) &*&
           obj_facts(objs, H, o) == true &*& mem(o, objs) == true;
  ensures [f]heap(objs, H);
{
  open [f]heap_rest(objs, H, o);
  close [f]heap_obj(objs, H)(o);
  foreach_unremove_frac(o, objs);
  close [f]heap(objs, H);
}


lemma void update_take_drop<t>(list<t> ps, int i, t v)
  requires 0 <= i &*& i < length(ps);
  ensures append(take(i, ps), cons(v, drop(i + 1, ps))) == update(i, v, ps);
{
  switch (ps) {
    case nil:
    case cons(p, ps0):
      if (i > 0) update_take_drop(ps0, i - 1, v);
  }
}

// The code indexes object words from the object's start (`_raw_at()[k]`),
// the predicates hold the body as an array after the header: focus on one
// element of such an array, and back.
lemma void pointers_focus(void **base, int i)
  requires [?f]pointers(base, ?n, ?ps) &*& 0 <= i &*& i < n;
  ensures [f]pointers(base, i, take(i, ps)) &*& [f]pointer(base + i, nth(i, ps)) &*&
          [f]pointers(base + i + 1, n - i - 1, drop(i + 1, ps));
{
  pointers_split(base, i);
  open [f]pointers(base + i, n - i, drop(i, ps));
  drop_n_plus_one(i, ps);
}

lemma void pointers_unfocus(void **base, int i, list<void *> ps)
  requires [?f]pointers(base, i, take(i, ps)) &*& [f]pointer(base + i, ?v) &*&
           [f]pointers(base + i + 1, ?m, drop(i + 1, ps)) &*& 0 <= i &*& i < length(ps);
  ensures [f]pointers(base, i + 1 + m, update(i, v, ps));
{
  close [f]pointers(base + i, m + 1, cons(v, drop(i + 1, ps)));
  pointers_join(base);
  update_take_drop(ps, i, v);
}


@*/

// inline bool is_smi(const Object* o) {
//   return (reinterpret_cast<uword>(o) & Object::SMI_TAG_MASK) == Object::SMI_TAG;
// }
bool is_smi(Object *o)
//@ requires true;
//@ ensures result == is_smi_w((uword)o);
{
  //@ bitand_pow_nat((uword)o, N1);
  return ((uword)o & SMI_TAG_MASK) == SMI_TAG;
}

// inline bool is_heap_object(const Object* o) {
//   return (reinterpret_cast<uword>(o) & Object::NON_SMI_TAG_MASK) == Object::HEAP_TAG;
// }
bool is_heap_object(Object *o)
//@ requires true;
//@ ensures result == is_heap_w((uword)o);
{
  //@ bitand_pow_nat((uword)o, N2);
  return ((uword)o & NON_SMI_TAG_MASK) == HEAP_TAG;
}

// static Smi* from(word value) {
//   return reinterpret_cast<Smi*>(static_cast<uword>(value) << SMI_TAG_SIZE);
// }
Smi *Smi_from(word value)
//@ requires 0 <= value &*& value < 1024;
//@ ensures result == smi_ptr(value) &*& (uword)result == 2 * value;
{
  return (Smi *)((uword)value << SMI_TAG_SIZE);
}

// INLINE uword* _raw_at() const {
//   return reinterpret_cast<uword*>(reinterpret_cast<uword>(this) - HEAP_TAG);
// }
uword *HeapObject__raw_at(HeapObject *self)
//@ requires 1 <= (uword)self;
//@ ensures result == raw(self);
{
  return (uword *)((uword)self - HEAP_TAG);
}

// INLINE Smi* header() const { Object* result = _at(HEADER_OFFSET); return Smi::cast(result); }
// with _at(offset) = reinterpret_cast<Object* const*>(_raw_at())[offset / WORD_SIZE].
Smi *HeapObject_header(HeapObject *self)
//@ requires [?f]header(self, ?hw);
//@ ensures [f]header(self, hw) &*& (uword)result == hw &*& header_ok(hw) == true;
{
  //@ open header(self, hw);
  Object *result = ((Object **)HeapObject__raw_at(self))[HEADER_OFFSET / WORD_SIZE];
  //@ close [f]header(self, hw);
  return result;
}

// INLINE Smi* class_id() const {
//   return Smi::from((Smi::value(header()) >> HeapObject::CLASS_ID_OFFSET) & HeapObject::CLASS_ID_MASK);
// }
Smi *HeapObject_class_id(HeapObject *self)
//@ requires [?f]header(self, ?hw);
//@ ensures [f]header(self, hw) &*& result == smi_ptr(header_cid(hw)) &*& (uword)result == 2 * header_cid(hw) &*& 0 <= header_cid(hw) &*& header_cid(hw) < 1024 &*& is_smi_w((uword)result) && smi_val((uword)result) == header_cid(hw);
{
  word v = Smi_value(HeapObject_header(self));
  //@ div_rem_nonneg(hw, 2);
  //@ shiftright_div(v, N5);
  //@ div_rem_nonneg(v, 32);
  //@ div_rem_nonneg_unique(hw, 64, v / 32, 2 * (v % 32));
  //@ nat bits = sizeof(word) == 8 ? N64 : N32;
  //@ bitand_pow_nat(v >> CLASS_ID_OFFSET, bits);
  //@ assert pow_nat(2, bits) - 1 == UINTPTR_MAX;
  //@ div_rem_nonneg_unique(v >> CLASS_ID_OFFSET, pow_nat(2, bits), 0, v >> CLASS_ID_OFFSET);
  // C++: `(word >> 5) & CLASS_ID_MASK` converts the word operand to uword
  // implicitly and the result back to word for Smi::from; VeriFast's C wants
  // both conversions written. CLASS_ID_MASK is `static const uword = -1`.
  //@ div_rem_nonneg_unique(2 * (hw / 64), 2, hw / 64, 0);
  return Smi_from((word)((uword)(v >> CLASS_ID_OFFSET) & UINTPTR_MAX));
}

// INLINE bool has_class_tag(TypeTag tag) const {
//   uword header_word = reinterpret_cast<uword>(header());
//   uword tag_word = static_cast<uword>(tag);
//   int shift = HeapObject::CLASS_TAG_OFFSET + SMI_TAG_SIZE;
//   uword mask = HeapObject::CLASS_TAG_MASK << shift;
//   return (header_word & mask) == (tag_word << shift);
// }
bool HeapObject_has_class_tag(HeapObject *self, int tag)
//@ requires [?f]header(self, ?hw) &*& 0 <= tag &*& tag < 16;
//@ ensures [f]header(self, hw) &*& result == (header_tag2(hw) == 2 * tag);
{
  uword header_word = (uword)HeapObject_header(self);
  uword tag_word = (uword)tag;
  int shift = CLASS_TAG_OFFSET + SMI_TAG_SIZE;
  //@ shiftleft_def(15, N1);
  //@ shiftleft_def(tag_word, N1);
  uword mask = CLASS_TAG_MASK << shift;
  return (header_word & mask) == (tag_word << shift);
}

// Object* at(word index) const { return _at(_offset_from(index)); }
// with _offset_from(index) = HEADER_SIZE + index * WORD_SIZE.
Object *Instance_at(Instance *self, word index)
//@ requires [?f]instance_body(self, ?n, ?fields) &*& 0 <= index &*& index < n;
//@ ensures [f]instance_body(self, n, fields) &*& result == nth(index, fields) &*& length(fields) == n;
{
  //@ open instance_body(self, n, fields);
  word offset = INSTANCE_HEADER_SIZE + index * WORD_SIZE;
  //@ div_rem_nonneg_unique(offset, WORD_SIZE, 1 + index, 0);
  //@ pointers_focus((void **)raw(self) + 1, index);
  Object *result = ((Object **)HeapObject__raw_at(self))[offset / WORD_SIZE];
  //@ pointers_unfocus((void **)raw(self) + 1, index, fields);
  //@ close [f]instance_body(self, n, fields);
  return result;
}

// void at_put_no_write_barrier(word index, Object* value) { _at_put(_offset_from(index), value); }
void Instance_at_put_no_write_barrier(Instance *self, word index, Object *value)
//@ requires instance_body(self, ?n, ?fields) &*& 0 <= index &*& index < n;
//@ ensures instance_body(self, n, update(index, value, fields));
{
  //@ open instance_body(self, n, fields);
  word offset = INSTANCE_HEADER_SIZE + index * WORD_SIZE;
  //@ div_rem_nonneg_unique(offset, WORD_SIZE, 1 + index, 0);
  //@ pointers_focus((void **)raw(self) + 1, index);
  ((Object **)HeapObject__raw_at(self))[offset / WORD_SIZE] = value;
  //@ pointers_unfocus((void **)raw(self) + 1, index, fields);
  //@ close instance_body(self, n, update(index, value, fields));
}

// word length() const { return _word_at(LENGTH_OFFSET); }
// with _word_at(offset) = _raw_at()[offset / WORD_SIZE] (a uword, converted
// to word implicitly; written here).
word Array_length(Array *self)
//@ requires [?f]array_body(self, ?len, ?elems);
//@ ensures [f]array_body(self, len, elems) &*& result == len &*& 0 <= len;
{
  //@ open array_body(self, len, elems);
  uword w = HeapObject__raw_at(self)[ARRAY_LENGTH_OFFSET / WORD_SIZE];
  //@ close [f]array_body(self, len, elems);
  return (word)w;
}

// INLINE Object* at(word index) const { return _at(_offset_from(index)); }
Object *Array_at(Array *self, word index)
//@ requires [?f]array_body(self, ?len, ?elems) &*& 0 <= index &*& index < len;
//@ ensures [f]array_body(self, len, elems) &*& result == nth(index, elems) &*& length(elems) == len;
{
  //@ open array_body(self, len, elems);
  word offset = ARRAY_HEADER_SIZE + index * WORD_SIZE;
  //@ div_rem_nonneg_unique(offset, WORD_SIZE, 2 + index, 0);
  //@ pointers_focus((void **)raw(self) + 2, index);
  Object *result = ((Object **)HeapObject__raw_at(self))[offset / WORD_SIZE];
  //@ pointers_unfocus((void **)raw(self) + 2, index, elems);
  //@ close [f]array_body(self, len, elems);
  return result;
}

// word raw_length() const { return _word_at(LENGTH_OFFSET); }
word ByteArray_raw_length(ByteArray *self)
//@ requires [?f]byte_array_body(self, ?l);
//@ ensures [f]byte_array_body(self, l) &*& result == l;
{
  //@ open byte_array_body(self, l);
  word result = ((word *)HeapObject__raw_at(self))[BYTE_ARRAY_LENGTH_OFFSET / WORD_SIZE];
  //@ close [f]byte_array_body(self, l);
  return result;
}

// uint8* content() { return reinterpret_cast<uint8*>(_raw() + _offset_from(0)); }
uint8 *ByteArray_content(ByteArray *self)
//@ requires [?f]byte_array_body(self, ?l) &*& 0 <= l;
//@ ensures [f]byte_array_body(self, l) &*& result == (uint8 *)raw(self) + 2 * WORD_SIZE;
{
  //@ open byte_array_body(self, l);
  //@ close [f]byte_array_body(self, l);
  return (uint8 *)((uword)self - HEAP_TAG + (uword)BYTE_ARRAY_HEADER_SIZE);  // C++: uword + word, implicit
}

// The type tests: `return is_heap_object(o) && HeapObject::cast(o)->has_class_tag(TAG);`
// (the ghost code takes the object out of the heap for the header read).
// (VeriFast does not allow annotations inside macros, so the six are
// written out.)

bool is_instance(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, INSTANCE_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, INSTANCE_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

bool is_array(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, ARRAY_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, ARRAY_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

bool is_byte_array(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, BYTE_ARRAY_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, BYTE_ARRAY_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

bool is_double(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, DOUBLE_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, DOUBLE_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

bool is_string(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, STRING_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, STRING_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

bool is_large_integer(Object *o)
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, LARGE_INTEGER_TAG);
{
  //@ if (is_heap_w((uword)o)) { good_heap(objs, o); heap_open(o); }
  bool result = is_heap_object(o) && HeapObject_has_class_tag(o, LARGE_INTEGER_TAG);
  //@ if (is_heap_w((uword)o)) heap_close(o);
  return result;
}

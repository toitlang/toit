// Copyright (C) 2026 Toit contributors.
//
// The Toit object model for VeriFast: a C rendering of the word-level
// operations of src/objects.h (tagged words, Smi tagging, the HeapObject
// header, Instance, Array, ByteArray) and the separation-logic predicates
// that say what a VM object is. Written once; the targets (encoder,
// primitives) use only the contracts below. The bodies are in objects.c
// and are verified against these contracts there.
//
// Correspondence with src/objects.h (see CXX-ANNOTATED-PILOT.md, "The C
// rendering"): a member function `T C::f(args)` is the function `C_f(C* self,
// args)`; every C++ class is the same opaque struct (they have no data
// members; `this` is the tagged word); `reinterpret_cast<uword>(p)` is
// `(uword)p`, `reinterpret_cast<T*>(w)` is `(T*)w`; static constants are
// macros with the same values. Where VeriFast's C needs an explicit
// conversion that C++ does implicitly, the rendering says so.

#ifndef TOIT_OBJECTS_H
#define TOIT_OBJECTS_H

#include <stdint.h>
#include <stdbool.h>
//@ #include <listex.gh>
//@ #include <bitops.gh>

typedef intptr_t word;
typedef uintptr_t uword;
typedef unsigned char uint8;

struct Object;
typedef struct Object Object;
typedef struct Object HeapObject;
typedef struct Object Smi;
typedef struct Object Instance;
typedef struct Object Array;
typedef struct Object ByteArray;

// src/top.h, src/objects.h.
#define WORD_SIZE ((word)sizeof(word))
#define SMI_TAG_SIZE 1
#define SMI_TAG_MASK ((uword)1)
#define SMI_TAG ((uword)0)
#define NON_SMI_TAG_MASK ((uword)3)
#define HEAP_TAG ((uword)1)
#define HEADER_OFFSET 0
#define CLASS_TAG_OFFSET 0
#define CLASS_TAG_MASK ((uword)15)
#define CLASS_ID_OFFSET 5
#define HEAPOBJECT_SIZE (HEADER_OFFSET + WORD_SIZE)
#define ARRAY_LENGTH_OFFSET HEAPOBJECT_SIZE
#define ARRAY_HEADER_SIZE (ARRAY_LENGTH_OFFSET + WORD_SIZE)
#define INSTANCE_HEADER_SIZE HEAPOBJECT_SIZE
#define BYTE_ARRAY_LENGTH_OFFSET HEAPOBJECT_SIZE
#define BYTE_ARRAY_HEADER_SIZE (BYTE_ARRAY_LENGTH_OFFSET + WORD_SIZE)

// enum TypeTag.
#define ARRAY_TAG 0
#define STRING_TAG 1
#define INSTANCE_TAG 2
#define ODDBALL_TAG 3
#define DOUBLE_TAG 4
#define BYTE_ARRAY_TAG 5
#define LARGE_INTEGER_TAG 6
#define STACK_TAG 7
#define TASK_TAG 8

// Instance field indices (src/objects.h, class Instance).
#define LIST_ARRAY_INDEX 0
#define LIST_SIZE_INDEX 1
#define LIST_SLICE_LIST_INDEX 0
#define LIST_SLICE_FROM_INDEX 1
#define LIST_SLICE_TO_INDEX 2
#define MAP_SIZE_INDEX 0
#define MAP_SPACES_LEFT_INDEX 1
#define MAP_INDEX_INDEX 2
#define MAP_BACKING_INDEX 3

/*@

// ---------------------------------------------------------------------------
// Tagged words.

fixpoint bool is_smi_w(uword w) { return w % 2 == 0; }
fixpoint bool is_heap_w(uword w) { return w % 4 == 1; }

// The value of a smi: the word read as a signed integer, halved (exact for
// an even word, so C's truncating division and the arithmetic shift agree).
fixpoint int signed_of(uword w) { return w <= UINTPTR_MAX / 2 ? w : w - UINTPTR_MAX - 1; }
fixpoint int smi_val(uword w) { return signed_of(w) / 2; }

// The word Smi::from(v) makes, for 0 <= v (all the encoder needs: class ids).
fixpoint void *smi_ptr(int v) { return (void *)(2 * v); }

// The raw (untagged) address of a heap object, as the code computes it:
// `reinterpret_cast<uword*>(reinterpret_cast<uword>(this) - HEAP_TAG)`.
// VeriFast gives an integer-to-pointer cast the null provenance, and so do
// these definitions: object memory is addressed by integer, which is what
// the VM does (the heap is exposed memory). That this memory is the object
// is the content of the predicates below, i.e. an assumption about the
// allocator and the GC (TRUSTED.md V2).
fixpoint uword *raw(void *o) { return (uword *)((uword)o - 1); }

// ---------------------------------------------------------------------------
// Headers. A header is a smi whose value is (class_id << 5) | (finalizer
// bit << 4) | class_tag. The heap model keeps class ids in [0, 1024) (the
// 10 bits of CLASS_ID_BIT_SIZE); negative ids are the GC's free-memory
// pseudo objects, which the code under proof never sees.

fixpoint bool header_ok(uword hw) { return hw % 2 == 0 && hw < 65536; }
fixpoint int header_cid(uword hw) { return hw / 64; }
// has_class_tag compares `header_word & (CLASS_TAG_MASK << 1)` with `tag << 1`.
fixpoint int header_tag2(uword hw) { return hw & 30; }

// The program's classes (src/program.h roots and class bits). Global and
// uninterpreted: one program per proof.
fixpoint int class_tag(int cid);
fixpoint int class_fields(int cid);

inductive prog_ids = prog_ids(
    int array_cid, int list_cid, int list_slice_cid, int map_cid,
    int large_array_cid, int tombstone_cid);

// What VerifierImpl::check_builtin_classes (src/verifier.cc) establishes
// for an accepted program, and the class tags of the builtin classes.
fixpoint int array_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return a; } }
fixpoint int list_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return l; } }
fixpoint int list_slice_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return s; } }
fixpoint int map_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return m; } }
fixpoint int large_array_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return la; } }
fixpoint int tombstone_cid(prog_ids ids) { switch (ids) { case prog_ids(a, l, s, m, la, t): return t; } }

// (Written over the accessors, not with a switch, so that VeriFast unfolds
// it for a variable `ids`.)
fixpoint bool prog_ok(prog_ids ids) {
  return 0 <= array_cid(ids) && array_cid(ids) < 1024 &&
         0 <= list_cid(ids) && list_cid(ids) < 1024 &&
         0 <= list_slice_cid(ids) && list_slice_cid(ids) < 1024 &&
         0 <= map_cid(ids) && map_cid(ids) < 1024 &&
         0 <= large_array_cid(ids) && large_array_cid(ids) < 1024 &&
         0 <= tombstone_cid(ids) && tombstone_cid(ids) < 1024 &&
         class_tag(array_cid(ids)) == ARRAY_TAG &&
         class_tag(list_cid(ids)) == INSTANCE_TAG && class_fields(list_cid(ids)) >= 2 &&
         class_tag(list_slice_cid(ids)) == INSTANCE_TAG && class_fields(list_slice_cid(ids)) >= 3 &&
         class_tag(map_cid(ids)) == INSTANCE_TAG && class_fields(map_cid(ids)) >= 4;
}

// ---------------------------------------------------------------------------
// Objects. The abstract heap `H` maps each object to its ghost content:
// the header word, a length (fields of an instance, length of an array or
// a byte array) and the words of its body (fields, elements; nil for byte
// arrays). The heap is a list of distinct tagged addresses `objs`; every
// reference word in an object is a smi or one of `objs` (heap integrity,
// TRUSTED.md V2). The values of fields are otherwise arbitrary: a size field
// can be any smi, a backing field anything (the function must not trust
// them).

inductive oinfo = oinfo(uword hw, int len, list<void *> words);
fixpoint uword o_hw(oinfo i) { switch (i) { case oinfo(hw, l, ws): return hw; } }
fixpoint int o_len(oinfo i) { switch (i) { case oinfo(hw, l, ws): return l; } }
fixpoint list<void *> o_words(oinfo i) { switch (i) { case oinfo(hw, l, ws): return ws; } }

fixpoint bool good(list<void *> objs, void *w) { return is_smi_w((uword)w) || mem(w, objs); }

// The upper bound of an object's address range: objects are in pages far
// below the top of the address space (pages are at most a few hundred KB).
#define MAX_OBJECT_WORDS 0x100000

fixpoint bool addr_ok(void *o) {
  return is_heap_w((uword)o) && 1 < (uword)o &&
         (uword)o + sizeof(word) * (MAX_OBJECT_WORDS + 2) <= UINTPTR_MAX;
}

predicate header(void *o; uword hw) =
  addr_ok(o) == true &*&
  pointer((void **)raw(o), ?hp) &*& hw == (uword)hp &*& header_ok(hw) == true;

predicate instance_body(void *o, int n; list<void *> fields) =
  addr_ok(o) == true &*&
  pointers((void **)raw(o) + 1, n, fields) &*& 0 <= n &*& n <= MAX_OBJECT_WORDS &*& length(fields) == n;

predicate array_body(void *o; int len, list<void *> elems) =
  addr_ok(o) == true &*&
  uintptr(raw(o) + 1, len) &*& len <= MAX_OBJECT_WORDS &*&
  pointers((void **)raw(o) + 2, len, elems) &*& length(elems) == len;

// A byte array (internal content, or external with the length and address
// word: the bytes themselves are a separate region, see primitives).
predicate byte_array_body(void *o; int raw_length) =
  addr_ok(o) == true &*&
  intptr((intptr_t *)raw(o) + 1, raw_length) &*&
  raw_length >= 0 ?
    uchars((uint8 *)raw(o) + 2 * WORD_SIZE, raw_length, _) &*& raw_length <= WORD_SIZE * MAX_OBJECT_WORDS
  :
    uintptrs(raw(o) + 2, 2, _);

predicate body(void *o, int tag2, int len; list<void *> words) =
  tag2 == 2 * INSTANCE_TAG ? instance_body(o, len, words) :
  tag2 == 2 * ARRAY_TAG ? array_body(o, len, words) :
  tag2 == 2 * BYTE_ARRAY_TAG ? byte_array_body(o, len) &*& words == nil :
  len == 0 &*& words == nil;  // Other objects: only the header is used here.

predicate_ctor heap_obj(list<void *> objs, fixpoint(void *, oinfo) H)(void *o) =
  header(o, o_hw(H(o))) &*&
  header_tag2(o_hw(H(o))) == 2 * class_tag(header_cid(o_hw(H(o)))) &*&
  (class_tag(header_cid(o_hw(H(o)))) == INSTANCE_TAG ? o_len(H(o)) == class_fields(header_cid(o_hw(H(o)))) : true) &*&
  body(o, header_tag2(o_hw(H(o))), o_len(H(o)), o_words(H(o))) &*&
  forall(o_words(H(o)), (good)(objs)) == true;

predicate heap(list<void *> objs, fixpoint(void *, oinfo) H) =
  foreach(objs, heap_obj(objs, H));

// The facts about one object besides its memory.
fixpoint bool obj_facts(list<void *> objs, fixpoint(void *, oinfo) H, void *o) {
  return header_tag2(o_hw(H(o))) == 2 * class_tag(header_cid(o_hw(H(o)))) &&
         (class_tag(header_cid(o_hw(H(o)))) == INSTANCE_TAG ? o_len(H(o)) == class_fields(header_cid(o_hw(H(o)))) : true) &&
         forall(o_words(H(o)), (good)(objs));
}

predicate heap_rest(list<void *> objs, fixpoint(void *, oinfo) H, void *o) =
  foreach(remove(o, objs), heap_obj(objs, H));

// Lemmas about the model (proved in objects.c).

lemma void good_nth(list<void *> objs, list<void *> ws, int i);
  requires forall(ws, (good)(objs)) == true &*& 0 <= i &*& i < length(ws);
  ensures good(objs, nth(i, ws)) == true;

// Take one object out of (a fraction of) the heap, and put it back.
lemma void heap_open(void *o);
  requires [?f]heap(?objs, ?H) &*& mem(o, objs) == true;
  ensures [f]heap_rest(objs, H, o) &*& [f]header(o, o_hw(H(o))) &*&
          [f]body(o, header_tag2(o_hw(H(o))), o_len(H(o)), o_words(H(o))) &*&
          obj_facts(objs, H, o) == true &*& addr_ok(o) == true;

lemma void heap_close(void *o);
  requires [?f]heap_rest(?objs, ?H, o) &*& [f]header(o, o_hw(H(o))) &*&
           [f]body(o, header_tag2(o_hw(H(o))), o_len(H(o)), o_words(H(o))) &*&
           obj_facts(objs, H, o) == true &*& mem(o, objs) == true;
  ensures [f]heap(objs, H);

lemma void array_body_facts(void *o);
  requires [?f]array_body(o, ?len, ?es);
  ensures [f]array_body(o, len, es) &*& 0 <= len &*& len <= MAX_OBJECT_WORDS &*& length(es) == len;

// A good word that is not a smi is an object of the heap.
lemma void good_mem(list<void *> objs, void *w);
  requires good(objs, w) == true &*& is_smi_w((uword)w) == false;
  ensures mem(w, objs) == true;

// A heap-tagged word that is a good reference is an object of the heap.
lemma void good_heap(list<void *> objs, void *w);
  requires good(objs, w) == true &*& is_heap_w((uword)w) == true &*& 0 <= (uword)w;
  ensures mem(w, objs) == true;

@*/

// ---------------------------------------------------------------------------
// Accessors (src/objects.h). Contracts over one object's chunks; a caller
// that holds the heap opens the object (foreach_remove, open heap_obj) first.

bool is_smi(Object *o);
//@ requires true;
//@ ensures result == is_smi_w((uword)o);

bool is_heap_object(Object *o);
//@ requires true;
//@ ensures result == is_heap_w((uword)o);

// Smi::value. The body, `reinterpret_cast<word>(o) >> 1`, relies on two
// implementation-defined conversions (uword to word for a word above
// INTPTR_MAX, and the right shift of a negative word) that VeriFast refuses
// and GCC/Clang define (and C++20 standardizes); so this contract is
// assumed, not proved (see objects.c).
word Smi_value(Object *o);
//@ requires is_smi_w((uword)o) == true;
//@ ensures result == smi_val((uword)o) &*& -(UINTPTR_MAX / 4) - 1 <= result &*& result <= UINTPTR_MAX / 4;

// HeapObject::class_id.
Smi *HeapObject_class_id(HeapObject *self);
//@ requires [?f]header(self, ?hw);
//@ ensures [f]header(self, hw) &*& result == smi_ptr(header_cid(hw)) &*& (uword)result == 2 * header_cid(hw) &*& 0 <= header_cid(hw) &*& header_cid(hw) < 1024 &*& is_smi_w((uword)result) && smi_val((uword)result) == header_cid(hw);

// HeapObject::has_class_tag.
bool HeapObject_has_class_tag(HeapObject *self, int tag);
//@ requires [?f]header(self, ?hw) &*& 0 <= tag &*& tag < 16;
//@ ensures [f]header(self, hw) &*& result == (header_tag2(hw) == 2 * tag);

// Instance::at.
Object *Instance_at(Instance *self, word index);
//@ requires [?f]instance_body(self, ?n, ?fields) &*& 0 <= index &*& index < n;
//@ ensures [f]instance_body(self, n, fields) &*& result == nth(index, fields) &*& length(fields) == n;

// Instance::at_put_no_write_barrier.
void Instance_at_put_no_write_barrier(Instance *self, word index, Object *value);
//@ requires instance_body(self, ?n, ?fields) &*& 0 <= index &*& index < n;
//@ ensures instance_body(self, n, update(index, value, fields));

// Array::length.
word Array_length(Array *self);
//@ requires [?f]array_body(self, ?len, ?elems);
//@ ensures [f]array_body(self, len, elems) &*& result == len &*& 0 <= len;

// Array::at.
Object *Array_at(Array *self, word index);
//@ requires [?f]array_body(self, ?len, ?elems) &*& 0 <= index &*& index < len;
//@ ensures [f]array_body(self, len, elems) &*& result == nth(index, elems) &*& length(elems) == len;

// ByteArray::raw_length (private; used by ByteArray::Bytes).
word ByteArray_raw_length(ByteArray *self);
//@ requires [?f]byte_array_body(self, ?l);
//@ ensures [f]byte_array_body(self, l) &*& result == l;

// ByteArray::content (internal representation).
uint8 *ByteArray_content(ByteArray *self);
//@ requires [?f]byte_array_body(self, ?l) &*& 0 <= l;
//@ ensures [f]byte_array_body(self, l) &*& result == (uint8 *)raw(self) + 2 * WORD_SIZE;

// The type tests of src/objects.h (`is_heap_object(o) &&
// HeapObject::cast(o)->has_class_tag(TAG)`), on any good word of the heap.
/*@
fixpoint bool has_tag(fixpoint(void *, oinfo) H, void *o, int tag) {
  return is_heap_w((uword)o) && header_tag2(o_hw(H(o))) == 2 * tag;
}
@*/
bool is_instance(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, INSTANCE_TAG);
bool is_array(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, ARRAY_TAG);
bool is_byte_array(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, BYTE_ARRAY_TAG);
bool is_double(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, DOUBLE_TAG);
bool is_string(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, STRING_TAG);
bool is_large_integer(Object *o);
//@ requires [?f]heap(?objs, ?H) &*& good(objs, o) == true;
//@ ensures [f]heap(objs, H) &*& result == has_tag(H, o, LARGE_INTEGER_TAG);

#endif

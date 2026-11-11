// Copyright (C) 2026 Toit contributors.
//
// PRIMITIVE(string_write_to_byte_array) of src/primitive_core.cc, end to
// end with its ARGS decoding (the macros of src/primitive.h, with the
// member calls written as functions), rendered in C, with VeriFast
// annotations.
//
// Model of blob memory: the bytes of strings and byte arrays live in
// regions (internal content, external memory); several objects may share
// one (a slice and its byte array, a byte array and itself). The heap's
// regions are `regions(rs)`, one `uchars` chunk per region. byte_content
// and mutable_byte_content (src/objects_runtime.cc) are trusted: they
// return a range inside one region of the heap (mutable_byte_content may
// add a region, for a copy-on-write byte array made mutable).
//
// Property: memory safety (the copy stays inside the destination region
// and reads inside the source region), no overflow, and memmove semantics
// when source and destination are the same region.
//
// With -DAF4BA7AB_REVERTED the copy is a memcpy again (VeriFast's own
// contract for memcpy, from its string.h: disjoint source and destination).

#include <stdint.h>
#include <stdbool.h>
//@ #include <listex.gh>

typedef intptr_t word;
typedef uintptr_t uword;
typedef unsigned char uint8;
struct Object;
typedef struct Object Object;
typedef struct Object Error;
struct Process;
typedef struct Process Process;
struct Program;
typedef struct Program Program;

#define SMI_TAG_MASK ((uword)1)
#define SMI_TAG ((uword)0)
#define ERROR_SHIFT 2
#define ERROR_TAG ((uword)3)
// Program::*_INDEX (src/program.h ERROR_STRING list): only their being
// small matters here.
#define WRONG_OBJECT_TYPE_INDEX 1
#define WRONG_BYTES_TYPE_INDEX 2
#define OUT_OF_BOUNDS_INDEX 3
#define STRINGS_OR_BYTE_ARRAYS 0

// ---------------------------------------------------------------------------
// Smis (as in ../model/objects.h).

/*@
fixpoint int signed_of(uword w) { return w <= UINTPTR_MAX / 2 ? w : w - UINTPTR_MAX - 1; }
fixpoint int smi_val(uword w) { return signed_of(w) / 2; }
@*/

bool is_smi(Object *o);
//@ requires true;
//@ ensures result == ((uword)o % 2 == 0);

word Smi_value(Object *o);
//@ requires (uword)o % 2 == 0;
//@ ensures result == smi_val((uword)o) &*& -(UINTPTR_MAX / 4) - 1 <= result &*& result <= UINTPTR_MAX / 4;

// ---------------------------------------------------------------------------
// Blob memory.

/*@
inductive region = region(uint8 *base, int len);
fixpoint uint8 *r_base(region r) { switch (r) { case region(b, l): return b; } }
fixpoint int r_len(region r) { switch (r) { case region(b, l): return l; } }

predicate region_bytes(region r) = uchars(r_base(r), r_len(r), _);
predicate regions(list<region> rs) = foreach(rs, region_bytes) &*& distinct(rs) == true;

fixpoint bool in_region(region r, uint8 *a, int l) {
  return 0 <= l && r_base(r) <= a && a + l <= r_base(r) + r_len(r) &&
         a == r_base(r) + ((uword)a - (uword)r_base(r));  // same provenance as the region
}

// The range [a, a + l) lies in region r of rs.
predicate blob_in(list<region> rs, uint8 *a, int l, region r) =
  mem(r, rs) == true &*& in_region(r, a, l) == true;
@*/

// class Blob { const uint8* address_; word length_; }; class MutableBlob likewise.
struct Blob { uint8 *address_; word length_; };
struct MutableBlob { uint8 *address_; word length_; };

Program *Process_program(Process *process);
//@ requires true;
//@ ensures true;

// bool Object::byte_content(Program* program, Blob* blob, BlobKind strings_only) const;
bool Object_byte_content(Object *self, Program *program, struct Blob *blob, int kind);
//@ requires blob->address_ |-> _ &*& blob->length_ |-> _ &*& [?f]regions(?rs);
/*@ ensures blob->address_ |-> ?a &*& blob->length_ |-> ?l &*& [f]regions(rs) &*&
            result ? [_]blob_in(rs, a, l, _) : true; @*/

// bool Object::mutable_byte_content(Process* process, MutableBlob* blob, Error** error);
bool Object_mutable_byte_content(Object *self, Process *process, struct MutableBlob *blob, Error **error);
//@ requires blob->address_ |-> _ &*& blob->length_ |-> _ &*& *error |-> _ &*& regions(?rs);
/*@ ensures blob->address_ |-> ?a &*& blob->length_ |-> ?l &*& *error |-> ?e &*& regions(?rs2) &*&
            forall(rs, (contains)(rs2)) == true &*&
            result ? [_]blob_in(rs2, a, l, _) : true; @*/

// ---------------------------------------------------------------------------
// memmove and memcpy.

/*@
// memmove copies within one region or between two (its C contract allows
// any overlap; VeriFast's string.h states only the adjacent overlapping
// case, so it is restated here: one region holding both ranges, or two
// separate chunks).
inductive mm_mode = mm_one(uint8 *base, int len) | mm_two;

predicate mm_pre(mm_mode m, uint8 *dst, uint8 *src, int n) =
  switch (m) {
    case mm_one(base, len):
      return uchars(base, len, ?bs) &*& base <= src &*& src + n <= base + len &*&
             base <= dst &*& dst + n <= base + len &*& 0 <= n;
    case mm_two:
      return uchars(src, n, ?cs) &*& uchars_(dst, n, _);
  };

predicate mm_post(mm_mode m, uint8 *dst, uint8 *src, int n) =
  switch (m) {
    case mm_one(base, len): return uchars(base, len, _);
    case mm_two: return uchars(src, n, ?cs) &*& uchars(dst, n, cs);
  };
@*/

void *memmove(void *dest, void *src, uword count);
//@ requires mm_pre(?m, dest, src, count);
//@ ensures mm_post(m, dest, src, count) &*& result == dest;

// From VeriFast's bin/string.h (there: chars; uchars here).
void *memcpy(void *array, void *array0, uword count);
//@ requires uchars_(array, count, _) &*& [?f]uchars(array0, count, ?cs0);
//@ ensures uchars(array, count, cs0) &*& [f]uchars(array0, count, cs0) &*& result == array;

// For the mutant only: -DAF4BA7AB_DISJOINT assumes that the two ranges do
// not overlap (a call of a function whose contract says so); the memcpy
// mutant then verifies, which shows that its failure is the overlap.
#ifdef AF4BA7AB_DISJOINT
void assume_disjoint(uint8 *d, uint8 *s, word n);
//@ requires true;
//@ ensures (uword)d + n <= (uword)s || (uword)s + n <= (uword)d;
#define ASSUME_DISJOINT(d, s, n) assume_disjoint(d, s, n)
#else
#define ASSUME_DISJOINT(d, s, n)
#endif

// ---------------------------------------------------------------------------
// src/primitive.h, verbatim but for the member calls.

#define FAIL(name) return (Object *)(((uword)(name##_INDEX) << ERROR_SHIFT) | ERROR_TAG)

#define _A_T_word(N, name)                             \
  Object* _raw_##name = __args[-(N)];                  \
  if (!is_smi(_raw_##name)) FAIL(WRONG_OBJECT_TYPE);   \
  word name = Smi_value(_raw_##name);

#define _A_T_Blob(N, name)                                                   \
  Object* _raw_##name = __args[-(N)];                                        \
  /* struct Blob name; (declared at the block start: VeriFast) */           \
  if (!Object_byte_content(_raw_##name, Process_program(process), &name, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_BYTES_TYPE);

#define _A_T_MutableBlob(N, name)                                            \
  Object* _raw_##name = __args[-(N)];                                        \
  /* MutableBlob name; (declared at the block start: VeriFast) */           \
  name.address_ = 0; name.length_ = 0;                                       \
  /* Error* _mutable_blob_error_##name; (likewise) */                       \
  if (!Object_mutable_byte_content(_raw_##name, process, &name, &_mutable_blob_error_##name)) return _mutable_blob_error_##name;

#define _A_10(t1, n1, t2, n2, t3, n3, t4, n4, t5, n5) \
  _A_T_##t1(0, n1); \
  _A_T_##t2(1, n2); \
  _A_T_##t3(2, n3); \
  _A_T_##t4(3, n4); \
  _A_T_##t5(4, n5);

#define ARGS(...) _A_10(__VA_ARGS__)

/*@
lemma void regions_take(list<region> rs, region r)
  requires regions(rs) &*& mem(r, rs) == true;
  ensures foreach(remove(r, rs), region_bytes) &*& uchars(r_base(r), r_len(r), _) &*& distinct(rs) == true;
{
  open regions(rs);
  foreach_remove(r, rs);
  open region_bytes(r);
}

lemma void regions_give(list<region> rs, region r)
  requires foreach(remove(r, rs), region_bytes) &*& uchars(r_base(r), r_len(r), _) &*& distinct(rs) == true &*& mem(r, rs) == true;
  ensures regions(rs);
{
  close region_bytes(r);
  foreach_unremove(r, rs);
  close regions(rs);
}

lemma void contains_mem(list<region> rs, list<region> rs2, region r)
  requires forall(rs, (contains)(rs2)) == true &*& mem(r, rs) == true;
  ensures mem(r, rs2) == true;
{
  forall_mem(r, rs, (contains)(rs2));
}
@*/

// PRIMITIVE(string_write_to_byte_array) {
Object *primitive_string_write_to_byte_array(Process *process, Object **__args)
/*@ requires pointer(__args, ?a0) &*& pointer(__args - 1, ?a1) &*& pointer(__args - 2, ?a2) &*&
             pointer(__args - 3, ?a3) &*& pointer(__args - 4, ?a4) &*& regions(?rs); @*/
/*@ ensures pointer(__args, a0) &*& pointer(__args - 1, a1) &*& pointer(__args - 2, a2) &*&
            pointer(__args - 3, a3) &*& pointer(__args - 4, a4) &*& regions(?rs2); @*/
{
  // The locals of _A_T_Blob and _A_T_MutableBlob whose address is taken.
  struct Blob source_bytes;
  struct MutableBlob dest;
  Error *_mutable_blob_error_dest;
  ARGS(Blob, source_bytes, MutableBlob, dest, word, from, word, to, word, dest_index);
  //@ open [_]blob_in(rs, source_bytes.address_, source_bytes.length_, ?r_src);
  //@ assert regions(?rs2);
  //@ open [_]blob_in(rs2, dest.address_, dest.length_, ?r_dst);
  //@ contains_mem(rs, rs2, r_src);
  if (to == from) return _raw_dest;
  if (from < 0 || to > source_bytes.length_ || from > to) FAIL(OUT_OF_BOUNDS);
  if (dest_index < 0 || to - from > dest.length_ - dest_index) FAIL(OUT_OF_BOUNDS);
  // The source and the destination may be the same byte array.
  //@ regions_take(rs2, r_dst);
  //@ if (r_src != r_dst) { neq_mem_remove(r_src, r_dst, rs2); foreach_remove(r_src, remove(r_dst, rs2)); open region_bytes(r_src); }
  uint8 *d = &dest.address_[dest_index];
  uint8 *s = &source_bytes.address_[from];
  /*@
  if (r_src == r_dst) {
    close mm_pre(mm_one(r_base(r_dst), r_len(r_dst)), d, s, to - from);
  } else {
    uint8 *sb = r_base(r_src);
    uint8 *db = r_base(r_dst);
    uchars_split(sb, (uword)s - (uword)sb);
    uchars_split(s, to - from);
    uchars_split(db, (uword)d - (uword)db);
    uchars_split(d, to - from);
    close mm_pre(mm_two, d, s, to - from);
  }
  @*/
#ifndef AF4BA7AB_REVERTED
  memmove(d, s, (uword)(to - from));   // C++: implicit word -> size_t
  /*@
  if (r_src == r_dst) {
    open mm_post(_, _, _, _);
    regions_give(rs2, r_dst);
  } else {
    open mm_post(_, _, _, _);
    uint8 *sb = r_base(r_src);
    uint8 *db = r_base(r_dst);
    uchars_join(s);
    uchars_join(sb);
    uchars_join(d);
    uchars_join(db);
    close region_bytes(r_src);
    foreach_unremove(r_src, remove(r_dst, rs2));
    regions_give(rs2, r_dst);
  }
  @*/
#else
  // The best a proof can do for memcpy: two separate chunks for different
  // regions (mm_two), and for one region split it when the two ranges do
  // not overlap. What is left is the overlapping case: no proof.
  ASSUME_DISJOINT(d, s, to - from);
  //@ open mm_pre(_, _, _, _);
  //@ int n = to - from;
  /*@
  if (r_src == r_dst) {
    uint8 *b = r_base(r_dst);
    if ((uword)d + n <= (uword)s) {
      uchars_split(b, (uword)d - (uword)b);
      uchars_split(d, n);
      uchars_split(d + n, (uword)s - (uword)d - n);
      uchars_split(s, n);
    } else if ((uword)s + n <= (uword)d) {
      uchars_split(b, (uword)s - (uword)b);
      uchars_split(s, n);
      uchars_split(s + n, (uword)d - (uword)s - n);
      uchars_split(d, n);
    }
  }
  @*/
  memcpy(d, s, (uword)(to - from));
  //@ assume(false);  // (only the call is of interest in the mutant)
#endif
  return _raw_dest;
}

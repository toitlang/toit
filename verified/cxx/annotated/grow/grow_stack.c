// Copyright (C) 2026 Toit contributors.
//
// toit_v2_grow_stack (src/interpreter_v2.cc) and Stack::v2_copy_to
// (src/objects_runtime.cc), rendered in C, with VeriFast annotations,
// against the leaf contract the Verus proof assumes (verified/core/src/
// step.rs, `gc_grow_stack`): on V2_OK the current task's stack has at least
// `needed` free words, and the abstract state is unchanged (the frame and
// finally records, the header fields, and the used object-stack slots by
// position from the end); otherwise the state is unchanged too.
//
// Trusted (contracts below, not bodies): the GC (preserves that abstraction,
// may move and shrink the stack), the allocator (null or a fresh stack of
// the asked length), the Stack header accessors (bit-packed words), the
// write barrier. Verified: the arithmetic of the new length, the retry loop,
// the two copies (memcpy) and their bounds.
//
// The precondition on `needed` (NEEDED_OK) is selectable: the default is
// `needed <= Stack::max_length()`; -DNEEDED_UNBOUNDED drops it (the Verus
// contract as it is: VeriFast then fails at `static_cast<word>(needed)`);
// -DNEEDED_WORD_RANGE requires only that the cast is exact (VeriFast then
// fails at the sum `(length - free) + needed`).

#include <stdint.h>
#include <stdbool.h>
//@ #include <listex.gh>
//@ #include "../model/arith.gh"

typedef intptr_t word;
typedef uintptr_t uword;
typedef unsigned char uint8;
struct Process;
typedef struct Process Process;
struct Stack;
typedef struct Stack Stack;

#define TOIT_V2_OK ((uword)0)
#define TOIT_V2_STACK_OVERFLOW ((uword)1)
#define TOIT_V2_OUT_OF_MEMORY ((uword)2)
#define WORD_SIZE ((word)sizeof(word))
// Stack::max_length() = (ObjectHeap::max_allocation_size() - HEADER_SIZE) / WORD_SIZE:
// a few thousand words (pages of 32 KB on the host, 4 KB on devices); a
// generous upper bound here.
#define STACK_MAX_BOUND 0x100000

#if defined(NEEDED_UNBOUNDED)
#define NEEDED_OK(needed) true
#elif defined(NEEDED_WORD_RANGE)
#define NEEDED_OK(needed) (needed <= UINTPTR_MAX / 2)
#else
#define NEEDED_OK(needed) (needed <= STACK_MAX_BOUND)
#endif

/*@
// A Stack object: length, top, record top, the header fields the core
// keeps (frame top, finally count, bci), and the array as bytes.
predicate stack(Stack *s; int len, int top, int rtop, int ftop, int fin, int bci, list<uint8> bs);

// The current task's stack.
predicate current_stack(Process *p; Stack *s);

// The abstraction the core relies on: same records, header fields and used
// slots (by position from the end).
fixpoint bool same_abstraction(int len, int top, int rtop, list<uint8> bs,
                               int len2, int top2, int rtop2, list<uint8> bs2) {
  return rtop2 == rtop && len2 - top2 == len - top &&
         take(rtop * sizeof(word), bs2) == take(rtop * sizeof(word), bs) &&
         drop(top2 * sizeof(word), bs2) == drop(top * sizeof(word), bs);
}

fixpoint bool stack_ok(int len, int top, int rtop, list<uint8> bs) {
  return 0 <= rtop && rtop <= top && top <= len && len <= STACK_MAX_BOUND &&
         length(bs) == len * sizeof(word);
}
@*/

word Stack_max_length();
//@ requires true;
//@ ensures 0 < result &*& result <= STACK_MAX_BOUND;

word Stack_length(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == len;
word Stack_top(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == top;
word Stack_v2_record_top(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == rtop;
word Stack_v2_frame_top(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == ft;
word Stack_v2_fin_count(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == fin;
word Stack_v2_bci(Stack *s);
//@ requires [?f]stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures [f]stack(s, len, top, rtop, ft, fin, bci, bs) &*& result == bci;

void Stack__set_top(Stack *s, word top);
//@ requires stack(s, ?len, _, ?rtop, ?ft, ?fin, ?bci, ?bs);
//@ ensures stack(s, len, top, rtop, ft, fin, bci, bs);
// v2_set_records(frame_top, fin_count, bci): the record top is
// frame_top + fin_count * V2_FIN_WORDS; taken here as the source's.
void Stack_v2_set_records(Stack *s, word ftop, word fin, word bci);
//@ requires stack(s, ?len, ?top, _, _, _, _, ?bs) &*& [_]records_of(ftop, fin, ?rtop);
//@ ensures stack(s, len, top, rtop, ftop, fin, bci, bs);
//@ predicate records_of(int ftop, int fin; int rtop);

// The array as bytes: open and close the stack predicate (the array
// address is the layout constant Stack::HEADER_SIZE after the raw address).
/*@
predicate stack_hdr(Stack *s; int len, int top, int rtop, int ftop, int fin, int bci);
fixpoint uint8 *stack_array(Stack *s);
lemma void stack_open(Stack *s);
  requires stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs);
  ensures stack_hdr(s, len, top, rtop, ft, fin, bci) &*& uchars(stack_array(s), len * sizeof(word), bs) &*&
          [_]records_of(ft, fin, rtop);
lemma void stack_close(Stack *s);
  requires stack_hdr(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci) &*& uchars(stack_array(s), len * sizeof(word), ?bs);
  ensures stack(s, len, top, rtop, ft, fin, bci, bs);
@*/

// uword* _array_address(word index) { return _raw_at(_array_offset_from(index)); }
uint8 *Stack__array_address(Stack *s, word index);
//@ requires [?f]stack_hdr(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci) &*& 0 <= index &*& index <= len;
//@ ensures [f]stack_hdr(s, len, top, rtop, ft, fin, bci) &*& result == (index == 0 ? stack_array(s) : stack_array(s) + index * sizeof(word));  // (VeriFast does not simplify p + 0 to p)
word Stack_hdr_length(Stack *s);
//@ requires [?f]stack_hdr(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci);
//@ ensures [f]stack_hdr(s, len, top, rtop, ft, fin, bci) &*& result == len;
word Stack_hdr_top(Stack *s);
//@ requires [?f]stack_hdr(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci);
//@ ensures [f]stack_hdr(s, len, top, rtop, ft, fin, bci) &*& result == top;
word Stack_hdr_v2_record_top(Stack *s);
//@ requires [?f]stack_hdr(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci);
//@ ensures [f]stack_hdr(s, len, top, rtop, ft, fin, bci) &*& result == rtop;

// From VeriFast's bin/string.h (there: chars; uchars here).
void *memcpy(void *array, void *array0, uword count);
//@ requires uchars_(array, count, _) &*& [?f]uchars(array0, count, ?cs0);
//@ ensures uchars(array, count, cs0) &*& [f]uchars(array0, count, cs0) &*& result == array;

void GcMetadata_insert_into_remembered_set(Stack *s);
//@ requires true;
//@ ensures true;

// ObjectHeap::allocate_stack: null, or a fresh stack of the asked length.
Stack *ObjectHeap_allocate_stack(Process *p, word length);
//@ requires 0 <= length &*& length <= STACK_MAX_BOUND;
//@ ensures result == 0 ? true : stack(result, length, length, 0, 0, 0, 0, ?bs) &*& length(bs) == length * sizeof(word);

void ObjectHeap_leave_primitive(Process *p);
//@ requires true;
//@ ensures true;

// v2_gc: TRUSTED, "the GC preserves the abstraction": the current task's
// stack may be another (moved) object, possibly shrunk, with the same
// records, header fields and used slots.
void v2_gc(Process *p, int attempts, word length, word new_length);
//@ requires current_stack(p, ?s) &*& stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs) &*& stack_ok(len, top, rtop, bs) == true;
/*@ ensures current_stack(p, ?s2) &*& stack(s2, ?len2, ?top2, rtop, ft, fin, bci, ?bs2) &*&
            stack_ok(len2, top2, rtop, bs2) == true &*& same_abstraction(len, top, rtop, bs, len2, top2, rtop, bs2) == true; @*/

Stack *Task_stack_of(Process *p);
//@ requires [?f]current_stack(p, ?s);
//@ ensures [f]current_stack(p, s) &*& result == s;

// process->task()->set_stack(new_stack): the old stack becomes garbage
// (given back to the heap).
void Task_set_stack(Process *p, Stack *new_stack);
//@ requires current_stack(p, ?s) &*& stack(s, _, _, _, _, _, _, _);
//@ ensures current_stack(p, new_stack);

// Utils::max, Utils::min (templates; here for word).
word Utils_max(word x, word y)
//@ requires true;
//@ ensures result == (x >= y ? x : y);
{
  return x >= y ? x : y;
}
word Utils_min(word x, word y)
//@ requires true;
//@ ensures result == (x <= y ? x : y);
{
  return x <= y ? x : y;
}

/*@
lemma void take_take_le(int i, int j, list<uint8> xs)
  requires 0 <= i &*& i <= j;
  ensures take(i, take(j, xs)) == take(i, xs);
{
  switch (xs) {
    case nil:
    case cons(x, xs0):
      if (i > 0) take_take_le(i - 1, j - 1, xs0);
  }
}

lemma void drop_append_one(list<uint8> b, list<uint8> c, int n)
  requires n == length(b);
  ensures drop(n, append(b, c)) == c;
{
  switch (b) {
    case nil:
    case cons(y, b0): drop_append_one(b0, c, n - 1);
  }
}

lemma void drop_append_bytes(list<uint8> a, list<uint8> b, list<uint8> c, int n)
  requires n == length(a) + length(b);
  ensures drop(n, append(a, append(b, c))) == c;
{
  switch (a) {
    case nil: drop_append_one(b, c, n);
    case cons(x, a0): drop_append_bytes(a0, b, c, n - 1);
  }
}

lemma void take_append_bytes(list<uint8> a, list<uint8> b, list<uint8> c, int n)
  requires n == length(a);
  ensures take(n, append(a, append(b, c))) == a;
{
  switch (a) {
    case nil:
    case cons(x, a0): take_append_bytes(a0, b, c, n - 1);
  }
}
@*/

// void Stack::v2_copy_to(Stack* other) {
void Stack_v2_copy_to(Stack *self, Stack *other)
/*@ requires stack(self, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs) &*& stack_ok(len, top, rtop, bs) == true &*&
             stack(other, ?olen, _, _, _, _, _, ?obs) &*& length(obs) == olen * sizeof(word) &*&
             olen <= STACK_MAX_BOUND &*& olen >= (len - top) + rtop; @*/
/*@ ensures stack(self, len, top, rtop, ft, fin, bci, bs) &*&
            stack(other, olen, ?otop, rtop, ft, fin, bci, ?obs2) &*& stack_ok(olen, otop, rtop, obs2) == true &*&
            same_abstraction(len, top, rtop, bs, olen, otop, rtop, obs2) == true; @*/
{
  //@ stack_open(self);
  //@ stack_open(other);
  word used = Stack_hdr_length(self) - Stack_hdr_top(self);
  // The frame and the finally records.
  word records = Stack_hdr_v2_record_top(self);
  // ASSERT(other->length() >= used + records);
  word displacement = Stack_hdr_length(other) - Stack_hdr_length(self);
  //@ int W = sizeof(word);
  //@ uint8 *sa = stack_array(self);
  //@ uint8 *oa = stack_array(other);
  //@ uchars_split(sa, top * W);
  //@ uchars_split(sa, records * W);
  //@ uchars_split(oa, (top + displacement) * W);
  //@ uchars_split(oa, records * W);
  memcpy(Stack__array_address(other, 0), Stack__array_address(self, 0), (uword)(records * WORD_SIZE));
  memcpy(Stack__array_address(other, Stack_hdr_top(self) + displacement), Stack__array_address(self, Stack_hdr_top(self)), (uword)(used * WORD_SIZE));
  //@ list<uint8> o1 = take(records * W, take(top * W, bs));
  //@ list<uint8> o3 = drop(top * W, bs);
  //@ assert uchars(oa + records * W, (top + displacement - records) * W, ?o2);
  //@ uchars_join(oa);
  //@ uchars_join(oa);
  //@ uchars_join(sa);
  //@ uchars_join(sa);
  //@ stack_close(self);
  //@ stack_close(other);
  Stack__set_top(other, displacement + Stack_top(self));
  Stack_v2_set_records(other, Stack_v2_frame_top(self), Stack_v2_fin_count(self), Stack_v2_bci(self));
  // See copy_to.
  GcMetadata_insert_into_remembered_set(other);
  //@ append_assoc(o1, o2, o3);
  //@ take_append_bytes(o1, o2, o3, records * W);
  //@ take_take_le(records * W, top * W, bs);
  //@ drop_append_bytes(o1, o2, o3, (top + displacement) * W);
}


// uword toit_v2_grow_stack(void* raw_process, uword needed) {
uword toit_v2_grow_stack(Process *process, uword needed)
/*@ requires current_stack(process, ?s) &*& stack(s, ?len, ?top, ?rtop, ?ft, ?fin, ?bci, ?bs) &*&
             stack_ok(len, top, rtop, bs) == true &*& NEEDED_OK(needed); @*/
/*@ ensures current_stack(process, ?s2) &*& stack(s2, ?len2, ?top2, rtop, ft, fin, bci, ?bs2) &*&
            stack_ok(len2, top2, rtop, bs2) == true &*&
            same_abstraction(len, top, rtop, bs, len2, top2, rtop, bs2) == true &*&
            (result == TOIT_V2_OK ? top2 - rtop >= needed :
             result == TOIT_V2_STACK_OVERFLOW || result == TOIT_V2_OUT_OF_MEMORY); @*/
{
  // Process* process = v2_process(raw_process);
  Stack *stack = Task_stack_of(process);
  GcMetadata_insert_into_remembered_set(stack);
  word length = Stack_length(stack);
  word free = Stack_top(stack) - Stack_v2_record_top(stack);
  word new_length = -1;
  if (length < Stack_max_length()) {
    //@ shiftright_1(length);
    //@ div_rem_nonneg(length, 2);
    new_length = Utils_max(length + (length >> 1), (length - free) + (word)needed);
    new_length = Utils_min(Stack_max_length(), new_length);
    if (free + (new_length - length) < (word)needed) new_length = -1;
  }
  if (new_length < 0) return TOIT_V2_STACK_OVERFLOW;
  Stack *new_stack = ObjectHeap_allocate_stack(process, new_length);
  for (int attempts = 1; new_stack == 0 && attempts < 4; attempts++)
  /*@ invariant current_stack(process, ?sc) &*& stack(sc, ?lenc, ?topc, rtop, ft, fin, bci, ?bsc) &*&
                stack_ok(lenc, topc, rtop, bsc) == true &*&
                same_abstraction(len, top, rtop, bs, lenc, topc, rtop, bsc) == true &*&
                (new_stack == 0 ? true : stack(new_stack, new_length, new_length, 0, 0, 0, 0, ?nbs) &*& length(nbs) == new_length * sizeof(word)) &*&
                1 <= attempts; @*/
  {
    v2_gc(process, attempts, length, new_length);
    new_stack = ObjectHeap_allocate_stack(process, new_length);
  }
  ObjectHeap_leave_primitive(process);
  if (new_stack == 0) return TOIT_V2_OUT_OF_MEMORY;
  // The GC may have moved or shrunk the old stack.
  stack = Task_stack_of(process);
  Stack_v2_copy_to(stack, new_stack);
  Task_set_stack(process, new_stack);
  return TOIT_V2_OK;
}

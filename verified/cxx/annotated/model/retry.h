// Copyright (C) 2026 Toit contributors.
//
// The retry protocol's terms and the facts of the loader's error roots
// (wave 8), for the renderings that need them (the boundary, the loader's
// check, the primitives that state `oom_unchanged`, the decoders). Not in
// objects.gen.h: there, these lemmas and definitions slowed down, and on
// ILP32 broke, unrelated proofs (utf16-to-8: Z3's search changes with the
// declarations in scope). The `program` predicate's conjunct and its two
// fixpoints (error_roots_ok, addr_not_in) stay in objects.gen.h; the
// lemma process_program too (its body needs the process predicate's).
// Ghost declarations only; every lemma has its body.

#ifndef TOIT_ANNOTATED_RETRY_H
#define TOIT_ANNOTATED_RETRY_H

#include "objects.gen.h"

/*@
// The error roots (Program::FIRST_ERROR_INDEX and up): heap references
// above the immediate errors, so a marked root decodes to itself
// (Primitive::unmark_from_error), at pairwise different addresses. The
// retry protocol tells an out-of-memory failure from the others by the
// root, so the loader checks this: ProcessGroup::create refuses a program
// for which Program::has_valid_error_roots is false, and its proof
// (loader/error_roots.render) shows that it returns exactly
// error_roots_ok of the root table. A process's program passed the check:
// the process predicate's body (model/objects.render) states it and
// process_program hands it out.
fixpoint bool error_root_ok(void *r) { return (uword)r % 4 == 1 && Error_MAX_TAGGED_ERROR <= (uword)r && (uword)r <= UINTPTR_MAX; }
fixpoint bool addr_not_in(void *x, list<void *> xs) {
  switch (xs) {
    case nil: return true;
    case cons(y, t): return (uword)x != (uword)y && addr_not_in(x, t);
  }
}
fixpoint bool error_roots_ok(list<void *> xs) {
  switch (xs) {
    case nil: return true;
    case cons(x, t): return error_root_ok(x) && addr_not_in(x, t) && error_roots_ok(t);
  }
}

// The program of a process is a loaded program whose error roots passed
// the loader's check (what Process::program gives, without the call; the
// body is in objects.gen.c, which includes this header).
lemma void process_program(Process *p);
  requires [?f]process(p, ?prog, ?ids);
  ensures [f]process(p, prog, ids) &*& [_]program(prog, ids) &*& error_roots_ok(drop(Program_FIRST_ERROR_INDEX, program_roots(prog))) == true;

lemma void addr_not_in_nth(void *x, list<void *> xs, int j)
  requires addr_not_in(x, xs) == true &*& 0 <= j &*& j < length(xs);
  ensures (uword)x != (uword)nth(j, xs);
{
  switch (xs) {
    case nil:
    case cons(y, t): if (j > 0) addr_not_in_nth(x, t, j - 1);
  }
}

lemma void error_roots_nth(list<void *> xs, int i, int j)
  requires error_roots_ok(xs) == true &*& 0 <= i &*& i < length(xs) &*& 0 <= j &*& j < length(xs);
  ensures error_root_ok(nth(i, xs)) == true &*& (i == j || (uword)nth(i, xs) != (uword)nth(j, xs));
{
  switch (xs) {
    case nil:
    case cons(x, t):
      if (i == 0) {
        if (j > 0) addr_not_in_nth(x, t, j - 1);
      } else if (j == 0) {
        error_roots_nth(t, i - 1, i - 1);
        addr_not_in_nth(x, t, i - 1);
      } else {
        error_roots_nth(t, i - 1, j - 1);
      }
  }
}

// Two slots of a root table whose error slots are error_roots_ok.
lemma void error_roots_at(list<void *> rs, int i, int j)
  requires error_roots_ok(drop(Program_FIRST_ERROR_INDEX, rs)) == true &*&
           Program_FIRST_ERROR_INDEX <= i &*& i < length(rs) &*& Program_FIRST_ERROR_INDEX <= j &*& j < length(rs);
  ensures error_root_ok(nth(i, rs)) == true &*& (i == j || (uword)nth(i, rs) != (uword)nth(j, rs));
{
  nth_drop(i - Program_FIRST_ERROR_INDEX, Program_FIRST_ERROR_INDEX, rs);
  nth_drop(j - Program_FIRST_ERROR_INDEX, Program_FIRST_ERROR_INDEX, rs);
  length_drop(Program_FIRST_ERROR_INDEX, rs);
  error_roots_nth(drop(Program_FIRST_ERROR_INDEX, rs), i - Program_FIRST_ERROR_INDEX, j - Program_FIRST_ERROR_INDEX);
}

// Two error roots of a loaded program: a heap reference above the
// immediate errors, and at different addresses unless they are one slot.
lemma void error_root_facts(Program *prog, int i, int j)
  requires [_]program(prog, ?ids) &*& error_roots_ok(drop(Program_FIRST_ERROR_INDEX, program_roots(prog))) == true &*&
           Program_FIRST_ERROR_INDEX <= i &*& i < Program_ROOT_COUNT &*&
           Program_FIRST_ERROR_INDEX <= j &*& j < Program_ROOT_COUNT;
  ensures error_root_ok(nth(i, program_roots(prog))) == true &*&
          (i == j || (uword)nth(i, program_roots(prog)) != (uword)nth(j, program_roots(prog)));
{
  open [_]program(prog, ids);
  error_roots_at(program_roots(prog), i, j);
}

// A marked error (Primitive::is_error), the value it stands for
// (Primitive::unmark_from_error), the roots that ask for a GC and a
// retry (v2_primitive_failed; ffi/interpreter_v2.render).
fixpoint bool is_marked(Object *raw) { return (uword)raw % 4 == 3; }
fixpoint Object *unmarked(Program *prog, Object *raw) {
  return (uword)raw < Error_MAX_TAGGED_ERROR
      ? nth((uword)raw / 4 < Program_ROOT_COUNT ? (uword)raw / 4 : Program_INVALID_ARGUMENT_INDEX, program_roots(prog))
      : (Object *)((uword)raw - 2);
}
fixpoint Object *root_malloc_failed(Program *prog) { return nth(Program_MALLOC_FAILED_INDEX, program_roots(prog)); }
fixpoint Object *root_cross_process_gc(Program *prog) { return nth(Program_CROSS_PROCESS_GC_INDEX, program_roots(prog)); }
// (VeriFast's C pointer comparison: a true `p == q` means the same address,
// a false one different pointers. In the VM, one address space, the two
// coincide for these roots; the core gets THROW for the first and FAILURE
// for the second.)
fixpoint bool oom_error(Program *prog, Object *raw) {
  return is_marked(raw) &&
         ((uword)unmarked(prog, raw) == (uword)root_malloc_failed(prog) ||
          (uword)unmarked(prog, raw) == (uword)root_allocation_failed(prog) ||
          (uword)unmarked(prog, raw) == (uword)root_cross_process_gc(prog));
}
fixpoint bool other_error(Program *prog, Object *raw) {
  return is_marked(raw) &&
         unmarked(prog, raw) != root_malloc_failed(prog) && unmarked(prog, raw) != root_allocation_failed(prog) &&
         unmarked(prog, raw) != root_cross_process_gc(prog);
}

// The retry obligation in the retry protocol's own terms, for a primitive
// that can write an existing object (a copy-on-write byte array's copy)
// before a later check fails: a result that asks for a GC and a retry
// (oom_error) leaves every object of the heap before the call unchanged.
// The other errors need no such statement (no retry follows them). Its
// proofs rest on the loader's error_roots_ok (the `program` predicate):
// an error other than the three out-of-memory ones decodes to another
// root.
fixpoint bool oom_unchanged(Program *prog, list<void *> objs, fixpoint(void *, oinfo) H,
                            list<void *> objs2, fixpoint(void *, oinfo) H2, void *result) {
  return !oom_error(prog, result) || (objs2 == objs && H2 == H) || forall(objs, (same_obj)(H, H2));
}

// An immediate error naming error root `index` (FAIL), or a marked error
// root (Error::from), other than the three out-of-memory roots: not an
// out-of-memory error.
lemma void immediate_error_not_oom(Program *prog, int index)
  requires [_]program(prog, ?ids) &*& error_roots_ok(drop(Program_FIRST_ERROR_INDEX, program_roots(prog))) == true &*&
           Program_FIRST_ERROR_INDEX <= index &*& index < Program_ROOT_COUNT &*&
           index != Program_ALLOCATION_FAILED_INDEX &*& index != Program_MALLOC_FAILED_INDEX &*&
           index != Program_CROSS_PROCESS_GC_INDEX;
  ensures oom_error(prog, (Object *)(index * 4 + 3)) == false;
{
  error_root_facts(prog, index, Program_ALLOCATION_FAILED_INDEX);
  error_root_facts(prog, index, Program_MALLOC_FAILED_INDEX);
  error_root_facts(prog, index, Program_CROSS_PROCESS_GC_INDEX);
  div_rem_nonneg_unique(index * 4 + 3, 4, index, 3);
}

lemma void marked_root_not_oom(Program *prog, int index, Object *raw)
  requires [_]program(prog, ?ids) &*& error_roots_ok(drop(Program_FIRST_ERROR_INDEX, program_roots(prog))) == true &*&
           Program_FIRST_ERROR_INDEX <= index &*& index < Program_ROOT_COUNT &*&
           index != Program_ALLOCATION_FAILED_INDEX &*& index != Program_MALLOC_FAILED_INDEX &*&
           index != Program_CROSS_PROCESS_GC_INDEX &*&
           (uword)raw == ((uword)nth(index, program_roots(prog)) | 3);
  ensures oom_error(prog, raw) == false;
{
  error_root_facts(prog, index, Program_ALLOCATION_FAILED_INDEX);
  error_root_facts(prog, index, Program_MALLOC_FAILED_INDEX);
  error_root_facts(prog, index, Program_CROSS_PROCESS_GC_INDEX);
  uword x = (uword)nth(index, program_roots(prog));
  div_rem_nonneg(x, 4);
  // x | 3 == x + 2 for x % 4 == 1 (as in HeapObject::mark).
  Z high = int_of_Z_of_uintN(x / 4, N64);
  bitor_def(x, Zdigit(Zdigit(high, false), true), 3, Zdigit(Zdigit(Zsign(false), true), true));
  switch (high) { case Zsign(b): case Zdigit(z, b): }
}
@*/

#endif

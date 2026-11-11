// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! TRUSTED: the only module that touches raw memory.
//!
//! Each view wraps memory owned by the C++ VM and exposes it to verified
//! code as a ghost sequence with small contracts. Every `external_body`
//! item is listed with its contract in `TRUSTED.md`.
//!
//! Views of process memory (`StackMem`) are invalidated by every call that
//! may garbage collect: those calls (`Runtime`) take the view by value and
//! the caller derives a new one afterwards (`Runtime::stack`), so no view
//! survives a GC point (enforced by the type system: a moved-from view
//! cannot be used). Object references read from memory are plain words;
//! that none of them is used after a GC point without being re-read from a
//! root is the GC-safety discipline (DESIGN.md).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use core::sync::atomic::{AtomicUsize, Ordering};
use crate::layout::*;
use toit_spec::types::{HeapObj, Body, Value};

/// `HALF_WORD_SIZE` (src/top.h): string lengths and hash codes are half
/// words.
#[cfg(target_pointer_width = "64")]
pub type HalfWord = u32;
#[cfg(target_pointer_width = "32")]
pub type HalfWord = u16;

verus! {

// ---------------------------------------------------------------------------
// The memory model (verified/core/TRUSTED.md section 1, "Memory model").
//
// Every view below owns permissions (`vstd::raw_ptr::PointsTo`) for the VM
// memory it touches, as tracked (erased) fields, and its ghost content is
// defined from them: the value of element `i` of a table is the value of
// the permission at index `i`. A type invariant (`#[verifier::type_invariant]`)
// ties each permission to the address the accessor computes, so that every
// read and write below is verified against vstd's pointer axioms instead
// of trusted. The permissions come from the derivation points (the
// constructors at the end of this file, `ffi::Runtime::stack` and the calls
// that may GC): there the VM's word that the memory is well formed is
// turned into the bundle. That is the trusted part.

/// The word-size modulus `2^WORD_BITS`.
pub open spec fn modulus() -> int {
    usize::MAX as int + 1
}

/// `x` modulo the word size: the result of wrapping address arithmetic.
pub open spec fn wrap(x: int) -> usize {
    (x % modulus()) as usize
}

/// The pointer to element `i` of the array of `T` at `base` (wrapping
/// address arithmetic, with the provenance of `base`).
pub open spec fn at_index<T>(base: *mut T, i: int) -> *mut T {
    ptr_mut_from_data::<T>(PtrData::<T> {
        addr: wrap(base@.addr + i * size_of::<T>()),
        provenance: base@.provenance,
        metadata: (),
    })
}

/// The array `base[0..len)` lies in the address space.
pub open spec fn array_fits<T>(base: *mut T, len: int) -> bool {
    base@.addr + len * size_of::<T>() <= usize::MAX
}

/// Permission `i` of `perms` is element `i` of the array at `base`, and is
/// initialized.
pub open spec fn elem_ok<T>(perms: Map<int, PointsTo<T>>, base: *mut T, i: int) -> bool {
    &&& perms.contains_key(i)
    &&& perms[i].ptr() == at_index(base, i)
    &&& perms[i].is_init()
}

/// The permissions `perms[0..len)` are the initialized elements of the
/// array at `base`, which lies in the address space.
pub open spec fn array_ok<T>(perms: Map<int, PointsTo<T>>, base: *mut T, len: int) -> bool {
    &&& array_fits(base, len)
    &&& forall|i: int| 0 <= i < len ==> #[trigger] elem_ok(perms, base, i)
}

/// The values of the permissions `perms[0..len)`.
pub open spec fn values<T>(perms: Map<int, PointsTo<T>>, len: int) -> Seq<T> {
    Seq::new(len as nat, |i: int| perms[i].value())
}

/// TRUSTED (Rust's semantics of wrapping pointer arithmetic,
/// `pointer::wrapping_add`): the address moves by `count` elements modulo
/// the word size; the provenance stays. Never undefined behavior (the
/// result is only dereferenced through a permission for its address).
/// Used instead of vstd's `with_addr` so that the code is exactly the
/// former trusted bodies' (`getelementptr T`, scaled addressing).
pub assume_specification<T>[<*mut T>::wrapping_add](p: *mut T, count: usize) -> (q: *mut T)
    ensures q == ptr_mut_from_data::<T>(PtrData::<T> {
        addr: wrap(p@.addr + count * size_of::<T>()), provenance: p@.provenance, metadata: () }),
    opens_invariants none
    no_unwind;

/// TRUSTED (as `wrapping_add`, `pointer::wrapping_offset`): a signed count.
pub assume_specification<T>[<*mut T>::wrapping_offset](p: *mut T, count: isize) -> (q: *mut T)
    ensures q == ptr_mut_from_data::<T>(PtrData::<T> {
        addr: wrap(p@.addr + count * size_of::<T>()), provenance: p@.provenance, metadata: () }),
    opens_invariants none
    no_unwind;

/// Wrapping address arithmetic composes: moving the element `i` of the
/// array at `base` by `k` elements gives element `i + k`.
pub proof fn lemma_at_index_move<T>(base: *mut T, i: int, k: int)
    ensures
        ptr_mut_from_data::<T>(PtrData::<T> {
            addr: wrap(at_index(base, i)@.addr + k * size_of::<T>()),
            provenance: at_index(base, i)@.provenance, metadata: () })
            == at_index(base, i + k),
{
    let m = modulus();
    let s = size_of::<T>() as int;
    let b = base@.addr as int;
    assert(at_index(base, i)@.addr as int == (b + i * s) % m);
    vstd::arithmetic::div_mod::lemma_add_mod_noop(b + i * s, k * s, m);
    vstd::arithmetic::div_mod::lemma_mod_twice(b + i * s, m);
    vstd::arithmetic::div_mod::lemma_mod_twice(k * s, m);
    vstd::arithmetic::div_mod::lemma_add_mod_noop((b + i * s) % m, k * s, m);
    assert(b + i * s + k * s == b + (i + k) * s) by (nonlinear_arith);
}

/// The address of element `i` of an array that lies in the address space
/// is exact (no wrapping).
pub proof fn lemma_at_index_exact<T>(base: *mut T, i: int, len: int)
    requires array_fits(base, len), 0 <= i <= len,
    ensures
        wrap(base@.addr + i * size_of::<T>()) == base@.addr + i * size_of::<T>(),
        base@.addr + i * size_of::<T>() <= base@.addr + len * size_of::<T>(),
{
    assert(0 <= i * size_of::<T>() <= len * size_of::<T>()) by (nonlinear_arith)
        requires 0 <= i <= len, size_of::<T>() >= 0;
    vstd::arithmetic::div_mod::lemma_small_mod((base@.addr + i * size_of::<T>()) as nat, modulus() as nat);
}

/// A read-only table of `T` (program data: immutable while the program
/// runs). Owns a permission for each element.
#[verifier::reject_recursive_types(T)]
pub struct Table<T> {
    ptr: *mut T,
    len: usize,
    perms: Tracked<Map<int, PointsTo<T>>>,
}

impl<T> Table<T> {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        array_ok(self.perms@, self.ptr, self.len as int)
    }
}

impl<T: Copy> Table<T> {
    pub closed spec fn view(&self) -> Seq<T> {
        values(self.perms@, self.len as int)
    }

    /// The identity of this view (the cursors into it carry it): its
    /// pointer.
    pub closed spec fn sid(&self) -> *mut T {
        self.ptr
    }

    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    #[inline(always)]
    pub fn at(&self, i: usize) -> (r: T)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        proof {
            use_type_invariant(self);
            assert(elem_ok(self.perms@, self.ptr, i as int));
        }
        let p = self.ptr.wrapping_add(i);
        *ptr_ref(p, Tracked(self.perms.borrow().tracked_borrow(i as int)))
    }
}

impl Table<u8> {
    /// The cursor at index `i` (wrapping address arithmetic; reading
    /// through it requires the index to lie in the table, `Ip::byte`).
    #[inline(always)]
    pub fn cursor(&self, i: usize) -> (r: Ip)
        ensures r@ == i, r.sid() == self.sid(),
    {
        Cursor { ptr: self.ptr.wrapping_add(i), base: Ghost(self.ptr), idx: Ghost(i as int) }
    }
}

/// `wrapping_sub` is subtraction modulo the word size.
pub proof fn lemma_wrapping_sub(a: usize, c: usize)
    ensures vstd::wrapping::usize_specs::wrapping_sub(a, c) as int == (a as int - c as int) % modulus(),
{
    let m = modulus();
    if (a as int) < (c as int) {
        vstd::arithmetic::div_mod::lemma_mod_multiples_vanish(1, a as int - c as int, m);
        vstd::arithmetic::div_mod::lemma_small_mod((a as int - c as int + m) as nat, m as nat);
    } else {
        vstd::arithmetic::div_mod::lemma_small_mod((a as int - c as int) as nat, m as nat);
    }
}

/// The global variables of the process (mutable words, GC roots). Owns a
/// permission for each.
pub struct Globals {
    ptr: *mut usize,
    len: usize,
    perms: Tracked<Map<int, PointsTo<usize>>>,
}

impl Globals {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        array_ok(self.perms@, self.ptr, self.len as int)
    }

    pub closed spec fn view(&self) -> Seq<usize> {
        values(self.perms@, self.len as int)
    }

    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    #[inline(always)]
    pub fn at(&self, i: usize) -> (r: usize)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        proof {
            use_type_invariant(self);
            assert(elem_ok(self.perms@, self.ptr, i as int));
            lemma_at_index_exact(self.ptr, i as int, self.len as int);
        }
        let p = self.ptr.wrapping_add(i);
        *ptr_ref(p, Tracked(self.perms.borrow().tracked_borrow(i as int)))
    }

    #[inline(always)]
    pub fn set(&mut self, i: usize, v: usize)
        requires i < old(self)@.len(),
        ensures final(self)@ == old(self)@.update(i as int, v),
    {
        proof {
            use_type_invariant(&*self);
            assert(elem_ok(self.perms@, self.ptr, i as int));
            lemma_at_index_exact(self.ptr, i as int, self.len as int);
        }
        let ghost old_view = self@;
        let p = self.ptr.wrapping_add(i);
        write_elem(Tracked(self.perms.borrow_mut()), Ghost(self.ptr), Ghost(self.len as int), Ghost(i as int), p, v);
        proof {
            assert(self@ =~= old_view.update(i as int, v));
        }
    }
}

/// Stores `v` into element `k` of the array at `base` through `p` (its
/// pointer), with the permission at key `k`: the permissions stay the
/// array's, with the value of `k` replaced. The callers pass a tracked
/// mutable borrow of the view's permission field, so that the view's type
/// invariant is checked at the end of this call, against this contract
/// (Verus' rule for a mutable borrow of a field of a type with a type
/// invariant; hence `no_unwind`). The borrow is erased: no pointer to the
/// view is passed at run time, so the view can stay in registers.
#[inline(always)]
fn write_elem<T>(Tracked(perms): Tracked<&mut Map<int, PointsTo<T>>>, Ghost(base): Ghost<*mut T>,
                 Ghost(len): Ghost<int>, Ghost(k): Ghost<int>, p: *mut T, v: T)
    requires
        array_ok(*old(perms), base, len),
        0 <= k < len,
        p == at_index(base, k),
    ensures
        array_ok(*final(perms), base, len),
        values(*final(perms), len) == values(*old(perms), len).update(k, v),
    no_unwind
{
    proof { assert(elem_ok(*perms, base, k)); }
    let ghost p0 = *perms;
    ptr_mut_write(p, Tracked(perms.tracked_borrow_mut(k)), v);
    proof {
        assert forall|j: int| 0 <= j < len implies #[trigger] elem_ok(*perms, base, j) by {
            assert(elem_ok(p0, base, j));
        }
        assert(values(*perms, len) =~= values(p0, len).update(k, v));
    }
}

/// The array of the running task's Stack object: frame records at the
/// bottom, the object stack at the top. Only valid until the next call that
/// may GC (those consume it). Owns a permission for each array word and
/// for the three header words the core keeps up to date.
pub struct StackMem {
    /// Untagged address of the Stack object.
    object: *mut usize,
    /// Address of array element 0.
    array: *mut usize,
    len: usize,
    /// The array words by index.
    words: Tracked<Map<int, PointsTo<usize>>>,
    /// The header words by word offset: words `0..=STACK_BCI_WORD` of the
    /// object, of which the core accesses the last three (`is_hdr_word`).
    hdr: Tracked<Map<int, PointsTo<usize>>>,
}

/// The header words of the Stack object the core accesses.
pub open spec fn is_hdr_word(word: usize) -> bool {
    word == STACK_TOP_WORD || word == STACK_RECORD_TOP_WORD || word == STACK_BCI_WORD
}

/// The header permissions of a Stack object at `object`.
pub open spec fn hdr_ok(hdr: Map<int, PointsTo<usize>>, object: *mut usize) -> bool {
    &&& array_fits(object, (STACK_BCI_WORD + 1) as int)
    &&& forall|w: usize| is_hdr_word(w) ==> #[trigger] elem_ok(hdr, object, w as int)
}

/// `write_elem` for the header words.
#[inline(always)]
fn write_hdr(Tracked(hdr): Tracked<&mut Map<int, PointsTo<usize>>>, Ghost(object): Ghost<*mut usize>,
             word: usize, p: *mut usize, v: usize)
    requires
        hdr_ok(*old(hdr), object),
        is_hdr_word(word),
        p == at_index(object, word as int),
    ensures
        hdr_ok(*final(hdr), object),
        final(hdr)[word as int].value() == v,
        forall|w: usize| w != word ==> #[trigger] final(hdr)[w as int] == old(hdr)[w as int],
    no_unwind
{
    proof { assert(elem_ok(*hdr, object, word as int)); }
    let ghost h0 = *hdr;
    ptr_mut_write(p, Tracked(hdr.tracked_borrow_mut(word as int)), v);
    proof {
        assert forall|w: usize| is_hdr_word(w) implies #[trigger] elem_ok(*hdr, object, w as int) by {
            assert(elem_ok(h0, object, w as int));
            if w != word {
                assert(w as int != word as int);
            }
        }
        assert forall|w: usize| w != word implies #[trigger] hdr[w as int] == h0[w as int] by {
            assert(w as int != word as int);
        }
    }
}

impl StackMem {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        &&& array_ok(self.words@, self.array, self.len as int)
        &&& hdr_ok(self.hdr@, self.object)
    }

    pub closed spec fn view(&self) -> Seq<usize> {
        values(self.words@, self.len as int)
    }

    /// The identity of this view of the stack array: the cursors (`Slot`)
    /// derived from it carry it, and only a view with the same identity can
    /// be read or written through them. It is the array's pointer
    /// (address and provenance): a cursor with the same identity points
    /// into this array, whatever view it was made from. The accessors below
    /// keep it; a view replaced at a GC point (`ffi::Runtime`) has an
    /// identity no contract relates to the old one.
    pub closed spec fn sid(&self) -> *mut usize {
        self.array
    }

    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    /// The cursor at array index `i` (`i == len` is the end, not readable).
    #[inline(always)]
    pub fn slot(&self, i: usize) -> (r: Slot)
        requires i <= self@.len(),
        ensures r@ == i, r.sid() == self.sid(),
    {
        proof {
            use_type_invariant(self);
            lemma_at_index_exact(self.array, i as int, self.len as int);
        }
        Cursor { ptr: self.array.wrapping_add(i), base: Ghost(self.array), idx: Ghost(i as int) }
    }

    #[inline(always)]
    pub fn read(&self, i: usize) -> (r: usize)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        self.slot(0).read(i, self)
    }

    #[inline(always)]
    pub fn write(&mut self, i: usize, v: usize)
        requires i < old(self)@.len(),
        ensures
            final(self)@ == old(self)@.update(i as int, v),
            final(self).sid() == old(self).sid(),
            forall|w: usize| #[trigger] final(self).hdr(w) == old(self).hdr(w),
    {
        let s = self.slot(0);
        s.write(i, v, self)
    }

    /// The array index of a cursor into this view.
    #[inline(always)]
    pub fn index(&self, s: Slot) -> (r: usize)
        requires s.sid() == self.sid(), 0 <= s@ <= self@.len(), self@.len() < MAX_STACK_LENGTH,
        ensures r == s@,
    {
        s.diff(self.slot(0))
    }

    /// Copies `n` words from `from..from+n` to `to..to+n` (memmove). Used
    /// for the frame and finally records (calls and unwinding through
    /// TRY). `copy_words` gets the array pointer and the permissions
    /// (erased), not the view, so that the view can stay in registers.
    #[inline(always)]
    pub fn copy_within(&mut self, from: usize, to: usize, n: usize)
        requires
            from + n <= old(self)@.len(),
            to + n <= old(self)@.len(),
        ensures
            final(self)@.len() == old(self)@.len(),
            forall|i: int| 0 <= i < final(self)@.len() ==> #[trigger] final(self)@[i] ==
                (if to <= i < to + n { old(self)@[i - to + from] } else { old(self)@[i] }),
            final(self).sid() == old(self).sid(),
            forall|w: usize| #[trigger] final(self).hdr(w) == old(self).hdr(w),
    {
        proof { use_type_invariant(&*self); }
        copy_words(self.array, Ghost(self.len as int), Tracked(self.words.borrow_mut()), from, to, n);
    }

    /// The header words of the Stack object (outside the array): word
    /// `word` of the object. The core keeps the task's top, frame top and
    /// bci there (`STACK_TOP_WORD`, `STACK_FRAME_TOP_WORD`,
    /// `STACK_BCI_WORD`) across calls that may GC.
    pub closed spec fn hdr(&self, word: usize) -> usize {
        self.hdr@[word as int].value()
    }

    /// The header fields the core keeps up to date (top, frame top, bci).
    #[inline(always)]
    pub fn header(&self, word: usize) -> (r: usize)
        requires word == STACK_TOP_WORD || word == STACK_RECORD_TOP_WORD || word == STACK_BCI_WORD,
        ensures r == self.hdr(word),
    {
        proof {
            use_type_invariant(self);
            assert(elem_ok(self.hdr@, self.object, word as int));
            lemma_at_index_exact(self.object, word as int, (STACK_BCI_WORD + 1) as int);
        }
        let p = self.object.wrapping_add(word);
        *ptr_ref(p, Tracked(self.hdr.borrow().tracked_borrow(word as int)))
    }

    #[inline(always)]
    pub fn set_header(&mut self, word: usize, v: usize)
        requires word == STACK_TOP_WORD || word == STACK_RECORD_TOP_WORD || word == STACK_BCI_WORD,
        ensures
            final(self)@ == old(self)@,
            final(self).sid() == old(self).sid(),
            final(self).hdr(word) == v,
            forall|w: usize| w != word ==> #[trigger] final(self).hdr(w) == old(self).hdr(w),
    {
        proof {
            use_type_invariant(&*self);
            lemma_at_index_exact(self.object, word as int, (STACK_BCI_WORD + 1) as int);
        }
        let p = self.object.wrapping_add(word);
        write_hdr(Tracked(self.hdr.borrow_mut()), Ghost(self.object), word, p, v);
    }
}


/// memmove of `n` elements from `from..from+n` to `to..to+n` of the array
/// at `array` (`StackMem::copy_within`). TRUSTED: the C library's
/// `memmove` (an FFI leaf, `core::ptr::copy`), stated on the permissions:
/// it writes exactly the destination words, which then hold the source
/// words' old values. (A verified word loop with the same contract,
/// verified/core/TRUSTED.md section 1, costs up to 1 percent more
/// instructions on unwinding-heavy code: kept out.)
#[verifier::external_body]
#[inline(always)]
fn copy_words(array: *mut usize, Ghost(len): Ghost<int>, Tracked(words): Tracked<&mut Map<int, PointsTo<usize>>>,
              from: usize, to: usize, n: usize)
    requires
        array_ok(*old(words), array, len),
        from + n <= len,
        to + n <= len,
    ensures
        array_ok(*final(words), array, len),
        forall|i: int| 0 <= i < len ==> #[trigger] final(words)[i].value() ==
            (if to <= i < to + n { old(words)[i - to + from].value() } else { old(words)[i].value() }),
    no_unwind
{
    // SAFETY: `from + n` and `to + n` lie in the array (the permissions
    // cover `array[0..len)`).
    unsafe { core::ptr::copy(array.add(from), array.add(to), n) }
}

/// A cursor into the elements of a view: a pointer to element `self@` of
/// the view with identity `sid()`. The run loop keeps the object-stack top,
/// the top frame's limit, the frame top and the array end (`Slot`, into a
/// `StackMem`) and the instruction pointer (`Ip`, into the bytecodes) in
/// cursors (registers), so that a slot access or an operand fetch is one
/// load relative to a register. Arithmetic on a cursor is plain address
/// arithmetic (wrapping, never dereferenced by itself); reads and writes
/// require the index to lie in the view the cursor belongs to (cursors are
/// created only by `StackMem::slot` and `Table::<u8>::cursor`). The base
/// pointer and the index are ghost: a cursor is one pointer at run time.
pub struct Cursor<T> {
    ptr: *mut T,
    base: Ghost<*mut T>,
    idx: Ghost<int>,
}

impl<T> Clone for Cursor<T> {
    #[inline(always)]
    fn clone(&self) -> (r: Self)
        ensures r == *self,
    {
        proof { use_type_invariant(self); }
        Cursor { ptr: self.ptr, base: self.base, idx: self.idx }
    }
}

impl<T> Copy for Cursor<T> {}

/// A cursor into the stack array.
pub type Slot = Cursor<usize>;

/// A cursor into the bytecodes: the instruction pointer.
pub type Ip = Cursor<u8>;

impl<T> Cursor<T> {
    /// The pointer is element `idx` of the array at `base`.
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        self.ptr == at_index(self.base@, self.idx@)
    }

    pub closed spec fn view(&self) -> int {
        self.idx@
    }

    /// The array the cursor points into (its view's identity).
    pub closed spec fn sid(&self) -> *mut T {
        self.base@
    }

    /// The cursor `k` elements further (negative: towards index 0).
    #[inline(always)]
    pub fn offset(self, k: isize) -> (r: Cursor<T>)
        ensures r@ == self@ + k, r.sid() == self.sid(),
    {
        proof {
            use_type_invariant(&self);
            lemma_at_index_move(self.base@, self.idx@, k as int);
        }
        Cursor { ptr: self.ptr.wrapping_offset(k), base: self.base, idx: Ghost(self.idx@ + k) }
    }
}

impl Cursor<u8> {
    /// The number of elements from `o` to `self` (cursors of the same view,
    /// less than 2^28 elements apart).
    #[inline(always)]
    pub fn diff(self, o: Cursor<u8>) -> (r: usize)
        requires self.sid() == o.sid(), 0 <= o@ <= self@, self@ - o@ < 0x1000_0000,
        ensures r == self@ - o@,
    {
        proof { use_type_invariant(&self); use_type_invariant(&o); }
        let d = self.ptr.addr().wrapping_sub(o.ptr.addr());
        proof { lemma_cursor_diff(self.base@, self.idx@, o.idx@); }
        d / core::mem::size_of::<u8>()
    }

    /// Byte `self@ + k` of the table (the bytecodes).
    #[inline(always)]
    pub fn byte(self, k: usize, t: &Table<u8>) -> (r: u8)
        requires self.sid() == t.sid(), 0 <= self@ + k < t@.len(),
        ensures r == t@[self@ + k],
    {
        proof {
            use_type_invariant(&self);
            use_type_invariant(t);
            assert(elem_ok(t.perms@, t.ptr, self@ + k));
            lemma_at_index_move(t.ptr, self@, k as int);
        }
        let p = self.ptr.wrapping_add(k);
        *ptr_ref(p, Tracked(t.perms.borrow().tracked_borrow(self@ + k)))
    }
}

impl Cursor<usize> {
    /// The number of elements from `o` to `self` (cursors of the same view,
    /// less than 2^28 elements apart).
    #[inline(always)]
    pub fn diff(self, o: Cursor<usize>) -> (r: usize)
        requires self.sid() == o.sid(), 0 <= o@ <= self@, self@ - o@ < 0x1000_0000,
        ensures r == self@ - o@,
    {
        proof { use_type_invariant(&self); use_type_invariant(&o); }
        let d = self.ptr.addr().wrapping_sub(o.ptr.addr());
        proof { lemma_cursor_diff(self.base@, self.idx@, o.idx@); }
        d / WORD_SIZE
    }

    /// Element `self@ + n` of the view.
    #[inline(always)]
    pub fn read(self, n: usize, mem: &StackMem) -> (r: usize)
        requires self.sid() == mem.sid(), 0 <= self@ + n < mem@.len(),
        ensures r == mem@[self@ + n],
    {
        proof {
            use_type_invariant(&self);
            use_type_invariant(mem);
            assert(elem_ok(mem.words@, mem.array, self@ + n));
            lemma_at_index_move(mem.array, self@, n as int);
        }
        let p = self.ptr.wrapping_add(n);
        *ptr_ref(p, Tracked(mem.words.borrow().tracked_borrow(self@ + n)))
    }

    /// Stores `v` into element `self@ + n` of the view.
    #[inline(always)]
    pub fn write(self, n: usize, v: usize, mem: &mut StackMem)
        requires self.sid() == old(mem).sid(), 0 <= self@ + n < old(mem)@.len(),
        ensures
            final(mem)@ == old(mem)@.update(self@ + n, v),
            final(mem).sid() == old(mem).sid(),
            forall|w: usize| #[trigger] final(mem).hdr(w) == old(mem).hdr(w),
    {
        proof {
            use_type_invariant(&self);
            use_type_invariant(&*mem);
            assert(elem_ok(mem.words@, mem.array, self@ + n));
            lemma_at_index_move(mem.array, self@, n as int);
        }
        let p = self.ptr.wrapping_add(n);
        write_elem(Tracked(mem.words.borrow_mut()), Ghost(mem.array), Ghost(mem.len as int), Ghost(self@ + n), p, v);
    }

    /// `self` lies before `o` (two cursors into the array of `mem`, the end
    /// included): a pointer comparison.
    #[inline(always)]
    pub fn lt(self, o: Cursor<usize>, mem: &StackMem) -> (r: bool)
        requires
            self.sid() == mem.sid(), o.sid() == mem.sid(),
            0 <= self@ <= mem@.len(), 0 <= o@ <= mem@.len(),
        ensures r == (self@ < o@),
    {
        proof {
            use_type_invariant(&self);
            use_type_invariant(&o);
            use_type_invariant(mem);
            lemma_at_index_exact(mem.array, self@, mem.len as int);
            lemma_at_index_exact(mem.array, o@, mem.len as int);
            assert((self@ < o@) == (self@ * WORD_SIZE < o@ * WORD_SIZE)) by (nonlinear_arith);
        }
        self.ptr.addr() < o.ptr.addr()
    }
}

/// The distance of two cursors into the same array, less than 2^28
/// elements apart (`diff`): exact, whatever the wrapping of the addresses.
pub proof fn lemma_cursor_diff<T>(base: *mut T, i: int, j: int)
    requires 0 <= j <= i, i - j < 0x1000_0000, size_of::<T>() == WORD_SIZE || size_of::<T>() == 1,
    ensures
        vstd::wrapping::usize_specs::wrapping_sub(
            at_index(base, i)@.addr, at_index(base, j)@.addr) as int / (size_of::<T>() as int) == i - j,
{
    let m = modulus();
    let s = size_of::<T>() as int;
    let b = base@.addr as int;
    let a = at_index(base, i)@.addr;
    let c = at_index(base, j)@.addr;
    assert(a as int == (b + i * s) % m);
    assert(c as int == (b + j * s) % m);
    lemma_wrapping_sub(a, c);
    vstd::arithmetic::div_mod::lemma_sub_mod_noop(b + i * s, b + j * s, m);
    assert(b + i * s - (b + j * s) == (i - j) * s) by (nonlinear_arith);
    assert(0 <= (i - j) * s < m) by (nonlinear_arith)
        requires 0 <= i - j < 0x1000_0000, s == WORD_SIZE || s == 1, m == modulus();
    vstd::arithmetic::div_mod::lemma_small_mod(((i - j) * s) as nat, m as nat);
    assert(((i - j) * s) / s == i - j) by (nonlinear_arith) requires s > 0;
}

/// Access to heap objects. A word with the heap tag that the core reads
/// from a root (the object stack, a global, a program table) or from a
/// field of such an object designates a live object (the GC maintains this;
/// TRUSTED.md, "heap integrity"). Valid until the next call that may GC
/// (holds no pointers itself, but the words it is given do).
#[verifier::external_body]
pub struct Heap {
    remembered_set_bias: usize,
}

impl Heap {
    /// The heap model: the objects of the process as abstract heap objects
    /// (`State2::heap`, object ids are indices) ...
    pub uninterp spec fn objs(&self) -> Seq<HeapObj>;

    /// ... and their current addresses (tagged words). The contracts of
    /// the accessors and of the calls that may GC (`ffi::Runtime`) relate
    /// memory to this model (TRUSTED.md, "Heap model").
    pub uninterp spec fn addrs(&self) -> Seq<usize>;

    /// The program's class bits (class tag and instance size per class id),
    /// which the objects' headers follow.
    pub uninterp spec fn class_bits(&self) -> Seq<u16>;

    /// The class id of object `id` (`obj` is its address): the header's
    /// class id.
    #[verifier::external_body]
    #[inline(always)]
    pub fn class_id(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
        ensures r == self.objs()[id].class_id,
    {
        let header = unsafe { *((obj - HEAP_TAG) as *const usize) };
        (((header as isize) >> 1) as usize) >> CLASS_ID_OFFSET
    }

    /// The class tag of object `id`: the header's tag, which is its class'
    /// tag in the class bits.
    #[verifier::external_body]
    #[inline(always)]
    pub fn class_tag(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            (self.objs()[id].class_id as int) < self.class_bits().len(),
        ensures r == (self.class_bits()[self.objs()[id].class_id as int] & 0xf) as usize,
    {
        let header = unsafe { *((obj - HEAP_TAG) as *const usize) };
        (((header as isize) >> 1) as usize) & CLASS_TAG_MASK
    }

    /// Field `f` of the instance `id`: the encoding of the abstract field
    /// (`crate::abs::enc`).
    #[verifier::external_body]
    #[inline(always)]
    pub fn field(&self, obj: usize, f: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Instance,
            f < self.objs()[id].body->Instance_0.len(),
        ensures r == crate::abs::enc(self.addrs(), self.objs()[id].body->Instance_0[f as int]),
    {
        unsafe { *((obj - HEAP_TAG) as *const usize).add(INSTANCE_FIELDS_WORD + f) }
    }

    /// Stores the encoding `w` of `v` into field `f` of the instance `id`
    /// (with the write barrier): the model's field becomes `v`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn set_field(&mut self, obj: usize, f: usize, w: usize, Ghost(id): Ghost<int>, Ghost(v): Ghost<Value>)
        requires
            0 <= id < old(self).objs().len(),
            old(self).addrs().len() == old(self).objs().len(),
            obj == old(self).addrs()[id],
            old(self).objs()[id].body is Instance,
            f < old(self).objs()[id].body->Instance_0.len(),
            !old(self).objs()[id].ro,
            w == crate::abs::enc(old(self).addrs(), v),
        ensures
            final(self).objs() == old(self).objs().update(id, HeapObj {
                body: Body::Instance(old(self).objs()[id].body->Instance_0.update(f as int, v)),
                ..old(self).objs()[id]
            }),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe {
            *((obj - HEAP_TAG) as *mut usize).add(INSTANCE_FIELDS_WORD + f) = w;
            let card = ((obj - HEAP_TAG) >> CARD_SIZE_LOG_2).wrapping_add(self.remembered_set_bias);
            *(card as *mut u8) = NEW_SPACE_POINTERS;
        }
    }

    /// The length of the array `id` (its length word).
    #[verifier::external_body]
    #[inline(always)]
    pub fn array_length(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Array,
        ensures r == self.objs()[id].body->Array_0.len(),
    {
        unsafe { *((obj - HEAP_TAG) as *const usize).add(ARRAY_LENGTH_WORD) }
    }

    /// Element `i` of the array `id`: the encoding of the abstract element.
    #[verifier::external_body]
    #[inline(always)]
    pub fn element(&self, obj: usize, i: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Array,
            i < self.objs()[id].body->Array_0.len(),
        ensures r == crate::abs::enc(self.addrs(), self.objs()[id].body->Array_0[i as int]),
    {
        unsafe { *((obj - HEAP_TAG) as *const usize).add(ARRAY_ELEMENTS_WORD + i) }
    }

    /// Stores the encoding `w` of `v` into element `i` of the array `id`
    /// (with the write barrier): the model's element becomes `v`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn set_element(&mut self, obj: usize, i: usize, w: usize, Ghost(id): Ghost<int>, Ghost(v): Ghost<Value>)
        requires
            0 <= id < old(self).objs().len(),
            old(self).addrs().len() == old(self).objs().len(),
            obj == old(self).addrs()[id],
            old(self).objs()[id].body is Array,
            i < old(self).objs()[id].body->Array_0.len(),
            !old(self).objs()[id].ro,
            w == crate::abs::enc(old(self).addrs(), v),
        ensures
            final(self).objs() == old(self).objs().update(id, HeapObj {
                body: Body::Array(old(self).objs()[id].body->Array_0.update(i as int, v)),
                ..old(self).objs()[id]
            }),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe {
            *((obj - HEAP_TAG) as *mut usize).add(ARRAY_ELEMENTS_WORD + i) = w;
            let card = ((obj - HEAP_TAG) >> CARD_SIZE_LOG_2).wrapping_add(self.remembered_set_bias);
            *(card as *mut u8) = NEW_SPACE_POINTERS;
        }
    }

    /// The bits of the double `id` (its value word).
    #[verifier::external_body]
    #[inline(always)]
    pub fn double_bits(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: u64)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Double,
        ensures r == self.objs()[id].body->Double_0,
    {
        // Word aligned only (two words on 32-bit targets).
        unsafe { core::ptr::read_unaligned((obj - HEAP_TAG + DOUBLE_VALUE_WORD * WORD_SIZE) as *const u64) }
    }

    /// The value of the large integer `id` (its value word).
    #[verifier::external_body]
    #[inline(always)]
    pub fn large_int(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: i64)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is LargeInt,
        ensures r == self.objs()[id].body->LargeInt_0,
    {
        unsafe { core::ptr::read_unaligned((obj - HEAP_TAG + LARGE_INTEGER_VALUE_WORD * WORD_SIZE) as *const i64) }
    }

    /// The length of the string `id` (internal: the 32-bit length field;
    /// external: the length word).
    #[verifier::external_body]
    #[inline(always)]
    pub fn string_len(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Str,
        ensures r == self.objs()[id].body->Str_0.len(),
    {
        let base = obj - HEAP_TAG;
        unsafe {
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            if internal != STRING_SENTINEL { internal } else { *(base as *const usize).add(STRING_EXTERNAL_LENGTH_WORD) }
        }
    }

    /// Byte `i` of the string `id` (inline content or external memory).
    #[verifier::external_body]
    #[inline(always)]
    pub fn string_byte(&self, obj: usize, i: usize, Ghost(id): Ghost<int>) -> (r: u8)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Str,
            i < self.objs()[id].body->Str_0.len(),
        ensures r == self.objs()[id].body->Str_0[i as int],
    {
        let base = obj - HEAP_TAG;
        unsafe {
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            if internal != STRING_SENTINEL {
                *((base + STRING_CONTENT_BYTE + i) as *const u8)
            } else {
                let address = *(base as *const usize).add(STRING_EXTERNAL_ADDRESS_WORD);
                *(address as *const u8).add(i)
            }
        }
    }

    /// Whether the object `id`, whose class has the byte-array tag, is a
    /// byte array in the model (`Body::Bytes`), and then its length. The
    /// model's byte arrays are exactly the internal ones and the external
    /// ones with raw bytes (`RAW_BYTE_TAG`) at a non-null address; other
    /// external byte arrays (mapped files, proxies of resources, whose
    /// address is not program-accessible memory) are opaque objects of the
    /// model (TRUSTED.md, "Heap model").
    #[verifier::external_body]
    #[inline(always)]
    pub fn bytes_len(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: Option<usize>)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            (self.objs()[id].class_id as int) < self.class_bits().len(),
            (self.class_bits()[self.objs()[id].class_id as int] & 0xf) as usize == BYTE_ARRAY_TAG,
        ensures
            r is Some == self.objs()[id].body is Bytes,
            r is Some ==> r->0 == self.objs()[id].body->Bytes_0.len(),
    {
        let base = (obj - HEAP_TAG) as *const usize;
        unsafe {
            let raw = *base.add(BYTE_ARRAY_LENGTH_WORD) as isize;
            if raw >= 0 { return Some(raw as usize); }
            let tag = *base.add(BYTE_ARRAY_EXTERNAL_TAG_WORD);
            let address = *base.add(BYTE_ARRAY_EXTERNAL_ADDRESS_WORD);
            if tag == RAW_BYTE_TAG && address != 0 { Some((-1 - raw) as usize) } else { None }
        }
    }

    /// Byte `i` of the byte array `id`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn byte_at(&self, obj: usize, i: usize, Ghost(id): Ghost<int>) -> (r: u8)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Bytes,
            i < self.objs()[id].body->Bytes_0.len(),
        ensures r == self.objs()[id].body->Bytes_0[i as int],
    {
        unsafe {
            let base = (obj - HEAP_TAG) as *const usize;
            let address = if (*base.add(BYTE_ARRAY_LENGTH_WORD) as isize) >= 0 {
                (obj - HEAP_TAG + BYTE_ARRAY_CONTENT_BYTE) as *const u8
            } else {
                *base.add(BYTE_ARRAY_EXTERNAL_ADDRESS_WORD) as *const u8
            };
            *address.add(i)
        }
    }

    /// Stores `b` into byte `i` of the byte array `id`, outside the program
    /// heap (bytes hold no references: no write barrier).
    #[verifier::external_body]
    #[inline(always)]
    pub fn set_byte_at(&mut self, obj: usize, i: usize, b: u8, Ghost(id): Ghost<int>)
        requires
            0 <= id < old(self).objs().len(),
            old(self).addrs().len() == old(self).objs().len(),
            obj == old(self).addrs()[id],
            old(self).objs()[id].body is Bytes,
            i < old(self).objs()[id].body->Bytes_0.len(),
            !old(self).objs()[id].ro,
        ensures
            final(self).objs() == old(self).objs().update(id, HeapObj {
                body: Body::Bytes(old(self).objs()[id].body->Bytes_0.update(i as int, b)),
                ..old(self).objs()[id]
            }),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe {
            let base = (obj - HEAP_TAG) as *const usize;
            let address = if (*base.add(BYTE_ARRAY_LENGTH_WORD) as isize) >= 0 {
                (obj - HEAP_TAG + BYTE_ARRAY_CONTENT_BYTE) as *mut u8
            } else {
                *base.add(BYTE_ARRAY_EXTERNAL_ADDRESS_WORD) as *mut u8
            };
            *address.add(i) = b
        }
    }

    /// The header word of a heap object.
    #[verifier::external_body]
    #[inline(always)]
    pub fn header(&self, obj: usize) -> (r: usize)
        requires obj & 3 == 1,
    {
        unsafe { *((obj - HEAP_TAG) as *const usize) }
    }

    /// Word `k` of a heap object (k >= 1), within the object.
    #[verifier::external_body]
    #[inline(always)]
    pub fn word(&self, obj: usize, k: usize) -> (r: usize)
        requires obj & 3 == 1,
    {
        unsafe { *((obj - HEAP_TAG) as *const usize).add(k) }
    }

    /// The 64-bit payload starting at word `k` of a heap object (word
    /// aligned only: two words on 32-bit targets).
    #[verifier::external_body]
    #[inline(always)]
    pub fn word64(&self, obj: usize, k: usize) -> (r: u64)
        requires obj & 3 == 1,
    {
        unsafe { core::ptr::read_unaligned((obj - HEAP_TAG + k * WORD_SIZE) as *const u64) }
    }

    /// Stores into word `k` of an object of the process heap, with the
    /// write barrier.
    #[verifier::external_body]
    #[inline(always)]
    pub fn set_word(&mut self, obj: usize, k: usize, v: usize)
        requires obj & 3 == 1,
    {
        unsafe {
            *((obj - HEAP_TAG) as *mut usize).add(k) = v;
            let card = ((obj - HEAP_TAG) >> CARD_SIZE_LOG_2).wrapping_add(self.remembered_set_bias);
            *(card as *mut u8) = NEW_SPACE_POINTERS;
        }
    }

    /// Byte `i` at byte offset `offset` of a heap object, or of the external
    /// memory at address `address` if `address != 0`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn byte(&self, obj: usize, address: usize, offset: usize) -> (r: u8) {
        unsafe {
            if address != 0 {
                *(address as *const u8).add(offset)
            } else {
                *((obj - HEAP_TAG) as *const u8).add(offset)
            }
        }
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn set_byte(&mut self, obj: usize, address: usize, offset: usize, v: u8) {
        unsafe {
            if address != 0 {
                *(address as *mut u8).add(offset) = v;
            } else {
                *((obj - HEAP_TAG) as *mut u8).add(offset) = v;
            }
        }
    }

    /// The half word (`HalfWord`) at byte offset `offset` of a heap object.
    #[verifier::external_body]
    #[inline(always)]
    pub fn half_word_at(&self, obj: usize, offset: usize) -> (r: usize) {
        unsafe { *(((obj - HEAP_TAG) as *const u8).add(offset) as *const HalfWord) as usize }
    }
}

// ---------------------------------------------------------------------------
// Primitives (src/prims): numbers, strings and byte arrays. The heap model
// `obj_model_ok` (abs.rs) relates only instances and arrays to memory; the
// accessors below relate the other bodies the primitives read and write.

/// The bytes of a string or byte array.
pub open spec fn content(o: HeapObj) -> Seq<u8> {
    match o.body {
        Body::Str(s) => s,
        Body::Bytes(b) => b,
        _ => Seq::empty(),
    }
}

pub open spec fn is_blob(o: HeapObj) -> bool {
    o.body is Str || o.body is Bytes
}

/// `o` with its bytes replaced by `s` (same kind of body).
pub open spec fn with_content(o: HeapObj, s: Seq<u8>) -> HeapObj {
    HeapObj {
        body: match o.body {
            Body::Str(_) => Body::Str(s),
            Body::Bytes(_) => Body::Bytes(s),
            b => b,
        },
        ..o
    }
}

/// The class tag of class `cid` (`abs::tag_bits`).
pub open spec fn class_tag_of(cb: Seq<u16>, cid: int) -> int {
    (cb[cid] & 0xfu16) as int
}

/// The bytes of a string or byte array (`Heap::string_content`,
/// `Heap::byte_array_content`): the object `id()` of the heap model,
/// `slen()` bytes. Valid until the next GC point: primitives never reach
/// one (they report an allocation failure instead, `prims::PrimOutcome`),
/// so a `Content` never outlives the primitive call that created it.
#[verifier::external_body]
pub struct Content {
    ptr: *mut u8,
    len: usize,
}

impl Content {
    pub uninterp spec fn id(&self) -> int;

    pub uninterp spec fn slen(&self) -> nat;

    /// The bytes may be written: a string or a byte array with inline or
    /// raw external bytes, outside the program heap.
    pub uninterp spec fn writable(&self) -> bool;

    #[verifier::external_body]
    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self.slen(),
    {
        self.len
    }
}

/// A content view of object `c.id()` of the heap: its bytes are `c.slen()`
/// long.
pub open spec fn content_ok(h: &Heap, c: &Content) -> bool {
    &&& 0 <= c.id() < h.objs().len()
    &&& is_blob(h.objs()[c.id()])
    &&& content(h.objs()[c.id()]).len() == c.slen()
}

/// `new` is `old` with one object appended at the tagged address `r`, which
/// is new and outside the program heap (`ro_start..ro_start+ro_size`); the
/// model stays below 2^30 objects.
pub open spec fn appended(old: &Heap, new: &Heap, r: usize, ro_start: usize, ro_size: usize) -> bool {
    let n = old.objs().len();
    &&& new.objs().len() == n + 1
    &&& new.addrs().len() == n + 1
    &&& old.addrs().len() == n
    &&& new.objs().subrange(0, n as int) == old.objs()
    &&& new.addrs().subrange(0, n as int) == old.addrs()
    &&& new.addrs()[n as int] == r
    &&& new.class_bits() == old.class_bits()
    &&& r & 3 == 1
    &&& forall|i: int| 0 <= i < n ==> #[trigger] old.addrs()[i] != r
    &&& !(ro_start <= r && r < ro_start + ro_size)
    &&& !new.objs()[n as int].ro
    &&& n + 1 < 0x4000_0000
}

impl Heap {
    /// The bytes of the string `id` (inline or external). Writable exactly
    /// when the string is not in the program heap.
    #[verifier::external_body]
    #[inline(always)]
    pub fn string_content(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: Content)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Str,
        ensures
            r.id() == id,
            r.slen() == content(self.objs()[id]).len(),
            r.writable() == !self.objs()[id].ro,
    {
        unsafe {
            let base = (obj - HEAP_TAG) as *mut u8;
            let internal = *(base.add(STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            if internal != STRING_SENTINEL {
                Content { ptr: base.add(STRING_CONTENT_BYTE), len: internal }
            } else {
                let words = base as *const usize;
                Content {
                    ptr: *words.add(STRING_EXTERNAL_ADDRESS_WORD) as *mut u8,
                    len: *words.add(STRING_EXTERNAL_LENGTH_WORD),
                }
            }
        }
    }

    /// The bytes of the byte array `id` of the model (`Body::Bytes`: by V5
    /// internal, or external with the raw-bytes tag at a non-null address;
    /// `bytes_len` tells a model byte array from an opaque one). Writable
    /// when `for_write` and not in the program heap.
    #[verifier::external_body]
    #[inline(always)]
    pub fn byte_array_content(&self, obj: usize, Ghost(id): Ghost<int>, for_write: bool) -> (r: Content)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Bytes,
        ensures
            r.id() == id,
            r.slen() == content(self.objs()[id]).len(),
            r.writable() == (for_write && !self.objs()[id].ro),
    {
        unsafe {
            let base = (obj - HEAP_TAG) as *mut u8;
            let words = base as *const usize;
            let raw = *words.add(BYTE_ARRAY_LENGTH_WORD) as isize;
            if raw >= 0 {
                Content { ptr: base.add(BYTE_ARRAY_CONTENT_BYTE), len: raw as usize }
            } else {
                Content { ptr: *words.add(BYTE_ARRAY_EXTERNAL_ADDRESS_WORD) as *mut u8, len: (-1 - raw) as usize }
            }
        }
    }

    /// The hash code cached in the string `id` (`String::NO_HASH_CODE` if
    /// not computed yet; a 32-bit field holding 16 bits, as
    /// `String::_raw_hash_code`). Not in the model: any value.
    #[verifier::external_body]
    #[inline(always)]
    pub fn string_hash_field(&self, obj: usize, Ghost(id): Ghost<int>) -> u16
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Str,
    {
        unsafe { *(((obj - HEAP_TAG) as *const u8).add(STRING_HASH_CODE_BYTE) as *const HalfWord) as u16 }
    }

    /// Caches the hash code of the string `id` (not in the program heap).
    /// The model does not include it, so it is unchanged.
    #[verifier::external_body]
    #[inline(always)]
    pub fn set_string_hash_field(&mut self, obj: usize, Ghost(id): Ghost<int>, v: u16)
        requires
            0 <= id < old(self).objs().len(),
            old(self).addrs().len() == old(self).objs().len(),
            obj == old(self).addrs()[id],
            old(self).objs()[id].body is Str,
            !old(self).objs()[id].ro,
        ensures *final(self) == *old(self),
    {
        unsafe { *(((obj - HEAP_TAG) as *mut u8).add(STRING_HASH_CODE_BYTE) as *mut HalfWord) = v as HalfWord }
    }

    /// Byte `i` of a content view.
    #[verifier::external_body]
    #[inline(always)]
    pub fn content_at(&self, c: &Content, i: usize) -> (r: u8)
        requires content_ok(self, c), i < c.slen(),
        ensures r == content(self.objs()[c.id()])[i as int],
    {
        unsafe { *c.ptr.add(i) }
    }

    /// Stores byte `i` of a writable content view.
    #[verifier::external_body]
    #[inline(always)]
    pub fn content_set(&mut self, c: &Content, i: usize, v: u8)
        requires content_ok(old(self), c), i < c.slen(), c.writable(),
        ensures
            final(self).objs() == old(self).objs().update(c.id(),
                with_content(old(self).objs()[c.id()], content(old(self).objs()[c.id()]).update(i as int, v))),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe { *c.ptr.add(i) = v }
    }

    /// memmove of `n` bytes from `src[from..]` to `dst[to..]` (`dst`
    /// writable; the views may be of the same object).
    #[verifier::external_body]
    #[inline(always)]
    pub fn content_copy(&mut self, dst: &Content, to: usize, src: &Content, from: usize, n: usize)
        requires
            content_ok(old(self), dst), content_ok(old(self), src), dst.writable(),
            to + n <= dst.slen(), from + n <= src.slen(),
        ensures
            final(self).objs() == old(self).objs().update(dst.id(),
                with_content(old(self).objs()[dst.id()], Seq::new(dst.slen(), |k: int|
                    if to <= k < to + n { content(old(self).objs()[src.id()])[k - to + from] }
                    else { content(old(self).objs()[dst.id()])[k] }))),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe { core::ptr::copy(src.ptr.add(from), dst.ptr.add(to), n) }
    }

    /// memset of `n` bytes at `dst[to..]`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn content_fill(&mut self, dst: &Content, to: usize, n: usize, v: u8)
        requires content_ok(old(self), dst), dst.writable(), to + n <= dst.slen(),
        ensures
            final(self).objs() == old(self).objs().update(dst.id(),
                with_content(old(self).objs()[dst.id()], Seq::new(dst.slen(), |k: int|
                    if to <= k < to + n { v } else { content(old(self).objs()[dst.id()])[k] }))),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe { core::ptr::write_bytes(dst.ptr.add(to), v, n) }
    }

    /// memmove of `n` elements from `src[from..]` to `dst[to..]` of two
    /// arrays (possibly the same), with the write barrier on `dst`.
    #[verifier::external_body]
    #[inline(always)]
    pub fn array_copy(&mut self, dst: usize, to: usize, src: usize, from: usize, n: usize,
                      Ghost(d): Ghost<int>, Ghost(s): Ghost<int>)
        requires
            0 <= d < old(self).objs().len(),
            0 <= s < old(self).objs().len(),
            old(self).addrs().len() == old(self).objs().len(),
            dst == old(self).addrs()[d],
            src == old(self).addrs()[s],
            old(self).objs()[d].body is Array,
            old(self).objs()[s].body is Array,
            !old(self).objs()[d].ro,
            to + n <= old(self).objs()[d].body->Array_0.len(),
            from + n <= old(self).objs()[s].body->Array_0.len(),
        ensures
            final(self).objs() == old(self).objs().update(d, HeapObj {
                body: Body::Array(Seq::new(old(self).objs()[d].body->Array_0.len(), |k: int|
                    if to <= k < to + n { old(self).objs()[s].body->Array_0[k - to + from] }
                    else { old(self).objs()[d].body->Array_0[k] })),
                ..old(self).objs()[d]
            }),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        unsafe {
            let d = ((dst - HEAP_TAG) as *mut usize).add(ARRAY_ELEMENTS_WORD);
            let s = ((src - HEAP_TAG) as *const usize).add(ARRAY_ELEMENTS_WORD);
            core::ptr::copy(s.add(from), d.add(to), n);
            if n != 0 {
                let card = ((dst - HEAP_TAG) >> CARD_SIZE_LOG_2).wrapping_add(self.remembered_set_bias);
                *(card as *mut u8) = NEW_SPACE_POINTERS;
            }
        }
    }
}

/// A path Verus proves unreachable (`requires false`: no caller can meet
/// the precondition), marked as such for the compiler so that it can drop
/// the path (the range check before the dispatch's jump table). TRUSTED
/// only in that Verus' proof of the callers is sound.
#[verifier::external_body]
#[inline(always)]
pub fn proven_unreachable<A>() -> A
    requires false,
{
    // SAFETY: unreachable: every call site is proven dead (requires false).
    unsafe { core::hint::unreachable_unchecked() }
}

/// The preemption flag: the interpreter's watermark, set to
/// `PREEMPTION_MARKER` by the scheduler from another thread. No contract:
/// its value is environment nondeterminism.
#[verifier::external_body]
pub struct Preemption {
    watermark: *const AtomicUsize,
}

impl Preemption {
    /// The watermark word: `PREEMPTION_MARKER` (all ones) when preemption is
    /// requested; any other value otherwise (null while the core runs; the
    /// call's room check is `free < (word | needed)`, which a request makes
    /// fail and any other value leaves at `free < needed` or stricter).
    #[verifier::external_body]
    #[inline(always)]
    pub fn word(&self) -> usize {
        unsafe { (*self.watermark).load(Ordering::Relaxed) }
    }

    #[inline(always)]
    pub fn requested(&self) -> bool {
        self.word() == PREEMPTION_MARKER
    }

    #[verifier::external_body]
    pub fn clear(&self) {
        unsafe { (*self.watermark).store(0, Ordering::Relaxed) }
    }

    #[verifier::external_body]
    pub fn request(&self) {
        unsafe { (*self.watermark).store(PREEMPTION_MARKER, Ordering::Relaxed) }
    }
}

} // verus!

// The derivation points (TRUSTED.md section 1, "Memory model"). Invisible to
// the verifier: they create the views, and with them the permissions
// (`Tracked::assume_new`), which the type invariants relate to the
// addresses. What each assumes is stated in its comment and in TRUSTED.md.
impl<T> Table<T> {
    /// TRUSTED (derivation point): `ptr[0..len)` is an initialized,
    /// aligned array of `T` in the address space, immutable while the view
    /// lives and covered by no other view: the permissions of its elements.
    ///
    /// # Safety
    /// `ptr..ptr+len` must be valid, aligned and immutable while the view
    /// lives.
    pub unsafe fn from_raw(ptr: *const T, len: usize) -> Self {
        Table { ptr: ptr as *mut T, len, perms: Tracked::assume_new() }
    }
}

impl Globals {
    /// TRUSTED (derivation point): `ptr[0..len)` are the process' global
    /// variables, initialized words in the address space that nothing else
    /// accesses while the core runs (V1): the permissions of the words.
    ///
    /// # Safety
    /// `ptr..ptr+len` must be the process' global variables.
    pub unsafe fn from_raw(ptr: *mut usize, len: usize) -> Self {
        Globals { ptr, len, perms: Tracked::assume_new() }
    }
}

impl StackMem {
    /// TRUSTED (derivation point, at entry and after every GC point:
    /// `ffi::Runtime::stack`): the Stack object at `stack - HEAP_TAG` has
    /// an array of `len` (its length word) initialized words at word
    /// `array_word` and, if `len > 0`, the top, record-top and bci header
    /// words, all in the address space and accessed by nothing else while
    /// the view lives: the permissions of those words.
    ///
    /// # Safety
    /// `stack` must be the tagged pointer of the running task's Stack object
    /// and `array_word` the word offset of its array.
    pub unsafe fn from_stack(stack: usize, array_word: usize) -> Self {
        let object = (stack - HEAP_TAG) as *mut usize;
        let len = *object.add(STACK_LENGTH_WORD);
        StackMem { object, array: object.add(array_word), len, words: Tracked::assume_new(), hdr: Tracked::assume_new() }
    }
}

impl Heap {
    pub fn new(remembered_set_bias: usize) -> Self {
        Heap { remembered_set_bias }
    }
}

impl Preemption {
    /// # Safety
    /// `watermark` must point to the interpreter's `std::atomic<Object**>`.
    pub unsafe fn from_raw(watermark: *const AtomicUsize) -> Self {
        Preemption { watermark }
    }
}

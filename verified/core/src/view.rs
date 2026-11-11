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

/// The class id and class tag a header word encodes (`HeapObject::header`
/// is the smi `class_id << CLASS_ID_OFFSET | class_tag`, plus GC bits above
/// the tag the core does not read).
pub open spec fn hdr_class_id(h: usize) -> usize {
    (((h as isize) >> 1usize) as usize) >> CLASS_ID_OFFSET
}

pub open spec fn hdr_class_tag(h: usize) -> usize {
    (((h as isize) >> 1usize) as usize) & CLASS_TAG_MASK
}

/// Word `k` of an object of the model is one the verified accessors use:
/// the header, an instance's fields, an array's length and elements.
pub open spec fn is_word(o: HeapObj, k: int) -> bool {
    k == 0 || match o.body {
        Body::Instance(f) => 1 <= k < 1 + f.len(),
        Body::Array(e) => 1 <= k < 2 + e.len(),
        Body::Double(_) | Body::LargeInt(_) => 1 <= k < 1 + VALUE_WORDS,
        _ => false,
    }
}

/// The number of those words.
pub open spec fn obj_words(o: HeapObj) -> int {
    match o.body {
        Body::Instance(f) => 1 + f.len() as int,
        Body::Array(e) => 2 + e.len() as int,
        Body::Double(_) | Body::LargeInt(_) => 1 + VALUE_WORDS,
        _ => 1,
    }
}

/// The words of the 64-bit payload of a double or large integer (one
/// word, or two on 32-bit targets, little endian).
#[cfg(target_pointer_width = "64")]
pub const VALUE_WORDS: usize = 1;
#[cfg(target_pointer_width = "32")]
pub const VALUE_WORDS: usize = 2;

/// The payload of a double (its bits) or large integer (its two's
/// complement).
pub open spec fn value64(o: HeapObj) -> u64 {
    match o.body {
        Body::Double(b) => b,
        Body::LargeInt(x) => x as u64,
        _ => 0,
    }
}

/// Word `j` of a 64-bit payload `b` (little endian).
#[cfg(target_pointer_width = "64")]
pub open spec fn value_word(b: u64, j: int) -> usize {
    b as usize
}

#[cfg(target_pointer_width = "32")]
pub open spec fn value_word(b: u64, j: int) -> usize {
    if j == 0 { (b & 0xffff_ffffu64) as usize } else { (b >> 32u64) as usize }
}

/// TRUSTED (the layout of the heap model, TRUSTED.md section 1 "Memory
/// model", V2; the same facts as verified/CONTRACTS.toml's bridge `heap`):
/// the value `v` of word `k` of an object agrees with the model `o`. The
/// header decodes to the object's class id and to its class' tag; the
/// fields of an instance are words `INSTANCE_FIELDS_WORD..`; an array has
/// its length at `ARRAY_LENGTH_WORD` and its elements from
/// `ARRAY_ELEMENTS_WORD`; references are encoded by `abs::enc` (smis and
/// tagged addresses); a double's bits and a large integer's value are the
/// words from `DOUBLE_VALUE_WORD` resp. `LARGE_INTEGER_VALUE_WORD`
/// (`value_word`). Checked against the C++ by the layout check.
pub open spec fn word_val(o: HeapObj, cb: Seq<u16>, addrs: Seq<usize>, k: int, v: usize) -> bool {
    if k == 0 {
        &&& hdr_class_id(v) == o.class_id
        &&& (o.class_id as int) < cb.len() ==> hdr_class_tag(v) == (cb[o.class_id as int] & 0xf) as usize
    } else {
        match o.body {
            Body::Instance(f) => v == crate::abs::enc(addrs, f[k - INSTANCE_FIELDS_WORD]),
            Body::Array(e) =>
                if k == ARRAY_LENGTH_WORD { v == e.len() } else { v == crate::abs::enc(addrs, e[k - ARRAY_ELEMENTS_WORD]) },
            Body::Double(_) => v == value_word(value64(o), k - DOUBLE_VALUE_WORD),
            Body::LargeInt(_) => v == value_word(value64(o), k - LARGE_INTEGER_VALUE_WORD),
            _ => true,
        }
    }
}

/// The memory of the heap model's objects: one permission per word the
/// verified accessors read or write (key: object id and word index), the
/// exposed provenance of the heap (addresses are computed from tagged
/// words), and the model itself (ghost).
pub tracked struct HeapMem {
    pub tracked exposed: IsExposed,
    pub tracked words: Map<(int, int), PointsTo<usize>>,
    pub ghost objs: Seq<HeapObj>,
    pub ghost addrs: Seq<usize>,
    pub ghost class_bits: Seq<u16>,
}

/// The untagged address of object `id`, as a pointer with the heap's
/// exposed provenance (what `with_exposed_provenance(obj - HEAP_TAG)` gives).
pub open spec fn obj_ptr(m: HeapMem, id: int) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> {
        addr: (m.addrs[id] - HEAP_TAG) as usize, provenance: m.exposed@, metadata: () })
}

/// Object `id` lies in the address space.
pub open spec fn obj_fits(m: HeapMem, id: int) -> bool {
    &&& m.addrs[id] >= HEAP_TAG
    &&& (m.addrs[id] - HEAP_TAG) + WORD_SIZE * obj_words(m.objs[id]) <= usize::MAX
}

/// The permission of word `k` of object `id` is that word's, initialized,
/// and its value agrees with the model.
pub open spec fn word_ok(m: HeapMem, id: int, k: int) -> bool {
    &&& m.words.contains_key((id, k))
    &&& m.words[(id, k)].ptr() == at_index(obj_ptr(m, id), k)
    &&& m.words[(id, k)].is_init()
    &&& word_val(m.objs[id], m.class_bits, m.addrs, k, m.words[(id, k)].value())
}

/// The heap invariant: the permissions of every word of every object.
pub open spec fn heap_ok(m: HeapMem) -> bool {
    &&& m.addrs.len() == m.objs.len()
    &&& forall|id: int| 0 <= id < m.objs.len() ==> #[trigger] obj_fits(m, id)
    &&& forall|id: int, k: int| 0 <= id < m.objs.len() && is_word(m.objs[id], k) ==> #[trigger] word_ok(m, id, k)
}

/// Stores `w` into word `k` of object `id` through `p` and makes `o2` the
/// model's object `id`: `o2` has the same words, word `k` agrees with `w`,
/// the others with their values as before. (A tracked borrow of the
/// heap's permission field, as `write_elem`.)
#[inline(always)]
fn write_heap_word(Tracked(m): Tracked<&mut HeapMem>, Ghost(id): Ghost<int>, k: usize, p: *mut usize, w: usize,
                   Ghost(o2): Ghost<HeapObj>)
    requires
        heap_ok(*old(m)),
        0 <= id < old(m).objs.len(),
        is_word(old(m).objs[id], k as int),
        p == at_index(obj_ptr(*old(m), id), k as int),
        obj_words(o2) == obj_words(old(m).objs[id]),
        forall|j: int| #[trigger] is_word(o2, j) == is_word(old(m).objs[id], j),
        word_val(o2, old(m).class_bits, old(m).addrs, k as int, w),
        forall|j: int, x: usize| j != k && is_word(o2, j) ==>
            #[trigger] word_val(o2, old(m).class_bits, old(m).addrs, j, x)
                == word_val(old(m).objs[id], old(m).class_bits, old(m).addrs, j, x),
    ensures
        heap_ok(*final(m)),
        final(m).objs == old(m).objs.update(id, o2),
        final(m).addrs == old(m).addrs,
        final(m).class_bits == old(m).class_bits,
        final(m).exposed == old(m).exposed,
    no_unwind
{
    let ghost m0 = *m;
    proof { assert(word_ok(m0, id, k as int)); }
    ptr_mut_write(p, Tracked(m.words.tracked_borrow_mut((id, k as int))), w);
    proof {
        m.objs = m0.objs.update(id, o2);
        assert forall|j: int| 0 <= j < m.objs.len() implies #[trigger] obj_fits(*m, j) by {
            assert(obj_fits(m0, j));
        }
        assert forall|j: int, kk: int| 0 <= j < m.objs.len() && is_word(m.objs[j], kk) implies
            #[trigger] word_ok(*m, j, kk) by {
            if j == id {
                assert(is_word(m0.objs[id], kk));
                if kk != k as int {
                    assert(word_ok(m0, j, kk));
                    assert(word_val(o2, m0.class_bits, m0.addrs, kk, m0.words[(j, kk)].value())
                        == word_val(m0.objs[id], m0.class_bits, m0.addrs, kk, m0.words[(j, kk)].value()));
                }
            } else {
                assert(word_ok(m0, j, kk));
            }
        }
    }
}

/// Access to heap objects. A word with the heap tag that the core reads
/// from a root (the object stack, a global, a program table) or from a
/// field of such an object designates a live object (the GC maintains this;
/// TRUSTED.md, "heap integrity"). Owns the permissions of the words the
/// verified accessors use (`HeapMem`), valid until the next call that may
/// GC (which produces new ones).
pub struct Heap {
    remembered_set_bias: usize,
    mem: Tracked<HeapMem>,
}

impl Heap {
    #[verifier::type_invariant]
    spec fn inv(&self) -> bool {
        heap_ok(self.mem@)
    }

    /// The heap model: the objects of the process as abstract heap objects
    /// (`State2::heap`, object ids are indices) ...
    pub closed spec fn objs(&self) -> Seq<HeapObj> {
        self.mem@.objs
    }

    /// ... and their current addresses (tagged words). The contracts of
    /// the accessors and of the calls that may GC (`ffi::Runtime`) relate
    /// memory to this model (TRUSTED.md, "Heap model").
    pub closed spec fn addrs(&self) -> Seq<usize> {
        self.mem@.addrs
    }

    /// The program's class bits (class tag and instance size per class id),
    /// which the objects' headers follow.
    pub closed spec fn class_bits(&self) -> Seq<u16> {
        self.mem@.class_bits
    }

    /// Word `k` of object `id` (`obj` is its address).
    #[inline(always)]
    fn read_word(&self, obj: usize, k: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            obj == self.addrs()[id],
            is_word(self.objs()[id], k as int),
        ensures word_val(self.objs()[id], self.class_bits(), self.addrs(), k as int, r),
    {
        proof {
            use_type_invariant(self);
            assert(word_ok(self.mem@, id, k as int));
            assert(obj_fits(self.mem@, id));
        }
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG, Tracked(self.mem.borrow().exposed));
        *ptr_ref(p.wrapping_add(k), Tracked(self.mem.borrow().words.tracked_borrow((id, k as int))))
    }

    /// The header word of object `id` (`read_word` of word 0, without the
    /// zero offset: `wrapping_add(0)` changes the run loop's register
    /// allocation, 5 percent more instructions on the smi loops).
    #[inline(always)]
    fn read_header(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            obj == self.addrs()[id],
        ensures word_val(self.objs()[id], self.class_bits(), self.addrs(), 0, r),
    {
        proof {
            use_type_invariant(self);
            assert(word_ok(self.mem@, id, 0));
            assert(obj_fits(self.mem@, id));
            lemma_at_index_exact(obj_ptr(self.mem@, id), 0, 0);
        }
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG, Tracked(self.mem.borrow().exposed));
        *ptr_ref(p, Tracked(self.mem.borrow().words.tracked_borrow((id, 0))))
    }

    /// Stores `w` into word `k` of object `id`, which becomes `o2` in the
    /// model (as `write_heap_word`).
    #[inline(always)]
    fn write_word(&mut self, obj: usize, k: usize, w: usize, Ghost(id): Ghost<int>, Ghost(o2): Ghost<HeapObj>)
        requires
            0 <= id < old(self).objs().len(),
            obj == old(self).addrs()[id],
            is_word(old(self).objs()[id], k as int),
            obj_words(o2) == obj_words(old(self).objs()[id]),
            forall|j: int| #[trigger] is_word(o2, j) == is_word(old(self).objs()[id], j),
            word_val(o2, old(self).class_bits(), old(self).addrs(), k as int, w),
            forall|j: int, x: usize| j != k && is_word(o2, j) ==>
                #[trigger] word_val(o2, old(self).class_bits(), old(self).addrs(), j, x)
                    == word_val(old(self).objs()[id], old(self).class_bits(), old(self).addrs(), j, x),
        ensures
            final(self).objs() == old(self).objs().update(id, o2),
            final(self).addrs() == old(self).addrs(),
            final(self).class_bits() == old(self).class_bits(),
    {
        proof {
            use_type_invariant(&*self);
            assert(obj_fits(self.mem@, id));
        }
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG, Tracked(self.mem.borrow().exposed));
        write_heap_word(Tracked(self.mem.borrow_mut()), Ghost(id), k, p.wrapping_add(k), w, Ghost(o2));
    }

    /// TRUSTED (FFI leaf: the write barrier, as the C++ `GcMetadata`
    /// remembered set): marks the card of the object at `obj` (a tagged
    /// address) in the remembered set. The card table is outside every
    /// view: no contract.
    #[verifier::external_body]
    #[inline(always)]
    fn write_barrier(&self, obj: usize) {
        unsafe {
            let card = ((obj - HEAP_TAG) >> CARD_SIZE_LOG_2).wrapping_add(self.remembered_set_bias);
            *(card as *mut u8) = NEW_SPACE_POINTERS;
        }
    }

    /// The class id of object `id` (`obj` is its address): the header's
    /// class id.
    #[inline(always)]
    pub fn class_id(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
        ensures r == self.objs()[id].class_id,
    {
        let header = self.read_header(obj, Ghost(id));
        (((header as isize) >> 1) as usize) >> CLASS_ID_OFFSET
    }

    /// The class tag of object `id`: the header's tag, which is its class'
    /// tag in the class bits.
    #[inline(always)]
    pub fn class_tag(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            (self.objs()[id].class_id as int) < self.class_bits().len(),
        ensures r == (self.class_bits()[self.objs()[id].class_id as int] & 0xf) as usize,
    {
        let header = self.read_header(obj, Ghost(id));
        (((header as isize) >> 1) as usize) & CLASS_TAG_MASK
    }

    /// Field `f` of the instance `id`: the encoding of the abstract field
    /// (`crate::abs::enc`).
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
        proof {
            use_type_invariant(self);
            assert(obj_fits(self.mem@, id));
        }
        self.read_word(obj, INSTANCE_FIELDS_WORD + f, Ghost(id))
    }

    /// Stores the encoding `w` of `v` into field `f` of the instance `id`
    /// (with the write barrier): the model's field becomes `v`.
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
        proof {
            use_type_invariant(&*self);
            assert(obj_fits(self.mem@, id));
        }
        let ghost o = self.objs()[id];
        let ghost o2 = HeapObj { body: Body::Instance(o.body->Instance_0.update(f as int, v)), ..o };
        proof {
            assert forall|j: int, x: usize| j != (INSTANCE_FIELDS_WORD + f) as int && is_word(o2, j) implies
                #[trigger] word_val(o2, self.class_bits(), self.addrs(), j, x)
                    == word_val(o, self.class_bits(), self.addrs(), j, x) by {
                if j != 0 {
                    assert(o2.body->Instance_0[j - INSTANCE_FIELDS_WORD] == o.body->Instance_0[j - INSTANCE_FIELDS_WORD]);
                }
            }
        }
        self.write_word(obj, INSTANCE_FIELDS_WORD + f, w, Ghost(id), Ghost(o2));
        self.write_barrier(obj);
    }

    /// The length of the array `id` (its length word).
    #[inline(always)]
    pub fn array_length(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: usize)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Array,
        ensures r == self.objs()[id].body->Array_0.len(),
    {
        self.read_word(obj, ARRAY_LENGTH_WORD, Ghost(id))
    }

    /// Element `i` of the array `id`: the encoding of the abstract element.
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
        proof {
            use_type_invariant(self);
            assert(obj_fits(self.mem@, id));
        }
        self.read_word(obj, ARRAY_ELEMENTS_WORD + i, Ghost(id))
    }

    /// Stores the encoding `w` of `v` into element `i` of the array `id`
    /// (with the write barrier): the model's element becomes `v`.
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
        proof {
            use_type_invariant(&*self);
            assert(obj_fits(self.mem@, id));
        }
        let ghost o = self.objs()[id];
        let ghost o2 = HeapObj { body: Body::Array(o.body->Array_0.update(i as int, v)), ..o };
        proof {
            assert forall|j: int, x: usize| j != (ARRAY_ELEMENTS_WORD + i) as int && is_word(o2, j) implies
                #[trigger] word_val(o2, self.class_bits(), self.addrs(), j, x)
                    == word_val(o, self.class_bits(), self.addrs(), j, x) by {
                if j >= ARRAY_ELEMENTS_WORD {
                    assert(o2.body->Array_0[j - ARRAY_ELEMENTS_WORD] == o.body->Array_0[j - ARRAY_ELEMENTS_WORD]);
                }
            }
        }
        self.write_word(obj, ARRAY_ELEMENTS_WORD + i, w, Ghost(id), Ghost(o2));
        self.write_barrier(obj);
    }

    /// The 64-bit payload of the double or large integer `id`: its value
    /// word (two words on 32-bit targets).
    #[cfg(target_pointer_width = "64")]
    #[inline(always)]
    fn read_value64(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: u64)
        requires
            0 <= id < self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Double || self.objs()[id].body is LargeInt,
        ensures r == value64(self.objs()[id]),
    {
        let w = self.read_word(obj, DOUBLE_VALUE_WORD, Ghost(id));
        let ghost b = value64(self.objs()[id]);
        proof { assert(w == b as usize ==> w as u64 == b) by (bit_vector); }
        w as u64
    }

    #[cfg(target_pointer_width = "32")]
    #[inline(always)]
    fn read_value64(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: u64)
        requires
            0 <= id < self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Double || self.objs()[id].body is LargeInt,
        ensures r == value64(self.objs()[id]),
    {
        let lo = self.read_word(obj, DOUBLE_VALUE_WORD, Ghost(id));
        let hi = self.read_word(obj, DOUBLE_VALUE_WORD + 1, Ghost(id));
        let ghost b = value64(self.objs()[id]);
        proof {
            assert(lo == (b & 0xffff_ffffu64) as usize && hi == (b >> 32u64) as usize
                ==> ((lo as u64) | ((hi as u64) << 32u64)) == b) by (bit_vector);
        }
        (lo as u64) | ((hi as u64) << 32)
    }

    /// The bits of the double `id` (its value word).
    #[inline(always)]
    pub fn double_bits(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: u64)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is Double,
        ensures r == self.objs()[id].body->Double_0,
    {
        self.read_value64(obj, Ghost(id))
    }

    /// The value of the large integer `id` (its value word).
    #[inline(always)]
    pub fn large_int(&self, obj: usize, Ghost(id): Ghost<int>) -> (r: i64)
        requires
            0 <= id < self.objs().len(),
            self.addrs().len() == self.objs().len(),
            obj == self.addrs()[id],
            self.objs()[id].body is LargeInt,
        ensures r == self.objs()[id].body->LargeInt_0,
    {
        let b = self.read_value64(obj, Ghost(id));
        let ghost x = self.objs()[id].body->LargeInt_0;
        proof { assert(b == x as u64 ==> b as i64 == x) by (bit_vector); }
        b as i64
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
        proof {
            use_type_invariant(&*self);
            assert(obj_fits(self.mem@, d));
            assert(obj_fits(self.mem@, s));
        }
        let pd: *mut usize = with_exposed_provenance(dst - HEAP_TAG, Tracked(self.mem.borrow().exposed));
        let ps: *mut usize = with_exposed_provenance(src - HEAP_TAG, Tracked(self.mem.borrow().exposed));
        let pd = pd.wrapping_add(ARRAY_ELEMENTS_WORD + to);
        let ps = ps.wrapping_add(ARRAY_ELEMENTS_WORD + from);
        copy_elements(Tracked(self.mem.borrow_mut()), pd, ps, n, to, from, Ghost(d), Ghost(s));
        if n != 0 {
            self.write_barrier(dst);
        }
    }
}

/// TRUSTED (FFI leaf: the C library's memmove, `core::ptr::copy`, stated
/// on the permissions): moves the values of the words `(s, sk..sk+n)` to
/// the words `(d, dk..dk+n)` through their pointers `src` and `dst`; every
/// other permission is unchanged.
#[verifier::external_body]
#[inline(always)]
fn heap_memmove(Tracked(words): Tracked<&mut Map<(int, int), PointsTo<usize>>>, dst: *mut usize, src: *mut usize,
                n: usize, Ghost(d): Ghost<int>, Ghost(dk): Ghost<int>, Ghost(s): Ghost<int>, Ghost(sk): Ghost<int>)
    requires
        forall|k: int| 0 <= k < n ==> #[trigger] old(words).contains_key((d, dk + k))
            && old(words)[(d, dk + k)].ptr() == at_index(dst, k) && old(words)[(d, dk + k)].is_init(),
        forall|k: int| 0 <= k < n ==> #[trigger] old(words).contains_key((s, sk + k))
            && old(words)[(s, sk + k)].ptr() == at_index(src, k) && old(words)[(s, sk + k)].is_init(),
    ensures
        final(words).dom() == old(words).dom(),
        forall|key: (int, int)| old(words).contains_key(key) ==>
            #[trigger] final(words)[key].ptr() == old(words)[key].ptr()
            && final(words)[key].is_init() == old(words)[key].is_init(),
        forall|key: (int, int)| !(key.0 == d && dk <= key.1 < dk + n) ==>
            #[trigger] final(words)[key] == old(words)[key],
        forall|k: int| 0 <= k < n ==>
            #[trigger] final(words)[(d, dk + k)].value() == old(words)[(s, sk + k)].value(),
    no_unwind
{
    // SAFETY: both ranges are permissions' words (inside their objects).
    unsafe { core::ptr::copy(src, dst, n) }
}

/// The elements of `array_copy`: the memmove and the model's new array.
#[inline(always)]
fn copy_elements(Tracked(m): Tracked<&mut HeapMem>, pd: *mut usize, ps: *mut usize, n: usize, to: usize, from: usize,
                 Ghost(d): Ghost<int>, Ghost(s): Ghost<int>)
    requires
        heap_ok(*old(m)),
        0 <= d < old(m).objs.len(),
        0 <= s < old(m).objs.len(),
        old(m).objs[d].body is Array,
        old(m).objs[s].body is Array,
        to + n <= old(m).objs[d].body->Array_0.len(),
        from + n <= old(m).objs[s].body->Array_0.len(),
        pd == at_index(obj_ptr(*old(m), d), ARRAY_ELEMENTS_WORD + to),
        ps == at_index(obj_ptr(*old(m), s), ARRAY_ELEMENTS_WORD + from),
    ensures
        heap_ok(*final(m)),
        final(m).objs == old(m).objs.update(d, HeapObj {
            body: Body::Array(Seq::new(old(m).objs[d].body->Array_0.len(), |k: int|
                if to <= k < to + n { old(m).objs[s].body->Array_0[k - to + from] }
                else { old(m).objs[d].body->Array_0[k] })),
            ..old(m).objs[d]
        }),
        final(m).addrs == old(m).addrs,
        final(m).class_bits == old(m).class_bits,
        final(m).exposed == old(m).exposed,
    no_unwind
{
    let ghost m0 = *m;
    let ghost dk = (ARRAY_ELEMENTS_WORD + to) as int;
    let ghost sk = (ARRAY_ELEMENTS_WORD + from) as int;
    proof {
        assert forall|k: int| 0 <= k < n implies #[trigger] m0.words.contains_key((d, dk + k))
            && m0.words[(d, dk + k)].ptr() == at_index(pd, k) && m0.words[(d, dk + k)].is_init() by {
            assert(word_ok(m0, d, dk + k));
            lemma_at_index_move(obj_ptr(m0, d), dk, k);
        }
        assert forall|k: int| 0 <= k < n implies #[trigger] m0.words.contains_key((s, sk + k))
            && m0.words[(s, sk + k)].ptr() == at_index(ps, k) && m0.words[(s, sk + k)].is_init() by {
            assert(word_ok(m0, s, sk + k));
            lemma_at_index_move(obj_ptr(m0, s), sk, k);
        }
    }
    heap_memmove(Tracked(&mut m.words), pd, ps, n, Ghost(d), Ghost(dk), Ghost(s), Ghost(sk));
    proof {
        let od = m0.objs[d];
        let e0 = od.body->Array_0;
        let es = m0.objs[s].body->Array_0;
        let e1 = Seq::new(e0.len(), |k: int| if to <= k < to + n { es[k - to + from] } else { e0[k] });
        let o2 = HeapObj { body: Body::Array(e1), ..od };
        m.objs = m0.objs.update(d, o2);
        assert forall|j: int| 0 <= j < m.objs.len() implies #[trigger] obj_fits(*m, j) by {
            assert(obj_fits(m0, j));
        }
        assert forall|j: int, kk: int| 0 <= j < m.objs.len() && is_word(m.objs[j], kk) implies
            #[trigger] word_ok(*m, j, kk) by {
            assert(obj_ptr(*m, j) == obj_ptr(m0, j));
            if j == d {
                assert(is_word(od, kk));
            }
            assert(word_ok(m0, j, kk));
            assert(m.words.contains_key((j, kk)));
            assert(m.words[(j, kk)].ptr() == m0.words[(j, kk)].ptr());
            assert(m.words[(j, kk)].is_init());
            if j == d && dk <= kk < dk + n {
                let k = kk - dk;
                assert(m.words[(d, dk + k)].value() == m0.words[(s, sk + k)].value());
                assert(is_word(m0.objs[s], sk + k));
                assert(word_ok(m0, s, sk + k));
                assert(e1[kk - ARRAY_ELEMENTS_WORD] == es[kk - ARRAY_ELEMENTS_WORD - to + from]);
                assert(word_val(o2, m.class_bits, m.addrs, kk, m.words[(j, kk)].value()));
            } else {
                assert(m.words[(j, kk)] == m0.words[(j, kk)]);
                if j == d && kk >= ARRAY_ELEMENTS_WORD {
                    assert(e1[kk - ARRAY_ELEMENTS_WORD] == e0[kk - ARRAY_ELEMENTS_WORD]);
                }
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
    /// TRUSTED (derivation point, at entry; the calls that may GC produce
    /// the heap after them by their contracts): the process' heap is well
    /// formed (V2): every object of the heap model (the ghost state the run
    /// loop's precondition names) lies at its address with the header,
    /// fields, length and elements `view::word_val` states, in the address
    /// space and accessed by nothing else while the core runs: the
    /// permissions of those words.
    pub fn new(remembered_set_bias: usize) -> Self {
        Heap { remembered_set_bias, mem: Tracked::assume_new() }
    }
}

impl Preemption {
    /// # Safety
    /// `watermark` must point to the interpreter's `std::atomic<Object**>`.
    pub unsafe fn from_raw(watermark: *const AtomicUsize) -> Self {
        Preemption { watermark }
    }
}

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

/// A read-only table of `T` (program data: immutable while the program
/// runs).
#[verifier::external_body]
#[verifier::reject_recursive_types(T)]
pub struct Table<T> {
    ptr: *const T,
    len: usize,
}

impl<T: Copy> Table<T> {
    pub uninterp spec fn view(&self) -> Seq<T>;

    /// The identity of this view (the cursors into it carry it).
    pub uninterp spec fn sid(&self) -> int;

    #[verifier::external_body]
    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn at(&self, i: usize) -> (r: T)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        unsafe { *self.ptr.add(i) }
    }
}

impl Table<u8> {
    /// The cursor at index `i` (wrapping address arithmetic; reading
    /// through it requires the index to lie in the table, `Ip::byte`).
    #[verifier::external_body]
    #[inline(always)]
    pub fn cursor(&self, i: usize) -> (r: Ip)
        ensures r@ == i, r.sid() == self.sid(),
    {
        Cursor { ptr: self.ptr.wrapping_add(i) as *mut u8 }
    }
}

/// The global variables of the process (mutable words, GC roots).
#[verifier::external_body]
pub struct Globals {
    ptr: *mut usize,
    len: usize,
}

impl Globals {
    pub uninterp spec fn view(&self) -> Seq<usize>;

    #[verifier::external_body]
    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn at(&self, i: usize) -> (r: usize)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        unsafe { *self.ptr.add(i) }
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn set(&mut self, i: usize, v: usize)
        requires i < old(self)@.len(),
        ensures final(self)@ == old(self)@.update(i as int, v),
    {
        unsafe { *self.ptr.add(i) = v }
    }
}

/// The array of the running task's Stack object: frame records at the
/// bottom, the object stack at the top. Only valid until the next call that
/// may GC (those consume it).
#[verifier::external_body]
pub struct StackMem {
    /// Untagged address of the Stack object.
    object: *mut usize,
    /// Address of array element 0.
    array: *mut usize,
    len: usize,
}

impl StackMem {
    pub uninterp spec fn view(&self) -> Seq<usize>;

    /// The identity of this view of the stack array: the cursors (`Slot`)
    /// derived from it carry it, and only a view with the same identity can
    /// be read or written through them. The accessors below keep it; a view
    /// replaced at a GC point (`ffi::Runtime`) has an identity no contract
    /// relates to the old one, so cursors into the old array are unusable
    /// (the type-level form of "no pointer survives a GC point").
    pub uninterp spec fn sid(&self) -> int;

    #[verifier::external_body]
    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    /// The cursor at array index `i` (`i == len` is the end, not readable).
    #[verifier::external_body]
    #[inline(always)]
    pub fn slot(&self, i: usize) -> (r: Slot)
        requires i <= self@.len(),
        ensures r@ == i, r.sid() == self.sid(),
    {
        Cursor { ptr: self.array.wrapping_add(i) }
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

    /// Copies `n` words from `from..from+n` to `to..to+n` (memmove).
    #[verifier::external_body]
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
        unsafe { core::ptr::copy(self.array.add(from), self.array.add(to), n) }
    }

    /// The header words of the Stack object (outside the array): word
    /// `word` of the object. The core keeps the task's top, frame top and
    /// bci there (`STACK_TOP_WORD`, `STACK_FRAME_TOP_WORD`,
    /// `STACK_BCI_WORD`) across calls that may GC.
    pub uninterp spec fn hdr(&self, word: usize) -> usize;

    /// The header fields the core keeps up to date (top, frame top, bci).
    #[verifier::external_body]
    #[inline(always)]
    pub fn header(&self, word: usize) -> (r: usize)
        requires word == STACK_TOP_WORD || word == STACK_RECORD_TOP_WORD || word == STACK_BCI_WORD,
        ensures r == self.hdr(word),
    {
        unsafe { *self.object.add(word) }
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn set_header(&mut self, word: usize, v: usize)
        requires word == STACK_TOP_WORD || word == STACK_RECORD_TOP_WORD || word == STACK_BCI_WORD,
        ensures
            final(self)@ == old(self)@,
            final(self).sid() == old(self).sid(),
            final(self).hdr(word) == v,
            forall|w: usize| w != word ==> #[trigger] final(self).hdr(w) == old(self).hdr(w),
    {
        unsafe { *self.object.add(word) = v }
    }
}

/// A cursor into the elements of a view: a pointer to element `self@` of
/// the view with identity `sid()`. The run loop keeps the object-stack top,
/// the top frame's limit, the frame top and the array end (`Slot`, into a
/// `StackMem`) and the instruction pointer (`Ip`, into the bytecodes) in
/// cursors (registers), so that a slot access or an operand fetch is one
/// load relative to a register. Arithmetic on a cursor is plain address
/// arithmetic (wrapping, never dereferenced by itself); reads and writes
/// require the index to lie in the view the cursor belongs to (cursors are
/// created only by `StackMem::slot` and `Table::<u8>::cursor`).
#[derive(Clone, Copy)]
pub struct Cursor<T> {
    ptr: *mut T,
}

/// A cursor into the stack array.
pub type Slot = Cursor<usize>;

/// A cursor into the bytecodes: the instruction pointer.
pub type Ip = Cursor<u8>;

impl<T> Cursor<T> {
    pub uninterp spec fn view(&self) -> int;

    pub uninterp spec fn sid(&self) -> int;

    /// The cursor `k` elements further (negative: towards index 0).
    #[verifier::external_body]
    #[inline(always)]
    pub fn offset(self, k: isize) -> (r: Cursor<T>)
        ensures r@ == self@ + k, r.sid() == self.sid(),
    {
        Cursor { ptr: self.ptr.wrapping_offset(k) }
    }

    /// The number of elements from `o` to `self` (cursors of the same view,
    /// less than 2^28 elements apart).
    #[verifier::external_body]
    #[inline(always)]
    pub fn diff(self, o: Cursor<T>) -> (r: usize)
        requires self.sid() == o.sid(), 0 <= o@ <= self@, self@ - o@ < 0x1000_0000,
        ensures r == self@ - o@,
    {
        ((self.ptr as usize).wrapping_sub(o.ptr as usize)) / core::mem::size_of::<T>()
    }
}

impl Cursor<u8> {
    /// Byte `self@ + k` of the table (the bytecodes).
    #[verifier::external_body]
    #[inline(always)]
    pub fn byte(self, k: usize, t: &Table<u8>) -> (r: u8)
        requires self.sid() == t.sid(), 0 <= self@ + k < t@.len(),
        ensures r == t@[self@ + k],
    {
        unsafe { *self.ptr.wrapping_add(k) }
    }
}

impl Cursor<usize> {
    /// Element `self@ + n` of the view.
    #[verifier::external_body]
    #[inline(always)]
    pub fn read(self, n: usize, mem: &StackMem) -> (r: usize)
        requires self.sid() == mem.sid(), 0 <= self@ + n < mem@.len(),
        ensures r == mem@[self@ + n],
    {
        unsafe { *self.ptr.wrapping_add(n) }
    }

    /// Stores `v` into element `self@ + n` of the view.
    #[verifier::external_body]
    #[inline(always)]
    pub fn write(self, n: usize, v: usize, mem: &mut StackMem)
        requires self.sid() == old(mem).sid(), 0 <= self@ + n < old(mem)@.len(),
        ensures
            final(mem)@ == old(mem)@.update(self@ + n, v),
            final(mem).sid() == old(mem).sid(),
            forall|w: usize| #[trigger] final(mem).hdr(w) == old(mem).hdr(w),
    {
        unsafe { *self.ptr.wrapping_add(n) = v }
    }
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

// Constructors are invisible to the verifier (they create the views).
impl<T> Table<T> {
    /// # Safety
    /// `ptr..ptr+len` must be valid, aligned and immutable while the view
    /// lives.
    pub unsafe fn from_raw(ptr: *const T, len: usize) -> Self {
        Table { ptr, len }
    }
}

impl Globals {
    /// # Safety
    /// `ptr..ptr+len` must be the process' global variables.
    pub unsafe fn from_raw(ptr: *mut usize, len: usize) -> Self {
        Globals { ptr, len }
    }
}

impl StackMem {
    /// # Safety
    /// `stack` must be the tagged pointer of the running task's Stack object
    /// and `array_word` the word offset of its array.
    pub unsafe fn from_stack(stack: usize, array_word: usize) -> Self {
        let object = (stack - HEAP_TAG) as *mut usize;
        let len = *object.add(STACK_LENGTH_WORD);
        StackMem { object, array: object.add(array_word), len }
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

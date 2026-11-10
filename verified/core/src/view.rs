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

    #[verifier::external_body]
    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(),
    {
        self.len
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn read(&self, i: usize) -> (r: usize)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        unsafe { *self.array.add(i) }
    }

    #[verifier::external_body]
    #[inline(always)]
    pub fn write(&mut self, i: usize, v: usize)
        requires i < old(self)@.len(),
        ensures final(self)@ == old(self)@.update(i as int, v),
    {
        unsafe { *self.array.add(i) = v }
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
            final(self).hdr(word) == v,
            forall|w: usize| w != word ==> #[trigger] final(self).hdr(w) == old(self).hdr(w),
    {
        unsafe { *self.object.add(word) = v }
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
        unsafe { *((obj - HEAP_TAG) as *const u64).add(DOUBLE_VALUE_WORD) }
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
        unsafe { *((obj - HEAP_TAG) as *const i64).add(LARGE_INTEGER_VALUE_WORD) }
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
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const u32) as usize;
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
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const u32) as usize;
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

    /// The 32-bit word at byte offset `offset` of a heap object.
    #[verifier::external_body]
    #[inline(always)]
    pub fn u32_at(&self, obj: usize, offset: usize) -> (r: u32) {
        unsafe { *(((obj - HEAP_TAG) as *const u8).add(offset) as *const u32) }
    }
}

/// The preemption flag: the interpreter's watermark, set to
/// `PREEMPTION_MARKER` by the scheduler from another thread. No contract:
/// its value is environment nondeterminism.
#[verifier::external_body]
pub struct Preemption {
    watermark: *const AtomicUsize,
}

impl Preemption {
    #[verifier::external_body]
    #[inline(always)]
    pub fn requested(&self) -> bool {
        unsafe { (*self.watermark).load(Ordering::Relaxed) == PREEMPTION_MARKER }
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

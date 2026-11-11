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

//! Kani pilot for group (1) of the trusted base: the raw-pointer accessors
//! of verified/core/src/view.rs. Two accessors are copied here verbatim
//! (minus the Verus attributes and ghost parameters), with the layout
//! constants of verified/core/src/layout.rs they use:
//!
//! * `StackMem::copy_within` (memmove inside the stack array), checked
//!   against its Verus `ensures` (the exact memmove contract);
//! * `Heap::string_len` and `Heap::string_byte` (internal or external
//!   string), checked against their `ensures` on a String object laid out
//!   as the VM lays it out (the layout the layout check compares).
//!
//! The Verus `requires` become `kani::assume`, the `ensures` `assert!`.
//! What Kani proves: for every input within the stated bounds, no UB (out
//! of bounds, misaligned or dangling access, arithmetic overflow) and the
//! postcondition, on the target this is compiled for (64-bit host here).

#![allow(dead_code)]

// verified/core/src/layout.rs (64-bit values).
pub const WORD_SIZE: usize = 8;
pub const HEAP_TAG: usize = 1;
pub const STRING_INTERNAL_LENGTH_BYTE: usize = 12;
pub const STRING_CONTENT_BYTE: usize = 16;
pub const STRING_SENTINEL: usize = 65535;
pub const STRING_EXTERNAL_LENGTH_WORD: usize = 2;
pub const STRING_EXTERNAL_ADDRESS_WORD: usize = 3;
pub type HalfWord = u32;

pub struct StackMem {
    pub object: *mut usize,
    pub array: *mut usize,
    pub len: usize,
}

impl StackMem {
    /// verified/core/src/view.rs, `StackMem::copy_within` (body verbatim).
    #[inline(always)]
    pub fn copy_within(&mut self, from: usize, to: usize, n: usize) {
        unsafe { core::ptr::copy(self.array.add(from), self.array.add(to), n) }
    }
}

pub struct Heap;

impl Heap {
    /// verified/core/src/view.rs, `Heap::string_len` (body verbatim).
    #[inline(always)]
    pub fn string_len(&self, obj: usize) -> usize {
        let base = obj - HEAP_TAG;
        unsafe {
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            if internal != STRING_SENTINEL { internal } else { *(base as *const usize).add(STRING_EXTERNAL_LENGTH_WORD) }
        }
    }

    /// verified/core/src/view.rs, `Heap::string_byte` (body verbatim).
    #[inline(always)]
    pub fn string_byte(&self, obj: usize, i: usize) -> u8 {
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
}

// Harness naming: `pos_*` must verify, `neg_*` must FAIL (they check that
// the harness is not vacuous: the tool finds a violated precondition or a
// broken layout), `tool_*` reproduce a tool defect (pilot write-up, "Tool
// findings"). verified/cxx/run.sh checks the expected verdicts.
#[cfg(kani)]
mod proofs {
    use super::*;

    const LEN: usize = 6;
    // String content size: a multiple of the word size, so the struct has no
    // tail padding and a read past the content leaves the object (CBMC checks
    // bounds per object: a read into padding is not reported).
    const SLEN: usize = 8;

    /// copy_within, memory safety: requires from + n <= len and
    /// to + n <= len (Verus: mathematical integers, so no wrap).
    #[kani::proof]
    fn pos_copy_within_safe() {
        let mut array: [usize; LEN] = kani::any();
        let mut header: [usize; 4] = kani::any();
        let mut mem = StackMem { object: header.as_mut_ptr(), array: array.as_mut_ptr(), len: LEN };
        let from: usize = kani::any();
        let to: usize = kani::any();
        let n: usize = kani::any();
        kani::assume(from <= LEN && n <= LEN - from);
        kani::assume(to <= LEN && n <= LEN - to);
        mem.copy_within(from, to, n);
    }

    /// copy_within, the full `ensures` (exact memmove), with the count
    /// fixed per instance (n = 0..=3, every from/to): a symbolic count hits
    /// tool defect T2 (see tool_copy_symbolic_count).
    fn copy_within_contract(n: usize) {
        let mut array: [usize; LEN] = kani::any();
        let old = array;
        let mut header: [usize; 4] = kani::any();
        let mut mem = StackMem { object: header.as_mut_ptr(), array: array.as_mut_ptr(), len: LEN };
        let from: usize = kani::any();
        let to: usize = kani::any();
        kani::assume(from <= LEN - n && to <= LEN - n);
        mem.copy_within(from, to, n);
        let i: usize = kani::any();
        kani::assume(i < LEN);
        let expected = if to <= i && i < to + n { old[i - to + from] } else { old[i] };
        assert!(array[i] == expected);
    }

    #[kani::proof]
    fn pos_copy_within_contract_n0() { copy_within_contract(0) }
    #[kani::proof]
    fn pos_copy_within_contract_n1() { copy_within_contract(1) }
    #[kani::proof]
    fn pos_copy_within_contract_n3() { copy_within_contract(3) }

    /// With the precondition evaluated in usize (wrapping) arithmetic the
    /// accessor is unsafe: Kani reports it.
    #[kani::proof]
    fn neg_copy_within_wrapping_precondition() {
        let mut array: [usize; LEN] = kani::any();
        let mut header: [usize; 4] = kani::any();
        let mut mem = StackMem { object: header.as_mut_ptr(), array: array.as_mut_ptr(), len: LEN };
        let from: usize = kani::any();
        let to: usize = kani::any();
        let n: usize = kani::any();
        kani::assume(from.wrapping_add(n) <= LEN && to.wrapping_add(n) <= LEN);
        mem.copy_within(from, to, n);
    }

    /// Tool defect T2: ptr::copy of usize elements with a symbolic count
    /// (constrained to 1) leaves a wrong value in Kani 0.68's model; the same
    /// with u8 elements or a constant count is right. Expected to FAIL until
    /// the defect is fixed.
    #[kani::proof]
    fn tool_copy_symbolic_count() {
        let mut array: [usize; LEN] = [10, 11, 12, 13, 14, 15];
        let p = array.as_mut_ptr();
        let n: usize = kani::any();
        kani::assume(n == 1);
        unsafe { core::ptr::copy(p.add(1), p.add(4), n) }
        assert!(array[4] == 11);
    }

    /// An internal string object as src/objects.h lays it out (64-bit):
    /// header word, 32-bit hash, 32-bit length, then the content bytes.
    /// The tagged address is base + HEAP_TAG.
    #[repr(C, align(8))]
    struct InternalString {
        header: usize,
        hash_and_len: [HalfWord; 2],
        content: [u8; SLEN],
    }

    /// An external string: the length half word is the sentinel, the
    /// external length and address are words 2 and 3.
    #[repr(C, align(8))]
    struct ExternalString {
        header: usize,
        hash_and_len: [HalfWord; 2],
        length: usize,
        address: usize,
    }

    /// string_len/string_byte on an internal string: requires the object
    /// is a string of the model (here: laid out as one, length < sentinel)
    /// and i < len; ensures the model's length and byte.
    #[kani::proof]
    fn pos_string_internal() {
        let len: usize = kani::any();
        kani::assume(len <= SLEN);
        let mut s = InternalString { header: kani::any(), hash_and_len: [kani::any(), len as HalfWord], content: kani::any() };
        let obj = (&mut s as *mut InternalString as usize) + HEAP_TAG;
        let heap = Heap;
        assert!(heap.string_len(obj) == len);
        let i: usize = kani::any();
        kani::assume(i < len);
        assert!(heap.string_byte(obj, i) == s.content[i]);
    }

    #[kani::proof]
    fn pos_string_external() {
        let mut bytes: [u8; SLEN] = kani::any();
        let len: usize = kani::any();
        kani::assume(len <= SLEN);
        let mut s = ExternalString {
            header: kani::any(),
            hash_and_len: [kani::any(), STRING_SENTINEL as HalfWord],
            length: len,
            address: bytes.as_mut_ptr() as usize,
        };
        let obj = (&mut s as *mut ExternalString as usize) + HEAP_TAG;
        let heap = Heap;
        assert!(heap.string_len(obj) == len);
        let i: usize = kani::any();
        kani::assume(i < len);
        assert!(heap.string_byte(obj, i) == bytes[i]);
    }

    /// The layout assumption made visible: an internal string whose length
    /// half word is the sentinel makes the accessor read external words
    /// that aren't there. Kani reports it.
    #[kani::proof]
    fn neg_string_sentinel_in_internal_string() {
        let mut s = InternalString { header: kani::any(), hash_and_len: [kani::any(), STRING_SENTINEL as HalfWord], content: kani::any() };
        let obj = (&mut s as *mut InternalString as usize) + HEAP_TAG;
        let heap = Heap;
        let i: usize = kani::any();
        kani::assume(i < SLEN);
        let _ = heap.string_byte(obj, i);
    }

    /// Off-by-one in the precondition (i <= len): Kani reports the read
    /// past the content.
    #[kani::proof]
    fn neg_string_index_at_length() {
        let mut s = InternalString { header: kani::any(), hash_and_len: [kani::any(), SLEN as HalfWord], content: kani::any() };
        let obj = (&mut s as *mut InternalString as usize) + HEAP_TAG;
        let heap = Heap;
        let _ = heap.string_byte(obj, SLEN);
    }
}


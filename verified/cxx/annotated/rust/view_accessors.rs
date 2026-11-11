// Copyright (C) 2026 Toit contributors.
//
// VeriFast's Rust front end on two accessors of verified/core/src/view.rs
// (the copies of verified/cxx/kani/src/lib.rs: bodies verbatim, Verus
// attributes and ghost parameters dropped), with VeriFast specifications
// in the place of the Verus requires/ensures. The question: can the same
// tool that checks the C++ side check the unsafe blocks of the Rust side,
// with the same object predicate?

// verified/core/src/layout.rs (64-bit values).
pub const HEAP_TAG: usize = 1;
pub const STRING_INTERNAL_LENGTH_BYTE: usize = 12;
pub const STRING_CONTENT_BYTE: usize = 16;
pub const STRING_SENTINEL: usize = 65535;
pub const STRING_EXTERNAL_LENGTH_WORD: usize = 2;
pub const STRING_EXTERNAL_ADDRESS_WORD: usize = 3;
pub type HalfWord = u32;

/*@

// An internal string at tagged address `obj`: the 32-bit length field and
// the content, at the addresses the code computes from the integer.
pred internal_string(obj: usize, len: usize) =
    1 <= obj &*& obj + 16 + 65536 <= usize::MAX &*&
    *((obj - 1 + 12) as *u32) |-> ?l32 &*& l32 as usize == len &*& len != 65535 &*&
    ((obj - 1 + 16) as *u8)[..len] |-> ?bytes;

@*/

pub struct Heap;

impl Heap {
    /// verified/core/src/view.rs, `Heap::string_len` (body verbatim), on an
    /// internal string.
    pub unsafe fn string_len(&self, obj: usize) -> usize
    //@ req [?f]internal_string(obj, ?len);
    //@ ens [f]internal_string(obj, len) &*& result == len;
    {
        //@ open [f]internal_string(obj, len);
        let base = obj - HEAP_TAG;
        unsafe {
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            //@ close [f]internal_string(obj, len);
            if internal != STRING_SENTINEL { internal } else { *(base as *const usize).add(STRING_EXTERNAL_LENGTH_WORD) }
        }
    }

    /// verified/core/src/view.rs, `Heap::string_byte` (body verbatim), on an
    /// internal string.
    pub unsafe fn string_byte(&self, obj: usize, i: usize) -> u8
    //@ req [?f]internal_string(obj, ?len) &*& i < len;
    //@ ens [f]internal_string(obj, len);
    {
        //@ open [f]internal_string(obj, len);
        let base = obj - HEAP_TAG;
        unsafe {
            let internal = *((base + STRING_INTERNAL_LENGTH_BYTE) as *const HalfWord) as usize;
            let r = if internal != STRING_SENTINEL {
                //@ let p = (obj - 1 + 16) as *u8;
                //@ array_split(p, i);
                //@ open array(p + i, len - i, _);
                let b = *((base + STRING_CONTENT_BYTE + i) as *const u8);
                //@ close [f]array(p + i, len - i, _);
                //@ array_join(p);
                b
            } else {
                let address = *(base as *const usize).add(STRING_EXTERNAL_ADDRESS_WORD);
                *(address as *const u8).add(i)
            };
            //@ close [f]internal_string(obj, len);
            r
        }
    }
}

fn main() {}

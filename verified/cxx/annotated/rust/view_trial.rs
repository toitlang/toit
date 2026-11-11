// Copyright (C) 2026 Toit contributors.
//
// The like-for-like trial (verified/cxx/annotated/README.md, "The Rust
// raw-memory layer"): five accessors of verified/core/src/view.rs,
// `Heap::class_id`, `class_tag`, `field`, `array_length`, `element`, with
// their bodies VERBATIM, verified by VeriFast's Rust front end against
// predicates over the words at the computed addresses (the same objects as
// rust/verus_pptr.rs, where Verus proves them with PointsTo permissions).
// The Verus ghost parameter `id` is dropped (VeriFast has no Ghost type);
// a function with a precondition is `unsafe` (VeriFast's soundness rule).
// Host target (64-bit).

pub const HEAP_TAG: usize = 1;
pub const CLASS_ID_OFFSET: usize = 5;
pub const CLASS_TAG_MASK: usize = 0xf;
pub const INSTANCE_FIELDS_WORD: usize = 1;
pub const ARRAY_LENGTH_WORD: usize = 1;
pub const ARRAY_ELEMENTS_WORD: usize = 2;

/*@

// The header word of the object at tagged address obj.
pred header(obj: usize; hw: usize) =
    obj % 4 == 1 &*& 1 <= obj &*& obj + 8 * 0x100002 <= usize::MAX &*&
    *((obj - 1) as *usize) |-> hw;

// The n words after the header (instance fields).
pred fields(obj: usize, n: usize; ws: list<usize>) =
    obj % 4 == 1 &*& 1 <= obj &*& n <= 0x100000 &*& obj + 8 * (n + 2) <= usize::MAX &*&
    ((obj - 1 + 8) as *usize)[..n] |-> ws;

// An array: the length word, then the elements.
pred array_obj(obj: usize; len: usize, es: list<usize>) =
    obj % 4 == 1 &*& 1 <= obj &*& len <= 0x100000 &*& obj + 8 * (len + 3) <= usize::MAX &*&
    *((obj - 1 + 8) as *usize) |-> len &*&
    ((obj - 1 + 16) as *usize)[..len] |-> es;

@*/

pub struct Heap;

impl Heap {
    pub unsafe fn class_id(&self, obj: usize) -> usize
    //@ req [?f]header(obj, ?hw);
    //@ ens [f]header(obj, hw) &*& result == ((hw as isize >> 1) as usize) >> CLASS_ID_OFFSET;
    {
        //@ open [f]header(obj, hw);
        let header = unsafe { *((obj - HEAP_TAG) as *const usize) };
        //@ close [f]header(obj, hw);
        (((header as isize) >> 1) as usize) >> CLASS_ID_OFFSET
    }

    pub unsafe fn class_tag(&self, obj: usize) -> usize
    //@ req [?f]header(obj, ?hw);
    //@ ens [f]header(obj, hw) &*& result == ((hw as isize >> 1) as usize) & CLASS_TAG_MASK;
    {
        //@ open [f]header(obj, hw);
        let header = unsafe { *((obj - HEAP_TAG) as *const usize) };
        //@ close [f]header(obj, hw);
        (((header as isize) >> 1) as usize) & CLASS_TAG_MASK
    }

    pub unsafe fn field(&self, obj: usize, f: usize) -> usize
    //@ req [?q]fields(obj, ?n, ?ws) &*& f < n;
    //@ ens [q]fields(obj, n, ws) &*& result == nth(f, ws);
    {
        //@ open [q]fields(obj, n, ws);
        //@ let p = (obj - 1 + 8) as *usize;
        //@ array_split(p, f);
        //@ open array(p + f, n - f, _);
        //@ drop_n_plus_one(f, ws);
        let r = unsafe { *((obj - HEAP_TAG) as *const usize).add(INSTANCE_FIELDS_WORD + f) };
        //@ close [q]array(p + f, n - f, _);
        //@ array_join(p);
        //@ close [q]fields(obj, n, ws);
        r
    }

    pub unsafe fn array_length(&self, obj: usize) -> usize
    //@ req [?q]array_obj(obj, ?len, ?es);
    //@ ens [q]array_obj(obj, len, es) &*& result == len;
    {
        //@ open [q]array_obj(obj, len, es);
        let r = unsafe { *((obj - HEAP_TAG) as *const usize).add(ARRAY_LENGTH_WORD) };
        //@ close [q]array_obj(obj, len, es);
        r
    }

    pub unsafe fn element(&self, obj: usize, i: usize) -> usize
    //@ req [?q]array_obj(obj, ?len, ?es) &*& i < len;
    //@ ens [q]array_obj(obj, len, es) &*& result == nth(i, es);
    {
        //@ open [q]array_obj(obj, len, es);
        //@ let p = (obj - 1 + 16) as *usize;
        //@ array_split(p, i);
        //@ open array(p + i, len - i, _);
        //@ drop_n_plus_one(i, es);
        let r = unsafe { *((obj - HEAP_TAG) as *const usize).add(ARRAY_ELEMENTS_WORD + i) };
        //@ close [q]array(p + i, len - i, _);
        //@ array_join(p);
        //@ close [q]array_obj(obj, len, es);
        r
    }
}

fn main() {}

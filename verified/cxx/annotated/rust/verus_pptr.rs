// Copyright (C) 2026 Toit contributors.
//
// The like-for-like trial (verified/cxx/annotated/README.md, "The Rust
// raw-memory layer"): five accessors of verified/core/src/view.rs (bodies
// verbatim, `Heap::class_id`, `class_tag`, `field`, `array_length`,
// `element`) proved INSIDE Verus with raw-pointer permissions
// (vstd::raw_ptr: PointsTo, IsExposed), instead of external_body. Same
// objects as rust/view_trial.rs (VeriFast's Rust front end): one header
// word, the instance fields, the array length and elements, each word a
// PointsTo at the address the code computes from the tagged address.
//
// The heap is exposed memory: integer-to-pointer casts take the provenance
// from an IsExposed token (`with_exposed_provenance`), as the VM does.
// Run: verus --crate-type=lib verus_pptr.rs

use vstd::prelude::*;
use vstd::raw_ptr::*;

verus! {

pub const HEAP_TAG: usize = 1;
pub const CLASS_ID_OFFSET: usize = 5;
pub const CLASS_TAG_MASK: usize = 0xf;
pub const INSTANCE_FIELDS_WORD: usize = 1;
pub const ARRAY_LENGTH_WORD: usize = 1;
pub const ARRAY_ELEMENTS_WORD: usize = 2;

/// The memory of one object, as permissions: the header word, and the words
/// after it (fields of an instance; the length and the elements of an
/// array), each at its address from the object's untagged address.
pub tracked struct ObjMem {
    pub tracked exposed: IsExposed,
    pub tracked words: Map<int, PointsTo<usize>>,
}

pub open spec fn word_ok(m: ObjMem, obj: usize, k: int) -> bool {
    &&& m.words.contains_key(k)
    &&& m.words[k].ptr() == ptr_mut_from_data::<usize>(PtrData::<usize> {
            addr: (obj - HEAP_TAG + k * 8) as usize, provenance: m.exposed.provenance(), metadata: () })
    &&& m.words[k].is_init()
}

pub open spec fn obj_ok(m: ObjMem, obj: usize, n: int) -> bool {
    &&& obj & 3 == 1
    &&& 1 <= obj
    &&& obj + 8 * (n + 2) <= usize::MAX
    &&& forall|k: int| 0 <= k < n ==> #[trigger] word_ok(m, obj, k)
}

pub struct Heap;

impl Heap {
    /// view.rs `Heap::class_id`: the header's class id.
    pub fn class_id(&self, obj: usize, Tracked(m): Tracked<&ObjMem>) -> (r: usize)
        requires obj_ok(*m, obj, 1),
        ensures r == ((m.words[0].value() as isize >> 1) as usize) >> CLASS_ID_OFFSET,
    {
        assert(word_ok(*m, obj, 0));
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG, Tracked(m.exposed));
        let header = *ptr_ref(p, Tracked(m.words.tracked_borrow(0)));
        (((header as isize) >> 1) as usize) >> CLASS_ID_OFFSET
    }

    /// view.rs `Heap::class_tag`: the header's class tag.
    pub fn class_tag(&self, obj: usize, Tracked(m): Tracked<&ObjMem>) -> (r: usize)
        requires obj_ok(*m, obj, 1),
        ensures r == ((m.words[0].value() as isize >> 1) as usize) & CLASS_TAG_MASK,
    {
        assert(word_ok(*m, obj, 0));
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG, Tracked(m.exposed));
        let header = *ptr_ref(p, Tracked(m.words.tracked_borrow(0)));
        (((header as isize) >> 1) as usize) & CLASS_TAG_MASK
    }

    /// view.rs `Heap::field`: field f of an instance with n fields.
    pub fn field(&self, obj: usize, f: usize, Ghost(n): Ghost<int>, Tracked(m): Tracked<&ObjMem>) -> (r: usize)
        requires obj_ok(*m, obj, n + 1), f < n,
        ensures r == m.words[INSTANCE_FIELDS_WORD + f].value(),
    {
        let k = INSTANCE_FIELDS_WORD + f;
        assert(word_ok(*m, obj, k as int));
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG + k * 8, Tracked(m.exposed));
        *ptr_ref(p, Tracked(m.words.tracked_borrow(k as int)))
    }

    /// view.rs `Heap::array_length`: the length word of an array.
    pub fn array_length(&self, obj: usize, Tracked(m): Tracked<&ObjMem>) -> (r: usize)
        requires obj_ok(*m, obj, 2),
        ensures r == m.words[ARRAY_LENGTH_WORD as int].value(),
    {
        assert(word_ok(*m, obj, 1));
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG + ARRAY_LENGTH_WORD * 8, Tracked(m.exposed));
        *ptr_ref(p, Tracked(m.words.tracked_borrow(ARRAY_LENGTH_WORD as int)))
    }

    /// view.rs `Heap::element`: element i of an array of length len.
    pub fn element(&self, obj: usize, i: usize, Ghost(len): Ghost<int>, Tracked(m): Tracked<&ObjMem>) -> (r: usize)
        requires obj_ok(*m, obj, len + 2), i < len,
        ensures r == m.words[ARRAY_ELEMENTS_WORD + i].value(),
    {
        let k = ARRAY_ELEMENTS_WORD + i;
        assert(word_ok(*m, obj, k as int));
        let p: *mut usize = with_exposed_provenance(obj - HEAP_TAG + k * 8, Tracked(m.exposed));
        *ptr_ref(p, Tracked(m.words.tracked_borrow(k as int)))
    }
}

} // verus!

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

//! Heap updates that keep the heap well formed: replacing an ordinary
//! object by one of the same class and kind, and writing a field.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_upto::*;
#[cfg(verus_only)]
use crate::spec_common::{is_instance, fields, obj, obj_id};

verus! {

/// An object that is not a suspended task.
pub open spec fn ordinary(o: HeapObj) -> bool {
    !(o.body is Stack2)
}

/// Replacing an ordinary object by an ordinary object of the same class
/// whose contents are values (and that keeps the fields of a task the
/// machine owns) keeps the heap well formed.
pub proof fn lemma_heap_update(p: Program2, c: Cert, h: Seq<HeapObj>, id: int, o2: HeapObj)
    requires
        heap_ok(p, c, h),
        0 <= id < h.len(),
        o2.class_id == h[id].class_id,
        ordinary(h[id]),
        ordinary(o2),
        basic_obj_ok(p, h, o2),
        h[id].class_id as int == task_class(p) ==> task_fields_kept(h[id], o2),
    ensures
        heap_ok(p, c, h.update(id, o2)),
        heap_ext(p, h, h.update(id, o2)),
        h.update(id, o2).len() == h.len(),
{
    let h2 = h.update(id, o2);
    assert forall|i: int| 0 <= i < h.len() && h[i].class_id as int == task_class(p) implies
        task_fields_kept(h[i], #[trigger] h2[i]) by {
        if i != id { lemma_kept_refl(h[i]); }
    }
    assert(heap_ext(p, h, h2));
    reveal(heap_ok);
    assert forall|i: int| 0 <= i < h2.len() implies #[trigger] obj_ok(p, c, h2, h2[i]) by {
        if i != id {
            assert(obj_ok(p, c, h, h[i]));
            lemma_obj_ok_mono(p, c, h, h2, h[i]);
        } else {
            if o2.class_id as int == task_class(p) {
                assert(obj_ok(p, c, h, h[id]));
                assert(task_obj_ok(h, h[id]));
                match (h[id].body, o2.body) {
                    (Body::Instance(f), Body::Instance(f2)) => {
                        assert(f2[0] == f[0] && f2[1] == f[1]);
                        match f[0] {
                            Value::Obj(j) => {
                                if (j as int) < h.len() && h[j as int].body is Stack2 {
                                    assert(j as int != id);
                                    assert(h2[j as int] == h[j as int]);
                                }
                            },
                            _ => {},
                        }
                        assert(task_obj_ok(h2, o2));
                    },
                    _ => {},
                }
            }
            match o2.body {
                Body::Instance(f) => {
                    assert forall|j: int| 0 <= j < f.len() implies good(h2, #[trigger] f[j]) by {
                        assert(good(h, f[j]));
                    }
                },
                Body::Array(e) => {
                    assert forall|j: int| 0 <= j < e.len() implies good(h2, #[trigger] e[j]) by {
                        assert(good(h, e[j]));
                    }
                },
                _ => {},
            }
        }
    }
}

/// Writing a value into an existing field of an instance (not a field of
/// a task the machine owns).
pub proof fn lemma_set_field2(p: Program2, c: Cert, s: State2, inst: Value, f: int, v: Value)
    requires
        heap_ok(p, c, s.heap),
        field_ok(s, inst, f),
        !(is_task_obj(p, s, inst) && f <= TASK_ID_FIELD),
        good(s.heap, v),
    ensures
        heap_ok(p, c, set_field2(s, inst, f, v).heap),
        heap_ext(p, s.heap, set_field2(s, inst, f, v).heap),
        set_field2(s, inst, f, v).heap.len() == s.heap.len(),
        set_field2(s, inst, f, v) == with_heap(s, set_field2(s, inst, f, v).heap),
{
    let id = obj_id(inst);
    let o = obj(as1(s), inst);
    let fs = fields(as1(s), inst);
    let o2 = HeapObj { body: Body::Instance(fs.update(f, v)), ..o };
    assert(o == s.heap[id]);
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    assert(basic_obj_ok(p, s.heap, o2)) by {
        assert forall|j: int| 0 <= j < fs.update(f, v).len() implies good(s.heap, #[trigger] fs.update(f, v)[j]) by {
            if j != f { assert(good(s.heap, fs[j])); }
        }
    }
    if o.class_id as int == task_class(p) {
        assert(is_task_obj(p, s, inst));
        assert(f >= 2);
        assert(fs.update(f, v)[0] == fs[0] && fs.update(f, v)[1] == fs[1]);
    }
    lemma_heap_update(p, c, s.heap, id, o2);
}

} // verus!

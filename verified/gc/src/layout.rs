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

//! Object layouts: the size of an object and its range of reference slots,
//! computed from its raw words (the header and, for some kinds, a length
//! word). The collector depends on layouts only through `lay`, `obj_ok`
//! and `obj_layout`.
//!
//! Milestone M1 layout (the pilot's three kinds, decoded from the header):
//! bit 0 of the header is clear (a forwarding header is a tagged address,
//! bit 0 set); kind `(h / 2) % 4`: 0 an instance with `h / 8` reference
//! fields; 1 an array (a length word, then reference elements); 2 and 3 a
//! raw object (a length word, then raw words).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;

verus! {

/// Size in words, and the reference slots `lo..hi`.
pub struct Lay {
    pub size: int,
    pub lo: int,
    pub hi: int,
}

pub open spec fn hdr(o: AObj) -> usize { raw(o.words[0]) }

pub open spec fn kind(h: usize) -> int { (h as int / 2) % 4 }

pub open spec fn lay(o: AObj) -> Lay {
    let h = hdr(o);
    if kind(h) == 0 {
        Lay { size: 1 + h as int / 8, lo: 1, hi: 1 + h as int / 8 }
    } else if kind(h) == 1 {
        Lay { size: 2 + raw(o.words[1]) as int, lo: 2, hi: 2 + raw(o.words[1]) as int }
    } else {
        Lay { size: 2 + raw(o.words[1]) as int, lo: 2 + raw(o.words[1]) as int, hi: 2 + raw(o.words[1]) as int }
    }
}

/// The object agrees with its layout: its words, a raw even header, raw
/// words outside the reference slots.
pub open spec fn obj_ok(o: AObj) -> bool {
    let l = lay(o);
    &&& o.words.len() == l.size
    &&& 1 <= l.lo <= l.hi <= l.size
    &&& o.words[0] is Raw
    &&& hdr(o) % 2 == 0
    &&& forall|k: int| 0 <= k < l.size && !(l.lo <= k < l.hi) ==> #[trigger] o.words[k] is Raw
}

/// The raw words of the object at offset `off` of page `pg` (base pointer
/// `page`) in `m` are the object's.
pub open spec fn raw_words_at(m: Map<(int, int), PointsTo<usize>>, page: *mut usize, pg: int, off: int, o: AObj) -> bool {
    forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw ==>
        wperm_ok(m, (pg, off + k), page, off + k) && m[(pg, off + k)].is_init()
        && m[(pg, off + k)].value() == raw(o.words[k])
}

/// The layout of the object at offset `off` of page `pg`, read from its
/// raw words: (size, lo, hi).
pub fn obj_layout(page: *mut usize, off: usize, Ghost(pg): Ghost<int>, Tracked(m): Tracked<&Map<(int, int), PointsTo<usize>>>,
                  Ghost(o): Ghost<AObj>, Ghost(pw): Ghost<int>) -> (r: (usize, usize, usize))
    requires
        obj_ok(o),
        off + lay(o).size <= pw,
        page@.addr + pw * W <= usize::MAX,
        raw_words_at(*m, page, pg, off as int, o),
    ensures
        r.0 == lay(o).size, r.1 == lay(o).lo, r.2 == lay(o).hi,
{
    proof {
        lemma_w();
        assert(o.words[0] is Raw);
        assert(off * W <= pw * W) by (nonlinear_arith) requires off <= pw, W > 0;
        assert(pw <= usize::MAX) by (nonlinear_arith) requires page@.addr + pw * W <= usize::MAX, W >= 1, page@.addr >= 0;
    }
    let h = rd(page, off, Ghost((pg, off as int)), Tracked(m));
    proof { assert(h == hdr(o)); }
    if (h / 2) % 4 == 0 {
        let n = h / 8;
        (1 + n, 1, 1 + n)
    } else {
        proof {
            assert(1 < lay(o).lo);
            assert(o.words[1] is Raw);
            assert((off + 1) * W <= pw * W) by (nonlinear_arith) requires off + 1 <= pw, W > 0;
        }
        let n = rd(page, off + 1, Ghost((pg, off + 1)), Tracked(m));
        if (h / 2) % 4 == 1 {
            (2 + n, 2, 2 + n)
        } else {
            (2 + n, 2 + n, 2 + n)
        }
    }
}

} // verus!

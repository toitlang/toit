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

//! Slot conformance only depends on the frames up to the slot's frame:
//! transfer lemmas used when frames are popped, pushed or cut, and when a
//! frame's kinds grow.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of};

verus! {

/// Frames `0..=fi` are the same in `s2`, the first `n` slots of frame
/// `fi` and everything below them are the same in both, and the heap only
/// grew.
pub open spec fn same_upto(s: State2, s2: State2, fi: int, n: int) -> bool {
    &&& 0 <= fi < s.frames.len() && fi < s2.frames.len()
    &&& forall|g: int| 0 <= g <= fi ==> #[trigger] s2.frames[g] == s.frames[g]
    &&& 0 <= n
    &&& fbase(s, fi) + n <= limit(s, fi)
    &&& fbase(s, fi) + n <= limit(s2, fi)
    &&& limit(s, fi) <= s.stack.len()
    &&& limit(s2, fi) <= s2.stack.len()
    &&& forall|x: int| 0 <= x < fbase(s, fi) + n ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& heap_grows(s.heap, s2.heap)
}

pub proof fn lemma_upto_kinds(p: Program2, c: Cert, s: State2, s2: State2, fi: int, n: int, f: int)
    requires same_upto(s, s2, fi, n), 0 <= f < fi,
    ensures
        kinds_of(p, c, s2, f) == kinds_of(p, c, s, f),
        slots(s2, f) == slots(s, f),
        limit(s2, f) == limit(s, f),
        fbase(s2, f) == fbase(s, f),
        fmethod(s2, f) == fmethod(s, f),
{
    assert(s2.frames[f] == s.frames[f]);
    assert(s2.frames[f + 1] == s.frames[f + 1]);
    assert(top_i(s) != f && top_i(s2) != f);
}

/// The context chain from frame `g <= fi` is the same (when it exists;
/// for `g == fi` it reads slot 0 of frame `fi`, which needs `n >= 1`).
pub proof fn lemma_context_frame_upto(s: State2, s2: State2, fi: int, n: int, g: int, d: nat)
    requires
        same_upto(s, s2, fi, n), bases_ok(s), 0 <= g <= fi, context_frame(s, g, d) >= 0,
        g == fi && d > 0 ==> n >= 1,
    ensures context_frame(s2, g, d) == context_frame(s, g, d),
    decreases d,
{
    if d > 0 {
        assert(s2.frames[g] == s.frames[g]);
        assert(0 <= g < s.frames.len() && slots(s, g) >= 1 && 0 <= fbase(s, g) < s.stack.len());
        if g < fi {
            assert(s2.frames[g + 1] == s.frames[g + 1]);
            lemma_bases_mono(s, g + 1, fi);
            assert(limit(s, g) <= fbase(s, fi));
            assert(limit(s2, g) == limit(s, g));
            assert(fbase(s, g) < fbase(s, fi) + n);
        } else {
            assert(fbase(s, g) < fbase(s, fi) + n);
            assert(slots(s2, g) >= 1);
        }
        assert(s2.stack[fbase(s, g)] == s.stack[fbase(s, g)]);
        match s.stack[fbase(s, g)] {
            Value::BlockRef(f, _) => if (f as int) < g {
                lemma_context_frame_upto(s, s2, fi, n, f as int, (d - 1) as nat);
            },
            _ => {},
        }
    }
}

pub proof fn lemma_ref_ok_upto(s: State2, s2: State2, fi: int, n: int, f: int, slot: int)
    requires
        same_upto(s, s2, fi, n), 0 <= f <= fi, ref_ok(s, f, slot), bases_ok(s),
        f == fi ==> slot < fbase(s, fi) + n,
    ensures ref_ok(s2, f, slot),
{
    assert(s2.frames[f] == s.frames[f]);
    if f < fi {
        assert(s2.frames[f + 1] == s.frames[f + 1]);
        lemma_bases_mono(s, f + 1, fi);
        assert(base_step(s, fi) || fi + 1 >= s.frames.len());
        if fi + 1 < s.frames.len() { assert(base_step(s, fi)); }
    }
}

/// A conforming slot `j < n` of frame `fi` still conforms (with the same
/// frame kinds `kf`) when a local block reference in it points below `n`.
pub proof fn lemma_conf_upto(p: Program2, c: Cert, s: State2, s2: State2, fi: int, n: int, kf: Seq<Kind>, j: int, k: Kind, v: Value)
    requires
        conf(p, c, s, fi, kf, j, k, v),
        same_upto(s, s2, fi, n),
        bases_ok(s),
        0 <= j < n,
        match k { Kind::Block(d, sl) => d == 0 ==> sl < n, _ => true },
    ensures conf(p, c, s2, fi, kf, j, k, v),
{
    reveal(conf);
    reveal(good_ref);
    reveal(pending_ok);
    match k {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    let f = f as int;
                    if d > 0 {
                        lemma_context_frame_upto(s, s2, fi, n, fi, d as nat);
                        lemma_context_frame_lt(s, fi, d as nat);
                        lemma_upto_kinds(p, c, s, s2, fi, n, f);
                    }
                    assert(0 <= f <= fi);
                    assert(s2.frames[f] == s.frames[f]);
                    lemma_ref_ok_upto(s, s2, fi, n, f, slot as int);
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_upto_kinds(p, c, s, s2, fi, n, f as int);
                    lemma_ref_ok_upto(s, s2, fi, n, f as int, slot as int);
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, _, _) => {
                    assert(s2.frames[fi] == s.frames[fi]);
                    if second {
                        assert(s2.stack[fbase(s, fi) + j - 1] == s.stack[fbase(s, fi) + j - 1]);
                    }
                    match d {
                        Pending::Branch(f, bci, hb) => if !second {
                            if (f as int) < fi {
                                lemma_upto_kinds(p, c, s, s2, fi, n, f as int);
                            }
                            assert(frame_kinds_from(p, c, s2, fi, kf, f as int) == frame_kinds_from(p, c, s, fi, kf, f as int));
                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
    }
}

/// The frame's own kinds may change above the slot.
pub proof fn lemma_conf_kf(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, kf2: Seq<Kind>, j: int, k: Kind, v: Value)
    requires
        conf(p, c, s, fi, kf, j, k, v),
        0 <= j <= kf.len(), j <= kf2.len(),
        kf2.subrange(0, j) == kf.subrange(0, j),
    ensures conf(p, c, s, fi, kf2, j, k, v),
{
    reveal(conf);
    reveal(pending_ok);
    match k {
        Kind::Token => {
            match v {
                Value::Token(false, d, _, _) => {
                    assert(kf2[j - 1] == kf2.subrange(0, j)[j - 1]);
                    assert(kf[j - 1] == kf.subrange(0, j)[j - 1]);
                    match d {
                        Pending::Branch(f, bci, hb) => {
                            if f as int == fi {
                                let m = fmethod(s, fi);
                                let t = map_at(c, m, bci as int - info(p, m).entry)->0;
                                assert(t.len() + 1 <= j);
                                assert(kf2.subrange(0, t.len() as int) =~= kf2.subrange(0, j).subrange(0, t.len() as int));
                                assert(kf.subrange(0, t.len() as int) =~= kf.subrange(0, j).subrange(0, t.len() as int));
                            }
                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// `same_below` is a special case.
pub proof fn lemma_below_upto(s: State2, s2: State2, fi: int)
    requires same_below(s, s2, fi), bases_ok(s),
    ensures same_upto(s, s2, fi, slots(s, fi)),
{
    lemma_limit_below(s, fi, fi + 1);
    lemma_base_le_len(s, fi + 1);
}

// ---------------------------------------------------------------------------
// The heap.

pub proof fn lemma_obj_ok_mono(p: Program2, c: Cert, h: Seq<HeapObj>, h2: Seq<HeapObj>, o: HeapObj)
    requires obj_ok(p, c, h, o), heap_grows(h, h2),
    ensures obj_ok(p, c, h2, o),
{
    match o.body {
        Body::Instance(f) => {
            assert forall|i: int| 0 <= i < f.len() implies good(h2, #[trigger] f[i]) by {
                assert(good(h, f[i]));
            }
            if o.class_id as int == task_class(p) && f.len() >= 1 {
                match f[0] {
                    Value::Obj(id) => if (id as int) < h.len() { assert(h2[id as int].body is Stack2 || !(h[id as int].body is Stack2)); },
                    _ => {},
                }
            }
        },
        Body::Array(e) => {
            assert forall|i: int| 0 <= i < e.len() implies good(h2, #[trigger] e[i]) by {
                assert(good(h, e[i]));
            }
        },
        Body::Stack2(w, fr, b) => {
            if fr.len() > 0 {
                let ss = susp_state(h, w, fr, b);
                lemma_wf_task_heap(p, c, ss, h2);
                assert(with_heap(ss, h2) == susp_state(h2, w, fr, b));
            }
        },
        _ => {},
    }
}

/// Appending a well-formed object keeps the heap well formed.
pub proof fn lemma_heap_push(p: Program2, c: Cert, h: Seq<HeapObj>, o: HeapObj)
    requires heap_ok(p, c, h), obj_ok(p, c, h.push(o), o),
    ensures heap_ok(p, c, h.push(o)), heap_ext(p, h, h.push(o)),
{
    reveal(heap_ok);
    let h2 = h.push(o);
    assert forall|i: int| 0 <= i < h.len() && h[i].class_id as int == task_class(p) implies
        task_fields_kept(h[i], #[trigger] h2[i]) by {
        lemma_kept_refl(h[i]);
    }
    assert(heap_ext(p, h, h2));
    assert forall|i: int| 0 <= i < h2.len() implies #[trigger] obj_ok(p, c, h2, h2[i]) by {
        if i < h.len() {
            assert(obj_ok(p, c, h, h[i]));
            lemma_obj_ok_mono(p, c, h, h2, h[i]);
        }
    }
}

pub proof fn lemma_globals_heap(c: Cert, s: State2, h2: Seq<HeapObj>)
    requires globals_ok(c, s), s.heap.len() <= h2.len(),
    ensures globals_ok(c, with_heap(s, h2)),
{
    assert forall|g: int| 0 <= g < s.globals.len() implies good(h2, #[trigger] s.globals[g]) by {
        assert(good(s.heap, s.globals[g]));
    }
}

pub proof fn lemma_consts_heap(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>)
    requires consts_ok(p, h), h.len() <= h2.len(),
    ensures consts_ok(p, h2),
{
    assert forall|i: int| 0 <= i < p.roots.len() implies good(h2, #[trigger] p.roots[i]) by {
        assert(good(h, p.roots[i]));
    }
    assert forall|i: int| 0 <= i < p.literals.len() implies good(h2, #[trigger] p.literals[i]) by {
        assert(good(h, p.literals[i]));
    }
}

} // verus!

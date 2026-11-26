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

//! Format 2: what a garbage collection does to the abstract state.
//!
//! A collection (`collection`) is two parts:
//!
//! 1. Weak processing (`zapped`; the C++ `WeakMapFinalizerNode::
//!    weak_processing` and `zap_dead_values` in src/heap_roots.cc). A map
//!    may be reset (`reset_map`: size and spaces left 0, index and backing
//!    null), and a value slot (odd index) of an array of a map's backing
//!    (`backing_array`: the backing list's array, or the arraylets of its
//!    large array) that holds an object other than a tombstone may become
//!    null. The C++ does this only for maps with a weak finalizer (a header
//!    bit the model does not have), resets only maps the strong marking did
//!    not reach (they may still be revived by a finalizer lambda) and nulls
//!    only values it did not reach; the step allows it for every map and
//!    value of that shape: a superset of what the collector does.
//! 2. Compaction (`ren_ok`, `renamed`). The live set (the ids `ren` maps to
//!    a new id, `ren[i] >= 0`) holds the roots the state has (the object
//!    stack, the globals, the running task) and is closed under references;
//!    it may hold more (the collector has more roots: other tasks, finalizer
//!    lambdas, messages, external roots). Garbage disappears; the live
//!    objects get the ids `0..n` (`back` is the inverse of `ren`), their
//!    references renamed. The program heap and the program's constants keep
//!    their ids. Nothing else changes: frames, handlers, finally records,
//!    bci, task counter; object classes and contents up to the renaming.
//!
//! The renaming keeps the heap within the model's bounds (`small`): a
//! collector that keeps object identities and only frees memory delivers
//! it by numbering the live objects (verified/core/src/gcbridge.rs). The
//! weak part makes "the reachable objects stay the same" false for
//! programs with weak maps (`Map.weak`, which untrusted programs may use).
//!
//! `gc_steps` is any number of collections (a call into C++ may collect
//! more than once). Collections keep the invariant (`lemma_gc_steps_wf`)
//! and the unwinding invariant of a raise (`lemma_gc_steps_unw`); a
//! program-heap object or smi keeps its value (`kept`).

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_unwind::*;
use crate::v2::sound_upto::*;
#[cfg(verus_only)]
use crate::v2::sound_raise::lemma_unw_heap;
#[cfg(verus_only)]
use crate::spec_common::{builtin, class_id_ok, class_id_of, is_double, MAP_CLASS, LIST_CLASS, LARGE_ARRAY_CLASS, TOMBSTONE_CLASS};

verus! {

// ---------------------------------------------------------------------------
// Weak processing.

/// Field indices of maps, lists and large arrays (src/objects.h, `Instance`).
pub spec const MAP_SIZE_INDEX: int = 0;
pub spec const MAP_SPACES_LEFT_INDEX: int = 1;
pub spec const MAP_INDEX_INDEX: int = 2;
pub spec const MAP_BACKING_INDEX: int = 3;
pub spec const LIST_ARRAY_INDEX: int = 0;
pub spec const LARGE_ARRAY_VECTOR_INDEX: int = 1;

/// A map the collector may treat as weak: a mutable instance of the map
/// class with its four fields (the C++ verifier's `check_builtin_classes`
/// gives the map class instance tag and at least four fields, the task
/// class the task tag, so it is not the task class).
pub open spec fn is_map(p: Program2, o: HeapObj) -> bool {
    &&& o.class_id as int == builtin(p1(p), MAP_CLASS)
    &&& o.class_id as int != task_class(p)
    &&& !o.ro
    &&& o.body is Instance
    &&& o.body->Instance_0.len() > MAP_BACKING_INDEX
}

/// An unreachable weak map after weak processing: empty, no index, no
/// backing.
pub open spec fn reset_map(p: Program2, o: HeapObj) -> HeapObj {
    let f = o.body->Instance_0;
    HeapObj {
        body: Body::Instance(f.update(MAP_SIZE_INDEX, Value::Smi(0)).update(MAP_SPACES_LEFT_INDEX, Value::Smi(0))
            .update(MAP_INDEX_INDEX, null2(p)).update(MAP_BACKING_INDEX, null2(p))),
        ..o
    }
}

/// Field `f` of `v` if `v` is an instance of class `cid` that has it.
pub open spec fn inst_field(h: Seq<HeapObj>, v: Value, cid: int, f: int) -> Option<Value> {
    match v {
        Value::Obj(id) => {
            let i = id as int;
            if i < h.len() && h[i].class_id as int == cid && h[i].body is Instance
                && 0 <= f < h[i].body->Instance_0.len() {
                Some(h[i].body->Instance_0[f])
            } else {
                None
            }
        },
        _ => None,
    }
}

/// Array `a` holds entries of map `m` (`zap_dead_values`): the array of
/// the map's backing list, or an arraylet of it if that is a large array.
pub open spec fn backing_array(p: Program2, h: Seq<HeapObj>, m: int, a: int) -> bool {
    &&& 0 <= m < h.len()
    &&& is_map(p, h[m])
    &&& 0 <= a < h.len()
    &&& h[a].body is Array
    &&& match inst_field(h, h[m].body->Instance_0[MAP_BACKING_INDEX], builtin(p1(p), LIST_CLASS), LIST_ARRAY_INDEX) {
        Some(arr) => {
            ||| arr == Value::Obj(a as usize)
            ||| match inst_field(h, arr, builtin(p1(p), LARGE_ARRAY_CLASS), LARGE_ARRAY_VECTOR_INDEX) {
                Some(Value::Obj(vid)) => (vid as int) < h.len() && h[vid as int].body is Array
                    && h[vid as int].body->Array_0.contains(Value::Obj(a as usize)),
                _ => false,
            }
        },
        None => false,
    }
}

/// The entries of an array after weak processing: each value slot (odd
/// index) that holds an object other than a tombstone may become null.
pub open spec fn zapped_elems(p: Program2, h: Seq<HeapObj>, e: Seq<Value>, e2: Seq<Value>) -> bool {
    &&& e2.len() == e.len()
    &&& forall|j: int| 0 <= j < e.len() ==> {
        ||| #[trigger] e2[j] == e[j]
        ||| j % 2 == 1 && e2[j] == null2(p) && match e[j] {
                Value::Obj(id) => (id as int) < h.len()
                    && h[id as int].class_id as int != builtin(p1(p), TOMBSTONE_CLASS),
                _ => false,
            }
    }
}

/// What weak processing may make of object `i` of `h`.
pub open spec fn weak_change(p: Program2, h: Seq<HeapObj>, i: int, o2: HeapObj) -> bool {
    let o = h[i];
    ||| o2 == o
    ||| is_map(p, o) && o2 == reset_map(p, o)
    ||| {
        &&& !o.ro
        &&& o.body is Array
        &&& exists|m: int| #[trigger] backing_array(p, h, m, i)
        &&& o2.class_id == o.class_id
        &&& o2.ro == o.ro
        &&& o2.body is Array
        &&& zapped_elems(p, h, o.body->Array_0, o2.body->Array_0)
    }
}

/// Weak processing: `s1` is `s` with some maps reset and some map values
/// nulled.
pub open spec fn zapped(p: Program2, s: State2, s1: State2) -> bool {
    &&& s1 == (State2 { heap: s1.heap, ..s })
    &&& s1.heap.len() == s.heap.len()
    &&& forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] weak_change(p, s.heap, i, s1.heap[i])
}

// ---------------------------------------------------------------------------
// Compaction.

/// A value with its object ids renamed by `ren`.
pub open spec fn ren_val(ren: Seq<int>, v: Value) -> Value {
    match v {
        Value::Obj(id) => Value::Obj(ren[id as int] as usize),
        _ => v,
    }
}

pub open spec fn ren_vals(ren: Seq<int>, vs: Seq<Value>) -> Seq<Value> {
    Seq::new(vs.len(), |j: int| ren_val(ren, vs[j]))
}

/// An object with its references renamed (class, flags and the other
/// contents stay).
pub open spec fn ren_obj(ren: Seq<int>, o: HeapObj) -> HeapObj {
    HeapObj {
        body: match o.body {
            Body::Instance(f) => Body::Instance(ren_vals(ren, f)),
            Body::Array(e) => Body::Array(ren_vals(ren, e)),
            Body::Stack(w, t) => Body::Stack(ren_vals(ren, w), t),
            Body::Stack2(w, fr, b) => Body::Stack2(ren_vals(ren, w), fr, b),
            _ => o.body,
        },
        ..o
    }
}

/// The values an object holds (what the collector traces).
pub open spec fn obj_vals(o: HeapObj) -> Seq<Value> {
    match o.body {
        Body::Instance(f) => f,
        Body::Array(e) => e,
        Body::Stack(w, _) => w,
        Body::Stack2(w, _, _) => w,
        _ => Seq::empty(),
    }
}

/// Object `i` survives: it gets a new id.
pub open spec fn live(ren: Seq<int>, i: int) -> bool {
    0 <= i < ren.len() && ren[i] >= 0
}

pub open spec fn val_live(ren: Seq<int>, v: Value) -> bool {
    match v {
        Value::Obj(id) => live(ren, id as int),
        _ => true,
    }
}

/// `v` keeps its id.
pub open spec fn fixed(ren: Seq<int>, v: Value) -> bool {
    match v {
        Value::Obj(id) => (id as int) < ren.len() && ren[id as int] == id as int,
        _ => true,
    }
}

/// Every value object `i` holds survives.
pub open spec fn refs_live(ren: Seq<int>, h: Seq<HeapObj>, i: int) -> bool {
    forall|j: int| 0 <= j < obj_vals(h[i]).len() ==> val_live(ren, #[trigger] obj_vals(h[i])[j])
}

/// `ren` and `back` describe a compaction of `s`: a bijection between the
/// live ids and `0..back.len()`; the program heap and the constants keep
/// their ids; the roots survive; the live set is closed under references.
pub open spec fn ren_ok(p: Program2, s: State2, ren: Seq<int>, back: Seq<int>) -> bool {
    let h = s.heap;
    &&& ren.len() == h.len()
    &&& back.len() <= h.len()
    &&& forall|k: int| 0 <= k < back.len() ==> live(ren, #[trigger] back[k]) && ren[back[k]] == k
    &&& forall|i: int| #[trigger] live(ren, i) ==> ren[i] < back.len() && back[ren[i]] == i
    &&& forall|i: int| 0 <= i < h.len() && (#[trigger] h[i]).ro ==> ren[i] == i
    &&& forall|i: int| 0 <= i < p.roots.len() ==> fixed(ren, #[trigger] p.roots[i])
    &&& forall|i: int| 0 <= i < p.literals.len() ==> fixed(ren, #[trigger] p.literals[i])
    &&& forall|j: int| 0 <= j < s.stack.len() ==> val_live(ren, #[trigger] s.stack[j])
    &&& forall|j: int| 0 <= j < s.globals.len() ==> val_live(ren, #[trigger] s.globals[j])
    &&& live(ren, s.task as int)
    &&& forall|i: int| #[trigger] live(ren, i) ==> refs_live(ren, h, i)
}

/// The state after the compaction.
pub open spec fn renamed(s: State2, ren: Seq<int>, back: Seq<int>) -> State2 {
    State2 {
        heap: Seq::new(back.len(), |k: int| ren_obj(ren, s.heap[back[k]])),
        stack: ren_vals(ren, s.stack),
        globals: ren_vals(ren, s.globals),
        task: ren[s.task as int] as usize,
        ..s
    }
}

// ---------------------------------------------------------------------------
// Collections.

/// A collection with weak processing to `s1` and compaction `ren`.
pub open spec fn gc_by(p: Program2, s: State2, s1: State2, ren: Seq<int>, back: Seq<int>, s2: State2) -> bool {
    &&& zapped(p, s, s1)
    &&& ren_ok(p, s1, ren, back)
    &&& s2 == renamed(s1, ren, back)
}

/// One collection.
pub open spec fn collection(p: Program2, s: State2, s2: State2) -> bool {
    exists|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, s, s1, ren, back, s2)
}

pub open spec fn gc_chain(p: Program2, tr: Seq<State2>) -> bool {
    forall|i: int| 0 <= i < tr.len() - 1 ==> #[trigger] collection(p, tr[i], tr[i + 1])
}

/// Any number of collections.
pub open spec fn gc_steps(p: Program2, s: State2, s2: State2) -> bool {
    exists|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2
}

/// What a collection keeps of a state: everything but the heap, the
/// values and the running task's id.
pub open spec fn gc_shape(s: State2, s2: State2) -> bool {
    &&& s2.frames == s.frames
    &&& s2.bci == s.bci
    &&& s2.next_task_id == s.next_task_id
    &&& s2.stack.len() == s.stack.len()
    &&& s2.globals.len() == s.globals.len()
    &&& s2.heap.len() <= s.heap.len()
}

/// A value every collection keeps: a smi or a program-heap object.
pub open spec fn kept(h: Seq<HeapObj>, v: Value) -> bool {
    match v {
        Value::Smi(_) => true,
        Value::Obj(id) => (id as int) < h.len() && h[id as int].ro,
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Chains.

pub proof fn lemma_gc_steps_refl(p: Program2, s: State2)
    ensures gc_steps(p, s, s),
{
    let tr = seq![s];
    assert(gc_chain(p, tr));
    assert(tr.last() == s);
}

pub proof fn lemma_gc_steps_trans(p: Program2, a: State2, b: State2, c: State2)
    requires gc_steps(p, a, b), gc_steps(p, b, c),
    ensures gc_steps(p, a, c),
{
    let t1 = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == a && tr.last() == b;
    let t2 = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == b && tr.last() == c;
    let t = t1 + t2.subrange(1, t2.len() as int);
    assert forall|i: int| 0 <= i < t.len() - 1 implies #[trigger] collection(p, t[i], t[i + 1]) by {
        if i < t1.len() - 1 {
            assert(t[i] == t1[i] && t[i + 1] == t1[i + 1]);
        } else {
            let j = i - (t1.len() - 1);
            assert(t[i] == t2[j]);
            assert(t[i + 1] == t2[j + 1]);
        }
    }
    assert(gc_chain(p, t));
    if t2.len() == 1 {
        assert(t =~= t1);
    } else {
        assert(t.last() == t2.last());
    }
}

// ---------------------------------------------------------------------------
// Renaming keeps the invariant.

/// The heap `h2` holds the renamed live objects of `h` at their new ids.
pub open spec fn heap_ren(ren: Seq<int>, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& ren.len() == h.len()
    &&& h2.len() < 0x8000_0000
    &&& forall|i: int| #[trigger] live(ren, i) ==> ren[i] < h2.len() && h2[ren[i]] == ren_obj(ren, h[i])
}

/// `s2` is `s` renamed: its heap, its object stack; the frames and the bci
/// stay.
pub open spec fn state_ren(ren: Seq<int>, s: State2, s2: State2) -> bool {
    &&& heap_ren(ren, s.heap, s2.heap)
    &&& s2.stack == ren_vals(ren, s.stack)
    &&& forall|j: int| 0 <= j < s.stack.len() ==> val_live(ren, #[trigger] s.stack[j])
    &&& s2.frames == s.frames
    &&& s2.bci == s.bci
}

pub proof fn lemma_ren_val(ren: Seq<int>, h: Seq<HeapObj>, h2: Seq<HeapObj>, v: Value)
    requires heap_ren(ren, h, h2), val_live(ren, v),
    ensures
        good(h, v) ==> good(h2, ren_val(ren, v)),
        v is Smi ==> ren_val(ren, v) == v,
        v is BlockRef ==> ren_val(ren, v) == v,
        v is Obj <==> ren_val(ren, v) is Obj,
        v is Obj ==> ({
            let id = v->Obj_0 as int;
            let id2 = ren_val(ren, v)->Obj_0 as int;
            &&& id2 == ren[id]
            &&& id2 < h2.len()
            &&& h2[id2] == ren_obj(ren, h[id])
        }),
{
    match v {
        Value::Obj(id) => {
            assert(live(ren, id as int));
            assert(0 <= ren[id as int] < 0x8000_0000);
        },
        _ => {},
    }
}

/// A fixed value is its own renaming.
pub proof fn lemma_ren_fixed(ren: Seq<int>, v: Value)
    requires fixed(ren, v),
    ensures ren_val(ren, v) == v,
{
    match v {
        Value::Obj(id) => { assert(ren[id as int] as usize == id); },
        _ => {},
    }
}

/// `context_frame` reads only block references of the stack, which the
/// renaming keeps.
pub proof fn lemma_ren_context(ren: Seq<int>, s: State2, s2: State2, fi: int, d: nat)
    requires s2.frames == s.frames, s2.stack == ren_vals(ren, s.stack),
    ensures context_frame(s2, fi, d) == context_frame(s, fi, d),
    decreases d,
{
    if d > 0 && 0 <= fi < s.frames.len() && 0 <= s.frames[fi].base < s.stack.len() {
        let b = s.frames[fi].base as int;
        assert(s2.stack[b] == ren_val(ren, s.stack[b]));
        match s.stack[b] {
            Value::BlockRef(f, _) => if (f as int) < fi { lemma_ren_context(ren, s, s2, f as int, (d - 1) as nat); },
            _ => {},
        }
    }
}

pub proof fn lemma_ren_conf(p: Program2, c: Cert, ren: Seq<int>, s: State2, s2: State2, fi: int, kf: Seq<Kind>,
    j: int, k: Kind, v: Value)
    requires
        conf(p, c, s, fi, kf, j, k, v),
        state_ren(ren, s, s2),
        val_live(ren, v),
        fixed(ren, null2(p)),
        fbase(s, fi) + j < s.stack.len(),
    ensures conf(p, c, s2, fi, kf, j, k, ren_val(ren, v)),
{
    reveal(conf);
    reveal(pending_ok);
    reveal(good_ref);
    assert(s2.stack.len() == s.stack.len());
    assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
    lemma_ren_val(ren, s.heap, s2.heap, v);
    match k {
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_ren_context(ren, s, s2, fi, d as nat);
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, _, _) => {
                    if second && 0 <= fbase(s, fi) + j - 1 < s.stack.len() {
                        assert(s2.stack[fbase(s, fi) + j - 1] == ren_val(ren, s.stack[fbase(s, fi) + j - 1]));
                    }
                    match d {
                        Pending::Branch(f, bci, hb) => {
                            assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                            assert(frame_kinds_from(p, c, s2, fi, kf, f as int) == frame_kinds_from(p, c, s, fi, kf, f as int));
                            assert(fmethod(s2, f as int) == fmethod(s, f as int));
                            assert(fbase(s2, f as int) == fbase(s, f as int));
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

/// The slots of a frame lie in the stack.
pub proof fn lemma_limit_le_len(s: State2, fi: int)
    requires bases_ok(s), 0 <= fi < s.frames.len(),
    ensures limit(s, fi) <= s.stack.len(),
{
    if fi + 1 < s.frames.len() {
        lemma_base_le_len(s, fi + 1);
    }
}

/// The receiver condition with `n` known slots of the top frame.
pub proof fn lemma_ren_receiver(p: Program2, ren: Seq<int>, s: State2, s2: State2, fi: int)
    requires
        state_ren(ren, s, s2),
        0 <= fi < s.frames.len(),
        0 <= fbase(s, fi) < s.stack.len(),
    ensures ({
        let r = s.stack[fbase(s, fi)];
        let r2 = s2.stack[fbase(s2, fi)];
        &&& class_id_ok(as1(s), r) ==> class_id_ok(as1(s2), r2)
        &&& class_id_ok(as1(s), r) ==> class_id_of(p1(p), as1(s2), r2) == class_id_of(p1(p), as1(s), r)
    }),
{
    let b = fbase(s, fi);
    let r = s.stack[b];
    assert(val_live(ren, r));
    assert(s2.stack[b] == ren_val(ren, r));
    lemma_ren_val(ren, s.heap, s2.heap, r);
}

pub proof fn lemma_ren_frame_ok(p: Program2, c: Cert, ren: Seq<int>, s: State2, s2: State2, fi: int)
    requires
        frame_ok(p, c, s, fi),
        state_ren(ren, s, s2),
        fixed(ren, null2(p)),
        bases_ok(s),
        0 <= fi < s.frames.len(),
    ensures frame_ok(p, c, s2, fi),
{
    reveal(frame_ok);
    assert(s2.stack.len() == s.stack.len());
    lemma_limit_le_len(s, fi);
    assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
    assert(try_frame(s2, fi) == try_frame(s, fi));
    assert(slots(s2, fi) == slots(s, fi));
    assert forall|j: int| 0 <= j < slots(s2, fi) implies
        #[trigger] conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, kinds_of(p, c, s2, fi)[j], s2.stack[fbase(s2, fi) + j]) by {
        let x = fbase(s, fi) + j;
        assert(conf(p, c, s, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[x]));
        assert(val_live(ren, s.stack[x]));
        lemma_ren_conf(p, c, ren, s, s2, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[x]);
        assert(s2.stack[x] == ren_val(ren, s.stack[x]));
    }
    let m = fmethod(s, fi);
    let i = info(p, m);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
        lemma_ren_receiver(p, ren, s, s2, fi);
    }
}

pub proof fn lemma_ren_wf_task(p: Program2, c: Cert, ren: Seq<int>, s: State2, s2: State2)
    requires
        wf_task(p, c, s),
        state_ren(ren, s, s2),
        fixed(ren, null2(p)),
    ensures wf_task(p, c, s2),
{
    reveal(wf_task);
    assert(s2.stack.len() == s.stack.len());
    assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
        assert(base_step(s, fi));
    }
    assert(bases_ok(s2));
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_ren_frame_ok(p, c, ren, s, s2, fi);
    }
}

/// A renamed object stays well formed when its references survive.
pub proof fn lemma_ren_obj_ok(p: Program2, c: Cert, ren: Seq<int>, h: Seq<HeapObj>, h2: Seq<HeapObj>, o: HeapObj)
    requires
        obj_ok(p, c, h, o),
        heap_ren(ren, h, h2),
        forall|j: int| 0 <= j < obj_vals(o).len() ==> val_live(ren, #[trigger] obj_vals(o)[j]),
        fixed(ren, null2(p)),
    ensures obj_ok(p, c, h2, ren_obj(ren, o)),
{
    let o2 = ren_obj(ren, o);
    match o.body {
        Body::Instance(f) => {
            let f2 = ren_vals(ren, f);
            assert forall|i: int| 0 <= i < f2.len() implies good(h2, #[trigger] f2[i]) by {
                assert(val_live(ren, obj_vals(o)[i]));
                lemma_ren_val(ren, h, h2, f[i]);
            }
            if o.class_id as int == task_class(p) {
                assert(val_live(ren, obj_vals(o)[0]));
                assert(val_live(ren, obj_vals(o)[1]));
                lemma_ren_val(ren, h, h2, f[0]);
                lemma_ren_val(ren, h, h2, f[1]);
                assert(task_obj_ok(h2, o2));
            }
        },
        Body::Array(e) => {
            let e2 = ren_vals(ren, e);
            assert forall|i: int| 0 <= i < e2.len() implies good(h2, #[trigger] e2[i]) by {
                assert(val_live(ren, obj_vals(o)[i]));
                lemma_ren_val(ren, h, h2, e[i]);
            }
        },
        Body::Stack2(w, fr, b) => {
            let w2 = ren_vals(ren, w);
            if fr.len() == 0 {
                if w.len() >= 1 {
                    assert(val_live(ren, obj_vals(o)[0]));
                    lemma_ren_val(ren, h, h2, w[0]);
                }
            } else {
                let ss = susp_state(h, w, fr, b);
                let ss2 = susp_state(h2, w2, fr, b);
                assert forall|j: int| 0 <= j < ss.stack.len() implies val_live(ren, #[trigger] ss.stack[j]) by {
                    assert(val_live(ren, obj_vals(o)[j]));
                }
                assert(state_ren(ren, ss, ss2));
                lemma_ren_wf_task(p, c, ren, ss, ss2);
                assert(at_transfer(p, ss2) == at_transfer(p, ss));
            }
        },
        _ => {},
    }
}

/// The renamed heap is well formed.
pub proof fn lemma_ren_heap_ok(p: Program2, c: Cert, s: State2, ren: Seq<int>, back: Seq<int>)
    requires
        heap_ok(p, c, s.heap),
        ren_ok(p, s, ren, back),
        s.heap.len() < 0x8000_0000,
        consts_ok(p, s.heap),
        crate::v2::exec::wf_program2(p),
    ensures
        heap_ok(p, c, renamed(s, ren, back).heap),
        heap_ren(ren, s.heap, renamed(s, ren, back).heap),
        fixed(ren, null2(p)),
{
    let h = s.heap;
    let h2 = renamed(s, ren, back).heap;
    assert(fixed(ren, p.roots[0]));
    assert forall|i: int| #[trigger] live(ren, i) implies ren[i] < h2.len() && h2[ren[i]] == ren_obj(ren, h[i]) by {
        assert(back[ren[i]] == i);
    }
    assert(heap_ren(ren, h, h2));
    reveal(heap_ok);
    assert forall|k: int| 0 <= k < h2.len() implies #[trigger] obj_ok(p, c, h2, h2[k]) by {
        let i = back[k];
        assert(live(ren, i));
        assert(obj_ok(p, c, h, h[i]));
        assert(refs_live(ren, h, i));
        assert forall|j: int| 0 <= j < obj_vals(h[i]).len() implies val_live(ren, #[trigger] obj_vals(h[i])[j]) by {}
        lemma_ren_obj_ok(p, c, ren, h, h2, h[i]);
    }
}

/// Renaming keeps the parts of the invariant outside the frames.
pub proof fn lemma_renamed_parts(p: Program2, c: Cert, s: State2, ren: Seq<int>, back: Seq<int>)
    requires
        heap_ok(p, c, s.heap),
        globals_ok(c, s),
        consts_ok(p, s.heap),
        running_ok(p, s),
        ren_ok(p, s, ren, back),
        s.heap.len() < 0x8000_0000,
        crate::v2::exec::wf_program2(p),
    ensures ({
        let s2 = renamed(s, ren, back);
        &&& heap_ok(p, c, s2.heap)
        &&& globals_ok(c, s2)
        &&& consts_ok(p, s2.heap)
        &&& running_ok(p, s2)
        &&& state_ren(ren, s, s2)
        &&& fixed(ren, null2(p))
        &&& gc_shape(s, s2)
    }),
{
    let s2 = renamed(s, ren, back);
    let h = s.heap;
    let h2 = s2.heap;
    lemma_ren_heap_ok(p, c, s, ren, back);
    assert(state_ren(ren, s, s2));
    assert forall|g: int| 0 <= g < s2.globals.len() implies good(h2, #[trigger] s2.globals[g]) by {
        assert(good(h, s.globals[g]));
        assert(val_live(ren, s.globals[g]));
        lemma_ren_val(ren, h, h2, s.globals[g]);
    }
    assert(globals_ok(c, s2));
    assert forall|i: int| 0 <= i < p.roots.len() implies good(h2, #[trigger] p.roots[i]) by {
        assert(fixed(ren, p.roots[i]));
        assert(good(h, p.roots[i]));
        match p.roots[i] {
            Value::Obj(id) => { assert(live(ren, id as int)); },
            _ => {},
        }
    }
    assert forall|i: int| 0 <= i < p.literals.len() implies good(h2, #[trigger] p.literals[i]) by {
        assert(fixed(ren, p.literals[i]));
        assert(good(h, p.literals[i]));
        match p.literals[i] {
            Value::Obj(id) => { assert(live(ren, id as int)); },
            _ => {},
        }
    }
    assert(consts_ok(p, h2));
    // The running task.
    let t = s.task as int;
    assert(live(ren, t));
    assert(0 <= ren[t] < 0x8000_0000);
    assert(s2.task as int == ren[t]);
    assert(h2[ren[t]] == ren_obj(ren, h[t]));
    assert(refs_live(ren, h, t));
    match h[t].body {
        Body::Instance(f) => {
            assert(val_live(ren, obj_vals(h[t])[0]));
            lemma_ren_val(ren, h, h2, f[0]);
        },
        _ => {},
    }
    assert(running_ok(p, s2));
}

/// Renaming keeps the invariant.
pub proof fn lemma_renamed_wf(p: Program2, c: Cert, s: State2, ren: Seq<int>, back: Seq<int>)
    requires
        wf(p, c, s),
        accepted(p, c),
        ren_ok(p, s, ren, back),
        s.heap.len() < 0x8000_0000,
    ensures wf(p, c, renamed(s, ren, back)), gc_shape(s, renamed(s, ren, back)),
{
    reveal(wf);
    let trusted = choose|trusted: bool| accepts(p, c, trusted);
    assert(crate::v2::exec::wf_program2(p));
    let s2 = renamed(s, ren, back);
    lemma_renamed_parts(p, c, s, ren, back);
    lemma_ren_wf_task(p, c, ren, s, s2);
}

/// Renaming keeps an unwinding state.
pub proof fn lemma_renamed_unw(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, ren: Seq<int>, back: Seq<int>)
    requires
        unw_ok(p, c, s, kt),
        accepted(p, c),
        ren_ok(p, s, ren, back),
    ensures unw_ok(p, c, renamed(s, ren, back), kt), gc_shape(s, renamed(s, ren, back)),
{
    let trusted = choose|trusted: bool| accepts(p, c, trusted);
    assert(crate::v2::exec::wf_program2(p));
    let s2 = renamed(s, ren, back);
    lemma_renamed_parts(p, c, s, ren, back);
    let t = top_i(s);
    let b = fbase(s, t);
    assert(s2.stack.len() == s.stack.len());
    assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
        assert(base_step(s, fi));
    }
    assert(bases_ok(s2));
    assert forall|fi: int| 0 <= fi < top_i(s2) implies #[trigger] frame_ok(p, c, s2, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_ren_frame_ok(p, c, ren, s, s2, fi);
    }
    assert forall|j: int| 0 <= j < kt.len() implies #[trigger] conf(p, c, s2, t, kt, j, kt[j], s2.stack[b + j]) by {
        assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
        assert(val_live(ren, s.stack[b + j]));
        lemma_ren_conf(p, c, ren, s, s2, t, kt, j, kt[j], s.stack[b + j]);
        assert(s2.stack[b + j] == ren_val(ren, s.stack[b + j]));
    }
    let m = fmethod(s, t);
    let i = info(p, m);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
        lemma_ren_receiver(p, ren, s, s2, t);
    }
    assert(top_receiver_ok(p, s2, kt.len() as int));
}

// ---------------------------------------------------------------------------
// Weak processing keeps the invariant.

/// The heap after weak processing is well formed and extends the old one
/// (same classes, suspended stacks and task fields).
pub proof fn lemma_zapped_heap(p: Program2, c: Cert, h: Seq<HeapObj>, h1: Seq<HeapObj>)
    requires
        heap_ok(p, c, h),
        consts_ok(p, h),
        crate::v2::exec::wf_program2(p),
        h1.len() == h.len(),
        forall|i: int| 0 <= i < h.len() ==> #[trigger] weak_change(p, h, i, h1[i]),
    ensures heap_ok(p, c, h1), heap_ext(p, h, h1),
{
    reveal(heap_ok);
    assert(good(h, null2(p)));
    assert forall|i: int| 0 <= i < h.len() implies {
        &&& (#[trigger] h1[i]).class_id == h[i].class_id
        &&& h[i].body is Stack2 ==> h1[i].body is Stack2
        &&& h[i].body is Stack2 ==> h1[i] == h[i]
        &&& h[i].class_id as int == task_class(p) ==> h1[i] == h[i]
        &&& h1[i].ro == h[i].ro
    } by {
        assert(weak_change(p, h, i, h1[i]));
        assert(obj_ok(p, c, h, h[i]));
    }
    assert(heap_grows(h, h1));
    assert forall|i: int| 0 <= i < h.len() && h[i].class_id as int == task_class(p) implies
        task_fields_kept(h[i], #[trigger] h1[i]) by {
        assert(h1[i] == h[i]);
        lemma_kept_refl(h[i]);
    }
    assert(heap_ext(p, h, h1));
    assert forall|i: int| 0 <= i < h1.len() implies #[trigger] obj_ok(p, c, h1, h1[i]) by {
        let o = h[i];
        assert(obj_ok(p, c, h, o));
        assert(weak_change(p, h, i, h1[i]));
        if h1[i] == o {
            lemma_obj_ok_mono(p, c, h, h1, o);
        } else if is_map(p, o) && h1[i] == reset_map(p, o) {
            let f = o.body->Instance_0;
            let f2 = h1[i].body->Instance_0;
            assert forall|j: int| 0 <= j < f2.len() implies good(h1, #[trigger] f2[j]) by {
                assert(good(h, f[j]));
            }
        } else {
            let e = o.body->Array_0;
            let e2 = h1[i].body->Array_0;
            assert(zapped_elems(p, h, e, e2));
            assert forall|j: int| 0 <= j < e2.len() implies good(h1, #[trigger] e2[j]) by {
                assert(good(h, e[j]));
            }
        }
    }
}

/// Weak processing keeps the invariant.
pub proof fn lemma_zapped_wf(p: Program2, c: Cert, s: State2, s1: State2)
    requires wf(p, c, s), accepted(p, c), zapped(p, s, s1),
    ensures wf(p, c, s1), gc_shape(s, s1), s1.heap.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s1.heap[i]).ro == s.heap[i].ro
            && (s.heap[i].ro ==> s1.heap[i] == s.heap[i]),
{
    reveal(wf);
    let trusted = choose|trusted: bool| accepts(p, c, trusted);
    assert(crate::v2::exec::wf_program2(p));
    lemma_zapped_heap(p, c, s.heap, s1.heap);
    assert(s1 == with_heap(s, s1.heap));
    lemma_globals_heap(c, s, s1.heap);
    lemma_consts_heap(p, s.heap, s1.heap);
    lemma_wf_task_heap(p, c, s, s1.heap);
    lemma_running_heap(p, s, s1);
    assert forall|i: int| 0 <= i < s.heap.len() implies (#[trigger] s1.heap[i]).ro == s.heap[i].ro
        && (s.heap[i].ro ==> s1.heap[i] == s.heap[i]) by {
        assert(weak_change(p, s.heap, i, s1.heap[i]));
    }
}

/// Weak processing keeps an unwinding state.
pub proof fn lemma_zapped_unw(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, s1: State2)
    requires unw_ok(p, c, s, kt), accepted(p, c), zapped(p, s, s1),
    ensures unw_ok(p, c, s1, kt), gc_shape(s, s1), s1.heap.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s1.heap[i]).ro == s.heap[i].ro
            && (s.heap[i].ro ==> s1.heap[i] == s.heap[i]),
{
    let trusted = choose|trusted: bool| accepts(p, c, trusted);
    assert(crate::v2::exec::wf_program2(p));
    lemma_zapped_heap(p, c, s.heap, s1.heap);
    assert(s1 == with_heap(s, s1.heap));
    lemma_unw_heap(p, c, s, kt, s1.heap);
    assert forall|i: int| 0 <= i < s.heap.len() implies (#[trigger] s1.heap[i]).ro == s.heap[i].ro
        && (s.heap[i].ro ==> s1.heap[i] == s.heap[i]) by {
        assert(weak_change(p, s.heap, i, s1.heap[i]));
    }
}

// ---------------------------------------------------------------------------
// Collections keep the invariant.

/// A kept value survives a compaction unchanged.
proof fn lemma_kept_renamed(s: State2, ren: Seq<int>, back: Seq<int>, p: Program2, v: Value)
    requires ren_ok(p, s, ren, back), kept(s.heap, v),
    ensures kept(renamed(s, ren, back).heap, v), ren_val(ren, v) == v,
{
    match v {
        Value::Obj(id) => {
            let i = id as int;
            assert(ren[i] == i);
            assert(live(ren, i));
            assert(back[ren[i]] == i);
        },
        _ => {},
    }
}

/// One collection keeps the invariant and the state's shape.
pub proof fn lemma_collection_wf(p: Program2, c: Cert, s: State2, s2: State2)
    requires wf(p, c, s), accepted(p, c), s.heap.len() < 0x8000_0000, collection(p, s, s2),
    ensures wf(p, c, s2), gc_shape(s, s2),
{
    let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, s, s1, ren, back, s2);
    lemma_zapped_wf(p, c, s, s1);
    lemma_renamed_wf(p, c, s1, ren, back);
}

/// One collection keeps an unwinding state and kept values.
pub proof fn lemma_collection_unw(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, s2: State2, v: Value)
    requires unw_ok(p, c, s, kt), accepted(p, c), collection(p, s, s2),
    ensures unw_ok(p, c, s2, kt), gc_shape(s, s2), kept(s.heap, v) ==> kept(s2.heap, v),
{
    let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, s, s1, ren, back, s2);
    lemma_zapped_unw(p, c, s, kt, s1);
    lemma_renamed_unw(p, c, s1, kt, ren, back);
    if kept(s.heap, v) {
        assert(kept(s1.heap, v));
        lemma_kept_renamed(s1, ren, back, p, v);
    }
}

/// Collections keep the invariant, the shape and the model's bounds.
pub proof fn lemma_gc_steps_wf(p: Program2, c: Cert, s: State2, s2: State2)
    requires wf(p, c, s), accepted(p, c), s.heap.len() < 0x8000_0000, gc_steps(p, s, s2),
    ensures wf(p, c, s2), gc_shape(s, s2), small(s) ==> small(s2),
{
    let tr = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2;
    lemma_chain_wf(p, c, tr, tr.len() as int);
}

proof fn lemma_chain_wf(p: Program2, c: Cert, tr: Seq<State2>, n: int)
    requires gc_chain(p, tr), 1 <= n <= tr.len(), wf(p, c, tr[0]), accepted(p, c), tr[0].heap.len() < 0x8000_0000,
    ensures wf(p, c, tr[n - 1]), gc_shape(tr[0], tr[n - 1]),
    decreases n,
{
    if n > 1 {
        lemma_chain_wf(p, c, tr, n - 1);
        { let i = n - 2; assert(collection(p, tr[i], tr[i + 1])); assert(i + 1 == n - 1); }
        lemma_collection_wf(p, c, tr[n - 2], tr[n - 1]);
    }
}

/// Collections keep an unwinding state, the shape and kept values.
pub proof fn lemma_gc_steps_unw(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, s2: State2, v: Value)
    requires unw_ok(p, c, s, kt), accepted(p, c), gc_steps(p, s, s2),
    ensures unw_ok(p, c, s2, kt), gc_shape(s, s2), kept(s.heap, v) ==> kept(s2.heap, v),
{
    let tr = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2;
    lemma_chain_unw(p, c, tr, kt, v, tr.len() as int);
}

proof fn lemma_chain_unw(p: Program2, c: Cert, tr: Seq<State2>, kt: Seq<Kind>, v: Value, n: int)
    requires gc_chain(p, tr), 1 <= n <= tr.len(), unw_ok(p, c, tr[0], kt), accepted(p, c),
    ensures unw_ok(p, c, tr[n - 1], kt), gc_shape(tr[0], tr[n - 1]), kept(tr[0].heap, v) ==> kept(tr[n - 1].heap, v),
    decreases n,
{
    if n > 1 {
        lemma_chain_unw(p, c, tr, kt, v, n - 1);
        { let i = n - 2; assert(collection(p, tr[i], tr[i + 1])); assert(i + 1 == n - 1); }
        lemma_collection_unw(p, c, tr[n - 2], kt, tr[n - 1], v);
    }
}

/// Collections keep the shape (no invariant needed).
pub proof fn lemma_gc_steps_shape(p: Program2, s: State2, s2: State2)
    requires gc_steps(p, s, s2),
    ensures gc_shape(s, s2),
{
    let tr = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2;
    lemma_chain_shape(p, tr, tr.len() as int);
}

proof fn lemma_chain_shape(p: Program2, tr: Seq<State2>, n: int)
    requires gc_chain(p, tr), 1 <= n <= tr.len(),
    ensures gc_shape(tr[0], tr[n - 1]),
    decreases n,
{
    if n > 1 {
        lemma_chain_shape(p, tr, n - 1);
        { let i = n - 2; assert(collection(p, tr[i], tr[i + 1])); assert(i + 1 == n - 1); }
        let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, tr[n - 2], s1, ren, back, tr[n - 1]);
    }
}

// ---------------------------------------------------------------------------
// Steps and collections.

/// An allocation step: `k` slots dropped, `o` appended to the heap, its
/// reference pushed, the bci advanced by `len` (ALLOCATE: `k == 0`; a
/// double result of an operator: `k == 2`).
pub open spec fn alloc_push(s: State2, o: HeapObj, k: int, len: int) -> State2 {
    State2 {
        heap: s.heap.push(o),
        stack: s.stack.subrange(0, s.stack.len() - k).push(Value::Obj(s.heap.len() as usize)),
        bci: (s.bci + len) as usize,
        ..s
    }
}

/// A new object whose values are smis or null (a new instance, a double).
pub open spec fn plain_obj(p: Program2, o: HeapObj) -> bool {
    &&& !o.ro
    &&& forall|j: int| 0 <= j < obj_vals(o).len() ==> (#[trigger] obj_vals(o)[j] is Smi || obj_vals(o)[j] == null2(p))
}

/// Weak processing of the old objects does not depend on new ones.
proof fn lemma_weak_change_push(p: Program2, h: Seq<HeapObj>, o: HeapObj, i: int, o2: HeapObj)
    requires weak_change(p, h, i, o2), 0 <= i < h.len(),
    ensures weak_change(p, h.push(o), i, o2),
{
    let h2 = h.push(o);
    assert(h2[i] == h[i]);
    if !(o2 == h[i]) && !(is_map(p, h[i]) && o2 == reset_map(p, h[i])) {
        let m = choose|m: int| #[trigger] backing_array(p, h, m, i);
        assert(h2[m] == h[m]);
        let backing = h[m].body->Instance_0[MAP_BACKING_INDEX];
        let lc = builtin(p1(p), LIST_CLASS);
        let lac = builtin(p1(p), LARGE_ARRAY_CLASS);
        match backing {
            Value::Obj(bid) => { assert(h2[bid as int] == h[bid as int]); },
            _ => {},
        }
        assert(inst_field(h2, backing, lc, LIST_ARRAY_INDEX) == inst_field(h, backing, lc, LIST_ARRAY_INDEX));
        let arr = inst_field(h, backing, lc, LIST_ARRAY_INDEX)->Some_0;
        match arr {
            Value::Obj(aid) => { assert(h2[aid as int] == h[aid as int]); },
            _ => {},
        }
        assert(inst_field(h2, arr, lac, LARGE_ARRAY_VECTOR_INDEX) == inst_field(h, arr, lac, LARGE_ARRAY_VECTOR_INDEX));
        match inst_field(h, arr, lac, LARGE_ARRAY_VECTOR_INDEX) {
            Some(Value::Obj(vid)) => { assert(h2[vid as int] == h[vid as int]); },
            _ => {},
        }
        assert(backing_array(p, h2, m, i));
        let e = h[i].body->Array_0;
        let e2 = o2.body->Array_0;
        assert forall|j: int| 0 <= j < e.len() implies {
            ||| #[trigger] e2[j] == e[j]
            ||| j % 2 == 1 && e2[j] == null2(p) && match e[j] {
                    Value::Obj(id) => (id as int) < h2.len()
                        && h2[id as int].class_id as int != builtin(p1(p), TOMBSTONE_CLASS),
                    _ => false,
                }
        } by {
            match e[j] {
                Value::Obj(id) => { if (id as int) < h.len() { assert(h2[id as int] == h[id as int]); } },
                _ => {},
            }
        }
        assert(zapped_elems(p, h2, e, e2));
    }
}

/// An allocation commutes with a collection in which the new object
/// survives: collecting and then allocating is allocating and then
/// collecting.
pub proof fn lemma_collection_alloc(p: Program2, s: State2, s2: State2, o: HeapObj, k: int, len: int)
    requires collection(p, s, s2), plain_obj(p, o), 0 <= k <= s.stack.len(), p.roots.len() > 0, s.heap.len() < 0x8000_0000,
    ensures collection(p, alloc_push(s, o, k, len), alloc_push(s2, o, k, len)),
{
    let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, s, s1, ren, back, s2);
    let n = s.heap.len() as int;
    let t = alloc_push(s, o, k, len);
    let t1 = alloc_push(s1, o, k, len);
    let t2 = alloc_push(s2, o, k, len);
    let ren2 = ren.push(back.len() as int);
    let back2 = back.push(n);
    assert(n as usize as int == n);
    assert(s2.heap.len() == back.len() && back.len() <= n);
    // Weak processing.
    assert(t1.stack == t.stack);
    assert(t1 == (State2 { heap: t1.heap, ..t }));
    assert forall|i: int| 0 <= i < t.heap.len() implies #[trigger] weak_change(p, t.heap, i, t1.heap[i]) by {
        if i < n {
            assert(weak_change(p, s.heap, i, s1.heap[i]));
            lemma_weak_change_push(p, s.heap, o, i, s1.heap[i]);
            assert(t.heap == s.heap.push(o));
        }
    }
    assert(zapped(p, t, t1));
    // The compaction, with the new object last.
    let h = s1.heap;
    let h1 = t1.heap;
    assert forall|i: int| #[trigger] live(ren2, i) implies (0 <= i < n && live(ren, i)) || i == n by {}
    assert forall|i: int| 0 <= i < n implies #[trigger] live(ren2, i) == live(ren, i) && ren2[i] == ren[i] by {}
    assert forall|k2: int| 0 <= k2 < back2.len() implies live(ren2, #[trigger] back2[k2]) && ren2[back2[k2]] == k2 by {
        if k2 < back.len() { assert(live(ren, back[k2])); }
    }
    assert forall|i: int| #[trigger] live(ren2, i) implies ren2[i] < back2.len() && back2[ren2[i]] == i by {
        if i < n { assert(live(ren, i)); }
    }
    assert forall|i: int| 0 <= i < h1.len() && (#[trigger] h1[i]).ro implies ren2[i] == i by {
        if i < n { assert(h1[i] == h[i]); }
    }
    assert(fixed(ren, p.roots[0]));
    assert forall|i: int| 0 <= i < p.roots.len() implies fixed(ren2, #[trigger] p.roots[i]) by {
        assert(fixed(ren, p.roots[i]));
    }
    assert forall|i: int| 0 <= i < p.literals.len() implies fixed(ren2, #[trigger] p.literals[i]) by {
        assert(fixed(ren, p.literals[i]));
    }
    assert forall|j: int| 0 <= j < t1.stack.len() implies val_live(ren2, #[trigger] t1.stack[j]) by {
        if j < t1.stack.len() - 1 {
            assert(t1.stack[j] == s1.stack[j]);
            assert(val_live(ren, s1.stack[j]));
        } else {
            assert(t1.stack[j] == Value::Obj(n as usize));
            assert(ren2[n] == back.len());
        }
    }
    assert forall|j: int| 0 <= j < t1.globals.len() implies val_live(ren2, #[trigger] t1.globals[j]) by {
        assert(val_live(ren, s1.globals[j]));
    }
    assert(live(ren, s1.task as int));
    assert forall|i: int| #[trigger] live(ren2, i) implies refs_live(ren2, h1, i) by {
        if i < n {
            assert(live(ren, i));
            assert(refs_live(ren, h, i));
            assert(h1[i] == h[i]);
            assert forall|j: int| 0 <= j < obj_vals(h1[i]).len() implies val_live(ren2, #[trigger] obj_vals(h1[i])[j]) by {
                assert(val_live(ren, obj_vals(h[i])[j]));
            }
        } else {
            assert(h1[i] == o);
            assert forall|j: int| 0 <= j < obj_vals(h1[i]).len() implies val_live(ren2, #[trigger] obj_vals(h1[i])[j]) by {
                assert(obj_vals(o)[j] is Smi || obj_vals(o)[j] == null2(p));
            }
        }
    }
    assert(ren_ok(p, t1, ren2, back2));
    // The renamed state is the allocation after the collection.
    let r = renamed(t1, ren2, back2);
    assert forall|i: int| #[trigger] live(ren, i) implies ren_obj(ren2, h[i]) == ren_obj(ren, h[i]) by {
        assert(refs_live(ren, h, i));
        let vs = obj_vals(h[i]);
        assert(ren_vals(ren2, vs) =~= ren_vals(ren, vs)) by {
            assert forall|j: int| 0 <= j < vs.len() implies ren_val(ren2, vs[j]) == ren_val(ren, vs[j]) by {
                assert(val_live(ren, vs[j]));
            }
        }
    }
    assert(ren_obj(ren2, o) == o) by {
        let vs = obj_vals(o);
        assert(ren_vals(ren2, vs) =~= vs) by {
            assert forall|j: int| 0 <= j < vs.len() implies ren_val(ren2, vs[j]) == vs[j] by {
                if vs[j] == null2(p) { lemma_ren_fixed(ren2, null2(p)); }
            }
        }
    }
    assert(r.heap =~= t2.heap) by {
        assert forall|k2: int| 0 <= k2 < r.heap.len() implies r.heap[k2] == t2.heap[k2] by {
            if k2 < back.len() {
                assert(live(ren, back[k2]));
                assert(h1[back[k2]] == h[back[k2]]);
            }
        }
    }
    assert(s2.heap.len() == back.len());
    assert(r.stack =~= t2.stack) by {
        assert forall|j: int| 0 <= j < r.stack.len() implies r.stack[j] == t2.stack[j] by {
            if j < r.stack.len() - 1 {
                assert(t1.stack[j] == s1.stack[j]);
                assert(val_live(ren, s1.stack[j]));
                assert(s2.stack[j] == ren_val(ren, s1.stack[j]));
                assert(t2.stack[j] == s2.stack[j]);
            } else {
                assert(t1.stack[j] == Value::Obj(n as usize));
                assert(ren2[n] == back.len());
                assert(t2.stack[j] == Value::Obj(s2.heap.len() as usize));
            }
        }
    }
    assert(r.globals =~= t2.globals) by {
        assert forall|j: int| 0 <= j < r.globals.len() implies r.globals[j] == t2.globals[j] by {
            assert(val_live(ren, s1.globals[j]));
        }
    }
    assert(r == t2);
    assert(gc_by(p, t, t1, ren2, back2, t2));
}

/// The same for any number of collections.
pub proof fn lemma_gc_steps_alloc(p: Program2, s: State2, s2: State2, o: HeapObj, k: int, len: int)
    requires gc_steps(p, s, s2), plain_obj(p, o), 0 <= k <= s.stack.len(), p.roots.len() > 0, s.heap.len() < 0x8000_0000,
    ensures gc_steps(p, alloc_push(s, o, k, len), alloc_push(s2, o, k, len)),
{
    let tr = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2;
    let tr2 = Seq::new(tr.len(), |i: int| alloc_push(tr[i], o, k, len));
    assert forall|i: int| 0 <= i < tr2.len() - 1 implies #[trigger] collection(p, tr2[i], tr2[i + 1]) by {
        assert(collection(p, tr[i], tr[i + 1]));
        lemma_chain_shape(p, tr, i + 1);
        lemma_collection_alloc(p, tr[i], tr[i + 1], o, k, len);
    }
    assert(gc_chain(p, tr2));
    assert(tr2.last() == alloc_push(s2, o, k, len));
}

/// A PRIMITIVE step is the same step after collections.
pub proof fn lemma_gc_step_primitive(p: Program2, s: State2, s2: State2, module: u8, index: u16)
    requires
        step(p, s) == Outcome2::Primitive(s, module, index),
        cur_op(p, s) == 89,
        gc_shape(s, s2),
    ensures step(p, s2) == Outcome2::Primitive(s2, module, index),
{
    reveal(step);
    assert(instruction_ok(p, s2) == instruction_ok(p, s));
    assert(frame_height(s2) == frame_height(s));
}

/// The operands of a double operator stay doubles after a collection.
proof fn lemma_collection_double(p: Program2, s: State2, s2: State2, j: int)
    requires collection(p, s, s2), 0 <= j < s.stack.len(), is_double(as1(s), s.stack[j]), s.heap.len() < 0x8000_0000,
    ensures is_double(as1(s2), s2.stack[j]),
{
    let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, s, s1, ren, back, s2);
    let v = s.stack[j];
    let id = v->Obj_0 as int;
    assert(weak_change(p, s.heap, id, s1.heap[id]));
    assert(s1.heap[id] == s.heap[id]);
    assert(s1.stack[j] == v);
    assert(val_live(ren, v));
    assert(live(ren, id));
    assert(back[ren[id]] == id);
    assert(s2.stack[j] == ren_val(ren, v));
    assert(0 <= ren[id] < back.len());
    assert(ren[id] < 0x8000_0000);
    assert(ren[id] as usize as int == ren[id]);
    assert(s2.heap[ren[id]] == ren_obj(ren, s1.heap[back[ren[id]]]));
    assert(s2.heap[ren[id]].body is Double);
}

/// A double operator stays one after collections.
pub proof fn lemma_gc_steps_double(p: Program2, s: State2, s2: State2, op: u8)
    requires crate::v2::prim::allocates_double(p, s, op), gc_steps(p, s, s2), s.heap.len() < 0x8000_0000,
    ensures crate::v2::prim::allocates_double(p, s2, op),
{
    let tr = choose|tr: Seq<State2>| #[trigger] gc_chain(p, tr) && tr.len() >= 1 && tr[0] == s && tr.last() == s2;
    lemma_chain_double(p, tr, op, tr.len() as int);
}

proof fn lemma_chain_double(p: Program2, tr: Seq<State2>, op: u8, n: int)
    requires gc_chain(p, tr), 1 <= n <= tr.len(), crate::v2::prim::allocates_double(p, tr[0], op), tr[0].heap.len() < 0x8000_0000,
    ensures crate::v2::prim::allocates_double(p, tr[n - 1], op),
    decreases n,
{
    if n > 1 {
        lemma_chain_double(p, tr, op, n - 1);
        lemma_chain_shape(p, tr, n - 1);
        let i = n - 2;
        assert(collection(p, tr[i], tr[i + 1]));
        let (a, b) = (tr[i], tr[i + 1]);
        let (s1, ren, back) = choose|s1: State2, ren: Seq<int>, back: Seq<int>| #[trigger] gc_by(p, a, s1, ren, back, b);
        assert(b.stack.len() == a.stack.len() && b.frames == a.frames);
        let l = a.stack.len() as int;
        lemma_collection_double(p, a, b, l - 2);
        lemma_collection_double(p, a, b, l - 1);
        assert(at(b, 1) == b.stack[l - 2] && at(b, 0) == b.stack[l - 1]);
    }
}

} // verus!

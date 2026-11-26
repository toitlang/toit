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

//! The verifier's facts at an instruction, and steps that change only the
//! top frame's slots, the heap and the globals.

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

/// A mapped offset of an accepted method is an accepted instruction.
pub proof fn lemma_map_instr(p: Program2, c: Cert, trusted: bool, m: int, off: int)
    requires
        accepts(p, c, trusted),
        valid_method(p, m),
        !dead_block(p, c, m),
        map_at(c, m, off) is Some,
    ensures
        instr_ok(p, c, m, off, map_at(c, m, off)->0, trusted),
        wf_kinds(p, c, m, map_at(c, m, off)->0),
        ctx_ok(p, c, m, map_at(c, m, off)->0),
        shape_ok(p, c, m, map_at(c, m, off)->0),
{
    assert(method_ok(p, c, m, trusted));
    assert(c.maps[m][off] is Some);
}

/// A method with a context is a block and pins parameter 0.
pub proof fn lemma_block_method(p: Program2, c: Cert, trusted: bool, m: int)
    requires accepts(p, c, trusted), valid_method(p, m), ctx_of(c, m) is Some,
    ensures info(p, m).kind == KIND_BLOCK, pinned0(p, m), arity(p, m) >= 1, !dead_block(p, c, m),
{
    assert(method_ok(p, c, m, trusted));
    assert(method_table_ok(p, c, m));
}

/// Kind `Block(d, _)` with `d > 0` in a frame of method `m` makes `m` a block.
pub proof fn lemma_outer_ref_in_block(p: Program2, c: Cert, trusted: bool, m: int, k: Seq<Kind>, j: int)
    requires
        accepts(p, c, trusted), valid_method(p, m), wf_kinds(p, c, m, k), 0 <= j < k.len(),
        k[j] is Block, k[j]->Block_0 > 0,
    ensures info(p, m).kind == KIND_BLOCK, pinned0(p, m), arity(p, m) >= 1, ctx_of(c, m) is Some,
{
    assert(wf_kind(p, c, m, k, j));
    let d = k[j]->Block_0;
    assert(ctx_kinds(c, m, d as nat) is Some);
    assert(ctx_of(c, m) is Some);
    lemma_block_method(p, c, trusted, m);
}

/// The kinds of the top frame are the map at its bci.
pub proof fn lemma_top_kinds(p: Program2, c: Cert, s: State2)
    requires wf_task(p, c, s),
    ensures
        kinds_of(p, c, s, top_i(s)) == fmap(p, c, s, top_i(s)),
        fmap(p, c, s, top_i(s)).len() == slots(s, top_i(s)),
        slots(s, top_i(s)) == s.stack.len() - fbase(s, top_i(s)),
        map_at(c, fmethod(s, top_i(s)), foff(p, s, top_i(s))) == Some(kinds_of(p, c, s, top_i(s))),
        0 <= foff(p, s, top_i(s)),
        valid_method(p, fmethod(s, top_i(s))),
        !dead_block(p, c, fmethod(s, top_i(s))),
{
    reveal(wf_task);
    reveal(frame_ok);
    assert(frame_ok(p, c, s, top_i(s)));
    assert(fmap(p, c, s, top_i(s)).subrange(0, slots(s, top_i(s))) =~= fmap(p, c, s, top_i(s)));
}

pub proof fn lemma_wf_parts(p: Program2, c: Cert, s: State2)
    requires wf(p, c, s),
    ensures heap_ok(p, c, s.heap), globals_ok(c, s), consts_ok(p, s.heap), wf_task(p, c, s), running_ok(p, s),
{
    reveal(wf);
}

/// A mapped offset is inside its method, inside the bytecodes.
pub proof fn lemma_map_bound(p: Program2, c: Cert, trusted: bool, m: int, off: int)
    requires accepts(p, c, trusted), valid_method(p, m), map_at(c, m, off) is Some,
    ensures
        0 <= off < info(p, m).end - info(p, m).entry,
        info(p, m).entry + off < p.bytecodes.len(),
        p.bytecodes.len() < 0x1000_0000,
{
    assert(method_ok(p, c, m, trusted));
    assert(tables_ok(p, c));
}

pub proof fn lemma_task_basics(p: Program2, c: Cert, s: State2)
    requires wf_task(p, c, s),
    ensures
        s.frames.len() > 0,
        bases_ok(s),
        fbase(s, top_i(s)) <= s.stack.len(),
{
    reveal(wf_task);
}

/// The conditions of `lemma_local_step`.
pub open spec fn local_step(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>) -> bool {
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let k = kinds_of(p, c, s, t);
    &&& s2.frames == s.frames
    &&& s2.task == s.task
    &&& info(p, m).entry <= s2.bci
    &&& map_at(c, m, s2.bci - info(p, m).entry) == Some(k2)
    &&& s2.stack.len() == b + k2.len()
    &&& forall|x: int| 0 <= x < b ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& forall|j: int| 0 <= j < k2.len() ==>
            #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, t, kinds_of(p, c, s2, t), j, k2[j], s2.stack[b + j])
    &&& forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token ==>
            k2.subrange(0, j) == k.subrange(0, j)
    // A token slot keeps its token (format note 23): no local step
    // writes or pushes one.
    &&& forall|j: int| 0 <= j < k2.len() && (#[trigger] k2[j]) is Token ==> unchanged(p, c, s, s2, k2, j)
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> k2.len() >= 1 && s2.stack[b] == s.stack[b])
    &&& heap_ext(p, s.heap, s2.heap)
    &&& heap_ok(p, c, s2.heap)
    &&& globals_ok(c, s2)
    &&& consts_ok(p, s2.heap)
}

/// Slot `j` of the top frame keeps its kind and value.
pub open spec fn unchanged(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>, j: int) -> bool {
    let t = top_i(s);
    let b = fbase(s, t);
    let k = kinds_of(p, c, s, t);
    &&& j < k.len()
    &&& k2[j] == k[j]
    &&& s2.stack[b + j] == s.stack[b + j]
}

pub proof fn lemma_top_kinds_local(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>)
    requires wf_task(p, c, s), local_step(p, c, s, s2, k2),
    ensures
        kinds_of(p, c, s2, top_i(s)) == k2,
        top_i(s2) == top_i(s),
        fbase(s2, top_i(s)) == fbase(s, top_i(s)),
        slots(s2, top_i(s)) == k2.len(),
        fmethod(s2, top_i(s)) == fmethod(s, top_i(s)),
{
    assert(fmap(p, c, s2, top_i(s)) == k2);
    assert(k2.subrange(0, k2.len() as int) =~= k2);
}

#[verifier::spinoff_prover]
pub proof fn lemma_local_same_below(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>)
    requires
        wf_task(p, c, s), top_i(s) > 0,
        s2.frames == s.frames,
        s2.stack.len() >= fbase(s, top_i(s)),
        forall|x: int| 0 <= x < fbase(s, top_i(s)) ==> #[trigger] s2.stack[x] == s.stack[x],
        heap_grows(s.heap, s2.heap),
    ensures same_below(s, s2, top_i(s) - 1), bases_ok(s2),
{
    lemma_task_bases(p, c, s);
    let t = top_i(s);
    assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {}
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
}

pub proof fn lemma_task_bases(p: Program2, c: Cert, s: State2)
    requires wf_task(p, c, s),
    ensures s.frames.len() > 0, bases_ok(s), fbase(s, top_i(s)) <= s.stack.len(),
{
    reveal(wf_task);
}

pub proof fn lemma_conf_top_unchanged(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>, j: int)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        local_step(p, c, s, s2, k2),
        0 <= j < k2.len(),
        unchanged(p, c, s, s2, k2, j),
    ensures conf(p, c, s2, top_i(s), kinds_of(p, c, s2, top_i(s)), j, k2[j], s2.stack[fbase(s, top_i(s)) + j]),
{
    reveal(conf);
    reveal(pending_ok);
    reveal(good_ref);
    reveal(wf);
    reveal(wf_task);
    reveal(frame_ok);
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let k = kinds_of(p, c, s, t);
    let v = s.stack[b + j];
    lemma_top_kinds(p, c, s);
    lemma_top_kinds_local(p, c, s, s2, k2);
    assert(frame_ok(p, c, s, t));
    assert(conf(p, c, s, t, kinds_of(p, c, s, t), j, k[j], v));
    let off2 = s2.bci - info(p, m).entry;
    lemma_map_instr(p, c, trusted, m, off2);
    assert(wf_kind(p, c, m, k2, j));
    if t > 0 {
        lemma_local_same_below(p, c, s, s2, k2);
    }
    match k[j] {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    if d == 0 {
                        assert(ref_ok(s2, f as int, slot as int));
                    } else {
                        lemma_outer_ref_in_block(p, c, trusted, m, k2, j);
                        assert(pinned_ok(p, s, t));
                        reveal_with_fuel(context_frame, 2);
                        lemma_context_frame_lt(s, t, d as nat);
                        let r = s.stack[b];
                        assert(s2.stack[b] == r);
                        assert(slots(s2, t) >= 1);
                        match r {
                            Value::BlockRef(f1, _) => {
                                if (f1 as int) < t {
                                    lemma_context_frame_below(s, s2, f1 as int, t - 1, (d - 1) as nat);
                                }
                            },
                            _ => {},
                        }
                        assert(context_frame(s2, t, d as nat) == context_frame(s, t, d as nat));
                        lemma_kinds_below(p, c, s, s2, f as int, t - 1);
                        lemma_ref_ok_below(s, s2, t - 1, f as int, slot as int);
                    }
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_kinds_below(p, c, s, s2, f as int, t - 1);
                    lemma_ref_ok_below(s, s2, t - 1, f as int, slot as int);
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, g, hh) => {
                    assert(k2.subrange(0, j) == k.subrange(0, j));
                    assert(k2[j - 1] == k2.subrange(0, j)[j - 1]);
                    assert(k[j - 1] == k.subrange(0, j)[j - 1]);
                    if second {
                        // The first word below keeps its slot and its token.
                        let va = s.stack[b + j - 1];
                        assert(conf(p, c, s, t, k, j - 1, k[j - 1], va));
                        assert(k[j - 1] is Token);
                        assert(unchanged(p, c, s, s2, k2, j - 1));
                        assert(s2.stack[b + j - 1] == va);
                    } else {
                        match d {
                            Pending::Branch(f, bci, hb) => {
                                if (f as int) < t {
                                    lemma_kinds_below(p, c, s, s2, f as int, t - 1);
                                } else {
                                let tt = map_at(c, m, bci as int - info(p, m).entry)->0;
                                assert(k2.subrange(0, j) == k.subrange(0, j));
                                assert(frame_kinds_from(p, c, s, t, k, f as int) == k);
                                assert(frame_kinds_from(p, c, s2, t, k2, f as int) == k2);
                                assert(tt == k.subrange(0, tt.len() as int));
                                assert(k2.subrange(0, tt.len() as int) =~= k2.subrange(0, j).subrange(0, tt.len() as int));
                                assert(k.subrange(0, tt.len() as int) =~= k.subrange(0, j).subrange(0, tt.len() as int));
                                }
                            },
                            _ => {},
                        }
                    }
                },
                _ => {},
            }
        },
    }
}


/// The top frame after a local step.
pub proof fn lemma_local_top(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        local_step(p, c, s, s2, k2),
    ensures frame_ok(p, c, s2, top_i(s)),
{
    reveal(wf);
    reveal(frame_ok);
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    lemma_top_kinds(p, c, s);
    lemma_top_kinds_local(p, c, s, s2, k2);
    assert(frame_ok(p, c, s, t)) by { reveal(wf_task); }
    lemma_map_instr(p, c, trusted, m, s2.bci - info(p, m).entry);
    assert(frame_shape_ok(p, c, s2, t));
    assert forall|j: int| 0 <= j < slots(s2, t) implies
        #[trigger] conf(p, c, s2, t, kinds_of(p, c, s2, t), j, kinds_of(p, c, s2, t)[j], s2.stack[fbase(s2, t) + j]) by {
        if unchanged(p, c, s, s2, k2, j) {
            lemma_conf_top_unchanged(p, c, trusted, s, s2, k2, j);
        }
    }
    let i = info(p, m);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
        let r = s.stack[b];
        assert(receiver_ok(p, s, t));
        assert(s2.stack[b] == r);
        match r {
            Value::Obj(id) => {
                assert(s2.heap[id as int].class_id == s.heap[id as int].class_id);
            },
            _ => {},
        }
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
    assert(receiver_ok(p, s2, t));
    assert(pinned_ok(p, s2, t));
}

pub proof fn lemma_local_step(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        local_step(p, c, s, s2, k2),
    ensures wf(p, c, s2),
{
    reveal(wf);
    let t = top_i(s);
    lemma_top_kinds(p, c, s);
    lemma_top_kinds_local(p, c, s, s2, k2);
    assert(bases_ok(s) && s.frames.len() > 0) by { reveal(wf_task); }
    if t > 0 {
        lemma_local_same_below(p, c, s, s2, k2);
    }
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        if fi < t {
            lemma_same_below_down(s, s2, t - 1, fi);
            lemma_frame_below(p, c, s, s2, fi);
        } else {
            lemma_local_top(p, c, trusted, s, s2, k2);
        }
    }
    lemma_running_heap(p, s, s2);
    reveal(wf_task);
}

} // verus!

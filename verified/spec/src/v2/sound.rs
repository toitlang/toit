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

//! The invariant of the soundness proof of the structural verifier and
//! the statement of the theorems (see SOUNDNESS.md).
//!
//! `wf(p, c, s)`: the state `s` of an accepted program `p` (certificate
//! `c`) is described by the certificate: every frame's slots conform to
//! the stack map at the frame's current offset, block references point to
//! live block slots whose frames have their contexts' kinds, unwinding
//! tokens hold unwindings that can complete, handlers sit at TRY sites,
//! and the heap, globals and program constants hold only values. The
//! suspended tasks in the heap satisfy the same invariant.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, u16_at, smi};

verus! {

// ---------------------------------------------------------------------------
// Values and the heap.

/// A value word: a smi or a reference to an existing object.
pub open spec fn good(heap: Seq<HeapObj>, v: Value) -> bool {
    match v {
        Value::Smi(_) => true,
        Value::Obj(id) => (id as int) < heap.len(),
        _ => false,
    }
}

pub open spec fn unwind_vals_ok(heap: Seq<HeapObj>, u: Unwind) -> bool {
    match u {
        Unwind::Throw(v) => good(heap, v),
        Unwind::Return(_, v) => good(heap, v),
        Unwind::Branch(_, _, _) => true,
    }
}

/// The parts of an object's well-formedness that do not involve tasks:
/// its class exists, objects of classes with fields are instances with
/// their class's field count, and its contents are values.
pub open spec fn basic_obj_ok(p: Program2, heap: Seq<HeapObj>, o: HeapObj) -> bool {
    &&& (o.class_id as int) < class_count(p)
    &&& (is_field_class(p, o.class_id as int) && ifc(p, o.class_id as int) >= 1) ==>
            (o.body is Instance && o.body->Instance_0.len() == ifc(p, o.class_id as int))
    &&& match o.body {
        Body::Instance(f) => forall|i: int| 0 <= i < f.len() ==> good(heap, #[trigger] f[i]),
        Body::Array(e) => forall|i: int| 0 <= i < e.len() ==> good(heap, #[trigger] e[i]),
        Body::Stack(_, _) => false,
        Body::Pending(u) => unwind_vals_ok(heap, u),
        _ => true,
    }
}

/// The state of a suspended task, as a machine state (only the stack,
/// frames, handlers, bci and heap are used by the task invariant).
pub open spec fn susp_state(heap: Seq<HeapObj>, w: Seq<Value>, fr: Seq<Frame>, tr: Seq<Handler>, bci: usize) -> State2 {
    State2 { heap: heap, globals: Seq::empty(), stack: w, frames: fr, tries: tr, bci: bci, task: 0, next_task_id: 0 }
}

/// A suspended task is at a task_transfer PRIMITIVE.
pub open spec fn at_transfer(p: Program2, s: State2) -> bool {
    let b = s.bci as int;
    &&& b + 4 <= p.bytecodes.len()
    &&& p.bytecodes[b] == PRIMITIVE
    &&& p.bytecodes[b + 1] == 0
    &&& u16_at(p1(p), b + 2) == PRIM_TASK_TRANSFER
}

/// A suspended task: never ran (its code is a value), or a well-formed
/// task stopped at task_transfer.
pub open spec fn susp_ok(p: Program2, c: Cert, heap: Seq<HeapObj>, w: Seq<Value>, fr: Seq<Frame>, tr: Seq<Handler>, bci: usize) -> bool {
    if fr.len() == 0 {
        w.len() >= 1 ==> good(heap, w[0])
    } else {
        wf_task(p, c, susp_state(heap, w, fr, tr, bci)) && at_transfer(p, susp_state(heap, w, fr, tr, bci))
    }
}

pub open spec fn obj_ok(p: Program2, c: Cert, heap: Seq<HeapObj>, o: HeapObj) -> bool {
    &&& basic_obj_ok(p, heap, o)
    &&& match o.body {
        Body::Stack2(w, fr, tr, b) => susp_ok(p, c, heap, w, fr, tr, b),
        _ => true,
    }
}

#[verifier::opaque]
pub open spec fn heap_ok(p: Program2, c: Cert, heap: Seq<HeapObj>) -> bool {
    forall|i: int| 0 <= i < heap.len() ==> #[trigger] obj_ok(p, c, heap, heap[i])
}

// ---------------------------------------------------------------------------
// Frames.

pub open spec fn top_i(s: State2) -> int {
    s.frames.len() - 1
}

pub open spec fn fbase(s: State2, fi: int) -> int {
    s.frames[fi].base as int
}

/// The end (exclusive) of frame `fi`'s slots.
pub open spec fn limit(s: State2, fi: int) -> int {
    if fi + 1 < s.frames.len() { s.frames[fi + 1].base as int } else { s.stack.len() as int }
}

pub open spec fn slots(s: State2, fi: int) -> int {
    limit(s, fi) - fbase(s, fi)
}

pub open spec fn fmethod(s: State2, fi: int) -> int {
    s.frames[fi].method as int
}

/// The bci frame `fi` continues at: the top frame's bci, else the return
/// address of the frame above.
pub open spec fn fbci(s: State2, fi: int) -> int {
    if fi == top_i(s) { s.bci as int } else { s.frames[fi + 1].ret as int }
}

pub open spec fn foff(p: Program2, s: State2, fi: int) -> int {
    fbci(s, fi) - info(p, fmethod(s, fi)).entry
}

/// The map at the frame's offset (for a suspended frame it includes the
/// result its callee pushes, or the finally triple of a TRY).
pub open spec fn fmap(p: Program2, c: Cert, s: State2, fi: int) -> Seq<Kind> {
    map_at(c, fmethod(s, fi), foff(p, s, fi))->0
}

/// The kinds of frame `fi`'s slots.
pub open spec fn kinds_of(p: Program2, c: Cert, s: State2, fi: int) -> Seq<Kind> {
    fmap(p, c, s, fi).subrange(0, slots(s, fi))
}

/// Frame `g` is suspended in a TRY (its handler is installed).
pub open spec fn try_frame(s: State2, g: int) -> bool {
    exists|x: int| 0 <= x < s.tries.len() && (#[trigger] s.tries[x]).frame as int == g
}

pub open spec fn base_step(s: State2, fi: int) -> bool {
    s.frames[fi].base <= s.frames[fi + 1].base
}

pub open spec fn bases_ok(s: State2) -> bool {
    &&& forall|fi: int| 0 <= fi && fi + 1 < s.frames.len() ==> #[trigger] base_step(s, fi)
    &&& s.frames.len() > 0 ==> s.frames.last().base <= s.stack.len()
}

pub open spec fn frame_shape_ok(p: Program2, c: Cert, s: State2, fi: int) -> bool {
    let m = fmethod(s, fi);
    let n = slots(s, fi);
    &&& valid_method(p, m)
    &&& !dead_block(p, c, m)
    &&& 0 <= foff(p, s, fi)
    &&& map_at(c, m, foff(p, s, fi)) is Some
    &&& if fi == top_i(s) {
        fmap(p, c, s, fi).len() == n
    } else if try_frame(s, fi) {
        let k = fmap(p, c, s, fi);
        k.len() == n + 3 && k[n] is Val && k[n + 1] is Token && k[n + 2] is Val
    } else {
        let k = fmap(p, c, s, fi);
        k.len() == n + 1 && k[n] is Val
    }
}

/// The frame `depth` contexts out from frame `fi`: following the block's
/// own reference (parameter 0) of each block frame.
pub open spec fn context_frame(s: State2, fi: int, depth: nat) -> int
    decreases depth,
{
    if depth == 0 {
        fi
    } else if !(0 <= fi < s.frames.len()) || !(slots(s, fi) >= 1) || !(0 <= fbase(s, fi) < s.stack.len()) {
        -1
    } else {
        match s.stack[s.frames[fi].base as int] {
            Value::BlockRef(f, _) => if (f as int) < fi { context_frame(s, f as int, (depth - 1) as nat) } else { -1 },
            _ => -1,
        }
    }
}

/// The slot `slot` of frame `f` holds a block method created there, and
/// the frame's kinds below it are the block's context.
#[verifier::opaque]
pub open spec fn good_ref(p: Program2, c: Cert, s: State2, f: int, slot: int) -> bool {
    let k = kinds_of(p, c, s, f);
    let i = slot - fbase(s, f);
    &&& block_slot(p, c, fmethod(s, f), k, i)
    &&& ctx_ok_upto(p, c, fmethod(s, f), k, i)
}

/// An unwinding held by a token in slot `i` of frame `g`.
/// The kinds of frame `f` as seen from a token of frame `g` whose own
/// kinds are `kg`.
pub open spec fn frame_kinds_from(p: Program2, c: Cert, s: State2, g: int, kg: Seq<Kind>, f: int) -> Seq<Kind> {
    if f == g { kg } else { kinds_of(p, c, s, f) }
}

#[verifier::opaque]
pub open spec fn pending_ok(p: Program2, c: Cert, s: State2, g: int, kg: Seq<Kind>, i: int, u: Unwind) -> bool {
    match u {
        Unwind::Throw(v) => good(s.heap, v),
        Unwind::Return(f, v) => (f as int) <= g && good(s.heap, v),
        Unwind::Branch(f, bci, hb) => {
            let fi = f as int;
            let m = fmethod(s, fi);
            let off = bci as int - info(p, m).entry;
            let kf = frame_kinds_from(p, c, s, g, kg, fi);
            &&& 0 <= fi <= g
            &&& match map_at(c, m, off) {
                Some(t) => {
                    &&& 0 <= off
                    &&& hb as int == fbase(s, fi) + t.len()
                    &&& t.len() <= kf.len()
                    &&& t == kf.subrange(0, t.len() as int)
                    &&& (fi == g ==> t.len() + 1 <= i)
                },
                None => false,
            }
        },
    }
}

/// Value `v` in slot `j` of frame `fi` conforms to kind `k`.
#[verifier::opaque]
pub open spec fn conf(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, k: Kind, v: Value) -> bool {
    match k {
        Kind::Val => good(s.heap, v),
        Kind::Method(t) => v == Value::Smi(t as i64),
        Kind::Block(d, sl) => match v {
            Value::BlockRef(f, slot) => {
                &&& ref_ok(s, f as int, slot as int)
                &&& slot as int == fbase(s, f as int) + sl
                &&& if d == 0 {
                    f as int == fi
                } else {
                    &&& d > 0
                    &&& f as int == context_frame(s, fi, d as nat)
                    &&& good_ref(p, c, s, f as int, slot as int)
                }
            },
            _ => false,
        },
        Kind::Param => match v {
            Value::BlockRef(f, slot) => ref_ok(s, f as int, slot as int) && (f as int) < fi
                && good_ref(p, c, s, f as int, slot as int),
            _ => false,
        },
        Kind::Token => v == null2(p) || match v {
            Value::Obj(id) => (id as int) < s.heap.len() && match s.heap[id as int].body {
                Body::Pending(u) => pending_ok(p, c, s, fi, kf, j, u),
                _ => false,
            },
            _ => false,
        },
    }
}

pub open spec fn frame_conf(p: Program2, c: Cert, s: State2, fi: int) -> bool {
    forall|j: int| 0 <= j < slots(s, fi) ==>
        #[trigger] conf(p, c, s, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j])
}

/// `this` of a method with a receiver range is in the range.
pub open spec fn receiver_ok(p: Program2, s: State2, fi: int) -> bool {
    let m = fmethod(s, fi);
    let i = info(p, m);
    ((i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1) ==> {
        let r = s.stack[fbase(s, fi)];
        &&& slots(s, fi) >= 1
        &&& class_id_ok(as1(s), r)
        &&& i.recv_start as int <= class_id_of(p1(p), as1(s), r) < i.recv_end as int
    }
}

/// A pinned parameter 0 is still in the frame.
pub open spec fn pinned_ok(p: Program2, s: State2, fi: int) -> bool {
    pinned0(p, fmethod(s, fi)) && arity(p, fmethod(s, fi)) >= 1 ==> slots(s, fi) >= 1
}

#[verifier::opaque]
pub open spec fn frame_ok(p: Program2, c: Cert, s: State2, fi: int) -> bool {
    &&& frame_shape_ok(p, c, s, fi)
    &&& frame_conf(p, c, s, fi)
    &&& receiver_ok(p, s, fi)
    &&& pinned_ok(p, s, fi)
}

/// Handler `x` belongs to a frame suspended in its TRY: the frame above is
/// the try block, returning to the finally code.
pub open spec fn try_ok(s: State2, x: int) -> bool {
    let h = s.tries[x];
    let g = h.frame as int;
    &&& 0 <= g && g + 1 < s.frames.len()
    &&& s.frames[g + 1].ret == h.bci
    &&& s.frames[g + 1].base == h.height
    &&& (x > 0 ==> s.tries[x - 1].frame < h.frame)
}

/// The task part of the invariant (also for suspended tasks).
#[verifier::opaque]
pub open spec fn wf_task(p: Program2, c: Cert, s: State2) -> bool {
    &&& s.frames.len() > 0
    &&& bases_ok(s)
    &&& forall|fi: int| 0 <= fi < s.frames.len() ==> #[trigger] frame_ok(p, c, s, fi)
    &&& forall|x: int| 0 <= x < s.tries.len() ==> #[trigger] try_ok(s, x)
}

pub open spec fn globals_ok(c: Cert, s: State2) -> bool {
    &&& s.globals.len() == c.global_count
    &&& forall|g: int| 0 <= g < s.globals.len() ==> good(s.heap, #[trigger] s.globals[g])
}

pub open spec fn consts_ok(p: Program2, heap: Seq<HeapObj>) -> bool {
    &&& forall|i: int| 0 <= i < p.roots.len() ==> good(heap, #[trigger] p.roots[i])
    &&& forall|i: int| 0 <= i < p.literals.len() ==> good(heap, #[trigger] p.literals[i])
}

/// The invariant.
#[verifier::opaque]
pub open spec fn wf(p: Program2, c: Cert, s: State2) -> bool {
    &&& heap_ok(p, c, s.heap)
    &&& globals_ok(c, s)
    &&& consts_ok(p, s.heap)
    &&& wf_task(p, c, s)
}

/// Sizes far from the machine word (the machine has finite memory).
/// Sizes well inside a 32-bit word (states a few steps away from a
/// `small` one).
pub open spec fn roomy(s: State2) -> bool {
    &&& s.heap.len() < 0x8000_0000
    &&& s.stack.len() < 0x8000_0000
    &&& s.frames.len() < 0x8000_0000
    &&& s.tries.len() < 0x8000_0000
}

pub open spec fn small(s: State2) -> bool {
    &&& s.heap.len() < 0x4000_0000
    &&& s.stack.len() < 0x4000_0000
    &&& s.frames.len() < 0x4000_0000
    &&& s.tries.len() < 0x4000_0000
}

/// The program `p` with certificate `c` is accepted.
pub open spec fn accepted(p: Program2, c: Cert) -> bool {
    exists|trusted: bool| accepts(p, c, trusted)
}

// ---------------------------------------------------------------------------
// Oracle and loader assumptions.

/// What a primitive may do to the heap (the oracle assumption): objects
/// are only added, classes do not change, the machine's own objects
/// (suspended stacks, unwinding tokens) are neither touched nor created,
/// and every object stays well formed.
pub open spec fn prim_heap_ok(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& h.len() <= h2.len()
    &&& h2.len() < 0x4000_0000
    &&& forall|i: int| 0 <= i < h.len() ==> {
        &&& (#[trigger] h2[i]).class_id == h[i].class_id
        &&& (h[i].body is Stack2 || h[i].body is Pending) ==> h2[i].body == h[i].body
        &&& !(h[i].body is Stack2 || h[i].body is Pending) ==> !(h2[i].body is Stack2 || h2[i].body is Pending)
    }
    &&& forall|i: int| h.len() <= i < h2.len() ==> !((#[trigger] h2[i]).body is Stack2 || h2[i].body is Pending)
    &&& forall|i: int| 0 <= i < h2.len() ==> basic_obj_ok(p, h2, #[trigger] h2[i])
}

/// What the loader guarantees about the program heap and globals.
pub open spec fn loaded_ok(p: Program2, c: Cert, heap0: Seq<HeapObj>, globals0: Seq<Value>) -> bool {
    &&& heap0.len() < 0x2000_0000
    &&& forall|i: int| 0 <= i < heap0.len() ==> basic_obj_ok(p, heap0, #[trigger] heap0[i])
            && !(heap0[i].body is Stack2 || heap0[i].body is Pending)
    &&& globals0.len() == c.global_count
    &&& forall|g: int| 0 <= g < globals0.len() ==> good(heap0, #[trigger] globals0[g])
    &&& consts_ok(p, heap0)
}

// ---------------------------------------------------------------------------
// The theorem.

/// The outcome of a step from a well-formed state: not stuck; a next
/// state (or the state of a yield) is well formed; a PRIMITIVE leaves the
/// state for its completion (`completions_ok`); other halts end the
/// process or the task.
pub open spec fn outcome_ok(p: Program2, c: Cert, o: Outcome2) -> bool {
    match o {
        Outcome2::Stuck(_) => false,
        Outcome2::Next(s2) => wf(p, c, s2),
        Outcome2::Halt(s2, h) => h is Yield ==> wf(p, c, s2),
        Outcome2::Primitive(s2, _, _) => wf(p, c, s2),
    }
}

/// Every completion of a PRIMITIVE step from `s`: success or failure with
/// any heap and value the oracle may produce, a missing primitive, and the
/// task primitives completed by the machine.
pub open spec fn completions_ok(p: Program2, c: Cert, s: State2, module: u8, index: u16) -> bool {
    &&& forall|h2: Seq<HeapObj>, v: Value| prim_heap_ok(p, s.heap, h2) && good(h2, v) ==> {
            &&& outcome_ok(p, c, #[trigger] crate::v2::prim::prim_success(p, s, h2, v))
            &&& outcome_ok(p, c, crate::v2::prim::prim_failure(s, h2, v))
        }
    &&& outcome_ok(p, c, crate::v2::prim::prim_missing(p, s))
    &&& (module == 0 && index as int == PRIM_TASK_NEW ==>
            outcome_ok(p, c, crate::v2::prim::task_new_step(p, s, s.stack[fbase(s, top_i(s))])))
    &&& (module == 0 && index as int == PRIM_TASK_TRANSFER ==>
            outcome_ok(p, c, crate::v2::prim::task_transfer_step(p, s,
                s.stack[fbase(s, top_i(s))], s.stack[fbase(s, top_i(s)) + 1])))
}

} // verus!

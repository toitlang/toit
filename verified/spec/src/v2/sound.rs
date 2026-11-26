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
        _ => true,
    }
}

/// The state of a suspended task, as a machine state (only the stack,
/// frames, handlers, finally records, bci and heap are used by the task
/// invariant).
pub open spec fn susp_state(heap: Seq<HeapObj>, w: Seq<Value>, fr: Seq<Frame>, tr: Seq<Handler>, fins: Seq<Fin>, bci: usize) -> State2 {
    State2 { heap: heap, globals: Seq::empty(), stack: w, frames: fr, tries: tr, fins: fins, bci: bci, task: 0, next_task_id: 0 }
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
pub open spec fn susp_ok(p: Program2, c: Cert, heap: Seq<HeapObj>, w: Seq<Value>, fr: Seq<Frame>, tr: Seq<Handler>, fins: Seq<Fin>, bci: usize) -> bool {
    if fr.len() == 0 {
        w.len() >= 1 ==> good(heap, w[0])
    } else {
        wf_task(p, c, susp_state(heap, w, fr, tr, fins, bci)) && at_transfer(p, susp_state(heap, w, fr, tr, fins, bci))
    }
}

/// The class of tasks.
pub open spec fn task_class(p: Program2) -> int {
    crate::spec_common::builtin(p1(p), crate::spec_common::TASK_CLASS)
}

/// `v` refers to a suspended stack (a `Stack2` object).
pub open spec fn stack_ref(heap: Seq<HeapObj>, v: Value) -> bool {
    match v {
        Value::Obj(id) => (id as int) < heap.len() && heap[id as int].body is Stack2,
        _ => false,
    }
}

/// The fields of a task the machine owns (`v2::spec::TASK_STACK_FIELD`,
/// `TASK_ID_FIELD`): its stack field refers to a stack object, or is the
/// smi 0 once the task has terminated (detached); its id is a smi.
pub open spec fn task_obj_ok(heap: Seq<HeapObj>, o: HeapObj) -> bool {
    match o.body {
        Body::Instance(f) => f.len() >= 2 && f[1] is Smi && (f[0] == Value::Smi(0) || stack_ref(heap, f[0])),
        _ => false,
    }
}

/// The machine's view of the stack field of the running task: it refers
/// to a stack object (the stack the machine runs on).
pub open spec fn running_ok(p: Program2, s: State2) -> bool {
    &&& (s.task as int) < s.heap.len()
    &&& s.heap[s.task as int].class_id as int == task_class(p)
    &&& match s.heap[s.task as int].body {
        Body::Instance(f) => f.len() >= 2 && stack_ref(s.heap, f[0]),
        _ => false,
    }
}

pub open spec fn obj_ok(p: Program2, c: Cert, heap: Seq<HeapObj>, o: HeapObj) -> bool {
    &&& basic_obj_ok(p, heap, o)
    &&& o.class_id as int == task_class(p) ==> task_obj_ok(heap, o)
    &&& match o.body {
        Body::Stack2(w, fr, tr, fins, b) => susp_ok(p, c, heap, w, fr, tr, fins, b),
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

/// The kinds of frame `f` as seen from a token of frame `g` whose own
/// kinds are `kg`.
pub open spec fn frame_kinds_from(p: Program2, c: Cert, s: State2, g: int, kg: Seq<Kind>, f: int) -> Seq<Kind> {
    if f == g { kg } else { kinds_of(p, c, s, f) }
}

/// The unwinding a token in slot `i` of frame `g` resumes can complete:
/// non-local returns and branches target frames at or below `g`, a
/// branch a mapped offset whose map is a prefix of the target frame's
/// kinds (below the token for frame `g` itself).
#[verifier::opaque]
pub open spec fn pending_ok(p: Program2, c: Cert, s: State2, g: int, kg: Seq<Kind>, i: int, u: Resume) -> bool {
    match u {
        Resume::Throw => true,
        Resume::Return(f) => (f as int) <= g,
        Resume::Branch(f, bci, hb) => {
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
                    // A block frame's own reference: its slot holds the
                    // frame's method.
                    &&& (j == 0 && d == 1 ==> kinds_of(p, c, s, f as int)[sl] == Kind::Method(fmethod(s, fi)))
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
            Value::Smi(k) => fin_ok(p, c, s, fi, kf, j, k as int),
            _ => false,
        },
    }
}

/// The token in slot `j` of frame `fi` names finally record `k`: a record
/// of the frame whose token slot it is, with an unwinding that can
/// complete.
pub open spec fn fin_ok(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, k: int) -> bool {
    &&& 0 <= k < s.fins.len()
    &&& s.fins[k].frame as int == fi
    &&& s.fins[k].height as int + 1 == fbase(s, fi) + j
    &&& pending_ok(p, c, s, fi, kf, j, s.fins[k].resume)
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

/// Finally record `a` comes before `b`: by frame, then by height.
pub open spec fn fin_lt(a: Fin, b: Fin) -> bool {
    a.frame < b.frame || (a.frame == b.frame && a.height < b.height)
}

/// The finally records belong to live frames and are ordered by frame and
/// height; the records of a frame suspended in a TRY are below the TRY's
/// height (so entering its finally code keeps the order).
pub open spec fn fins_ok(s: State2) -> bool {
    &&& forall|k: int| 0 <= k < s.fins.len() ==> (#[trigger] s.fins[k]).frame < s.frames.len()
    &&& forall|a: int, b: int| 0 <= a < b < s.fins.len() ==> fin_lt(#[trigger] s.fins[a], #[trigger] s.fins[b])
    &&& forall|x: int, k: int| 0 <= x < s.tries.len() && 0 <= k < s.fins.len()
            && (#[trigger] s.fins[k]).frame == (#[trigger] s.tries[x]).frame ==>
            s.fins[k].height < s.tries[x].height
}

/// The task part of the invariant (also for suspended tasks).
#[verifier::opaque]
pub open spec fn wf_task(p: Program2, c: Cert, s: State2) -> bool {
    &&& s.frames.len() > 0
    &&& bases_ok(s)
    &&& forall|fi: int| 0 <= fi < s.frames.len() ==> #[trigger] frame_ok(p, c, s, fi)
    &&& forall|x: int| 0 <= x < s.tries.len() ==> #[trigger] try_ok(s, x)
    &&& fins_ok(s)
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
    &&& running_ok(p, s)
}

/// Sizes far from the machine word (the machine has finite memory).
/// Sizes well inside a 32-bit word (states a few steps away from a
/// `small` one).
pub open spec fn roomy(s: State2) -> bool {
    &&& s.heap.len() < 0x8000_0000
    &&& s.stack.len() < 0x8000_0000
    &&& s.frames.len() < 0x8000_0000
    &&& s.tries.len() < 0x8000_0000
    &&& s.fins.len() < 0x8000_0000
}

pub open spec fn small(s: State2) -> bool {
    &&& s.heap.len() < 0x4000_0000
    &&& s.stack.len() < 0x4000_0000
    &&& s.frames.len() < 0x4000_0000
    &&& s.tries.len() < 0x4000_0000
    &&& s.fins.len() < 0x4000_0000
}

/// The program `p` with certificate `c` is accepted.
pub open spec fn accepted(p: Program2, c: Cert) -> bool {
    exists|trusted: bool| accepts(p, c, trusted)
}

// ---------------------------------------------------------------------------
// Oracle and loader assumptions.

/// The fields a task's machine owns are the same in `o2` as in `o`.
pub open spec fn task_fields_kept(o: HeapObj, o2: HeapObj) -> bool {
    match (o.body, o2.body) {
        (Body::Instance(f), Body::Instance(f2)) => f.len() >= 2 ==> f2.len() >= 2 && f2[0] == f[0] && f2[1] == f[1],
        (Body::Instance(_), _) => false,
        _ => true,
    }
}

/// What a primitive may do to the heap (the oracle assumption): objects
/// are only added, classes do not change, the machine's own objects
/// (suspended stacks, tasks) are not created and their machine-owned
/// parts are not touched, and every object stays well formed.
pub open spec fn prim_heap_ok(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& h.len() <= h2.len()
    &&& h2.len() < 0x4000_0000
    &&& forall|i: int| 0 <= i < h.len() ==> {
        &&& (#[trigger] h2[i]).class_id == h[i].class_id
        &&& h[i].body is Stack2 ==> h2[i].body == h[i].body
        &&& !(h[i].body is Stack2) ==> !(h2[i].body is Stack2)
        &&& h[i].class_id as int == task_class(p) ==> task_fields_kept(h[i], h2[i])
    }
    &&& forall|i: int| h.len() <= i < h2.len() ==> !((#[trigger] h2[i]).body is Stack2)
            && h2[i].class_id as int != task_class(p)
    &&& forall|i: int| 0 <= i < h2.len() ==> basic_obj_ok(p, h2, #[trigger] h2[i])
}

/// Byte `b` continues a UTF-8 sequence (`10xx_xxxx`).
pub open spec fn utf8_cont(b: u8) -> bool {
    0x80 <= b && b < 0xc0
}

/// The length of the well-formed UTF-8 sequence that starts at index `i`
/// of `s`, or 0 if none does (Unicode, table 3-7: no overlong encodings,
/// no surrogates, nothing above U+10FFFF; the VM's
/// `Utils::is_valid_utf_8`).
pub open spec fn utf8_seq_len(s: Seq<u8>, i: int) -> int {
    let n = s.len() - i;
    let b = s[i];
    if b < 0x80 {
        1
    } else if 0xc2 <= b && b <= 0xdf {
        if n >= 2 && utf8_cont(s[i + 1]) { 2 } else { 0 }
    } else if 0xe0 <= b && b <= 0xef {
        // The second byte excludes overlong encodings (e0) and surrogates (ed).
        let lo: u8 = if b == 0xe0 { 0xa0 } else { 0x80 };
        let hi: u8 = if b == 0xed { 0x9f } else { 0xbf };
        if n >= 3 && lo <= s[i + 1] && s[i + 1] <= hi && utf8_cont(s[i + 2]) { 3 } else { 0 }
    } else if 0xf0 <= b && b <= 0xf4 {
        // The second byte excludes overlong encodings (f0) and code points
        // above U+10FFFF (f4).
        let lo: u8 = if b == 0xf0 { 0x90 } else { 0x80 };
        let hi: u8 = if b == 0xf4 { 0x8f } else { 0xbf };
        if n >= 4 && lo <= s[i + 1] && s[i + 1] <= hi && utf8_cont(s[i + 2]) && utf8_cont(s[i + 3]) { 4 } else { 0 }
    } else {
        0
    }
}

/// The bytes of `s` from index `i` on are a sequence of well-formed UTF-8
/// sequences.
pub open spec fn utf8_from(s: Seq<u8>, i: int) -> bool
    decreases s.len() - i,
{
    if i < 0 || i >= s.len() {
        i == s.len()
    } else {
        let n = utf8_seq_len(s, i);
        n > 0 && utf8_from(s, i + n)
    }
}

/// `s` is well-formed UTF-8.
#[verifier::opaque]
pub open spec fn utf8_ok(s: Seq<u8>) -> bool {
    utf8_from(s, 0)
}

/// An object of the program heap: well formed, neither a suspended stack
/// nor a task, and a string holds well-formed UTF-8.
pub open spec fn loaded_obj_ok(p: Program2, heap0: Seq<HeapObj>, o: HeapObj) -> bool {
    &&& basic_obj_ok(p, heap0, o)
    &&& !(o.body is Stack2)
    &&& o.class_id as int != task_class(p)
    &&& o.body is Str ==> utf8_ok(o.body->Str_0)
}

/// The heap part of `loaded_ok` (checked by `v2::heap_check::x_loaded_heap_ok`).
pub open spec fn loaded_heap_ok(p: Program2, heap0: Seq<HeapObj>) -> bool {
    &&& heap0.len() < 0x2000_0000
    &&& forall|i: int| 0 <= i < heap0.len() ==> loaded_obj_ok(p, heap0, #[trigger] heap0[i])
    &&& consts_ok(p, heap0)
}

/// What the loader guarantees about the program heap and globals
/// (checked by `v2::heap_check::x_loaded_ok`).
pub open spec fn loaded_ok(p: Program2, c: Cert, heap0: Seq<HeapObj>, globals0: Seq<Value>) -> bool {
    &&& loaded_heap_ok(p, heap0)
    &&& globals0.len() == c.global_count
    &&& forall|g: int| 0 <= g < globals0.len() ==> good(heap0, #[trigger] globals0[g])
}

// ---------------------------------------------------------------------------
// The theorem.

/// A completed outcome (not an oracle step) is good: a next state (or the
/// state of a yield) is well formed; other halts end the process or the
/// task.
pub open spec fn final_ok(p: Program2, c: Cert, o: Outcome2) -> bool {
    match o {
        Outcome2::Next(s2) => wf(p, c, s2),
        Outcome2::Halt(s2, h) => h is Yield ==> wf(p, c, s2),
        _ => false,
    }
}

/// The outcome of a step from a well-formed state: not stuck; a next
/// state (or the state of a yield) is well formed; a PRIMITIVE leaves the
/// state for its completion (`completions_ok`); every completion of a
/// raise is good (`final_ok`); other halts end the process or the task.
pub open spec fn outcome_ok(p: Program2, c: Cert, o: Outcome2) -> bool {
    match o {
        Outcome2::Stuck(_) => false,
        Outcome2::Next(s2) => wf(p, c, s2),
        Outcome2::Halt(s2, h) => h is Yield ==> wf(p, c, s2),
        Outcome2::Primitive(s2, _, _) => wf(p, c, s2),
        Outcome2::Raise(s2, v) => forall|o2: Outcome2| #[trigger] crate::v2::prim::raised(p, s2, v, o2) ==> final_ok(p, c, o2),
    }
}

/// Every completion of a PRIMITIVE step from `s`: the continuation after
/// any heap and result the default primitive contract allows
/// (`prim_default`, which every `prim_spec` refines), a missing primitive,
/// and the task primitives completed by the machine.
pub open spec fn completions_ok(p: Program2, c: Cert, s: State2, module: u8, index: u16) -> bool {
    &&& forall|h2: Seq<HeapObj>, r: crate::v2::prim::PrimRet| crate::v2::prim::prim_default(p, s.heap, h2, r) ==>
            outcome_ok(p, c, #[trigger] crate::v2::prim::prim_complete(p, s, h2, r))
    &&& outcome_ok(p, c, crate::v2::prim::prim_missing(p, s))
    &&& outcome_ok(p, c, crate::v2::prim::prim_denied(p, s))
    &&& (crate::v2::prim::machine_completed(module, index) ==>
            outcome_ok(p, c, crate::v2::prim::task_step(p, s, index)))
}

/// In the unchecked mode of trusted programs (`spec::unchecked_fail`) the
/// step from `s` does not reach a failed unchecked field access: the
/// assumption that lets a trusted program skip those checks. Always true
/// without the mode (untrusted programs: `accepts`).
pub open spec fn unchecked_ok(p: Program2, s: State2) -> bool {
    !p.unchecked || step(p, s) != Outcome2::Stuck(Stuck::FieldRange)
}

/// The opcode at the state's bci, an unchecked twin as its base (as the
/// step and the verifier see it).
pub open spec fn cur_op(p: Program2, s: State2) -> u8 {
    base_op(p.bytecodes[s.bci as int])
}

/// A step from `s` is not stuck, keeps the invariant, and every completion
/// of a PRIMITIVE does too; a PRIMITIVE names a primitive the certificate's
/// table (the policy's) allows with the frame's arity, or denies.
pub open spec fn step_ok(p: Program2, c: Cert, s: State2) -> bool {
    &&& outcome_ok(p, c, step(p, s))
    &&& match step(p, s) {
        Outcome2::Primitive(s2, module, index) => completions_ok(p, c, s2, module, index)
            && s2 == s && prim_listed(c.prim_arity, module as int, index as int, frame_height(s2)),
        _ => true,
    }
}

} // verus!

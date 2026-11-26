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

//! Soundness of the block slot accesses: LOAD_OUTER, STORE_OUTER,
//! LOAD_BLOCK, LOAD_OUTER_BLOCK.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_upto::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_ctx::*;
use crate::v2::sound_field::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of};

verus! {

// ---------------------------------------------------------------------------
// Context chains.

/// Following `a` contexts and then `b` more is following `a + b`.
pub proof fn lemma_context_frame_add(s: State2, fi: int, a: nat, b: nat)
    ensures context_frame(s, fi, a + b) == context_frame(s, context_frame(s, fi, a), b),
    decreases a,
{
    if a > 0 && b > 0 {
        if 0 <= fi < s.frames.len() && slots(s, fi) >= 1 && 0 <= fbase(s, fi) < s.stack.len() {
            match s.stack[s.frames[fi].base as int] {
                Value::BlockRef(f, _) => if (f as int) < fi {
                    assert((a + b - 1) as nat == ((a - 1) as nat + b) as nat);
                    lemma_context_frame_add(s, f as int, (a - 1) as nat, b);
                },
                _ => {},
            }
        }
    }
}

/// A local block reference `Block(0, s1)` in slot `i` of a frame points
/// to a good block slot of that frame.
pub proof fn lemma_local_block_good_ref(p: Program2, c: Cert, trusted: bool, s: State2, g: int, i: int, s1: int)
    requires
        accepts(p, c, trusted),
        frame_ok(p, c, s, g),
        bases_ok(s), 0 <= g < s.frames.len(),
        0 <= i < kinds_of(p, c, s, g).len(),
        kinds_of(p, c, s, g)[i] == Kind::Block(0, s1),
    ensures good_ref(p, c, s, g, fbase(s, g) + s1),
{
    reveal(frame_ok);
    reveal(good_ref);
    let m = fmethod(s, g);
    let fm = fmap(p, c, s, g);
    let kg = kinds_of(p, c, s, g);
    lemma_map_instr(p, c, trusted, m, foff(p, s, g));
    assert(frame_shape_ok(p, c, s, g));
    if g + 1 < s.frames.len() { assert(base_step(s, g)); }
    assert(fm.len() >= slots(s, g));
    assert(kg.len() == slots(s, g));
    assert(kg[i] == fm[i]);
    assert(wf_kind(p, c, m, fm, i));
    assert(s1 < i && block_slot(p, c, m, fm, s1));
    assert(kg[s1] == fm[s1]);
    assert(block_slot(p, c, m, kg, s1));
    assert forall|i2: int| 0 <= i2 <= s1 && i2 < kg.len() implies #[trigger] ctx_ok_at(p, c, m, kg, i2) by {
        assert(live_from(fm, i2)) by {
            assert(0 <= i < fm.len() && match fm[i] { Kind::Block(d, sx) => d == 0 && sx >= i2, _ => false });
        }
        assert(ctx_ok_at(p, c, m, fm, i2));
        assert(kg[i2] == fm[i2]);
        assert(kg.subrange(0, i2 + 1) =~= fm.subrange(0, i2 + 1));
    }
}

/// The reference in slot `r` from the top of a `Block(d, j)` kind.
pub proof fn lemma_outer_ref(p: Program2, c: Cert, trusted: bool, s: State2, r: int)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        0 <= r < cur_k(p, c, s).len(),
        top_kind(cur_k(p, c, s), r) is Block,
        ref_kinds(c, cur_m(s), cur_k(p, c, s), top_kind(cur_k(p, c, s), r)->Block_0) is Some,
    ensures ({
        let k = cur_k(p, c, s);
        let t = top_i(s);
        let m = cur_m(s);
        let d = top_kind(k, r)->Block_0;
        let j = top_kind(k, r)->Block_1;
        let fk = ref_kinds(c, m, k, d)->0;
        let v = at(s, r);
        let f = v->BlockRef_0 as int;
        let slot = v->BlockRef_1 as int;
        &&& has_slot(s, r)
        &&& v is BlockRef
        &&& ref_ok(s, f, slot)
        &&& slot == fbase(s, f) + j
        &&& slot < limit(s, f)
        &&& d >= 0
        &&& 0 <= f <= t
        &&& f == context_frame(s, t, d as nat)
        &&& block_slot(p, c, ref_method(c, m, d), fk, j)
        &&& fmethod(s, f) == ref_method(c, m, d)
        &&& fk.len() <= kinds_of(p, c, s, f).len()
        &&& kinds_of(p, c, s, f).subrange(0, fk.len() as int) == fk
        &&& frame_ok(p, c, s, f)
        &&& (d == 0 ==> f == t && fk == k)
        &&& (d > 0 ==> f < t && good_ref(p, c, s, f, slot) && info(p, m).kind == KIND_BLOCK
                && pinned0(p, m) && ctx_of(c, m) is Some)
    }),
{
    lemma_instr(p, c, trusted, s);
    lemma_at_conf(p, c, trusted, s, r);
    let k = cur_k(p, c, s);
    let t = top_i(s);
    let m = cur_m(s);
    let h = k.len() as int;
    let idx = h - 1 - r;
    let d = top_kind(k, r)->Block_0;
    let j = top_kind(k, r)->Block_1;
    let v = at(s, r);
    assert(wf_kind(p, c, m, k, idx));
    lemma_task_bases(p, c, s);
    assert forall|g: int| 0 <= g <= t implies #[trigger] frame_ok(p, c, s, g) by {
        reveal(wf_task);
    }
    reveal(conf);
    match v {
        Value::BlockRef(f0, slot0) => {
            let f = f0 as int;
            if d == 0 {
                assert(kinds_of(p, c, s, f).subrange(0, k.len() as int) =~= k);
            } else {
                lemma_outer_ref_in_block(p, c, trusted, m, k, idx);
                lemma_ctx_frame(p, c, trusted, s, t, d as nat);
            }
        },
        _ => {},
    }
}

// ---------------------------------------------------------------------------
// Copying a slot of a frame on the context chain into the top frame.

/// A value conforming to `kd` in frame `f` (`d` contexts out from the
/// top) conforms to `shift(kd, d)` in a non-zero slot of the top frame of
/// `s2`, which keeps the frames and the first `n >= 1` slots of the top.
pub proof fn lemma_conf_shift(p: Program2, c: Cert, s: State2, s2: State2, n: int, d: int, f: int,
    kf: Seq<Kind>, i: int, kd: Kind, v: Value, kf2: Seq<Kind>, j2: int)
    requires
        conf(p, c, s, f, kf, i, kd, v),
        !(kd is Token),
        0 <= d,
        f == context_frame(s, top_i(s), d as nat),
        0 <= f,
        top_i(s) >= 0,
        same_upto(s, s2, top_i(s), n),
        n >= 1,
        bases_ok(s),
        s2.frames == s.frames,
        s2.stack.len() == s.stack.len(),
        j2 != 0,
        match kd { Kind::Block(d1, s1) => d1 == 0 && d > 0 ==> good_ref(p, c, s, f, fbase(s, f) + s1), _ => true },
    ensures conf(p, c, s2, top_i(s), kf2, j2, shift(kd, d), v),
{
    reveal(conf);
    reveal(good_ref);
    let t = top_i(s);
    if d > 0 { lemma_context_frame_lt(s, t, d as nat); }
    assert(f <= t);
    match kd {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d1, s1) => {
            match v {
                Value::BlockRef(f1, slot1) => {
                    let dd = d + d1;
                    lemma_context_frame_add(s, t, d as nat, d1 as nat);
                    assert(f1 as int == context_frame(s, t, dd as nat));
                    if dd > 0 {
                        lemma_context_frame_upto(s, s2, t, n, t, dd as nat);
                        lemma_context_frame_lt(s, t, dd as nat);
                        lemma_upto_kinds(p, c, s, s2, t, n, f1 as int);
                        if d1 == 0 {
                            assert(f1 as int == f);
                        }
                        assert(good_ref(p, c, s, f1 as int, slot1 as int));
                    } else {
                        assert(f1 as int == t);
                    }
                    assert(ref_ok(s2, f1 as int, slot1 as int));
                    assert(fbase(s2, f1 as int) == fbase(s, f1 as int));
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f1, slot1) => {
                    lemma_upto_kinds(p, c, s, s2, t, n, f1 as int);
                    assert(ref_ok(s2, f1 as int, slot1 as int));
                },
                _ => {},
            }
        },
        Kind::Token => {},
    }
}

/// The slot `i` of frame `f` (kinds `kf`, a prefix `fk`) conforms.
pub proof fn lemma_slot_conf(p: Program2, c: Cert, s: State2, f: int, fk: Seq<Kind>, i: int)
    requires
        frame_ok(p, c, s, f),
        bases_ok(s), 0 <= f < s.frames.len(),
        0 <= i < fk.len(),
        fk.len() <= kinds_of(p, c, s, f).len(),
        kinds_of(p, c, s, f).subrange(0, fk.len() as int) == fk,
    ensures
        kinds_of(p, c, s, f)[i] == fk[i],
        i < slots(s, f),
        conf(p, c, s, f, kinds_of(p, c, s, f), i, fk[i], s.stack[fbase(s, f) + i]),
{
    reveal(frame_ok);
    assert(frame_shape_ok(p, c, s, f));
    if f + 1 < s.frames.len() { assert(base_step(s, f)); }
    assert(kinds_of(p, c, s, f)[i] == kinds_of(p, c, s, f).subrange(0, fk.len() as int)[i]);
    assert(kinds_of(p, c, s, f).len() == slots(s, f));
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_outer(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_OUTER,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_task_bases(p, c, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let b = cur_b(s);
    let len = 2int;
    let b1 = b1_of(p, m, off);
    assert(h >= 1);
    let d = top_kind(k, 0)->Block_0;
    let j = top_kind(k, 0)->Block_1;
    let fk = ref_kinds(c, m, k, d)->0;
    let i = j - b1;
    let kd = fk[i];
    let k2 = k.update(h - 1, shift(kd, d));
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    assert(!(kd is Token));
    lemma_outer_ref(p, c, trusted, s, 0);
    let v0 = at(s, 0);
    let f = v0->BlockRef_0 as int;
    let slot = v0->BlockRef_1 as int;
    let x = slot - b1;
    let v = s.stack[x];
    lemma_slot_conf(p, c, s, f, fk, i);
    assert(x == fbase(s, f) + i);
    assert(step(p, s) == op_load_outer(s, b1)) by { reveal(step); }
    let s2 = goto(put(s, 0, v), s.bci + len);
    assert(step(p, s) == Outcome2::Next(s2));
    lemma_map_instr(p, c, trusted, m, off + len);
    if h == 1 {
        // The block's own reference reloaded: the same value.
        assert(wf_kind(p, c, m, k, 0));
        assert(d > 0);
        let ctx = ctx_of(c, m)->0;
        assert(k[0] == Kind::Block(1, ctx.slot));
        assert(k2[0] == Kind::Block(1, ctx.slot));
        assert(kd == Kind::Block(0, ctx.slot)) by {
            match kd { Kind::Block(_, _) => {}, Kind::Method(_) => {}, _ => {} }
        }
        reveal(conf);
        assert(v == v0);
        assert(s2.stack =~= s.stack);
        assert(k2 =~= k);
        assert(k2.subrange(0, 1) =~= k.subrange(0, 1));
        lemma_wf_parts(p, c, s);
        assert(simple_step(p, c, s, s2, k2, len, 1));
        lemma_simple_step(p, c, trusted, s, s2, k2, len, 1);
    } else {
        lemma_wf_parts(p, c, s);
        assert(same_upto(s, s2, t, h - 1));
        match kd {
            Kind::Block(d1, s1) => {
                if d1 == 0 && d > 0 {
                    lemma_local_block_good_ref(p, c, trusted, s, f, i, s1);
                }
            },
            _ => {},
        }
        lemma_conf_shift(p, c, s, s2, h - 1, d, f, kinds_of(p, c, s, f), i, kd, v, k2, h - 1);
        assert(k2[h - 1] == shift(kd, d));
        assert(!(k2[h - 1] is Token));
        assert(k2.subrange(0, h - 1) =~= k.subrange(0, h - 1));
        assert(simple_step(p, c, s, s2, k2, len, h - 1));
        lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 1);
    }
}

/// The reference LOAD_OUTER_BLOCK pushes conforms.
pub proof fn lemma_conf_outer_block(p: Program2, c: Cert, s: State2, s2: State2, n: int, d: int, f: int,
    slot: int, i: int, j: int, fk: Seq<Kind>, om: int, kf2: Seq<Kind>, j2: int)
    requires
        bases_ok(s),
        top_i(s) >= 0,
        same_upto(s, s2, top_i(s), n),
        n >= 1,
        s2.frames == s.frames,
        s2.stack.len() == s.stack.len(),
        ref_ok(s, f, slot),
        slot == fbase(s, f) + j,
        0 <= i <= j,
        0 <= d,
        f == context_frame(s, top_i(s), d as nat),
        d == 0 ==> f == top_i(s),
        d > 0 ==> f < top_i(s) && good_ref(p, c, s, f, slot),
        fmethod(s, f) == om,
        s.stack.len() < 0x8000_0000,
        s.frames.len() < 0x8000_0000,
        block_slot(p, c, om, fk, i),
        fk.len() <= kinds_of(p, c, s, f).len(),
        kinds_of(p, c, s, f).subrange(0, fk.len() as int) == fk,
        j2 != 0,
    ensures conf(p, c, s2, top_i(s), kf2, j2, Kind::Block(d, i), Value::BlockRef(f as usize, (fbase(s, f) + i) as usize)),
{
    reveal(conf);
    reveal(good_ref);
    let t = top_i(s);
    let x = fbase(s, f) + i;
    let w = Value::BlockRef(f as usize, x as usize);
    assert((f as usize) as int == f);
    assert((x as usize) as int == x);
    assert(ref_ok(s2, f, x));
    assert(x == fbase(s2, f) + i);
    if d > 0 {
        lemma_context_frame_upto(s, s2, t, n, t, d as nat);
        lemma_upto_kinds(p, c, s, s2, t, n, f);
        let kg = kinds_of(p, c, s, f);
        assert(kg[i] == kg.subrange(0, fk.len() as int)[i]);
        assert(block_slot(p, c, om, kg, i));
        assert(ctx_ok_upto(p, c, om, kg, j));
        assert forall|i2: int| 0 <= i2 <= i && i2 < kg.len() implies #[trigger] ctx_ok_at(p, c, om, kg, i2) by {
            assert(ctx_ok_at(p, c, om, kg, i2));
        }
        assert(good_ref(p, c, s2, f, x));
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_outer_block(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_OUTER_BLOCK,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_task_bases(p, c, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let b = cur_b(s);
    let len = 2int;
    let b1 = b1_of(p, m, off);
    assert(h >= 1);
    let d = top_kind(k, 0)->Block_0;
    let j = top_kind(k, 0)->Block_1;
    let fk = ref_kinds(c, m, k, d)->0;
    let i = j - b1;
    let om = ref_method(c, m, d);
    let k2 = k.update(h - 1, Kind::Block(d, i));
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    assert(block_slot(p, c, om, fk, i));
    lemma_outer_ref(p, c, trusted, s, 0);
    let v0 = at(s, 0);
    let f = v0->BlockRef_0 as int;
    let slot = v0->BlockRef_1 as int;
    let x = slot - b1;
    let w = Value::BlockRef(f as usize, x as usize);
    assert(x == fbase(s, f) + i);
    assert(step(p, s) == op_load_outer_block(s, b1)) by { reveal(step); }
    let s2 = goto(put(s, 0, w), s.bci + len);
    assert(step(p, s) == Outcome2::Next(s2));
    lemma_map_instr(p, c, trusted, m, off + len);
    lemma_wf_parts(p, c, s);
    if h == 1 {
        assert(wf_kind(p, c, m, k, 0));
        assert(d > 0);
        let ctx = ctx_of(c, m)->0;
        assert(k[0] == Kind::Block(1, ctx.slot));
        assert(k2[0] == Kind::Block(1, ctx.slot));
        assert(b1 == 0);
        assert(w == v0);
        assert(s2.stack =~= s.stack);
        assert(k2 =~= k);
        assert(k2.subrange(0, 1) =~= k.subrange(0, 1));
        assert(simple_step(p, c, s, s2, k2, len, 1));
        lemma_simple_step(p, c, trusted, s, s2, k2, len, 1);
    } else {
        assert(same_upto(s, s2, t, h - 1));
        lemma_conf_outer_block(p, c, s, s2, h - 1, d, f, slot, i, j, fk, om, k2, h - 1);
        assert(s2.stack[b + (h - 1)] == w);
        assert(k2[h - 1] == Kind::Block(d, i));
        assert(k2.subrange(0, h - 1) =~= k.subrange(0, h - 1));
        assert(simple_step(p, c, s, s2, k2, len, h - 1));
        lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 1);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_block(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_BLOCK,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_task_bases(p, c, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let b = cur_b(s);
    let len = 2int;
    let b1 = b1_of(p, m, off);
    let i = h - 1 - b1;
    let k2 = k.push(Kind::Block(0, i));
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    assert(0 <= i < h);
    let w = Value::BlockRef(t as usize, (b + i) as usize);
    assert(step(p, s) == op_load_block(s, b1)) by { reveal(step); }
    let s2 = goto(push(s, w), s.bci + len);
    assert(step(p, s) == Outcome2::Next(s2));
    lemma_wf_parts(p, c, s);
    assert(conf(p, c, s2, t, k2, h, Kind::Block(0, i), w)) by {
        reveal(conf);
        assert(ref_ok(s2, t, b + i));
    }
    assert(k2[h] == Kind::Block(0, i));
    assert(s2.stack[b + h] == w);
    assert(k2.subrange(0, h) =~= k.subrange(0, h));
    assert(simple_step(p, c, s, s2, k2, len, h));
    lemma_simple_step(p, c, trusted, s, s2, k2, len, h);
}

// ---------------------------------------------------------------------------
// STORE_OUTER: a write into a value slot of a frame below the top.

/// The state with stack slot `x` replaced by `w`.
pub open spec fn upd(s: State2, x: int, w: Value) -> State2 {
    State2 { stack: s.stack.update(x, w), ..s }
}

pub open spec fn plain_write(s: State2, x: int, w: Value) -> bool {
    0 <= x < s.stack.len() && !(s.stack[x] is BlockRef) && !(s.stack[x] is Token) && !(w is BlockRef)
}

pub proof fn lemma_context_frame_write(s: State2, x: int, w: Value, fi: int, d: nat)
    requires plain_write(s, x, w),
    ensures context_frame(upd(s, x, w), fi, d) == context_frame(s, fi, d),
    decreases d,
{
    let s2 = upd(s, x, w);
    if d > 0 && 0 <= fi < s.frames.len() && slots(s, fi) >= 1 && 0 <= fbase(s, fi) < s.stack.len() {
        let y = fbase(s, fi);
        if y != x {
            assert(s2.stack[y] == s.stack[y]);
            match s.stack[y] {
                Value::BlockRef(f, _) => if (f as int) < fi { lemma_context_frame_write(s, x, w, f as int, (d - 1) as nat); },
                _ => {},
            }
        }
    }
}

pub proof fn lemma_kinds_write(p: Program2, c: Cert, s: State2, x: int, w: Value, g: int)
    requires plain_write(s, x, w),
    ensures
        kinds_of(p, c, upd(s, x, w), g) == kinds_of(p, c, s, g),
        fmap(p, c, upd(s, x, w), g) == fmap(p, c, s, g),
        slots(upd(s, x, w), g) == slots(s, g),
        limit(upd(s, x, w), g) == limit(s, g),
        fbase(upd(s, x, w), g) == fbase(s, g),
        fmethod(upd(s, x, w), g) == fmethod(s, g),
        foff(p, upd(s, x, w), g) == foff(p, s, g),
        top_i(upd(s, x, w)) == top_i(s),
{
}

/// Conformance does not depend on a plain stack slot.
pub proof fn lemma_conf_write(p: Program2, c: Cert, s: State2, x: int, w: Value, g: int, kf: Seq<Kind>, j: int, kd: Kind, v: Value)
    requires plain_write(s, x, w), conf(p, c, s, g, kf, j, kd, v),
    ensures conf(p, c, upd(s, x, w), g, kf, j, kd, v),
{
    reveal(conf);
    reveal(good_ref);
    reveal(pending_ok);
    let s2 = upd(s, x, w);
    match kd {
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_context_frame_write(s, x, w, g, d as nat);
                    lemma_kinds_write(p, c, s, x, w, f as int);
                    lemma_kinds_write(p, c, s, x, w, g);
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_kinds_write(p, c, s, x, w, f as int);
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, _, _) => {
                    lemma_kinds_write(p, c, s, x, w, g);
                    if second && 0 <= fbase(s, g) + j - 1 < s.stack.len() {
                        assert(s2.stack[fbase(s, g) + j - 1] == s.stack[fbase(s, g) + j - 1]);
                    }
                    match d {
                        Pending::Branch(f, bci, hb) => {
                            lemma_kinds_write(p, c, s, x, w, f as int);
                            assert(frame_kinds_from(p, c, s2, g, kf, f as int) == frame_kinds_from(p, c, s, g, kf, f as int));
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

/// Slot `x` of the stack is slot `i` of frame `f` and of no other frame.
pub proof fn lemma_slot_owner(s: State2, f: int, i: int, g: int, j: int)
    requires
        bases_ok(s),
        0 <= f < s.frames.len(), 0 <= g < s.frames.len(),
        0 <= i < slots(s, f), 0 <= j < slots(s, g),
        fbase(s, g) + j == fbase(s, f) + i,
    ensures g == f, j == i,
{
    if g < f {
        lemma_limit_below(s, g, f);
    } else if f < g {
        lemma_limit_below(s, f, g);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_frame_write(p: Program2, c: Cert, s: State2, f: int, i: int, w: Value, g: int)
    requires
        wf_task(p, c, s),
        plain_write(s, fbase(s, f) + i, w),
        0 <= f < s.frames.len(),
        0 <= i < slots(s, f),
        kinds_of(p, c, s, f)[i] == Kind::Val,
        good(s.heap, w),
        !(i == 0 && pinned0(p, fmethod(s, f))),
        0 <= g < s.frames.len(),
    ensures frame_ok(p, c, upd(s, fbase(s, f) + i, w), g),
{
    reveal(wf_task);
    reveal(frame_ok);
    let x = fbase(s, f) + i;
    let s2 = upd(s, x, w);
    assert(frame_ok(p, c, s, g));
    lemma_kinds_write(p, c, s, x, w, g);
    assert(try_frame(s2, g) == try_frame(s, g));
    assert(frame_shape_ok(p, c, s2, g));
    let kg = kinds_of(p, c, s, g);
    assert forall|j: int| 0 <= j < slots(s2, g) implies
        #[trigger] conf(p, c, s2, g, kinds_of(p, c, s2, g), j, kinds_of(p, c, s2, g)[j], s2.stack[fbase(s2, g) + j]) by {
        assert(conf(p, c, s, g, kg, j, kg[j], s.stack[fbase(s, g) + j]));
        if fbase(s, g) + j == x {
            lemma_slot_owner(s, f, i, g, j);
            lemma_conf_val(p, c, s2, g, kg, j, w);
        } else {
            assert(s2.stack[fbase(s, g) + j] == s.stack[fbase(s, g) + j]);
            lemma_conf_write(p, c, s, x, w, g, kg, j, kg[j], s.stack[fbase(s, g) + j]);
        }
    }
    let m = fmethod(s, g);
    let mi = info(p, m);
    if (mi.kind == KIND_METHOD || mi.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(mi) && arity(p, m) >= 1 {
        assert(receiver_ok(p, s, g));
        if fbase(s, g) == x {
            lemma_slot_owner(s, f, i, g, 0);
        }
        let r = s.stack[fbase(s, g)];
        assert(s2.stack[fbase(s, g)] == r);
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
    assert(receiver_ok(p, s2, g));
    assert(pinned_ok(p, s2, g));
}

#[verifier::spinoff_prover]
pub proof fn lemma_wf_write(p: Program2, c: Cert, s: State2, f: int, i: int, w: Value)
    requires
        wf(p, c, s),
        plain_write(s, fbase(s, f) + i, w),
        0 <= f < s.frames.len(),
        0 <= i < slots(s, f),
        kinds_of(p, c, s, f)[i] == Kind::Val,
        good(s.heap, w),
        !(i == 0 && pinned0(p, fmethod(s, f))),
    ensures wf(p, c, upd(s, fbase(s, f) + i, w)),
{
    reveal(wf);
    let x = fbase(s, f) + i;
    let s2 = upd(s, x, w);
    assert forall|g: int| 0 <= g < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, g) by {
        lemma_frame_write(p, c, s, f, i, w, g);
    }
    reveal(wf_task);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_store_outer(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == STORE_OUTER,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_task_bases(p, c, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let b = cur_b(s);
    let len = 2int;
    let b1 = b1_of(p, m, off);
    assert(h >= 2);
    let d = top_kind(k, 1)->Block_0;
    let j = top_kind(k, 1)->Block_1;
    let fk = ref_kinds(c, m, k, d)->0;
    let i = j - b1;
    let om = ref_method(c, m, d);
    let k2 = pop_push(k, 2, Some(Kind::Val));
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    assert(d >= 1 && fk[i] is Val && is_val(top_kind(k, 0)) && !(i == 0 && pinned0(p, om)));
    lemma_outer_ref(p, c, trusted, s, 1);
    lemma_at_good(p, c, trusted, s, 0);
    let v = at(s, 0);
    let v1 = at(s, 1);
    let f = v1->BlockRef_0 as int;
    let slot = v1->BlockRef_1 as int;
    let x = slot - b1;
    assert(x == fbase(s, f) + i);
    lemma_limit_below(s, f, t);
    assert(x < b);
    assert(step(p, s) == op_store_outer(s, b1)) by { reveal(step); }
    let s1 = drop(s, 2);
    let s2 = goto(push(State2 { stack: s1.stack.update(x, v), ..s1 }, v), s.bci + len);
    assert(step(p, s) == Outcome2::Next(s2));
    // The old value of the slot is a plain value.
    lemma_slot_conf(p, c, s, f, fk, i);
    lemma_val_good(p, c, s, f, kinds_of(p, c, s, f), i, Kind::Val, s.stack[x]);
    let sm = upd(s, x, v);
    lemma_wf_write(p, c, s, f, i, v);
    // The block's own reference stays in slot 0: at least 3 slots.
    lemma_map_instr(p, c, trusted, m, off + len);
    let ctx = ctx_of(c, m)->0;
    assert(k2[0] == Kind::Block(1, ctx.slot));
    assert(h >= 3);
    // Then a local step from `sm`.
    lemma_kinds_write(p, c, s, x, v, t);
    assert(cur_k(p, c, sm) == k);
    lemma_conf_val(p, c, s2, t, k2, h - 2, v);
    assert(k2[h - 2] == Kind::Val);
    assert(s2.stack[b + (h - 2)] == v);
    assert(k2.subrange(0, h - 2) =~= k.subrange(0, h - 2));
    assert forall|y: int| 0 <= y < b + (h - 2) implies #[trigger] s2.stack[y] == sm.stack[y] by {}
    assert(simple_step(p, c, sm, s2, k2, len, h - 2));
    lemma_simple_step(p, c, trusted, sm, s2, k2, len, h - 2);
}

pub proof fn lemma_step_block(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_block(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == LOAD_OUTER {
        lemma_load_outer(p, c, trusted, s);
    } else if op == STORE_OUTER {
        lemma_store_outer(p, c, trusted, s);
    } else if op == LOAD_BLOCK {
        lemma_load_block(p, c, trusted, s);
    } else {
        lemma_load_outer_block(p, c, trusted, s);
    }
}

} // verus!

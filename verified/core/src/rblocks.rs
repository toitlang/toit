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

//! Blocks, tail calls and the special globals on registers (the fast
//! paths; DESIGN.md "Run loop").
//!
//! LOAD_BLOCK, LOAD_OUTER, STORE_OUTER and LOAD_OUTER_BLOCK are steps
//! inside the top frame (`rnext`/`rsame`, as regs.rs): a block reference
//! names an object-stack position `i` (from the bottom), which is the array
//! index `end - 1 - i`. INVOKE_BLOCK is a call: the fast path checks as
//! `rcalls::call_fast` does (room, no preemption
//! request), drops the extra arguments and pushes the frame
//! (`rcalls::push_call`); too few arguments (a raise) go to the bridge.
//!
//! INVOKE_STATIC_TAIL and INVOKE_INITIALIZER_TAIL replace the top frame's
//! method natively under the same check (the call's room check covers the
//! replaced frame's room);
//! everything else (a failing receiver check, a bad initializer, finally
//! records, preemption) and INVOKE_LAMBDA_TAIL go to the bridge.
//!
//! LOAD_GLOBAL_VAR_LAZY(_WIDE) loads an initialized global natively (the
//! initializer call goes to the bridge); LOAD/STORE_GLOBAL_VAR_DYNAMIC run
//! natively unless the index is bad (a raise, the bridge).

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::rcalls::{call_fast, push_call};
use crate::calls::*;
use crate::blocks::ref_slot;
#[cfg(verus_keep_ghost)]
use crate::blocks::{lemma_slot, lemma_block_target, lemma_block_decode};
#[cfg(verus_keep_ghost)]
use crate::tail::{replace_ready, lemma_frames_method};
use crate::ffi::V2Method;
use toit_spec::types::{Value, Frame};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::value_operands;

verus! {

// ---------------------------------------------------------------------------
// Blocks.

/// LOAD_BLOCK k: pushes a reference to slot k of the top frame.
#[inline(always)]
pub fn op_load_block(m: &mut Machine, r: &mut Regs, p: &Program, k: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_block(old(m).g@, k as int) is Stuck),
        old(r).ip@ + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_load_block(old(m).g@, k as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g = m.g@;
    proof {
        m0.lemma_frame(p);
        assert(m0.ftop / FRAME_WORDS == g.frames.len());
    }
    let slot = r.end.diff(r.sp) - 1 - k;
    let f = r.fr.diff(m.mem.slot(0)) / FRAME_WORDS - 1;
    let ghost v = Value::BlockRef(f, slot);
    let w = smi_of((f * 0x1_0000 + slot) as i64);
    proof {
        assert(sp::top_index(g) as usize == f);
        assert((g.stack.len() - 1 - k) as usize == slot);
    }
    push_next(m, r, p, w, 2, Ghost(v))
}

/// LOAD_OUTER k: replaces the block reference on top by the slot k below
/// the block's slot.
#[inline(always)]
pub fn op_load_outer(m: &mut Machine, r: &mut Regs, p: &Program, k: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_outer(old(m).g@, k as int) is Stuck),
        old(r).ip@ + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_load_outer(old(m).g@, k as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g = m.g@;
    proof { m0.lemma_at(p, 0); }
    let ghost v = sp::at(g, 0);
    let w = at(m, r, 0);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let i = slot - k;
    proof { lemma_slot(&m0, p, i as int); }
    let x = r.end.offset(-((i + 1) as isize)).read(0, &m.mem);
    r.sp.write(0, x, &mut m.mem);
    r.ip = r.ip.offset(2 as isize);
    let ghost g1 = sp::goto(sp::put(g, 0, g.stack[i as int]), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1, x));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != g.stack.len() - 1 { assert(g1.stack[j] == g.stack[j]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// STORE_OUTER k: stores the top value into the slot k below the block's
/// slot; the block reference is dropped, the value stays.
#[inline(always)]
pub fn op_store_outer(m: &mut Machine, r: &mut Regs, p: &Program, k: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_store_outer(old(m).g@, k as int) is Stuck),
        old(r).ip@ + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_store_outer(old(m).g@, k as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g = m.g@;
    proof {
        m0.lemma_at(p, 0);
        m0.lemma_at(p, 1);
        m0.lemma_frame(p);
    }
    let ghost v = sp::at(g, 1);
    let x = at(m, r, 0);
    let w = at(m, r, 1);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let i = slot - k;
    proof { lemma_slot(&m0, p, i as int); }
    r.end.offset(-((i + 1) as isize)).write(0, x, &mut m.mem);
    let s = r.sp.offset(1);
    s.write(0, x, &mut m.mem);
    r.sp = s;
    r.ip = r.ip.offset(2 as isize);
    let ghost s1 = sp::drop(g, 2);
    let ghost g1 = sp::goto(sp::push(State2 { stack: s1.stack.update(i as int, sp::at(g, 0)), ..s1 }, sp::at(g, 0)), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let t = m0.top + 1;
        let h = g.stack.len();
        assert(g1.stack.len() == h - 1);
        assert forall|j: int| 0 <= j < h - 1 implies #[trigger] m1.words()[j] == enc(m0.addr(), g1.stack[j]) by {
            assert(m1.words()[j] == m1.mem@[m1.len - 1 - j]);
            if j == h - 2 {
                assert(m1.len - 1 - j == t);
            } else if j == i {
            } else {
                assert(m1.mem@[m1.len - 1 - j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == enc_seq(m0.addr(), g.stack)[j]);
                assert(g1.stack[j] == g.stack[j]);
            }
        }
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != h - 2 && j != i { assert(g1.stack[j] == g.stack[j]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// LOAD_OUTER_BLOCK k: replaces the block reference on top by a reference
/// to the slot k below the block's slot, in the same frame: the word
/// minus `2 * k`.
#[inline(always)]
pub fn op_load_outer_block(m: &mut Machine, r: &mut Regs, p: &Program, k: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_outer_block(old(m).g@, k as int) is Stuck),
        old(r).ip@ + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_load_outer_block(old(m).g@, k as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g = m.g@;
    proof { m0.lemma_at(p, 0); }
    let ghost v = sp::at(g, 0);
    let ghost f = v->BlockRef_0;
    let ghost s = v->BlockRef_1;
    let w = at(m, r, 0);
    let ghost nv = Value::BlockRef(f, (s - k) as usize);
    proof {
        lemma_block_decode(f, s);
        lemma_block_decode(f, (s - k) as usize);
    }
    let w2 = w - 2 * k;
    r.sp.write(0, w2, &mut m.mem);
    r.ip = r.ip.offset(2 as isize);
    let ghost g1 = sp::goto(sp::put(g, 0, nv), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1, w2));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != g.stack.len() - 1 { assert(g1.stack[j] == g.stack[j]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// INVOKE_BLOCK n: calls the block whose reference is at STACK_AT(n - 1),
/// dropping extra arguments (`spec::op_invoke_block`). Too few arguments
/// (CODE_INVOCATION_FAILED) and the slow cases of a call go to the bridge.
#[inline(always)]
pub fn op_invoke_block(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, n: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 55,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_block(env.p.ap@, old(m).g@, n as int),
        bci + 2 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    if !call_fast(m, r, env) {
        return slow0(m, r, env, Slow::Op);
    }
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, n - 1);
    }
    let ghost v = sp::at(g, n - 1);
    let w = at(m, r, n - 1);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    proof {
        lemma_block_target(p, g, n - 1);
        lemma_slot(&w0, p, slot as int);
    }
    let ghost tt = sp::block_target(ap, g, slot as int)->0;
    let mw = r.end.offset(-((slot + 1) as isize)).read(0, &m.mem);
    proof {
        assert(g.stack[slot as int] == Value::Smi(tt as i64));
        assert(0 <= tt < ap.methods.len());
        assert(ap.methods.len() == p.methods@.len());
        lemma_smi_word_nat(tt as i64);
        assert(mw == 2 * tt);
        assert(mw >> 1 == mw / 2) by (bit_vector);
    }
    let t = mw >> 1;
    let info = p.method(t);
    proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
    let arity = info.arity as usize;
    if n < arity {
        return slow0(m, r, env, Slow::Op);
    }
    let d = n - arity;
    r.sp = r.sp.offset(d as isize);
    let ghost g1 = sp::drop(g, d as int);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= w0.words().subrange(0, w0.height() - d));
        assert(m1.words() =~= enc_seq(w0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(w0.addr(), g1.stack[i]) by {
            assert(g1.stack[i] == g.stack[i]);
        }
        lemma_local(p, w0, m1, g1);
        lemma_room_same(p, w0, m1);
        assert(sp::step(ap, g) == sp::call(ap, g1, t as int, bci + 2));
    }
    push_call(m, r, p, t, info.entry as usize, info.arity as usize, bci + 2, 0);
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

// ---------------------------------------------------------------------------
// Tail calls.

/// `spec::replace_frame(w0.g@, t, args)` on registers, once the `n`
/// arguments are written below the frame's limit (`tail::replace_ready` of
/// `w0` and the machine the registers describe): the frame record's method, the top, the method and the bci.
/// The room of the call check (`rcalls::call_fast`) gives the replaced
/// frame its room.
#[inline(always)]
pub fn replace_r(m: &mut Machine, r: &mut Regs, p: &Program, t: usize, info: V2Method, n: usize,
    Ghost(w0): Ghost<Machine>, Ghost(args): Ghost<Seq<Value>>)
    requires
        old(m).rok(*old(r)),
        gate_ok(p, *old(m)),
        old(r).fp@ >= n,
        replace_ready(p, w0, old(m).with(*old(r)), (old(r).fp@ - n) as usize, args),
        t < p.methods@.len(),
        info == p.minfo(t as int),
        info.arity as int == n,
        room_ok(p, w0),
        w0.top >= w0.ftop + FRAME_WORDS + p.max_height + STACK_RESERVE,
        n <= w0.lim - w0.top,
    ensures
        rnext(p, *final(m), *final(r), sp::replace_frame(p.ap@, w0.g@, t as int, args)),
        room_ok(p, final(m).with(*final(r))),
{
    let ghost ap = p.ap@;
    let ghost g0 = w0.g@;
    let ghost m1 = m.with(*r);
    proof { w0.lemma_frame(p); }
    let rr = r.fr.offset(-(FRAME_WORDS as isize));
    rr.write(FRAME_METHOD, t, &mut m.mem);
    r.sp = r.fp.offset(-(n as isize));
    r.ip = p.code.cursor(info.entry as usize);
    let ghost nf = g0.frames.len() as int;
    let ghost g1 = State2 {
        stack: g0.stack.subrange(0, sp::base(g0)) + args,
        frames: g0.frames.update(sp::top_index(g0), Frame { method: t, ..sp::top(g0) }),
        bci: info.entry as usize,
        ..g0
    };
    m.g = Ghost(g1);
    proof {
        let m2 = m.with(*r);
        let addr = w0.addr();
        assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height));
        assert(rr@ == FRAME_WORDS * (nf - 1));
        assert(sp::top(g0) == g0.frames.last());
        // Frame records.
        assert forall|i: int| 0 <= i < FRAME_WORDS * nf && i != FRAME_WORDS * (nf - 1) + FRAME_METHOD
            implies #[trigger] m2.mem@[i] == w0.mem@[i] by {
            assert(m2.mem@[i] == m1.mem@[i]);
        }
        lemma_frames_method(w0.mem@, m2.mem@, g0.frames, t);
        // The object stack.
        let b = sp::base(g0);
        assert(b == w0.base);
        assert(w0.words().len() == g0.stack.len());
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] m2.words()[i] == enc(addr, g1.stack[i]) by {
            if i < b {
                assert(g1.stack[i] == g0.stack[i]);
                assert(m2.mem@[m2.len - 1 - i] == w0.mem@[m2.len - 1 - i]);
                assert(w0.words()[i] == enc_seq(addr, g0.stack)[i]);
            } else {
                let j = i - b;
                assert(g1.stack[i] == args[j]);
                assert(m2.len - 1 - i == m1.lim - 1 - j);
                assert(m2.mem@[m2.len - 1 - i] == m1.mem@[m1.lim - 1 - j]);
            }
        }
        assert(m2.words() =~= enc_seq(addr, g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(addr, g1.stack[i]) by {
            if i < b { assert(g1.stack[i] == g0.stack[i]); } else { assert(g1.stack[i] == args[i - b]); }
        }
        assert(g1.frames.last().base == w0.base);
        assert(m2.refines(p));
        assert(sp::replace_frame(ap, g0, t as int, args) == Outcome2::Next(g1));
        // Room.
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m2, i) by {
            assert(frame_room(p, w0, i));
            if i < nf - 1 {
                assert(g1.frames[i] == g0.frames[i]);
            } else {
                assert(g1.frames[i].method == t);
                assert(g1.frames[i].base == w0.base);
            }
        }
    }
}

/// INVOKE_STATIC_TAIL d (`spec::op_invoke_static_tail`): the fast path
/// replaces the top frame's method; a failing receiver check, too little
/// room and preemption go to the bridge.
#[inline(always)]
pub fn op_invoke_static_tail(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, d: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 54,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_static_tail(env.p.ap@, old(m).g@, d as int),
        bci + 3 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    if !call_fast(m, r, env) {
        return slow0(m, r, env, Slow::Op);
    }
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        lemma_shape(p, g);
    }
    let t = p.dispatch.at(d) as usize;
    let info = p.method(t);
    proof {
        assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height));
        crate::calls::lemma_dispatch_kind(p, g.heap, w0.addr(), d as int);
    }
    let arity = info.arity as usize;
    let rs = p.dispatch_recv_start(t);
    if rs != NO_VALUE {
        proof { w0.lemma_at(p, arity - 1); }
        let receiver = at(m, r, arity - 1);
        let cid = m.class_of(p, receiver, Ghost(sp::at(g, arity - 1)));
        if !p.dispatch_recv_contains(t, rs, cid) {
            return slow0(m, r, env, Slow::Op);
        }
    }
    let ghost args = g.stack.subrange(g.stack.len() - arity, g.stack.len() as int);
    proof {
        assert(sp::op_invoke_static_tail(ap, g, d as int) == sp::replace_frame(ap, g, t as int, args));
    }
    let top = m.mem.index(r.sp);
    let new_top = m.mem.index(r.fp) - arity;
    m.mem.copy_within(top, new_top, arity);
    proof {
        let m1 = m.with(*r);
        let addr = w0.addr();
        assert forall|j: int| 0 <= j < args.len() implies #[trigger] m1.mem@[m1.lim - 1 - j] == enc(addr, args[j]) by {
            let i = g.stack.len() - arity + j;
            assert(args[j] == g.stack[i]);
            assert(m1.mem@[m1.lim - 1 - j] == w0.mem@[top + arity - 1 - j]);
            assert(w0.words()[i] == w0.mem@[w0.len - 1 - i]);
            assert(w0.words()[i] == enc_seq(addr, g.stack)[i]);
        }
        assert forall|j: int| 0 <= j < args.len() implies #[trigger] encodable(addr, args[j]) by {
            assert(args[j] == g.stack[g.stack.len() - arity + j]);
        }
        assert forall|i: int| 0 <= i < m1.ftop implies #[trigger] m1.mem@[i] == w0.mem@[i] by {}
        assert forall|i: int| m1.lim <= i < m1.len implies #[trigger] m1.mem@[i] == w0.mem@[i] by {}
        assert(replace_ready(p, w0, m1, new_top, args));
    }
    replace_r(m, r, p, t, info, arity, Ghost(w0), Ghost(args));
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

/// INVOKE_INITIALIZER_TAIL (`spec::op_invoke_initializer_tail`): the fast
/// path replaces the top frame's method by the initializer; a bad method
/// id (INVALID_PROGRAM) and preemption go to the bridge.
#[inline(always)]
pub fn op_invoke_initializer_tail(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_initializer_tail(env.p.ap@, old(m).g@),
        opcode == 57,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    if !call_fast(m, r, env) {
        return slow0(m, r, env, Slow::Op);
    }
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        lemma_shape(p, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        assert(value_operands(cur_k(ap, p.cert@, g), 1));
        crate::halt::lemma_value_operand(p, g, 1, 0);
        w0.lemma_at(p, 0);
        crate::halt::lemma_word_tag(&w0, p, w0.mem@[w0.top as int], sp::at(g, 0));
    }
    let w = at(m, r, 0);
    if w & 1 != 0 {
        return slow0(m, r, env, Slow::Op);
    }
    let mid = smi_value(w);
    if mid < 0 || mid as usize >= p.methods.len() {
        return slow0(m, r, env, Slow::Op);
    }
    let t = mid as usize;
    let info = p.method(t);
    proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
    if info.kind != KIND_METHOD || info.arity != 0 {
        return slow0(m, r, env, Slow::Op);
    }
    proof {
        assert(sp::op_invoke_initializer_tail(ap, g) == sp::replace_frame(ap, g, t as int, Seq::<Value>::empty()));
        let m1 = m.with(*r);
        assert(m1 == w0);
        assert(replace_ready(p, w0, m1, w0.lim, Seq::<Value>::empty()));
    }
    replace_r(m, r, p, t, info, 0, Ghost(w0), Ghost(Seq::<Value>::empty()));
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

// ---------------------------------------------------------------------------
// Globals.

/// LOAD_GLOBAL_VAR_LAZY(_WIDE) gi (`spec::op_load_global_lazy`): an
/// initialized global is pushed; the initializer call goes to the bridge.
#[inline(always)]
pub fn op_load_global_lazy(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, gi: usize, len: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 32 || opcode == 33,
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_global_lazy(env.p.ap@, old(m).g@, gi as int, len as int),
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        assert(m.globals@.len() == enc_seq(m.addr(), g.globals).len());
        assert(enc_seq(m.addr(), g.globals)[gi as int] == enc(m.addr(), g.globals[gi as int]));
    }
    let ghost v = g.globals[gi as int];
    let w = m.globals.at(gi);
    if m.is_lazy_word(p, w, Ghost(v)) {
        return slow0(m, r, env, Slow::Op);
    }
    let c = push_next(m, r, p, w, len, Ghost(v));
    proof {
        lemma_matches(p, w0, m.with(*r), c);
        lemma_room_same(p, w0, m.with(*r));
    }
    c
}

/// LOAD_GLOBAL_VAR_DYNAMIC (`spec::op_load_global_dynamic`); a bad index
/// (INVALID_PROGRAM) goes to the bridge.
#[inline(always)]
pub fn op_load_global_dynamic(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 34,
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_global_dynamic(env.p.ap@, old(m).g@),
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        crate::globals::lemma_dynamic_operands(p, g);
        w0.lemma_at(p, 0);
    }
    let w = at(m, r, 0);
    let gi = match m.dyn_global_index(p, w, Ghost(sp::at(g, 0))) {
        None => {
            proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
            return slow0(m, r, env, Slow::Invalid);
        },
        Some(gi) => gi,
    };
    proof {
        assert(enc_seq(m.addr(), g.globals)[gi as int] == enc(m.addr(), g.globals[gi as int]));
    }
    let v = m.globals.at(gi);
    r.sp.write(0, v, &mut m.mem);
    r.ip = r.ip.offset(1);
    let ghost g1 = sp::goto(sp::put(g, 0, g.globals[gi as int]), bci + 1);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= w0.words().update(w0.height() - 1, v));
        assert(m1.words() =~= enc_seq(w0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(w0.addr(), g1.stack[i]) by {
            if i != g.stack.len() - 1 { assert(g1.stack[i] == g.stack[i]); }
        }
        lemma_local(p, w0, m1, g1);
        lemma_matches(p, w0, m1, Ctl::Next);
        lemma_room_same(p, w0, m1);
    }
    Ctl::Next
}

/// STORE_GLOBAL_VAR_DYNAMIC (`spec::op_store_global_dynamic`): pops the
/// value and the index; a bad index (INVALID_PROGRAM) goes to the bridge.
#[inline(always)]
pub fn op_store_global_dynamic(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 37,
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_global_dynamic(env.p.ap@, old(m).g@),
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        crate::globals::lemma_dynamic_operands(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
        w0.lemma_frame(p);
    }
    let w = at(m, r, 1);
    let gi = match m.dyn_global_index(p, w, Ghost(sp::at(g, 1))) {
        None => {
            proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
            return slow0(m, r, env, Slow::Invalid);
        },
        Some(gi) => gi,
    };
    let v = at(m, r, 0);
    r.sp = r.sp.offset(2);
    m.globals.set(gi, v);
    r.ip = r.ip.offset(1);
    let ghost s1 = sp::drop(g, 2);
    let ghost g1 = sp::goto(State2 { globals: s1.globals.update(gi as int, sp::at(g, 0)), ..s1 }, bci + 1);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(enc_seq(w0.addr(), g1.globals) =~= enc_seq(w0.addr(), g.globals).update(gi as int, v));
        assert(m1.words() =~= w0.words().subrange(0, w0.height() - 2));
        assert(m1.words() =~= enc_seq(w0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(w0.addr(), g1.stack[i]) by {
            assert(g1.stack[i] == g.stack[i]);
        }
        assert forall|i: int| 0 <= i < g1.globals.len() implies #[trigger] encodable(w0.addr(), g1.globals[i]) by {
            if i != gi { assert(g1.globals[i] == g.globals[i]); }
        }
        lemma_local(p, w0, m1, g1);
        lemma_matches(p, w0, m1, Ctl::Next);
        lemma_room_same(p, w0, m1);
    }
    Ctl::Next
}

} // verus!

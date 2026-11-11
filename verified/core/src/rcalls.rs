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

//! Calls and returns on registers (the fast paths; DESIGN.md "Run loop").
//!
//! A call checks once, before it does anything, that it can take the fast
//! path: room for the callee's frame record, the maximal height and the
//! reserve (which gives the new frame its room, `room.rs`), no finally
//! records (they would move), and no preemption request: the room check is
//! `free < (watermark | needed)`, so a preemption request (all ones) makes
//! it fail as the C++ interpreter's watermark does. Anything else (stack
//! growth, preemption, finally records, a receiver outside the target's
//! range, a lookup failure) runs the instruction on the machine's handler
//! (`step::bridge`), which is unchanged. A return takes the fast path
//! unless the caller is suspended in a TRY, the task's bottom frame
//! returns, or there are finally records.

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::calls::*;
use crate::ffi::V2Method;
use toit_spec::types::{Value, Frame, Handler, Fin};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};

verus! {

/// `(w | n) >= n`: or-ing the watermark into the needed room never asks
/// for less.
pub proof fn lemma_or_ge(w: usize, n: usize)
    ensures (w | n) >= n,
{
    assert((w | n) >= n) by (bit_vector);
}

/// The fast path of a call applies: room for a frame record, the maximal
/// height and the reserve, no finally records, no preemption request (the
/// gate's `need` is all ones while there are finally records, the
/// watermark while preemption is requested).
#[inline(always)]
pub fn call_fast(m: &Machine, r: &Regs, env: &Env) -> (b: bool)
    requires m_ok(&env.p, *m, *r),
    ensures b ==> m.fw == 0 && r.sp@ - r.fr@ >= FRAME_WORDS + env.p.max_height + STACK_RESERVE + FIN_WORDS,
{
    let w = env.pre.word();
    let free = r.sp.diff(r.fr);
    proof { lemma_or_ge(w, m.need); }
    free >= (w | m.need)
}

/// `spec::call` without finally records: a frame for `target` (its entry and
/// arity), whose arguments are the top `arity` slots,
/// returning to `ret`. The new frame has room (`frame_room`).
#[inline(always)]
pub fn push_call(m: &mut Machine, r: &mut Regs, p: &Program, target: usize, entry: usize, arity: usize, ret: usize)
    requires
        m_ok(p, *old(m), *old(r)),
        old(m).fw == 0,
        old(r).sp@ - old(r).fr@ >= FRAME_WORDS + p.max_height + STACK_RESERVE,
        room_ok(p, old(m).with(*old(r))),
        target < p.methods@.len(),
        entry == p.minfo(target as int).entry as usize,
        arity == p.minfo(target as int).arity as usize,
        !(sp::call(p.ap@, old(m).g@, target as int, ret as int) is Stuck),
    ensures
        rnext(p, *final(m), *final(r), sp::call(p.ap@, old(m).g@, target as int, ret as int)),
        room_ok(p, final(m).with(*final(r))),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof {
        m0.lemma_frame(p);
        assert(p.ap@.methods[target as int] == method_info(p.minfo(target as int), p.max_height));
    }
    let f = r.fr;
    let fp = r.sp.offset(arity as isize);
    let base = r.end.diff(fp);
    f.write(FRAME_METHOD, target, &mut m.mem);
    f.write(FRAME_RET, ret, &mut m.mem);
    f.write(FRAME_BASE, base, &mut m.mem);
    f.write(FRAME_HANDLER, 0, &mut m.mem);
    let nf = f.offset(FRAME_WORDS as isize);
    r.fr = nf;
    r.fp = fp;
    r.ip = p.code.cursor(entry);
    let ghost fr = Frame { method: target, ret: ret, base: base };
    let ghost g1 = State2 { frames: g0.frames.push(fr), bci: entry, ..g0 };
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let n = g0.frames.len() as int;
        let fo = m0.ftop as int;
        assert(fo == FRAME_WORDS * n);
        assert(g0.fins.len() == 0);
        assert forall|i: int| 0 <= i < m1.mem@.len() && !(fo <= i < fo + FRAME_WORDS)
            implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        assert(rec(m1.mem@, n, FRAME_METHOD) == target);
        assert(rec(m1.mem@, n, FRAME_RET) == ret);
        assert(rec(m1.mem@, n, FRAME_BASE) == base);
        assert(rec(m1.mem@, n, FRAME_HANDLER) == 0);
        lemma_frames_push(m0.mem@, m1.mem@, g0.frames, g0.tries, fr);
        assert(fins_rel(m1.mem@, m1.ftop as int, g1.fins));
        assert(m1.words() =~= m0.words());
        assert(g1.frames.last() == fr);
        assert(m1.refines(p));
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            if i < n {
                assert(g1.frames[i] == g0.frames[i]);
                assert(frame_room(p, m0, i));
            }
        }
    }
}

/// INVOKE_STATIC d (`spec::call_static`).
#[inline(always)]
pub fn op_invoke_static(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, d: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::call_static(env.p.ap@, old(m).g@, sp::dispatch_target(env.p.ap@, d as int), 3),
        bci + 3 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
    }
    let t = p.dispatch.at(d) as usize;
    let info = p.method(t);
    proof {
        assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height));
        crate::calls::lemma_dispatch_kind(p, g.heap, w0.addr(), d as int);
    }
    let arity = info.arity as usize;
    // The receiver range (format note 21: a dispatch target's header has
    // one, at a fixed place).
    let rs = p.dispatch_recv_start(t);
    if rs != NO_VALUE {
        proof { w0.lemma_at(p, arity - 1); }
        let receiver = at(m, r, arity - 1);
        let cid = m.class_of(p, receiver, Ghost(sp::at(g, arity - 1)));
        if !p.dispatch_recv_contains(t, rs, cid) {
            proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::AS_CHECK_FAILED)); }
            return slow0(m, r, env, Slow::Raise(1));
        }
    }
    if !call_fast(m, r, env) {
        proof { assert(sp::step(ap, g) == sp::call(ap, g, t as int, bci + 3)); }
        return slow0(m, r, env, Slow::Call(t, bci + 3));
    }
    push_call(m, r, p, t, info.entry as usize, arity, bci + 3);
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

/// INVOKE_VIRTUAL(_WIDE) (`spec::invoke_virtual`) with `n` arguments,
/// receiver included.
#[inline(always)]
pub fn op_invoke_virtual(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, sel: i64, n: usize, len: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::invoke_virtual(env.p.ap@, old(m).g@, sel as int, n as int, len as int),
        -0x8000_0000 <= sel < 0x8000_0000,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    let ghost vo = sp::invoke_virtual(ap, g, sel as int, n as int, len as int);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, n - 1);
    }
    let receiver = at(m, r, n - 1);
    match m.lookup(p, receiver, Ghost(sp::at(g, n - 1)), sel) {
        VLookup::Missing => {
            proof { assert(vo == sp::raise(ap, g, sp::LOOKUP_FAILED)); }
            slow_r(m, r, env, Slow::Lookup(sel), receiver, Ghost(sp::at(g, n - 1)))
        },
        VLookup::Found(t) => {
            if !call_fast(m, r, env) {
                proof { assert(vo == sp::call(ap, g, t as int, bci + len)); }
                return slow0(m, r, env, Slow::Call(t, bci + len));
            }
            // The arity is the call's `n` (the spec is stuck otherwise):
            // the frame base is the receiver's slot plus one.
            proof { assert(sp::arity(ap, t as int) == n); }
            push_call(m, r, p, t, p.entry_of(t), n, bci + len);
            proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
            Ctl::Next
        },
    }
}

/// RETURN and RETURN_NULL (`spec::return_from`) with the result `w`: the
/// fast path pops the top frame and pushes the result.
#[inline(always)]
pub fn op_return(m: &mut Machine, r: &mut Regs, env: &Env, w: usize, Ghost(v): Ghost<Value>) -> (c: Ctl)
    requires
        rinv(&env.p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + old(m).fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g0)));
        lemma_shape(p, g0);
        m0.lemma_frame(p);
        lemma_no_handler(g0);
    }
    if !m.bot.lt(r.fr, &m.mem) {
        // The task's bottom frame returns, or there are finally records.
        return slow_r(m, r, env, Slow::Return, w, Ghost(v));
    }
    let ghost n = g0.frames.len() as int;
    proof {
        assert(m0.ftop == FRAME_WORDS * n);
        assert(n >= 2);
        lemma_rec_index(n, n - 2, FRAME_HANDLER);
        lemma_rec_index(n, n - 2, FRAME_METHOD);
        lemma_rec_index(n, n - 2, FRAME_BASE);
        lemma_rec_index(n, n - 1, FRAME_RET);
    }
    let crec = r.fr.offset(-((2 * FRAME_WORDS) as isize));
    let handler = crec.read(FRAME_HANDLER, &m.mem);
    if handler != 0 {
        // The caller is suspended in a TRY: its finally code runs.
        proof { assert(m.fw == 0); }
        let (r2, c2) = crate::rnonlocal::ret_try_v(m, *r, env, Ghost(v));
        set_regs(r, r2);
        return c2;
    }
    let rec_ = r.fr.offset(-(FRAME_WORDS as isize));
    let ret = rec_.read(FRAME_RET, &m.mem);
    let base = crec.read(FRAME_BASE, &m.mem);
    proof {
        assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
        assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
        assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
        assert(rec(m0.mem@, n - 2, FRAME_HANDLER) == handler);
        assert(toit_spec::v2::sound::base_step(g0, n - 2));
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        lemma_handler_word(m0.mem@, g0.frames.drop_last(), g0.tries);
        assert(g0.frames.drop_last()[n - 2] == g0.frames[n - 2]);
        assert(!sp::has_handler(State2 { frames: g0.frames.drop_last(), ..g0 }));
    }
    let s = r.fp.offset(-1);
    s.write(0, w, &mut m.mem);
    r.sp = s;
    r.fp = r.end.offset(-(base as isize));
    r.fr = rec_;
    r.ip = p.code.cursor(ret);
    let ghost g1 = State2 {
        stack: g0.stack.subrange(0, sp::top(g0).base as int).push(v),
        frames: g0.frames.drop_last(),
        fins: sp::fins_popped(g0),
        bci: sp::top(g0).ret,
        ..g0
    };
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(g0.fins.len() == 0);
        assert(sp::fins_popped(g0) =~= g0.fins);
        assert(sp::base(g1) == g0.frames[n - 2].base);
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        assert forall|i: int| 0 <= i < FRAME_WORDS * g1.frames.len() implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        lemma_frames_rel_same(m0.mem@, m1.mem@, g1.frames, g1.tries);
        let b = sp::top(g0).base as int;
        assert(m1.words() =~= m0.words().subrange(0, b).push(w));
        assert(enc_seq(m0.addr(), g1.stack) =~= enc_seq(m0.addr(), g0.stack).subrange(0, b).push(w));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < b { assert(g1.stack[i] == g0.stack[i]); }
        }
        assert(m1.method < p.methods@.len()) by {
            assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
        }
        assert(m1.refines(p));
        assert(sp::return_from(ap, g0, v) == Outcome2::Next(g1));
        lemma_matches(p, m0, m1, Ctl::Next);
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g1.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
    }
    Ctl::Next
}

} // verus!

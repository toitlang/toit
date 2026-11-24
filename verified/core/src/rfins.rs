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

//! Calls and returns while finally records exist, on registers (DESIGN.md
//! "Run loop"): during an unwinding's finally code the records follow the
//! frame records, so a call moves them up by one frame record and a return
//! moves them down (`Machine::push_call`, `Machine::do_return`). The
//! register handlers' fast paths fail their checks while there are records
//! (the gate), so these run first in `step::slow` (`call_fins_r`,
//! `ret_fins_fast`), before the machine path (`step::slow_body`): a call
//! with room and no preemption request, and a return that cuts no record (the records belong to frames below the
//! returning one), not of the bottom frame, the caller not in a TRY.

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::ffi::V2Method;
use crate::calls::*;
use toit_spec::types::{Value, Frame, Fin};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;

verus! {

/// `spec::call` with finally records (`m.fw` words of them after the frame
/// records): moves them up by one frame record, then writes the new frame
/// record as `rcalls::push_call` does. The room: `free` covers the frame
/// record, the maximal height, the reserve, one finally record of slack and
/// the records (as `step::ensure_room` asks of the machine path).
#[inline(always)]
pub fn push_call_fins(m: &mut Machine, r: &mut Regs, p: &Program, target: usize, info: V2Method, ret: usize)
    requires
        m_ok(p, *old(m), *old(r)),
        old(m).fw > 0,
        old(r).sp@ - old(r).fr@ >= FRAME_WORDS + p.max_height + STACK_RESERVE + FIN_WORDS + old(m).fw,
        room_ok(p, old(m).with(*old(r))),
        target < p.methods@.len(),
        info == p.minfo(target as int),
        !(sp::call(p.ap@, old(m).g@, target as int, ret as int) is Stuck),
    ensures
        rnext(p, *final(m), *final(r), sp::call(p.ap@, old(m).g@, target as int, ret as int)),
        room_ok(p, final(m).with(*final(r))),
        final(m).len == old(m).len,
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof {
        m0.lemma_frame(p);
        assert(p.ap@.methods[target as int] == method_info(p.minfo(target as int), p.max_height));
    }
    let arity = info.arity as usize;
    let f = r.fr;
    let fi = m.mem.index(f);
    let fw = m.fw;
    // The records move up by one frame record.
    proof { lemma_records_chunk(g0.fins.len() as int); }
    m.mem.move_records(fi, fi + FRAME_WORDS, fw);
    let ghost mem1 = m.mem@;
    let fp = r.sp.offset(arity as isize);
    let base = r.end.diff(fp);
    f.write(FRAME_METHOD, target, &mut m.mem);
    f.write(FRAME_RET, ret, &mut m.mem);
    f.write(FRAME_BASE, base, &mut m.mem);
    f.write(FRAME_HANDLER, 0, &mut m.mem);
    let nf = f.offset(FRAME_WORDS as isize);
    r.fr = nf;
    r.fp = fp;
    r.ip = p.code.cursor(info.entry as usize);
    let ghost fr = Frame { method: target, ret: ret, base: base };
    let ghost g1 = State2 { frames: g0.frames.push(fr), bci: info.entry as usize, ..g0 };
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let n = g0.frames.len() as int;
        let fo = m0.ftop as int;
        let e = m0.rtop as int;
        assert(fo == FRAME_WORDS * n);
        assert(e == fo + fw);
        assert(fw == FIN_WORDS * g0.fins.len());
        assert forall|i: int| 0 <= i < m1.mem@.len() && !(fo <= i < e + FRAME_WORDS)
            implies #[trigger] mem1[i] == m0.mem@[i] by {}
        assert forall|i: int| fo + FRAME_WORDS <= i < e + FRAME_WORDS
            implies #[trigger] mem1[i] == m0.mem@[i - FRAME_WORDS] by {}
        assert forall|i: int| 0 <= i < FRAME_WORDS * n implies #[trigger] m1.mem@[i] == m0.mem@[i] by {
            assert(mem1[i] == m0.mem@[i]);
        }
        assert forall|i: int| 0 <= i < FIN_WORDS * g0.fins.len()
            implies #[trigger] m1.mem@[fo + FRAME_WORDS + i] == m0.mem@[fo + i] by {
            assert(mem1[fo + FRAME_WORDS + i] == m0.mem@[fo + FRAME_WORDS + i - FRAME_WORDS]);
        }
        lemma_fins_rel_move(m0.mem@, m1.mem@, fo, fo + FRAME_WORDS, g0.fins, g0.fins.len() as int);
        assert(g0.fins.subrange(0, g0.fins.len() as int) =~= g0.fins);
        assert(fins_rel(m1.mem@, m1.ftop as int, g1.fins));
        assert forall|i: int| m0.top <= i < m0.len implies #[trigger] m1.mem@[i] == m0.mem@[i] by {
            assert(mem1[i] == m0.mem@[i]);
        }
        assert(rec(m1.mem@, n, FRAME_METHOD) == target);
        assert(rec(m1.mem@, n, FRAME_RET) == ret);
        assert(rec(m1.mem@, n, FRAME_BASE) == base);
        assert(rec(m1.mem@, n, FRAME_HANDLER) == 0);
        lemma_frames_push(m0.mem@, m1.mem@, g0.frames, g0.tries, fr);
        assert(m1.words() =~= m0.words());
        assert(g1.frames.last() == fr);
        assert(m1.refines(p));
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            if i < n {
                assert(g1.frames[i] == g0.frames[i]);
                assert(frame_room(p, m0, i));
            }
        }
        assert(top_room(p, m1));
    }
}


/// Without a finally record of the top frame (the last record's frame is
/// below it), popping the top frame cuts none.
pub proof fn lemma_fins_kept(g: State2)
    requires
        g.fins.len() > 0,
        g.frames.len() > 0,
        (g.fins.last().frame as int) < sp::top_index(g),
    ensures sp::fins_popped(g) == g.fins,
{
    assert(sp::cut_fins(g.fins, sp::top_index(g), 0) == g.fins);
}

/// A return (`spec::return_from`) with the result `w` while finally records
/// exist, on the registers: not the task's bottom frame, the caller not
/// suspended in a TRY, no record of the returning frame (so none is cut),
/// and the caller's room with the records (`room::top_room`). Moves the
/// records down by one frame record. `false` (nothing changed) otherwise.
#[inline(always)]
pub fn ret_fins_r(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (b: bool)
    requires
        m_ok(p, *old(m), *old(r)),
        old(m).fw > 0,
        room_ok(p, old(m).with(*old(r))),
        shape_ok(p, old(m).g@),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        !(sp::return_from(p.ap@, old(m).g@, v) is Stuck),
    ensures
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
        b ==> final(m).rok(*final(r)) && ipok(p, *final(r)) && final(m).with(*final(r)).refines(p) && gate_ok(p, *final(m))
            && sp::return_from(p.ap@, old(m).g@, v) == Outcome2::Next(final(m).g@)
            && room_ok(p, final(m).with(*final(r))),
{
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    proof {
        m0.lemma_frame(p);
        lemma_no_handler(g0);
    }
    let ghost n = g0.frames.len() as int;
    let fo = m.mem.index(r.fr);
    let fw = m.fw;
    proof {
        assert(m0.ftop == FRAME_WORDS * n);
        assert(fo == FRAME_WORDS * n);
        assert(fw == FIN_WORDS * g0.fins.len());
        assert(m0.rtop == fo + fw);
        assert(fo + fw <= m0.len);
    }
    if fo < 2 * FRAME_WORDS {
        // The task's bottom frame returns.
        return false;
    }
    proof {
        assert(n >= 2);
        lemma_rec_index(n, n - 2, FRAME_HANDLER);
        lemma_rec_index(n, n - 2, FRAME_METHOD);
        lemma_rec_index(n, n - 2, FRAME_BASE);
        lemma_rec_index(n, n - 1, FRAME_RET);
        let x = g0.fins.len() - 1;
        assert(fin_rel(m0.mem@, fo as int, x, g0.fins[x]));
        lemma_fin_index(fo as int, g0.fins.len() as int, x, FIN_FRAME);
        assert(FIN_WORDS * x + FIN_FRAME == fw - FIN_WORDS + FIN_FRAME);
    }
    // The last record's frame (records are in frame order, `cut_fins`
    // looks at the last one first).
    let lf = m.mem.read(fo + fw - FIN_WORDS + FIN_FRAME);
    if lf >= fo / FRAME_WORDS - 1 {
        // A record of the returning frame: cut on the machine.
        return false;
    }
    let crec = r.fr.offset(-((2 * FRAME_WORDS) as isize));
    let handler = crec.read(FRAME_HANDLER, &m.mem);
    if handler != 0 {
        // The caller is suspended in a TRY: its finally code runs.
        return false;
    }
    let rec_ = r.fr.offset(-(FRAME_WORDS as isize));
    let ret = rec_.read(FRAME_RET, &m.mem);
    let base = crec.read(FRAME_BASE, &m.mem);
    let method = crec.read(FRAME_METHOD, &m.mem);
    proof {
        assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
        assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
        assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
        assert(rec(m0.mem@, n - 2, FRAME_HANDLER) == handler);
        assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
        assert(ap.methods[method as int] == method_info(p.minfo(method as int), p.max_height));
        assert(p.max_height < 0x1_0000);
        assert(toit_spec::v2::sound::base_step(g0, n - 2));
        assert(base <= g0.frames[n - 1].base);
    }
    // The caller's room with the records.
    let a = p.method(method).arity as usize;
    if base + a + p.max_height + fo + fw + STACK_RESERVE > m.len {
        return false;
    }
    proof {
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        lemma_handler_word(m0.mem@, g0.frames.drop_last(), g0.tries);
        assert(g0.frames.drop_last()[n - 2] == g0.frames[n - 2]);
        assert(!sp::has_handler(State2 { frames: g0.frames.drop_last(), ..g0 }));
        lemma_fins_kept(g0);
    }
    // The records move down by one frame record (over the returning
    // frame's record).
    proof { lemma_records_chunk(g0.fins.len() as int); }
    m.mem.move_records(fo, fo - FRAME_WORDS, fw);
    let ghost mem1 = m.mem@;
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
        let f2 = fo - FRAME_WORDS;
        assert(g1.fins == g0.fins);
        assert(sp::base(g1) == g0.frames[n - 2].base);
        assert forall|i: int| 0 <= i < m1.mem@.len() && !(f2 <= i < f2 + fw) && i != s@
            implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        assert forall|i: int| 0 <= i < FRAME_WORDS * g1.frames.len() implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        lemma_frames_rel_same(m0.mem@, m1.mem@, g1.frames, g1.tries);
        assert forall|i: int| 0 <= i < FIN_WORDS * g0.fins.len()
            implies #[trigger] m1.mem@[f2 + i] == m0.mem@[fo + i] by {
            assert(mem1[f2 + i] == m0.mem@[f2 + i - f2 + fo]);
        }
        lemma_fins_rel_move(m0.mem@, m1.mem@, fo as int, f2 as int, g0.fins, g0.fins.len() as int);
        assert(g0.fins.subrange(0, g0.fins.len() as int) =~= g0.fins);
        assert(fins_rel(m1.mem@, m1.ftop as int, g1.fins));
        let b = sp::top(g0).base as int;
        assert(m1.words() =~= m0.words().subrange(0, b).push(w));
        assert(enc_seq(m0.addr(), g1.stack) =~= enc_seq(m0.addr(), g0.stack).subrange(0, b).push(w));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < b { assert(g1.stack[i] == g0.stack[i]); }
        }
        assert(m1.method < p.methods@.len());
        assert(m1.refines(p));
        assert(sp::return_from(ap, g0, v) == Outcome2::Next(g1));
        assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g1.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
        assert(frame_need(p, g1, n - 2) <= m1.len);
        assert(top_room(p, m1));
    }
    true
}

/// A call (`spec::call` of `target`, returning to `ret`) whose fast path
/// failed the gate (`Slow::Call`): while finally records exist, with room
/// for the frame and the records and no preemption request,
/// `push_call_fins`. `false` (nothing changed) otherwise: the machine path
/// runs (`step::slow_body`).
#[inline(always)]
pub fn call_fins_r(m: &mut Machine, r: &mut Regs, env: &Env, target: usize, ret: usize) -> (b: bool)
    requires
        crate::step::rinv(&env.p, *old(m), *old(r)),
        sp::step(env.p.ap@, old(m).g@) == sp::call(env.p.ap@, old(m).g@, target as int, ret as int),
    ensures
        b ==> crate::step::rpost(&env.p, *old(m), *old(r), *final(m), *final(r), Ctl::Next),
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    if m.fw == 0 || env.pre.requested() {
        return false;
    }
    proof {
        assert(p.max_height < 0x1_0000);
        w0.lemma_frame(p);
    }
    let free = r.sp.diff(r.fr);
    if free < FRAME_WORDS + p.max_height + STACK_RESERVE + FIN_WORDS + m.fw {
        return false;
    }
    proof {
        crate::step::lemma_small(p, &w0);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        assert(toit_spec::v2::sound::outcome_ok(ap, p.cert@, sp::step(ap, g)));
    }
    let info = p.method(target);
    push_call_fins(m, r, p, target, info, ret);
    proof { crate::step::lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    true
}

/// A return (`spec::return_from` with the result `w`) whose fast path
/// failed the gate (`Slow::Return`): while finally records exist,
/// `ret_fins_r` when it applies. `false` (nothing changed) otherwise: the
/// machine path runs (`step::slow_body`).
#[inline(always)]
pub fn ret_fins_fast(m: &mut Machine, r: &mut Regs, env: &Env, w: usize, Ghost(v): Ghost<Value>) -> (b: bool)
    requires
        crate::step::rinv(&env.p, *old(m), *old(r)),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
    ensures
        b ==> crate::step::rpost(&env.p, *old(m), *old(r), *final(m), *final(r), Ctl::Next),
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    if m.fw == 0 {
        return false;
    }
    proof {
        crate::step::lemma_small(p, &w0);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        assert(toit_spec::v2::sound::outcome_ok(ap, p.cert@, sp::step(ap, g)));
        lemma_shape(p, g);
    }
    if ret_fins_r(m, r, p, w, Ghost(v)) {
        proof { crate::step::lemma_matches(p, w0, m.with(*r), Ctl::Next); }
        return true;
    }
    false
}

} // verus!

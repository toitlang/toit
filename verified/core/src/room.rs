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

//! Room on the object stack (DESIGN.md, "Room").
//!
//! The run loop's invariant includes `room_ok`: every frame can grow to its
//! method's arity plus the program's maximal height (the verifier's bound
//! on every frame's height, `instr_ok`) and still leave `STACK_RESERVE`
//! words above the frame and finally records, the finally records counted
//! in full for every frame. A call checks for room once (the callee's frame
//! record, the maximal height and the reserve, as before) and establishes
//! the new frame's room; returns and pops keep it. With it, the top frame
//! always has at least `STACK_RESERVE` free words (`lemma_room_top`), so a
//! push needs no check.
//!
//! Things that can break it: a GC that shrinks the stack (the trusted GC
//! contracts keep the abstract state, not the length), a task switch
//! (another task's stack), and an unwinding entering finally code (one more
//! finally record). After those, `ensure_room_all` re-establishes it: a
//! scan of the frame records and, if needed, stack growth.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::alloc::reload;
#[cfg(verus_keep_ghost)]
use crate::alloc::{reloaded, lemma_saved};
use toit_spec::types::{Value, Frame};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::wf;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, cur_k, cur_m};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, instr_ok};

verus! {

/// The part of the array frame `i` may use, with its records below it:
/// its base, its method's arity and the program's maximal height above
/// the frame records up to `i`, all finally records and the reserve.
pub open spec fn frame_need(p: &Program, g: State2, i: int) -> int {
    let f = g.frames[i];
    f.base + p.ap@.methods[f.method as int].arity + p.max_height
        + FRAME_WORDS * (i + 1) + FIN_WORDS * g.fins.len() + STACK_RESERVE
}

pub open spec fn frame_room(p: &Program, m: Machine, i: int) -> bool {
    frame_need(p, m.g@, i) <= m.len
}

/// The frames that can grow have room for their maximal height: without
/// finally records every frame (each becomes the top frame again after
/// returns, which are fast then); with finally records (only during an
/// unwinding's finally code) the top frame: calls and returns run on the
/// machine then, and `step::resume` re-establishes the room after each of
/// them, for every frame once the records are gone. (Room for every frame
/// with the records counted may not exist after a stack overflow, at the
/// maximal length, where format 1 still runs the finally code.)
pub open spec fn room_ok(p: &Program, m: Machine) -> bool {
    if m.g@.fins.len() == 0 {
        forall|i: int| 0 <= i < m.g@.frames.len() ==> #[trigger] frame_room(p, m, i)
    } else {
        frame_room(p, m, m.g@.frames.len() - 1)
    }
}

/// With room, the top frame has `STACK_RESERVE` free words: the verifier
/// bounds its height by its method's arity plus the maximal height.
pub proof fn lemma_room_top(p: &Program, m: Machine)
    requires m.inv(p), room_ok(p, m),
    ensures m.top >= m.rtop + STACK_RESERVE,
{
    let ap = p.ap@;
    let g = m.g@;
    lemma_instr(ap, p.cert@, p.trusted@, g);
    m.lemma_frame(p);
    let n = g.frames.len() - 1;
    assert(frame_room(p, m, n));
    let mi = cur_m(g);
    let k = cur_k(ap, p.cert@, g);
    assert(instr_ok(ap, p.cert@, mi, toit_spec::v2::sound_instr::cur_off(ap, g), k, p.trusted@));
    assert(ap.methods[mi] == method_info(p.methods@[mi], p.max_height));
    assert(g.frames[n] == g.frames.last());
}

/// With room, a well-formed state `g1` with the machine's frames and
/// finally records (the next state of a step inside the top frame) leaves
/// the reserve above the records: the verifier bounds its top frame's
/// height as well.
pub proof fn lemma_room_next(p: &Program, m: Machine, g1: State2)
    requires
        m.inv(p), room_ok(p, m),
        wf(p.ap@, p.cert@, g1),
        g1.frames == m.g@.frames, g1.fins == m.g@.fins,
    ensures m.len - g1.stack.len() >= m.rtop + STACK_RESERVE,
{
    let ap = p.ap@;
    lemma_instr(ap, p.cert@, p.trusted@, g1);
    m.lemma_frame(p);
    let n = g1.frames.len() - 1;
    assert(frame_room(p, m, n));
    let mi = cur_m(g1);
    let k = cur_k(ap, p.cert@, g1);
    assert(instr_ok(ap, p.cert@, mi, toit_spec::v2::sound_instr::cur_off(ap, g1), k, p.trusted@));
    assert(ap.methods[mi] == method_info(p.methods@[mi], p.max_height));
    assert(g1.frames[n] == g1.frames.last());
}

/// Room depends only on the length, the frames and the number of finally
/// records: a step that keeps those (and does not shorten the stack)
/// keeps it.
pub proof fn lemma_room_same(p: &Program, m0: Machine, m1: Machine)
    requires
        room_ok(p, m0),
        m1.len >= m0.len,
        m1.g@.frames == m0.g@.frames,
        m1.g@.fins.len() == m0.g@.fins.len(),
    ensures room_ok(p, m1),
{
    if m0.g@.fins.len() == 0 {
        assert forall|i: int| 0 <= i < m1.g@.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(frame_room(p, m0, i));
        }
    } else {
        assert(frame_room(p, m0, m0.g@.frames.len() - 1));
    }
}

/// The registers of a machine after a GC point inside a step: `m` (the
/// registers written back, reloaded after the GC) satisfies `inv` with its
/// frames and records those of `m0`, a machine with room. If the stack did
/// not get shorter the room holds still; if the GC shrank it, it is
/// re-established (`ensure_room_all`).
#[inline(always)]
pub fn regain(m: &mut Machine, env: &Env, len0: usize, Ghost(m0): Ghost<Machine>) -> (res: Option<crate::regs::Regs>)
    requires
        len0 == m0.len,
        old(m).inv(&env.p),
        room_ok(&env.p, m0),
        old(m).g@.frames == m0.g@.frames,
        m0.refines(&env.p),
        old(m).g@.fins.len() == m0.g@.fins.len(),
    ensures
        res matches Some(r) ==> final(m).rok(r) && crate::regs::ipok(&env.p, r)
            && crate::regs::gate_ok(&env.p, *final(m))
            && final(m).with(r).inv(&env.p) && room_ok(&env.p, final(m).with(r)) && final(m).g == old(m).g,
{
    if m.len < len0 {
        let c = ensure_room_all(m, env);
        if let Ctl::Stuck(reason) = c {
            return None;
        }
    } else {
        proof { lemma_room_same(&env.p, m0, *m); }
    }
    Some(m.enter(&env.p))
}

/// Re-establishes `room_ok` (cold: after a GC that shrank the stack, a task
/// switch, a path on the machine, and at the start of a run): the largest
/// need of the frames, from their records (with finally records the top
/// frame's only); if the stack is too
/// short, it grows (a GC point; the state is unchanged). If it cannot grow,
/// the run stops with `LIMIT` (out of memory).
#[inline(never)]
pub fn ensure_room_all(m: &mut Machine, env: &Env) -> (c: Ctl)
    requires old(m).inv(&env.p),
    ensures
        c == Ctl::Next || is_limit(c),
        c == Ctl::Next ==> final(m).inv(&env.p) && room_ok(&env.p, *final(m)) && final(m).g == old(m).g,
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    proof {
        crate::calls::lemma_shape(p, g);
        assert(crate::calls::shape_ok(p, g));
        m.lemma_frame(p);
    }
    let n = m.ftop / FRAME_WORDS;
    proof { assert(n == g.frames.len()); }
    let mut need: usize = 0;
    // With finally records only the top frame needs room (`room_ok`).
    let mut i: usize = if m.rtop == m.ftop { 0 } else { n - 1 };
    let ghost i0 = i as int;
    while i < n
        invariant
            m.inv(p),
            ap == p.ap@,
            m.g@ == g,
            n == g.frames.len(),
            m.ftop == FRAME_WORDS * n,
            i0 <= i <= n,
            i0 == 0 || (g.fins.len() > 0 && i0 == n - 1),
            g.fins.len() == 0 ==> i0 == 0,
            need < 0x4_0000,
            forall|fi: int| 0 <= fi < g.frames.len() ==> sp::valid_method(ap, (#[trigger] g.frames[fi]).method as int),
            forall|j: int| i0 <= j < i ==> frame_need(p, g, j) - p.max_height - FIN_WORDS * g.fins.len() - STACK_RESERVE <= need,
        decreases n - i,
    {
        let ri = FRAME_WORDS * i;
        proof {
            lemma_rec_index(n as int, i as int, FRAME_BASE);
            lemma_rec_index(n as int, i as int, FRAME_METHOD);
            assert(rec(m.mem@, i as int, FRAME_BASE) == g.frames[i as int].base);
            assert(rec(m.mem@, i as int, FRAME_METHOD) == g.frames[i as int].method);
        }
        let base = m.mem.read(ri + FRAME_BASE);
        let method = m.mem.read(ri + FRAME_METHOD);
        if base >= MAX_STACK_LENGTH {
            return Ctl::Stuck(stuck::LIMIT);
        }
        proof {
            assert(sp::valid_method(ap, g.frames[i as int].method as int));
            assert(ap.methods[method as int] == method_info(p.methods@[method as int], p.max_height));
        }
        let a = p.methods.at(method).arity as usize;
        let v = base + a + ri + FRAME_WORDS;
        if v > need {
            need = v;
        }
        i = i + 1;
    }
    proof { assert(p.max_height < 0x1_0000); }
    let total = need + p.max_height + (m.rtop - m.ftop) + STACK_RESERVE;
    if total <= m.len {
        proof {
            assert forall|j: int| i0 <= j < g.frames.len() implies #[trigger] frame_room(p, *m, j) by {}
            if g.fins.len() > 0 { assert(frame_room(p, *m, n - 1)); }
        }
        return Ctl::Next;
    }
    let needed = total - m.len + (m.top - m.rtop);
    let ghost m1 = *m;
    m.save();
    proof { lemma_saved(p, *m); }
    let status = crate::step::gc_grow_stack(m, env, needed, Ghost(g));
    reload(m, p, Ghost(g));
    if status != V2_OK {
        return Ctl::Stuck(stuck::LIMIT);
    }
    proof {
        m.lemma_frame(p);
        m1.lemma_frame(p);
        assert forall|j: int| i0 <= j < g.frames.len() implies #[trigger] frame_room(p, *m, j) by {}
        if g.fins.len() > 0 { assert(frame_room(p, *m, n - 1)); }
    }
    Ctl::Next
}

} // verus!

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

//! Tail calls, verified: INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL and
//! INVOKE_INITIALIZER_TAIL (`spec::op_invoke_static_tail`,
//! `op_invoke_lambda_tail`, `op_invoke_initializer_tail`), which replace
//! the top frame's method (`spec::replace_frame`): the frame's finally
//! records go (`fins_popped`), the arguments move to the frame's base, the
//! frame record's method word changes; the return address and base stay.
//!
//! The lambda's method id and captures and the initializer's method id
//! come from the heap: they are checked at run time exactly as the spec
//! checks them (a failing check raises INVALID_PROGRAM or
//! CODE_INVOCATION_FAILED, the verified raise of raise.rs).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
#[cfg(verus_keep_ghost)]
use crate::arrays::{vals_good, val_ok, lemma_val, lemma_heap_good};
use toit_spec::types::{Value, Frame, Handler, Fin, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, good, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{is_instance, fields, is_array, elements};

verus! {

/// Changing the top frame record's method word to `t` replaces the top
/// frame's method.
pub proof fn lemma_frames_method(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>, t: usize)
    requires
        frames_rel(mem, frames, tries),
        frames.len() > 0,
        mem2.len() == mem.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() && i != FRAME_WORDS * (frames.len() - 1) + FRAME_METHOD
            ==> #[trigger] mem2[i] == mem[i],
        rec(mem2, frames.len() - 1, FRAME_METHOD) == t,
    ensures frames_rel(mem2, frames.update(frames.len() - 1, Frame { method: t, ..frames.last() }), tries),
{
    let n = frames.len() as int;
    let f2 = frames.update(n - 1, Frame { method: t, ..frames.last() });
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_METHOD) == f2[fi].method by {
        if fi != n - 1 {
            lemma_rec_index(n, fi, FRAME_METHOD);
            assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD));
        }
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_RET) == f2[fi].ret by {
        lemma_rec_index(n, fi, FRAME_RET);
        assert(rec(mem2, fi, FRAME_RET) == rec(mem, fi, FRAME_RET));
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_BASE) == f2[fi].base by {
        lemma_rec_index(n, fi, FRAME_BASE);
        assert(rec(mem2, fi, FRAME_BASE) == rec(mem, fi, FRAME_BASE));
    }
    assert forall|x: int| 0 <= x < tries.len() implies
        rec(mem2, (#[trigger] tries[x]).frame as int, FRAME_HANDLER) == handler_word(tries[x]) by {
        lemma_rec_index(n, tries[x].frame as int, FRAME_HANDLER);
        assert(rec(mem2, tries[x].frame as int, FRAME_HANDLER) == rec(mem, tries[x].frame as int, FRAME_HANDLER));
    }
    assert forall|fi: int| 0 <= fi < n && #[trigger] rec(mem2, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < tries.len() && tries[x].frame == fi by {
        lemma_rec_index(n, fi, FRAME_HANDLER);
        assert(rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER));
    }
}

/// `m` is `m0` with the top frame's finally records dropped
/// (`fins_popped`) and the arguments `args` written below the frame's base
/// (positions `base..`, array indices `lim - 1 - j`), nothing else
/// changed: ready for `replace_finish`.
pub open spec fn replace_ready(p: &Program, m0: Machine, m: Machine, new_top: usize, args: Seq<Value>) -> bool {
    let g0 = m0.g@;
    let addr = m0.addr();
    &&& m0.refines(p)
    &&& shape_ok(p, g0)
    &&& !sp::has_handler(g0)
    &&& m.mem@.len() == m0.mem@.len()
    &&& m.len == m0.len
    &&& m.top == m0.top
    &&& m.ftop == m0.ftop
    &&& m.base == m0.base
    &&& m.lim == m0.lim
    &&& m.method == m0.method
    &&& m.bci == m0.bci
    &&& m.heap == m0.heap
    &&& m.globals == m0.globals
    &&& m.g == m0.g
    &&& m.rtop == m.ftop + FIN_WORDS * sp::fins_popped(g0).len()
    &&& fins_rel(m.mem@, m.ftop as int, sp::fins_popped(g0))
    &&& forall|i: int| 0 <= i < m.ftop ==> #[trigger] m.mem@[i] == m0.mem@[i]
    &&& m.rtop <= new_top <= m.lim
    &&& forall|i: int| m.lim <= i < m.len ==> #[trigger] m.mem@[i] == m0.mem@[i]
    &&& args.len() == m.lim - new_top
    &&& forall|j: int| 0 <= j < args.len() ==> #[trigger] m.mem@[m.lim - 1 - j] == enc(addr, args[j])
    &&& forall|j: int| 0 <= j < args.len() ==> #[trigger] encodable(addr, args[j])
}

impl Machine {
    /// `spec::replace_frame(g0, t, args)` once the records are dropped and
    /// the arguments written (`replace_ready`): the frame record's method,
    /// the top, the frame cache and the bci; then the preemption point (as
    /// after a call).
    #[inline(always)]
    pub fn replace_finish(&mut self, env: &Env, t: usize, new_top: usize, Ghost(m0): Ghost<Machine>,
        Ghost(args): Ghost<Seq<Value>>) -> (r: Ctl)
        requires
            replace_ready(&env.p, m0, *old(self), new_top, args),
            t < env.p.methods@.len(),
        ensures
            r == Ctl::Next || r == Ctl::Exit(RESULT_PREEMPTED as u32, 0),
            matches(&env.p, sp::replace_frame(env.p.ap@, m0.g@, t as int, args), *final(self), r),
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost g0 = m0.g@;
        let ghost m1 = *self;
        proof { m0.lemma_frame(p); }
        let info = p.method(t);
        let rr = self.ftop - FRAME_WORDS;
        self.mem.write(rr + FRAME_METHOD, t);
        self.top = new_top;
        self.method = t;
        self.bci = info.entry as usize;
        let ghost n = g0.frames.len() as int;
        let ghost g1 = State2 {
            stack: g0.stack.subrange(0, sp::base(g0)) + args,
            frames: g0.frames.update(sp::top_index(g0), Frame { method: t, ..sp::top(g0) }),
            fins: sp::fins_popped(g0),
            bci: info.entry as usize,
            ..g0
        };
        self.g = Ghost(g1);
        proof {
            let addr = m0.addr();
            assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height));
            assert(rr == FRAME_WORDS * (n - 1));
            assert(sp::top(g0) == g0.frames.last());
            // Frame records.
            assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_METHOD
                implies #[trigger] self.mem@[i] == m0.mem@[i] by {
                assert(self.mem@[i] == m1.mem@[i]);
            }
            lemma_frames_method(m0.mem@, self.mem@, g0.frames, g0.tries, t);
            // Finally records.
            assert forall|i: int| self.ftop <= i < self.ftop + FIN_WORDS * g1.fins.len()
                implies #[trigger] self.mem@[i] == m1.mem@[i] by {}
            lemma_fins_rel_same(m1.mem@, self.mem@, self.ftop as int, g1.fins);
            // The object stack.
            let b = sp::base(g0);
            assert(b == m0.base);
            assert(m0.words().len() == g0.stack.len());
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] self.words()[i] == enc(addr, g1.stack[i]) by {
                if i < b {
                    assert(g1.stack[i] == g0.stack[i]);
                    assert(self.mem@[self.len - 1 - i] == m0.mem@[self.len - 1 - i]);
                    assert(m0.words()[i] == enc_seq(addr, g0.stack)[i]);
                } else {
                    let j = i - b;
                    assert(g1.stack[i] == args[j]);
                    assert(self.len - 1 - i == m1.lim - 1 - j);
                    assert(self.mem@[self.len - 1 - i] == m1.mem@[m1.lim - 1 - j]);
                }
            }
            assert(self.words() =~= enc_seq(addr, g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(addr, g1.stack[i]) by {
                if i < b { assert(g1.stack[i] == g0.stack[i]); } else { assert(g1.stack[i] == args[i - b]); }
            }
            assert(g1.frames.last().base == m0.base);
            assert(self.refines(p));
            assert(sp::replace_frame(ap, g0, t as int, args) == Outcome2::Next(g1));
        }
        if env.pre.requested() {
            env.pre.clear();
            return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
        }
        Ctl::Next
    }
}

/// INVOKE_STATIC_TAIL d (`spec::op_invoke_static_tail`).
#[inline(always)]
pub fn op_invoke_static_tail(m: &mut Machine, env: &Env, bci: usize, opcode: u8, d: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_static_tail(env.p.ap@, old(m).g@, d as int),
        bci + 3 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        lemma_shape(p, g);
    }
    let t = p.dispatch.at(d) as usize;
    let info = p.method(t);
    proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
    let arity = info.arity as usize;
    if info.recv_start != NO_VALUE {
        proof { m.lemma_at(p, arity - 1); }
        let receiver = m.at(arity - 1);
        let cid = m.class_of(p, receiver, Ghost(sp::at(g, arity - 1)));
        if !((info.recv_start as usize) <= cid && cid < info.recv_end as usize) {
            proof {
                assert(sp::step(ap, g) == sp::raise(ap, g, sp::AS_CHECK_FAILED));
                lemma_source_step(ap, g);
            }
            return m.v_raise_none(env, 1);
        }
    }
    let ghost args = g.stack.subrange(g.stack.len() - arity, g.stack.len() as int);
    proof {
        assert(sp::op_invoke_static_tail(ap, g, d as int) == sp::replace_frame(ap, g, t as int, args));
        assert(!sp::has_handler(g));
    }
    let rr = m.ftop - FRAME_WORDS;
    proof { assert(rr == FRAME_WORDS * (g.frames.len() - 1)); assert(rr / FRAME_WORDS == g.frames.len() - 1); }
    m.cut_records(rr / FRAME_WORDS, 0, Ghost(g.fins));
    let ghost m1 = *m;
    let top = m.top;
    let new_top = m.lim - arity;
    m.mem.copy_within(top, new_top, arity);
    proof {
        let addr = m0.addr();
        assert(sp::fins_popped(g) == sp::cut_fins(g.fins, sp::top_index(g), 0));
        assert forall|j: int| 0 <= j < args.len() implies #[trigger] m.mem@[m.lim - 1 - j] == enc(addr, args[j]) by {
            let i = g.stack.len() - arity + j;
            assert(args[j] == g.stack[i]);
            assert(m.mem@[m.lim - 1 - j] == m0.mem@[top + arity - 1 - j]);
            assert(m0.words()[i] == m0.mem@[m0.len - 1 - i]);
            assert(m0.words()[i] == enc_seq(addr, g.stack)[i]);
        }
        assert forall|j: int| 0 <= j < args.len() implies #[trigger] encodable(addr, args[j]) by {
            assert(args[j] == g.stack[g.stack.len() - arity + j]);
        }
        assert forall|i: int| 0 <= i < m.ftop implies #[trigger] m.mem@[i] == m0.mem@[i] by {}
        assert forall|i: int| m.lim <= i < m.len implies #[trigger] m.mem@[i] == m0.mem@[i] by {}
        lemma_fins_rel_same(m1.mem@, m.mem@, m.ftop as int, sp::fins_popped(g));
    }
    let r = m.replace_finish(env, t, new_top, Ghost(m0), Ghost(args));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// The captured values of a lambda (`spec::captured`) whose argument is the
/// array `av` (`alen` is its length) or a single value.
pub open spec fn cap_of(s: toit_spec::types::State, av: Value, alen: Option<usize>) -> Seq<Value> {
    match alen {
        Some(_) => elements(s, av),
        None => seq![av],
    }
}

/// INVOKE_LAMBDA_TAIL (`spec::op_invoke_lambda_tail`): in `Lambda.call`,
/// whose parameters are the lambda and the arguments. The lambda's method
/// id and captures come from the heap and are checked.
#[inline(always)]
pub fn op_invoke_lambda_tail(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_lambda_tail(env.p.ap@, old(m).g@),
        opcode == 56,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost c0 = p.cert@;
    let ghost g = m.g@;
    let ghost s = as1(g);
    let ghost m0 = *m;
    let ghost b = sp::base(g);
    proof {
        assert(outcome_ok(ap, c0, sp::step(ap, g)));
        m.lemma_frame(p);
        lemma_shape(p, g);
        lemma_instr(ap, c0, p.trusted@, g);
        lemma_heap_good(p, g);
    }
    let info0 = p.method(m.method);
    proof { assert(ap.methods[m.method as int] == method_info(p.minfo(m.method as int), p.max_height)); }
    let a = info0.arity as usize;
    proof {
        let k = cur_k(ap, c0, g);
        assert(k.len() == a && a >= 1);
        assert(toit_spec::v2::verifier::is_val(toit_spec::v2::verifier::top_kind(k, a - 1)));
        lemma_at_good(ap, c0, p.trusted@, g, a - 1);
        m.lemma_at(p, a - 1);
        assert(sp::at(g, a - 1) == g.stack[b]);
    }
    let recv = m.at(a - 1);
    let ghost rv = g.stack[b];
    let (cnt, _) = match m.inst_x(p, recv, Ghost(rv)) {
        Some(x) => x,
        None => { proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); lemma_source_step(ap, g); } return m.v_raise_invalid(env); },
    };
    if cnt < 2 {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let (mw, Ghost(mv)) = m.field_x(p, recv, Ghost(rv), 0);
    let mid = match m.smi_x(p, mw, Ghost(mv)) {
        Some(x) => x,
        None => { proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); lemma_source_step(ap, g); } return m.v_raise_invalid(env); },
    };
    if mid < 0 || mid as usize >= p.methods.len() {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let t = mid as usize;
    let info = p.method(t);
    proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
    if !p.is_kind(t, KIND_LAMBDA) {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let c = info.aux as usize;
    let (aw, Ghost(av)) = m.field_x(p, recv, Ghost(rv), 1);
    let alen = m.array_x(p, aw, Ghost(av));
    match alen {
        Some(l) => { if l != c { proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); lemma_source_step(ap, g); } return m.v_raise_invalid(env); } },
        None => { if c != 1 { proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); lemma_source_step(ap, g); } return m.v_raise_invalid(env); } },
    }
    let arity_t = info.arity as usize;
    if arity_t < c {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let user = arity_t - c;
    if a - 1 < user {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::CODE_INVOCATION_FAILED));
            lemma_source_step(ap, g);
        }
        return m.v_raise_code(env, false, user, a - 1, t);
    }
    let ghost cap = cap_of(s, av, alen);
    let ghost args = g.stack.subrange(b + 1, b + 1 + user) + cap;
    proof {
        assert(sp::captured(ap, g, av, c as int) == Some(cap));
        assert(sp::op_invoke_lambda_tail(ap, g) == sp::replace_frame(ap, g, t as int, args));
        assert(!sp::has_handler(g));
        lemma_val(p, m0, aw, av);
    }
    let rr = m.ftop - FRAME_WORDS;
    proof { assert(rr == FRAME_WORDS * (g.frames.len() - 1)); assert(rr / FRAME_WORDS == g.frames.len() - 1); }
    m.cut_records(rr / FRAME_WORDS, 0, Ghost(g.fins));
    let ghost m1 = *m;
    let nargs = user + c;
    if nargs > m.lim - m.rtop {
        return Ctl::Stuck(stuck::LIMIT);
    }
    let lim = m.lim;
    let new_top = lim - nargs;
    m.mem.copy_within(lim - 1 - user, lim - user, user);
    let ghost m2 = *m;
    let ghost addr = m0.addr();
    let ghost aid = av->Obj_0 as int;
    proof {
        if alen is Some {
            assert(g.heap == m0.heap.objs());
            assert(m.heap == m0.heap);
        }
    }
    let mut j: usize = 0;
    while j < c
        invariant
            m.mem@.len() == m2.mem@.len(),
            m.len == m2.len, m.top == m2.top, m.ftop == m2.ftop, m.rtop == m2.rtop,
            m.base == m2.base, m.lim == m2.lim, m.method == m2.method, m.bci == m2.bci,
            m.heap == m2.heap, m.globals == m2.globals, m.g == m2.g,
            m2.heap == m0.heap, m2.g == m0.g,
            lim == m2.lim, lim == m0.lim, lim <= m2.len, m2.len == m2.mem@.len(),
            m.rtop <= new_top, new_top == lim - user - c, user < lim,
            j <= c,
            m0.refines(p),
            addr == m0.addr(),
            alen is Some ==> is_array(s, av) && elements(s, av).len() == c && aw == enc(addr, av)
                && 0 <= aid < g.heap.len() && av == Value::Obj(aid as usize),
            alen is None ==> c == 1,
            alen is Some ==> m.heap.objs()[aid].body is Array && m.heap.objs()[aid].body->Array_0 == elements(s, av)
                && m.heap.addrs().len() == m.heap.objs().len() && aw == m.heap.addrs()[aid]
                && aid < m.heap.objs().len() && m.heap.addrs() == addr,
            cap == cap_of(s, av, alen),
            encodable(addr, av), aw == enc(addr, av),
            forall|i: int| 0 <= i < m.mem@.len() && !(lim - user - j <= i < lim - user)
                ==> #[trigger] m.mem@[i] == m2.mem@[i],
            forall|jj: int| 0 <= jj < j ==> #[trigger] m.mem@[lim - 1 - user - jj] == enc(addr, cap[jj]),
        decreases c - j,
    {
        let v = match alen {
            Some(_) => {
                m.heap.element(aw, j, Ghost(aid))
            },
            None => aw,
        };
        m.mem.write(lim - 1 - user - j, v);
        j = j + 1;
    }
    proof {
        assert forall|jj: int| 0 <= jj < cap.len() implies #[trigger] encodable(addr, cap[jj]) by {
            if alen is Some { assert(obj_model_ok(g.heap[aid], m.heap.class_bits(), m.addr())); }
        }
        assert forall|jx: int| 0 <= jx < args.len() implies #[trigger] m.mem@[m.lim - 1 - jx] == enc(addr, args[jx]) by {
            if jx < user {
                let i = b + 1 + jx;
                assert(args[jx] == g.stack[i]);
                assert(m.mem@[lim - 1 - jx] == m2.mem@[lim - 1 - jx]);
                assert(m2.mem@[lim - 1 - jx] == m1.mem@[lim - 2 - jx]);
                assert(m0.words()[i] == m0.mem@[m0.len - 1 - i]);
                assert(m0.words()[i] == enc_seq(addr, g.stack)[i]);
            } else {
                assert(args[jx] == cap[jx - user]);
                assert(m.lim - 1 - jx == lim - 1 - user - (jx - user));
            }
        }
        assert forall|jx: int| 0 <= jx < args.len() implies #[trigger] encodable(addr, args[jx]) by {
            if jx < user { assert(args[jx] == g.stack[b + 1 + jx]); } else { assert(args[jx] == cap[jx - user]); }
        }
        assert forall|i: int| 0 <= i < m.ftop implies #[trigger] m.mem@[i] == m0.mem@[i] by {
            assert(m.mem@[i] == m2.mem@[i]);
        }
        assert forall|i: int| m.lim <= i < m.len implies #[trigger] m.mem@[i] == m0.mem@[i] by {
            assert(m.mem@[i] == m2.mem@[i]);
        }
        assert forall|i: int| m.ftop <= i < m.ftop + FIN_WORDS * sp::fins_popped(g).len()
            implies #[trigger] m.mem@[i] == m1.mem@[i] by {
            assert(m.mem@[i] == m2.mem@[i]);
        }
        lemma_fins_rel_same(m1.mem@, m.mem@, m.ftop as int, sp::fins_popped(g));
        assert(args.len() == user + c);
    }
    let r = m.replace_finish(env, t, new_top, Ghost(m0), Ghost(args));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// INVOKE_INITIALIZER_TAIL (`spec::op_invoke_initializer_tail`): the top
/// slot is the method id of a lazy global's initializer (from the heap:
/// checked).
#[inline(always)]
pub fn op_invoke_initializer_tail(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_initializer_tail(env.p.ap@, old(m).g@),
        opcode == 57,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        lemma_shape(p, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        assert(value_operands(cur_k(ap, p.cert@, g), 1));
        crate::halt::lemma_value_operand(p, g, 1, 0);
        m.lemma_at(p, 0);
        crate::halt::lemma_word_tag(m, p, m.mem@[m.top as int], sp::at(g, 0));
    }
    let w = m.at(0);
    if w & 1 != 0 {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    // A smi (the verifier types the operand as a value, not a block).
    let mid = smi_value(w);
    if mid < 0 || mid as usize >= p.methods.len() {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let t = mid as usize;
    let info = p.method(t);
    proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
    if info.kind != KIND_METHOD || info.arity != 0 {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    proof {
        assert(sp::op_invoke_initializer_tail(ap, g) == sp::replace_frame(ap, g, t as int, Seq::<Value>::empty()));
        assert(!sp::has_handler(g));
    }
    let rr = m.ftop - FRAME_WORDS;
    proof { assert(rr == FRAME_WORDS * (g.frames.len() - 1)); assert(rr / FRAME_WORDS == g.frames.len() - 1); }
    m.cut_records(rr / FRAME_WORDS, 0, Ghost(g.fins));
    let new_top = m.lim;
    let r = m.replace_finish(env, t, new_top, Ghost(m0), Ghost(Seq::<Value>::empty()));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

} // verus!

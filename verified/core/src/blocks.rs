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

//! Blocks, verified: LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK
//! and INVOKE_BLOCK (`spec::op_load_block` ... `spec::op_invoke_block`).
//!
//! A block reference `BlockRef(f, slot)` is the smi `f << 20 | slot`
//! (`abs::block_word`). The spec is stuck unless the operand is a block
//! reference into a live frame (`spec::block_ref`) and the outer slot lies
//! in that frame (`spec::outer_slot`), so the handlers decode the word
//! without checking it: the slot is `(w >> 1) & 0xfffff`, and the frame
//! records are not read at all. The slot a block reference names holds
//! its block method (the verifier's block slots, `lemma_block_target`), so
//! INVOKE_BLOCK never raises INVALID_PROGRAM. Too few arguments raise
//! CODE_INVOCATION_FAILED, which is not proven yet: the handler hands the
//! instruction to `step_unverified` there (before changing anything).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, conf, good_ref, kinds_of, fmethod, fbase, top_i};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_conf, cur_k, cur_m};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_call_ops::lemma_slot_method;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, wf_kind, block_slot, Kind};

verus! {

// ---------------------------------------------------------------------------
// Block reference words.

/// A block reference word is twice `f << 20 | s`; shifting and masking
/// recovers the slot.
pub proof fn lemma_block_decode(f: usize, s: usize)
    requires f < 0x100_0000_0000, s < 0x10_0000,
    ensures
        block_word(f, s) as int == 2 * (f * 0x10_0000 + s),
        (block_word(f, s) >> 1) & 0xf_ffff == s,
{
    let v = f * 0x10_0000 + s;
    assert(0 <= v < 0x1000_0000_0000_0000);
    let vi = v as i64;
    assert(vi as int == v);
    lemma_smi_word_nat(vi);
    let w = block_word(f, s);
    assert(w as int == 2 * v);
    assert(w == (f * 0x10_0000 + s) * 2);
    assert((w >> 1) & 0xf_ffff == s) by (bit_vector)
        requires w == (f * 0x10_0000 + s) * 2, f < 0x100_0000_0000, s < 0x10_0000;
}

/// The slot of the block reference word `w` of `BlockRef(f, s)`.
#[inline(always)]
pub fn ref_slot(w: usize, Ghost(f): Ghost<usize>, Ghost(s): Ghost<usize>) -> (r: usize)
    requires w == block_word(f, s), f < 0x100_0000_0000, s < 0x10_0000,
    ensures r == s,
{
    proof { lemma_block_decode(f, s); }
    (w >> 1) & 0xf_ffff
}

// ---------------------------------------------------------------------------
// The object stack by position.

/// The word at object-stack position `i` (from the bottom) encodes the
/// abstract value there.
pub proof fn lemma_slot(m: &Machine, p: &Program, i: int)
    requires m.refines(p), 0 <= i < m.g@.stack.len(),
    ensures
        m.top <= m.len - 1 - i < m.len,
        m.mem@[m.len - 1 - i] == enc(m.addr(), m.g@.stack[i]),
        encodable(m.addr(), m.g@.stack[i]),
{
    m.lemma_frame(p);
    assert(m.words().len() == enc_seq(m.addr(), m.g@.stack).len());
    assert(m.words()[i] == m.mem@[m.len - 1 - i]);
    assert(enc_seq(m.addr(), m.g@.stack)[i] == enc(m.addr(), m.g@.stack[i]));
}

/// The slot a block reference names (from slot `n` of the top frame)
/// holds a block method: the verifier's kinds make the reference point to
/// a block slot (`block_slot`) of its frame, which holds the method
/// (`lemma_slot_method`). As in the soundness proof of INVOKE_BLOCK
/// (`sound_call_ops::lemma_step_invoke_block`).
pub proof fn lemma_block_target(p: &Program, g: State2, n: int)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        sp::has_slot(g, n),
        sp::at(g, n) is BlockRef,
    ensures
        sp::block_target(p.ap@, g, sp::at(g, n)->BlockRef_1 as int) is Some,
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let k = cur_k(ap, c, g);
    let jr = k.len() - 1 - n;
    lemma_at_conf(ap, c, p.trusted@, g, n);
    let v = sp::at(g, n);
    let f = v->BlockRef_0 as int;
    let slot = v->BlockRef_1 as int;
    assert(0 <= f < g.frames.len() && block_slot(ap, c, fmethod(g, f), kinds_of(ap, c, g, f), slot - fbase(g, f))) by {
        reveal(conf);
        match k[jr] {
            Kind::Block(d, i) => {
                if d == 0 {
                    assert(wf_kind(ap, c, cur_m(g), k, jr));
                } else {
                    reveal(good_ref);
                }
            },
            Kind::Param => { reveal(good_ref); },
            _ => {},
        }
    }
    lemma_slot_method(ap, c, p.trusted@, g, f, slot - fbase(g, f));
}

impl Machine {
    /// Drops the top `n` slots (`spec::drop`).
    #[inline(always)]
    pub fn drop_vals(&mut self, p: &Program, n: usize)
        requires old(self).refines(p), old(self).top + n <= old(self).lim,
        ensures
            final(self).refines(p),
            final(self).g@ == sp::drop(old(self).g@, n as int),
            final(self).top == old(self).top + n,
            final(self).ftop == old(self).ftop,
            final(self).bci == old(self).bci,
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_frame(p); }
        self.drop(n);
        let ghost g1 = sp::drop(g0, n as int);
        self.g = Ghost(g1);
        proof {
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                assert(g1.stack[i] == g0.stack[i]);
            }
            m0.lemma_local_step(p, self);
        }
    }
}

// ---------------------------------------------------------------------------
// Handlers.

/// LOAD_BLOCK k: pushes a reference to slot k of the top frame. The
/// encoding limits hold by `refines` (fewer than 2^20 words of stack).
#[inline(always)]
pub fn op_load_block(m: &mut Machine, env: &Env, bci: usize, opcode: u8, k: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_block(old(m).g@, k as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        assert(m.ftop / FRAME_WORDS == g.frames.len());
    }
    let slot = m.len - m.top - 1 - k;
    let f = m.ftop / FRAME_WORDS - 1;
    let ghost v = Value::BlockRef(f, slot);
    let w = smi_of((f * 0x10_0000 + slot) as i64);
    proof {
        assert(sp::top_index(g) as usize == f);
        assert((g.stack.len() - 1 - k) as usize == slot);
    }
    let r = m.push_next(p, w, 2, Ghost(v));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// LOAD_OUTER k: replaces the block reference on top by the slot k below
/// the block's slot.
#[inline(always)]
pub fn op_load_outer(m: &mut Machine, env: &Env, bci: usize, opcode: u8, k: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_outer(old(m).g@, k as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
    }
    let ghost v = sp::at(g, 0);
    let w = m.at(0);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let i = slot - k;
    proof { lemma_slot(m, p, i as int); }
    let x = m.mem.read(m.len - 1 - i);
    m.put(0, x);
    m.bci = m.bci + 2;
    let ghost g1 = sp::goto(sp::put(g, 0, g.stack[i as int]), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != g.stack.len() - 1 { assert(g1.stack[j] == g.stack[j]); }
        }
        m0.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// STORE_OUTER k: stores the top value into the slot k below the block's
/// slot; the block reference is dropped, the value stays.
#[inline(always)]
pub fn op_store_outer(m: &mut Machine, env: &Env, bci: usize, opcode: u8, k: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_outer(old(m).g@, k as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
        m.lemma_frame(p);
    }
    let ghost v = sp::at(g, 1);
    let x = m.at(0);
    let w = m.at(1);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let i = slot - k;
    proof { lemma_slot(m, p, i as int); }
    let idx = m.len - 1 - i;
    m.mem.write(idx, x);
    let t = m.top + 1;
    m.mem.write(t, x);
    m.top = t;
    m.bci = m.bci + 2;
    let ghost s1 = sp::drop(g, 2);
    let ghost g1 = sp::goto(sp::push(State2 { stack: s1.stack.update(i as int, sp::at(g, 0)), ..s1 }, sp::at(g, 0)), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        let h = g.stack.len();
        assert(g1.stack.len() == h - 1);
        assert forall|j: int| 0 <= j < h - 1 implies #[trigger] m.words()[j] == enc(m0.addr(), g1.stack[j]) by {
            assert(m.words()[j] == m.mem@[m.len - 1 - j]);
            if j == h - 2 {
                assert(m.len - 1 - j == t);
            } else if j == i {
            } else {
                assert(m.mem@[m.len - 1 - j] == m0.mem@[m.len - 1 - j]);
                assert(m0.words()[j] == m0.mem@[m.len - 1 - j]);
                assert(m0.words()[j] == enc_seq(m0.addr(), g.stack)[j]);
                assert(g1.stack[j] == g.stack[j]);
            }
        }
        assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != h - 2 && j != i { assert(g1.stack[j] == g.stack[j]); }
        }
        assert(m.stack_ok());
        m0.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// LOAD_OUTER_BLOCK k: replaces the block reference on top by a reference
/// to the slot k below the block's slot, in the same frame: the word
/// minus `2 * k`.
#[inline(always)]
pub fn op_load_outer_block(m: &mut Machine, env: &Env, bci: usize, opcode: u8, k: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_outer_block(old(m).g@, k as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
    }
    let ghost v = sp::at(g, 0);
    let ghost f = v->BlockRef_0;
    let ghost s = v->BlockRef_1;
    let w = m.at(0);
    let ghost nv = Value::BlockRef(f, (s - k) as usize);
    proof {
        lemma_block_decode(f, s);
        lemma_block_decode(f, (s - k) as usize);
    }
    let w2 = w - 2 * k;
    m.put(0, w2);
    m.bci = m.bci + 2;
    let ghost g1 = sp::goto(sp::put(g, 0, nv), g.bci + 2);
    m.g = Ghost(g1);
    proof {
        assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j != g.stack.len() - 1 { assert(g1.stack[j] == g.stack[j]); }
        }
        m0.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// INVOKE_BLOCK n: calls the block whose reference is at STACK_AT(n - 1),
/// dropping extra arguments. Raising CODE_INVOCATION_FAILED (too few
/// arguments) is not proven yet.
#[inline(always)]
pub fn op_invoke_block(m: &mut Machine, env: &Env, bci: usize, opcode: u8, n: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_block(env.p.ap@, old(m).g@, n as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    if let Some(c) = ensure_room(m, env) {
        return c;
    }
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, n - 1);
    }
    let ghost v = sp::at(g, n - 1);
    let w = m.at(n - 1);
    let slot = ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    proof {
        lemma_block_target(p, g, n - 1);
        lemma_slot(m, p, slot as int);
    }
    let ghost tt = sp::block_target(ap, g, slot as int)->0;
    let mw = m.mem.read(m.len - 1 - slot);
    proof {
        assert(g.stack[slot as int] == Value::Smi(tt as i64));
        assert(0 <= tt < ap.methods.len());
        assert(ap.methods.len() == p.methods@.len());
        lemma_smi_word_nat(tt as i64);
        assert(mw == 2 * tt);
        assert(mw >> 1 == mw / 2) by (bit_vector);
    }
    let t = mw >> 1;
    let info = p.methods.at(t);
    proof { assert(ap.methods[t as int] == method_info(p.methods@[t as int], p.max_height)); }
    let arity = info.arity as usize;
    if n < arity {
        return step_unverified(m, env, bci, opcode, false);
    }
    m.drop_vals(p, n - arity);
    let r = m.push_call(env, t, bci + 2);
    proof { lemma_matches(p, m0, *m, r); }
    r
}

} // verus!

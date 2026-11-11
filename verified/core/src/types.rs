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

//! Type checks, verified: IS_CLASS(_WIDE), IS_INTERFACE(_WIDE),
//! AS_CLASS(_WIDE), AS_INTERFACE(_WIDE) and AS_LOCAL (`spec::op_is`,
//! `spec::op_as`, `spec::op_as_local`). The check itself
//! (`spec::typecheck`) needs no run-time checks: the value has a class
//! id, the class check and interface check indices are in their tables
//! (the spec step is not stuck). A failed AS check raises AS_CHECK_FAILED
//! (the verified raise, raise.rs).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::outcome_ok;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;

verus! {

impl Machine {
    /// `spec::typecheck` of the value `v` (word `w`) when it is not stuck:
    /// true for `Check::Yes`, false for `Check::No`.
    #[inline(always)]
    pub fn check_type(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, index: usize, nullable: bool, interface: bool) -> (r: bool)
        requires
            self.hrefines(p),
            accepts(p.ap@, p.cert@, p.trusted@),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            index < 0x1_0000,
            !(sp::typecheck(p.ap@, self.g@, v, index as int, nullable, interface) is Stuck),
        ensures
            r == (sp::typecheck(p.ap@, self.g@, v, index as int, nullable, interface) is Yes),
    {
        let ghost ap = p.ap@;
        let ghost g = self.g@;
        proof {
            // Not stuck: the value is null or has a class id, so it is a
            // smi or an object (not a block reference).
            assert(v is Smi || v is Obj);
            assert(const_ok(g.heap, ap.roots[0]));
            lemma_enc_inj(g.heap, self.addr(), v, sp::null2(ap));
            assert((w == p.null) == (v == sp::null2(ap)));
        }
        if nullable && w == p.null {
            return true;
        }
        if !interface {
            let cid = self.class_of(p, w, Ghost(v));
            let start = p.class_check_ids.at(2 * index) as usize;
            let end = p.class_check_ids.at(2 * index + 1) as usize;
            start <= cid && cid < end
        } else {
            let sel = p.interface_check_offsets.at(index) as usize;
            match self.lookup(p, w, Ghost(v), sel as i64) {
                VLookup::Found(_) => true,
                VLookup::Missing => false,
            }
        }
    }
}

/// The slots of the stack (other than `n`) are those of `g`, and slot `n`
/// is the encoding of `v`: the stack of `put(g, n, v)`.
pub proof fn lemma_put_rel(p: &Program, m0: Machine, m1: Machine, n: int, w: usize, v: Value)
    requires
        m0.refines(p),
        sp::has_slot(m0.g@, n),
        m1.words() == m0.words().update(m0.height() - 1 - n, w),
        w == enc(m0.addr(), v),
        encodable(m0.addr(), v),
    ensures
        m1.words() == enc_seq(m0.addr(), sp::put(m0.g@, n, v).stack),
        forall|i: int| 0 <= i < sp::put(m0.g@, n, v).stack.len() ==>
            #[trigger] encodable(m0.addr(), sp::put(m0.g@, n, v).stack[i]),
{
    let g0 = m0.g@;
    let g1 = sp::put(g0, n, v);
    m0.lemma_frame(p);
    assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
    assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
        if i != g0.stack.len() - 1 - n { assert(g1.stack[i] == g0.stack[i]); }
    }
}

} // verus!

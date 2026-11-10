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

//! The verifier's context chain (`ctx_kinds`, `ctx_method`) describes the
//! frames the block references of a block frame reach.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;

verus! {

/// The frame `d >= 1` contexts out from frame `fi` runs the method
/// `ctx_method(c, m, d)` and its kinds start with `ctx_kinds(c, m, d)`.
pub proof fn lemma_ctx_frame(p: Program2, c: Cert, trusted: bool, s: State2, fi: int, d: nat)
    requires
        accepts(p, c, trusted),
        bases_ok(s),
        0 <= fi < s.frames.len(),
        forall|g: int| 0 <= g <= fi ==> #[trigger] frame_ok(p, c, s, g),
        d >= 1,
        ctx_kinds(c, fmethod(s, fi), d) is Some,
    ensures ({
        let f = context_frame(s, fi, d);
        let ck = ctx_kinds(c, fmethod(s, fi), d)->0;
        &&& 0 <= f < fi
        &&& fmethod(s, f) == ctx_method(c, fmethod(s, fi), d)
        &&& ck.len() <= kinds_of(p, c, s, f).len()
        &&& kinds_of(p, c, s, f).subrange(0, ck.len() as int) == ck
    }),
    decreases d,
{
    let m = fmethod(s, fi);
    let ctx = ctx_of(c, m)->0;
    assert(ctx_of(c, m) is Some);
    assert(frame_ok(p, c, s, fi));
    reveal(frame_ok);
    lemma_block_method(p, c, trusted, m);
    lemma_map_instr(p, c, trusted, m, foff(p, s, fi));
    let kf = kinds_of(p, c, s, fi);
    assert(slots(s, fi) >= 1);
    assert(kf[0] == fmap(p, c, s, fi)[0]);
    assert(kf[0] == Kind::Block(1, ctx.slot));
    lemma_base_le_len(s, fi);
    let v = s.stack[fbase(s, fi)];
    assert(conf(p, c, s, fi, kf, 0, kf[0], s.stack[fbase(s, fi) + 0]));
    reveal(conf);
    reveal(good_ref);
    match v {
        Value::BlockRef(f0, slot) => {
            let f = f0 as int;
            assert(f == context_frame(s, fi, 1));
            lemma_context_frame_lt(s, fi, 1);
            assert(0 <= f < fi);
            let kg = kinds_of(p, c, s, f);
            assert(kg[ctx.slot] == Kind::Method(m));
            assert(block_slot(p, c, fmethod(s, f), kg, ctx.slot));
            assert(ctx_ok_at(p, c, fmethod(s, f), kg, ctx.slot));
            assert(kind_method(kg[ctx.slot]) == m);
            assert(kg.subrange(0, ctx.slot + 1) == ctx.kinds);
            assert(ctx.outer == fmethod(s, f));
            reveal_with_fuel(context_frame, 2);
            if d == 1 {
                assert(ctx_kinds(c, m, 1) == Some(ctx.kinds));
                assert(ctx_method(c, m, 1) == ctx_method(c, ctx.outer, 0));
            } else {
                assert(ctx_kinds(c, m, d) == ctx_kinds(c, ctx.outer, (d - 1) as nat));
                assert(ctx_method(c, m, d) == ctx_method(c, ctx.outer, (d - 1) as nat));
                assert(context_frame(s, fi, d) == context_frame(s, f, (d - 1) as nat));
                lemma_ctx_frame(p, c, trusted, s, f, (d - 1) as nat);
            }
        },
        _ => { assert(false); },
    }
}

} // verus!

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

//! Soundness of HASH_FIND (proposal, verified/spec/format/
//! 19-builtins-proposal.md): the probe reads the heap only through
//! `fast_at` and `fast_size`, so a candidate key is a value of the heap;
//! a candidate overwrites three value slots and pushes two values, a miss
//! pushes a smi and branches forward to an instruction whose map has it.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_local_ops::*;
#[cfg(verus_only)]
use crate::spec_common::{smi, is_instance, fields};
#[cfg(verus_only)]
use crate::spec_helpers::{fast_at, fast_size, smi_val, FAST_AT_FUEL};

verus! {

/// The key of a candidate is a value of the heap.
pub proof fn lemma_hf_probe_good(p: Program2, c: Cert, s: State2, index: Value, backing: Value, hash: int,
    mask: int, start: int, slot: int, step: int, d: int, fuel: nat)
    requires heap_ok(p, c, s.heap), good(s.heap, null2(p)),
    ensures
        match hf_probe(p, s, index, backing, hash, mask, start, slot, step, d, fuel) {
            Probe::Cand(k, _, _, _, _) => good(s.heap, k),
            _ => true,
        },
    decreases fuel,
{
    if fuel > 0 {
        crate::v2::sound_virtual::lemma_fast_at(p, c, s, index, smi(slot), false, null2(p), FAST_AT_FUEL);
        match hf_at(p, s, index, slot) {
            Some(Value::Smi(hap)) => {
                if hap != 0 {
                    let pos = hap / 4096 - 1;
                    crate::v2::sound_virtual::lemma_fast_at(p, c, s, backing, smi(pos), false, null2(p), FAST_AT_FUEL);
                    match hf_at(p, s, backing, pos) {
                        Some(k) => {
                            let tomb = is_tombstone(p, s, k);
                            let d1 = if d == 0 && tomb { slot + 1 } else { d };
                            lemma_hf_probe_good(p, c, s, index, backing, hash, mask, start,
                                crate::spec_helpers::band(slot + step, mask), step + 1, d1, (fuel - 1) as nat);
                        },
                        None => {},
                    }
                }
            },
            _ => {},
        }
    }
}

pub proof fn lemma_hf_find_good(p: Program2, c: Cert, s: State2, coll: Value, hashv: Value, slotv: Value, stepv: Value, dv: Value)
    requires heap_ok(p, c, s.heap), good(s.heap, null2(p)),
    ensures
        match hf_find(p, s, coll, hashv, slotv, stepv, dv) {
            Probe::Cand(k, pos, slot, step, d) => good(s.heap, k),
            _ => true,
        },
{
    if is_instance(as1(s), coll) && fields(as1(s), coll).len() >= 4
        && hashv is Smi && slotv is Smi && stepv is Smi && dv is Smi {
        let index = fields(as1(s), coll)[2];
        let backing = fields(as1(s), coll)[3];
        match fast_size(p1(p), as1(s), index) {
            Some(size) => {
                let (hash, slot, step, d) = (smi_val(hashv), smi_val(slotv), smi_val(stepv), smi_val(dv));
                let mask = size - 1;
                let start = crate::spec_helpers::band(hash, mask);
                lemma_hf_probe_good(p, c, s, index, backing, hash, mask, start, start, 1, d, (2 * size) as nat);
                lemma_hf_probe_good(p, c, s, index, backing, hash, mask, start,
                    crate::spec_helpers::band(slot + step, mask), step + 1, d, (2 * size) as nat);
            },
            None => {},
        }
    }
}

/// A candidate: slots `n`, `n + 1`, `n + 2` get the values `a0`, `a1`,
/// `a2`; `k` and `v` are pushed.
#[verifier::spinoff_prover]
pub proof fn lemma_hf_cand(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, n: int,
    a0: Value, a1: Value, a2: Value, k: Value, v: Value)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        0 <= n, n + 2 < cur_k(p, c, s).len(),
        writable(p, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 1 - n, Kind::Val),
        writable(p, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 2 - n, Kind::Val),
        writable(p, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 3 - n, Kind::Val),
        good(s.heap, a0), good(s.heap, a1), good(s.heap, a2), good(s.heap, k), good(s.heap, v),
        s2.frames == s.frames,
        s2.task == s.task,
        s2.heap == s.heap,
        s2.globals == s.globals,
        s2.stack == put(put(put(s, n, a0), n + 1, a1), n + 2, a2).stack.push(k).push(v),
        info(p, cur_m(s)).entry <= s2.bci,
        map_at(c, cur_m(s), s2.bci - info(p, cur_m(s)).entry) == Some(hf_kinds(cur_k(p, c, s), n)),
    ensures wf(p, c, s2),
{
    lemma_instr(p, c, trusted, s);
    let b = cur_b(s);
    let m = cur_m(s);
    let kk = cur_k(p, c, s);
    let h = kk.len() as int;
    let i1 = h - 1 - n;
    let i2 = h - 2 - n;
    let i3 = h - 3 - n;
    let k2 = hf_kinds(kk, n);
    assert(s.stack.len() == b + h);
    assert(k2.len() == h + 2);
    assert(s2.stack.len() == b + h + 2);
    assert(s2.stack[b + i1] == a0);
    assert(s2.stack[b + i2] == a1);
    assert(s2.stack[b + i3] == a2);
    assert(s2.stack[b + h] == k);
    assert(s2.stack[b + h + 1] == v);
    assert forall|x: int| 0 <= x < b + h && x != b + i1 && x != b + i2 && x != b + i3
        implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < h && j != i1 && j != i2 && j != i3 implies #[trigger] k2[j] == kk[j] by {}
    assert(k2[i1] == Kind::Val && k2[i2] == Kind::Val && k2[i3] == Kind::Val);
    assert(k2[h] == Kind::Val && k2[h + 1] == Kind::Val);
    lemma_heap_ext_refl(p, s.heap);
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(i3 != 0);
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert forall|x: int| 0 <= x < b + i3 implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < i3 implies #[trigger] k2[j] == kk[j] by {}
    assert(globals_ok(c, s2));
    assert(lframe(p, c, s, s2, k2, i3));
    lemma_conf_val(p, c, s2, top_i(s), k2, i1, a0);
    lemma_conf_val(p, c, s2, top_i(s), k2, i2, a1);
    lemma_conf_val(p, c, s2, top_i(s), k2, i3, a2);
    lemma_conf_val(p, c, s2, top_i(s), k2, h, k);
    lemma_conf_val(p, c, s2, top_i(s), k2, h + 1, v);
    assert forall|j: int| i3 <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), k2, j, k2[j], s2.stack[b + j]) by {
        if i1 < j < h {
            assert(s2.stack[b + j] == s.stack[b + j]);
            assert(k2[j] == kk[j]);
        }
    }
    assert forall|j: int| i3 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == kk.subrange(0, j) by {
        assert(j > i1);
        assert(kk[j] is Token);
        assert(below_token(kk, i1));
        assert(below_token(kk, i2));
        assert(below_token(kk, i3));
        assert(kk[i1] is Val && kk[i2] is Val && kk[i3] is Val);
        assert(k2.subrange(0, j) =~= kk.subrange(0, j));
    }
    lemma_lgen(p, c, trusted, s, s2, k2, i3);
}

/// HASH_FIND.
#[verifier::spinoff_prover]
pub proof fn lemma_step_hash_find(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == HASH_FIND,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = opcode_length2(op);
    let w1 = w1_of(p, m, off);
    let n = bk_of(p, m, off, 3);
    let mm = bk_of(p, m, off, 4);
    assert(!is_terminator(op));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(hf_ok(p, m, k, n, mm));
    assert(post(p, c, m, off, k, trusted) == Some(hf_kinds(k, n)));
    assert(map_at(c, m, off + len) == Some(hf_kinds(k, n)));
    let toff = off + w1;
    let target = info(p, m).entry + toff;
    assert(map_at(c, m, toff) == Some(k.push(Kind::Val)));
    lemma_map_bound(p, c, trusted, m, toff);
    assert(byte2(p, s.bci + 3) == n && byte2(p, s.bci + 4) == mm);
    assert(s.bci + w1 == target);
    assert(step(p, s) == op_hash_find(p, s, s.bci + w1, n, mm, len)) by { reveal(step); }
    lemma_at_good(p, c, trusted, s, mm + 2);
    assert(has_slot(s, n + 2) && has_slot(s, mm + 2));
    assert(good(s.heap, null2(p)));
    lemma_hf_find_good(p, c, s, at(s, mm + 2), at(s, mm), at(s, n), at(s, n + 1), at(s, n + 2));
    match hf_find(p, s, at(s, mm + 2), at(s, mm), at(s, n), at(s, n + 1), at(s, n + 2)) {
        Probe::Cand(kv, pos, slot, step, d) => {
            let s2 = goto(push(push(put(put(put(s, n, smi(slot)), n + 1, smi(step)), n + 2, smi(d)), kv), smi(pos)), s.bci + len);
            assert(op_hash_find(p, s, target, n, mm, len) == Outcome2::Next(s2));
            lemma_hf_cand(p, c, trusted, s, s2, n, smi(slot), smi(step), smi(d), kv, smi(pos));
        },
        Probe::Miss(code) => {
            let s2 = goto(push(s, smi(code)), target);
            assert(info(p, m).entry <= target < info(p, m).end);
            assert(op_hash_find(p, s, target, n, mm, len) == Outcome2::Next(s2));
            assert(k.subrange(0, h - 0) =~= k);
            assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
            lemma_pop_push(p, c, trusted, s, s2, 0, smi(code), Kind::Val, 0);
        },
    }
}

} // verus!

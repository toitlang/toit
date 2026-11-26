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

//! The single-pass checker of a shipped certificate
//! (format/18-shipped-certificate.md).
//!
//! `walk(p, g, s, trusted, progress)` checks the program `p` against the
//! certificate's global part `g` and its maps stream `s`, one method at a
//! time, in one forward walk per method: the walk places the kinds of each
//! instruction (the previous instruction's successor, or a shipped map,
//! which must then agree), checks the instruction on them with the
//! checker's per-instruction functions (`check::x_post_into`,
//! `x_wf_kinds`, `x_ctx_ok`, `x_shape_ok`, `x_terminator_ok`), and keeps
//! only what later instructions need:
//!
//! * the current kinds (the successor of the instruction just checked);
//! * the pending forward obligations: the kinds a forward branch or
//!   HASH_FIND requires at its target, compared when the walk places the
//!   target;
//! * the kinds at the targets of backward branches and loop steps (found
//!   by a scan of the opcodes before the walk), kept when the walk places
//!   them.
//!
//! The maps of the method, which the two-pass checker materialised, are
//! ghost state here (`mm`): the walk is proven to return true only if the
//! method is accepted against them (`method_ok(p, local_cert(g, m, mm),
//! m, trusted)`) and the pins of the method agree with them, so `walk`
//! returns true only if `split_ok(vview(p), g@, ms, trusted)` holds for the
//! ghost maps `ms` of all methods, the hypothesis of `lemma_split_sound`
//! and so of `theorem_soundness`.
//!
//! The instruction rules are checked against `tables_cert(g)` (the global
//! part with the pins as the only maps); `lemma_local_mono` carries them
//! to `local_cert(g, m, mm)` once the method's pins agree with `mm`.
//!
//! Which offsets keep their kinds for backward targets is a hint: a
//! backward target without kept kinds rejects. Nothing about the stream's
//! decoding needs to be correct for soundness; it is total (no
//! out-of-bounds access, no overflow, it terminates). Out of memory is
//! `Err(Oom)` (rejected, but reported as such), never a panic.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::split::*;
use crate::v2::check::*;
use crate::v2::vprog::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;
#[cfg(verus_only)]
use crate::spec_common::{u16_at, u32_at};

verus! {

// ---------------------------------------------------------------------------
// `instr_ok` split into the instruction's own conditions and the maps it
// requires at other offsets of its method.

/// The target of the branch at offset `off` of `m`.
pub open spec fn branch_target(p: Program2, m: int, off: int) -> int {
    if op_of(p, m, off) <= BRANCH_IF_NOT_NULL { off + w1_of(p, m, off) } else { off - w1_of(p, m, off) }
}

/// The opcode falls through to the next instruction.
pub open spec fn falls(op: u8) -> bool {
    !is_terminator(op)
}

/// The kinds a branch requires at its target.
pub open spec fn branch_kinds(op: u8, k: Seq<Kind>) -> Seq<Kind> {
    if op == BRANCH || op == BRANCH_BACK { k } else { k.drop_last() }
}

/// Obligation `i` (0 to 3) of the instruction at `off` with kinds `k`: an
/// offset of `m` and the map `instr_ok` requires there. 0: the fall-through
/// successor; 1: a branch target; 2: a loop step's target; 3: HASH_FIND's
/// miss target.
pub open spec fn obl(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool, i: int)
    -> Option<(int, Seq<Kind>)>
{
    let op = op_of(p, m, off);
    let w1 = w1_of(p, m, off);
    if i == 0 {
        match post(p, c, m, off, k, trusted) {
            Some(k2) => Some((off + len_of(p, m, off), k2)),
            None => None,
        }
    } else if i == 1 {
        if is_branch(op) { Some((branch_target(p, m, off), branch_kinds(op, k))) } else { None }
    } else if i == 2 {
        if is_loop(op) {
            Some((off - w1, loop_kinds(k, loop_operands(p, m, off).0, loop_operands(p, m, off).1)))
        } else { None }
    } else if i == 3 {
        if op == HASH_FIND { Some((off + w1, k.push(Kind::Val))) } else { None }
    } else {
        None
    }
}

/// The map of `m` at the obligation's offset is the obligation's map.
pub open spec fn obl_holds(c: Cert, m: int, o: Option<(int, Seq<Kind>)>) -> bool {
    match o {
        Some((t, s)) => map_at(c, m, t) == Some(s),
        None => true,
    }
}

/// `instr_ok` without the maps at other offsets.
pub open spec fn local_ok(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool) -> bool {
    let i = info(p, m);
    let op = op_of(p, m, off);
    let w1 = w1_of(p, m, off);
    &&& 0 <= off
    &&& i.entry + off < i.end
    &&& op < OPCODE_COUNT2
    &&& raw_op_of(p, m, off) < OPCODE_COUNT2
    &&& (is_twin(raw_op_of(p, m, off)) ==> p.unchecked)
    &&& i.entry + off + len_of(p, m, off) <= i.end
    &&& wf_kinds(p, c, m, k)
    &&& ctx_ok(p, c, m, k)
    &&& shape_ok(p, c, m, k)
    &&& k.len() <= arity(p, m) + i.max_height
    &&& if is_terminator(op) { terminator_ok(p, c, m, off, k) } else { post(p, c, m, off, k, trusted) is Some }
    &&& (is_branch(op) && op <= BRANCH_IF_NOT_NULL ==> w1 > 0)
    &&& (op == HASH_FIND ==> w1 > 0)
}

pub proof fn lemma_instr_split(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool)
    ensures
        instr_ok(p, c, m, off, k, trusted) == (local_ok(p, c, m, off, k, trusted)
            && forall|i: int| 0 <= i < 4 ==> #[trigger] obl_holds(c, m, obl(p, c, m, off, k, trusted, i))),
{
    let a = instr_ok(p, c, m, off, k, trusted);
    let b = local_ok(p, c, m, off, k, trusted)
        && forall|i: int| 0 <= i < 4 ==> #[trigger] obl_holds(c, m, obl(p, c, m, off, k, trusted, i));
    assert(obl_holds(c, m, obl(p, c, m, off, k, trusted, 0)) == match post(p, c, m, off, k, trusted) {
        Some(k2) => map_at(c, m, off + len_of(p, m, off)) == Some(k2),
        None => true,
    });
    if a {
        assert forall|i: int| 0 <= i < 4 implies #[trigger] obl_holds(c, m, obl(p, c, m, off, k, trusted, i)) by {
            if i == 1 && is_branch(op_of(p, m, off)) {
                assert(obl(p, c, m, off, k, trusted, 1) == Some((branch_target(p, m, off), branch_kinds(op_of(p, m, off), k))));
            }
        }
    }
    if b {
        assert(obl_holds(c, m, obl(p, c, m, off, k, trusted, 0)));
        assert(obl_holds(c, m, obl(p, c, m, off, k, trusted, 1)));
        assert(obl_holds(c, m, obl(p, c, m, off, k, trusted, 2)));
        assert(obl_holds(c, m, obl(p, c, m, off, k, trusted, 3)));
    }
}

/// A terminator has no fall-through successor.
pub proof fn lemma_term_post(p: Program2, c: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool)
    requires is_terminator(op_of(p, m, off)),
    ensures post(p, c, m, off, k, trusted) is None,
{
}

pub proof fn lemma_terminator_mono(p: Program2, c1: Cert, c2: Cert, m: int, off: int, k: Seq<Kind>)
    requires same_g(c1, c2), sub_maps(c1, c2), terminator_ok(p, c1, m, off, k),
    ensures terminator_ok(p, c2, m, off, k),
{
    lemma_ctx_same_all(c1, c2);
    let op = op_of(p, m, off);
    if op == INVOKE_STATIC_TAIL {
        lemma_args_same(c1, c2, dispatch_target(p, w1_of(p, m, off)), k, arity(p, dispatch_target(p, w1_of(p, m, off))));
    }
    if op == NON_LOCAL_BRANCH {
        match top_kind(k, 0) {
            Kind::Block(d, j) => {
                let om = ctx_method(c1, m, d as nat);
                let target = u32_at(p1(p), instr_at(p, m, off) + 2);
                if map_at(c1, om, target) is Some {
                    assert(map_at(c2, om, target) == map_at(c1, om, target));
                }
            },
            _ => {},
        }
    }
}

/// The instruction's own conditions and obligations depend on the
/// certificate only through its global part and the maps of other methods
/// it compares with (`terminator_ok`'s NON_LOCAL_BRANCH).
pub proof fn lemma_local_mono(p: Program2, c1: Cert, c2: Cert, m: int, off: int, k: Seq<Kind>, trusted: bool)
    requires same_g(c1, c2), sub_maps(c1, c2), local_ok(p, c1, m, off, k, trusted),
    ensures
        local_ok(p, c2, m, off, k, trusted),
        forall|i: int| #[trigger] obl(p, c1, m, off, k, trusted, i) == obl(p, c2, m, off, k, trusted, i),
{
    lemma_frame_same(p, c1, c2, m, k);
    lemma_post_same(p, c1, c2, m, off, k, trusted);
    if is_terminator(op_of(p, m, off)) {
        lemma_terminator_mono(p, c1, c2, m, off, k);
    }
}

/// The pins of method `m` agree with its maps `mm`.
pub open spec fn pins_of_agree(g: GCert, m: int, mm: Maps) -> bool {
    forall|o: int| #[trigger] pin_at(g, m, o) is Some ==> 0 <= o < mm.len() && mm[o] == pin_at(g, m, o)
}

pub proof fn lemma_tables_sub_local(g: GCert, m: int, mm: Maps)
    requires 0 <= m < g.n, pins_of_agree(g, m, mm),
    ensures same_g(tables_cert(g), local_cert(g, m, mm)), sub_maps(tables_cert(g), local_cert(g, m, mm)),
{
    let tc = tables_cert(g);
    let lc = local_cert(g, m, mm);
    assert forall|m2: int, o: int| #[trigger] map_at(tc, m2, o) is Some implies map_at(lc, m2, o) == map_at(tc, m2, o) by {
        if m2 == m {
            assert(pin_at(g, m, o) is Some);
        }
    }
}

/// An instruction checked against the tables (pins only), whose
/// obligations hold in the method's maps `mm`, is accepted against the
/// method's certificate, once the method's pins agree with `mm`.
pub proof fn lemma_instr_of_local(p: Program2, g: GCert, m: int, mm: Maps, off: int, k: Seq<Kind>, trusted: bool)
    requires
        0 <= m < g.n,
        pins_of_agree(g, m, mm),
        local_ok(p, tables_cert(g), m, off, k, trusted),
        forall|i: int| 0 <= i < 4 ==> #[trigger] holds_opt(mm, obl(p, tables_cert(g), m, off, k, trusted, i)),
    ensures instr_ok(p, local_cert(g, m, mm), m, off, k, trusted),
{
    let tc = tables_cert(g);
    let lc = local_cert(g, m, mm);
    lemma_tables_sub_local(g, m, mm);
    lemma_local_mono(p, tc, lc, m, off, k, trusted);
    assert forall|i: int| 0 <= i < 4 implies #[trigger] obl_holds(lc, m, obl(p, lc, m, off, k, trusted, i)) by {
        assert(holds_opt(mm, obl(p, tc, m, off, k, trusted, i)));
        assert(obl(p, tc, m, off, k, trusted, i) == obl(p, lc, m, off, k, trusted, i));
        assert(lc.maps[m] == mm);
    }
    lemma_instr_split(p, lc, m, off, k, trusted);
}

// ---------------------------------------------------------------------------
// The walk's ghost state.

/// The map at `t` of `mm` is `s`.
pub open spec fn holds(mm: Maps, t: int, s: Seq<Kind>) -> bool {
    0 <= t < mm.len() && mm[t] == Some(s)
}

pub open spec fn holds_opt(mm: Maps, o: Option<(int, Seq<Kind>)>) -> bool {
    match o { Some((t, s)) => holds(mm, t, s), None => true }
}

/// A pending obligation or kept kinds: an offset and kinds `arena[start..start + len]`.
#[derive(Clone, Copy)]
pub struct Pend {
    pub at: usize,
    pub start: usize,
    pub len: usize,
}

pub open spec fn seg(a: Seq<XKind>, start: int, len: int) -> Seq<Kind> {
    Seq::new(len as nat, |j: int| a[start + j]@)
}

pub open spec fn pend_ok(v: Seq<Pend>, a: Seq<XKind>) -> bool {
    forall|i: int| 0 <= i < v.len() ==> #[trigger] v[i].start + v[i].len <= a.len()
}

pub open spec fn pview(v: Seq<Pend>, a: Seq<XKind>) -> Seq<(int, Seq<Kind>)> {
    Seq::new(v.len(), |i: int| (v[i].at as int, seg(a, v[i].start as int, v[i].len as int)))
}

/// The obligation holds in `mm`, is pending, or is the fall-through to the
/// offset `off` the walk is at, whose kinds are `k` (`have`).
pub open spec fn cov(mm: Maps, pv: Seq<(int, Seq<Kind>)>, have: bool, off: int, k: Seq<Kind>,
    o: Option<(int, Seq<Kind>)>) -> bool
{
    match o {
        None => true,
        Some((t, s)) => holds(mm, t, s)
            || (exists|j: int| 0 <= j < pv.len() && #[trigger] pv[j] == (t, s))
            || (have && t == off && s == k),
    }
}

/// The instruction placed at offset `o` was checked, and each of its
/// obligations is covered.
pub open spec fn checked(p: Program2, g: GCert, m: int, trusted: bool, mm: Maps, pv: Seq<(int, Seq<Kind>)>,
    have: bool, off: int, k: Seq<Kind>, o: int) -> bool
{
    &&& local_ok(p, tables_cert(g), m, o, mm[o]->0, trusted)
    &&& forall|i: int| 0 <= i < 4 ==> #[trigger] cov(mm, pv, have, off, k, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i))
}

/// The walk's invariant at offset `off`: every placed offset is below
/// `off` and checked; the kept kinds are maps of `mm`; the entry kinds are
/// at offset 0 (placed, or about to be).
pub open spec fn winv(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, have: bool, off: int, k: Seq<Kind>, entry: Seq<Kind>) -> bool
{
    &&& mm.len() == size
    &&& 0 <= off
    &&& forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some ==> o < off && checked(p, g, m, trusted, mm, pv, have, off, k, o)
    &&& forall|j: int| 0 <= j < sv.len() ==> holds(mm, (#[trigger] sv[j]).0, sv[j].1)
    &&& off == 0 ==> have && k == entry
    &&& off > 0 ==> holds(mm, 0, entry)
}

/// Jumping ahead (no fall-through into the new offset).
pub proof fn lemma_winv_jump(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>, off2: int)
    requires winv(p, g, m, trusted, size, mm, pv, sv, false, off, k, entry), off < off2,
    ensures winv(p, g, m, trusted, size, mm, pv, sv, false, off2, k, entry),
{
    assert forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some implies o < off2
        && checked(p, g, m, trusted, mm, pv, false, off2, k, o) by {
        assert(checked(p, g, m, trusted, mm, pv, false, off, k, o));
        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv, false, off2, k,
            obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)) by {
            assert(cov(mm, pv, false, off, k, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)));
        }
    }
}

/// Taking a shipped map at an offset no instruction falls through to.
pub proof fn lemma_winv_load(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>, k2: Seq<Kind>)
    requires winv(p, g, m, trusted, size, mm, pv, sv, false, off, k, entry),
    ensures winv(p, g, m, trusted, size, mm, pv, sv, true, off, k2, entry),
{
    assert forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some implies o < off
        && checked(p, g, m, trusted, mm, pv, true, off, k2, o) by {
        assert(checked(p, g, m, trusted, mm, pv, false, off, k, o));
        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv, true, off, k2,
            obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)) by {
            assert(cov(mm, pv, false, off, k, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)));
        }
    }
}

/// The state while the instruction at `off` (with kinds `k`, placed) is
/// processed: the obligations of the instructions before it are covered
/// without a fall-through (the fall-through into `off` holds now).
pub open spec fn wmid(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>) -> bool
{
    &&& mm.len() == size
    &&& 0 <= off < size
    &&& mm[off] == Some(k)
    &&& forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some && o != off ==>
            o < off && checked(p, g, m, trusted, mm, pv, false, off, k, o)
    &&& forall|j: int| 0 <= j < sv.len() ==> holds(mm, (#[trigger] sv[j]).0, sv[j].1)
    &&& holds(mm, 0, entry)
}

/// Placing the current kinds `k` at `off`.
pub proof fn lemma_winv_place(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>)
    requires winv(p, g, m, trusted, size, mm, pv, sv, true, off, k, entry), off < size,
    ensures
        mm[off] is None,
        wmid(p, g, m, trusted, size, mm.update(off, Some(k)), pv, sv, off, k, entry),
{
    let mm1 = mm.update(off, Some(k));
    assert(mm[off] is None);
    assert forall|t: int, s: Seq<Kind>| holds(mm, t, s) implies holds(mm1, t, s) by {
        assert(mm[t] is Some);
        assert(t != off);
    }
    assert forall|o: int| 0 <= o < size && (#[trigger] mm1[o]) is Some && o != off implies
        o < off && checked(p, g, m, trusted, mm1, pv, false, off, k, o) by {
        assert(mm1[o] == mm[o]);
        assert(checked(p, g, m, trusted, mm, pv, true, off, k, o));
        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm1, pv, false, off, k,
            obl(p, tables_cert(g), m, o, mm1[o]->0, trusted, i)) by {
            let x = obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i);
            assert(cov(mm, pv, true, off, k, x));
            match x {
                None => {},
                Some((t, s)) => {
                    if holds(mm, t, s) { assert(holds(mm1, t, s)); }
                    if t == off && s == k { assert(holds(mm1, t, s)); }
                },
            }
        }
    }
    assert forall|j: int| 0 <= j < sv.len() implies holds(mm1, (#[trigger] sv[j]).0, sv[j].1) by {
        assert(holds(mm, sv[j].0, sv[j].1));
    }
    if off > 0 { assert(holds(mm, 0, entry)); }
}

/// Every pending obligation of `pv` is in `pv2` or holds at `off`.
pub open spec fn kept_or_at(pv: Seq<(int, Seq<Kind>)>, pv2: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>) -> bool {
    forall|j: int| #![trigger pv[j]] 0 <= j < pv.len() ==>
        (exists|l: int| 0 <= l < pv2.len() && #[trigger] pv2[l] == pv[j]) || pv[j] == (off, k)
}

/// Changing the pending obligations and the kept kinds.
pub proof fn lemma_mid_pv(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>,
    pv2: Seq<(int, Seq<Kind>)>, sv2: Seq<(int, Seq<Kind>)>)
    requires
        wmid(p, g, m, trusted, size, mm, pv, sv, off, k, entry),
        kept_or_at(pv, pv2, off, k),
        forall|j: int| 0 <= j < sv2.len() ==> holds(mm, (#[trigger] sv2[j]).0, sv2[j].1),
    ensures wmid(p, g, m, trusted, size, mm, pv2, sv2, off, k, entry),
{
    assert forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some && o != off implies
        o < off && checked(p, g, m, trusted, mm, pv2, false, off, k, o) by {
        assert(checked(p, g, m, trusted, mm, pv, false, off, k, o));
        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv2, false, off, k,
            obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)) by {
            let x = obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i);
            assert(cov(mm, pv, false, off, k, x));
            match x {
                None => {},
                Some((t, s)) => {
                    if !holds(mm, t, s) {
                        let j = choose|j: int| 0 <= j < pv.len() && #[trigger] pv[j] == (t, s);
                        if pv[j] == (off, k) {
                            assert(holds(mm, t, s));
                        } else {
                            let l = choose|l: int| 0 <= l < pv2.len() && #[trigger] pv2[l] == pv[j];
                            assert(pv2[l] == (t, s));
                        }
                    }
                },
            }
        }
    }
}

/// The instruction at `off` was checked and its obligations are covered
/// at the next offset `off2`: back to the walk's invariant.
pub proof fn lemma_mid_advance(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    pv: Seq<(int, Seq<Kind>)>, sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>,
    have2: bool, off2: int, k2: Seq<Kind>)
    requires
        wmid(p, g, m, trusted, size, mm, pv, sv, off, k, entry),
        local_ok(p, tables_cert(g), m, off, k, trusted),
        forall|i: int| 0 <= i < 4 ==> #[trigger] cov(mm, pv, have2, off2, k2, obl(p, tables_cert(g), m, off, k, trusted, i)),
        off < off2,
    ensures winv(p, g, m, trusted, size, mm, pv, sv, have2, off2, k2, entry),
{
    assert forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some implies o < off2
        && checked(p, g, m, trusted, mm, pv, have2, off2, k2, o) by {
        if o != off {
            assert(checked(p, g, m, trusted, mm, pv, false, off, k, o));
            assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv, have2, off2, k2,
                obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)) by {
                assert(cov(mm, pv, false, off, k, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)));
            }
        } else {
            assert(mm[o]->0 == k);
        }
    }
}

/// The end of a method's walk: no fall-through and no pending obligation
/// left, so every obligation of a placed instruction holds.
pub proof fn lemma_winv_done(p: Program2, g: GCert, m: int, trusted: bool, size: int, mm: Maps,
    sv: Seq<(int, Seq<Kind>)>, off: int, k: Seq<Kind>, entry: Seq<Kind>)
    requires
        winv(p, g, m, trusted, size, mm, Seq::empty(), sv, false, off, k, entry),
        0 <= m < g.n,
        pins_of_agree(g, m, mm),
    ensures
        forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some ==>
            instr_ok(p, local_cert(g, m, mm), m, o, mm[o]->0, trusted),
        holds(mm, 0, entry),
{
    assert forall|o: int| 0 <= o < size && (#[trigger] mm[o]) is Some implies
        instr_ok(p, local_cert(g, m, mm), m, o, mm[o]->0, trusted) by {
        assert(checked(p, g, m, trusted, mm, Seq::empty(), false, off, k, o));
        assert forall|i: int| 0 <= i < 4 implies #[trigger] holds_opt(mm, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)) by {
            assert(cov(mm, Seq::empty(), false, off, k, obl(p, tables_cert(g), m, o, mm[o]->0, trusted, i)));
        }
        lemma_instr_of_local(p, g, m, mm, o, mm[o]->0, trusted);
    }
}

// ---------------------------------------------------------------------------
// The kinds kept in the arena.

pub proof fn lemma_pview_grow(v: Seq<Pend>, a: Seq<XKind>, a2: Seq<XKind>)
    requires pend_ok(v, a), a.len() <= a2.len(), a2.subrange(0, a.len() as int) == a,
    ensures pend_ok(v, a2), pview(v, a2) == pview(v, a),
{
    assert forall|i: int| 0 <= i < v.len() implies #[trigger] pview(v, a2)[i] == pview(v, a)[i] by {
        assert(v[i].start + v[i].len <= a.len());
        assert(seg(a2, v[i].start as int, v[i].len as int) =~= seg(a, v[i].start as int, v[i].len as int)) by {
            assert forall|j: int| 0 <= j < v[i].len implies #[trigger] a2[v[i].start + j] == a[v[i].start + j] by {
                assert(a2.subrange(0, a.len() as int)[v[i].start + j] == a2[v[i].start + j]);
            }
        }
    }
    assert(pview(v, a2) =~= pview(v, a));
}

pub proof fn lemma_pview_push(v: Seq<Pend>, a: Seq<XKind>, e: Pend)
    requires pend_ok(v, a), e.start + e.len <= a.len(),
    ensures
        pend_ok(v.push(e), a),
        pview(v.push(e), a) == pview(v, a).push((e.at as int, seg(a, e.start as int, e.len as int))),
{
    assert(pview(v.push(e), a) =~= pview(v, a).push((e.at as int, seg(a, e.start as int, e.len as int))));
}

/// `arena` with the first `n` kinds of `k` appended.
pub fn x_seg_push(arena: &mut Vec<XKind>, k: &Vec<XKind>, n: usize) -> (res: Result<(), Oom>)
    requires n <= k.len(),
    ensures
        res is Ok ==> final(arena)@ == old(arena)@ + k@.subrange(0, n as int)
            && final(arena)@.subrange(0, old(arena)@.len() as int) == old(arena)@
            && seg(final(arena)@, old(arena)@.len() as int, n as int) == kv(*k).subrange(0, n as int),
{
    let ghost a0 = arena@;
    let mut i = 0;
    while i < n
        invariant n <= k.len(), 0 <= i <= n, arena@ == a0 + k@.subrange(0, i as int),
        decreases n - i,
    {
        try_push(arena, vix(k, i))?;
        proof { assert(arena@ =~= a0 + k@.subrange(0, i + 1)); }
        i += 1;
    }
    proof { assert(arena@.subrange(0, a0.len() as int) =~= a0); }
    proof {
        assert(seg(arena@, a0.len() as int, n as int) =~= kv(*k).subrange(0, n as int)) by {
            assert forall|j: int| 0 <= j < n implies #[trigger] arena@[a0.len() + j]@ == kv(*k)[j] by {
                assert(arena@[a0.len() + j] == k@[j]);
            }
        }
    }
    Ok(())
}

/// The kinds `arena[start..start + n]` are the first `kn` kinds of `k`.
pub fn x_seg_eq(arena: &Vec<XKind>, start: usize, n: usize, k: &Vec<XKind>, kn: usize) -> (r: bool)
    requires start + n <= arena.len(), kn <= k.len(),
    ensures r == (seg(arena@, start as int, n as int) == kv(*k).subrange(0, kn as int)),
{
    let ghost s = seg(arena@, start as int, n as int);
    let ghost t = kv(*k).subrange(0, kn as int);
    if n != kn {
        proof { assert(s.len() != t.len()); }
        return false;
    }
    let mut i = 0;
    while i < n
        invariant start + n <= arena.len(), n == kn, kn <= k.len(), 0 <= i <= n,
            s == seg(arena@, start as int, n as int), t == kv(*k).subrange(0, kn as int),
            forall|j: int| 0 <= j < i ==> s[j] == t[j],
        decreases n - i,
    {
        if !x_kind_eq(vix(arena, start + i), vix(k, i)) {
            proof { assert(s[i as int] == arena@[start + i]@); assert(t[i as int] == k@[i as int]@); }
            return false;
        }
        proof { assert(s[i as int] == arena@[start + i]@); assert(t[i as int] == k@[i as int]@); }
        i += 1;
    }
    proof { assert(s =~= t); }
    true
}

/// The index of an entry of `v` at offset `t`, if any.
pub fn x_find(v: &Vec<Pend>, t: usize) -> (r: Option<usize>)
    ensures r matches Some(j) ==> j < v@.len() && v@[j as int].at == t,
{
    let mut j = 0;
    while j < v.len()
        invariant 0 <= j <= v.len(),
        decreases v.len() - j,
    {
        if vix(v, j).at == t { return Some(j); }
        j += 1;
    }
    None
}

// ---------------------------------------------------------------------------
// The stream.

/// Why a method's walk stopped early: the certificate is rejected, or an
/// allocation failed.
pub enum Stop {
    Reject,
    Oom,
}

/// Reads the next shipped map into `out`: drop `d` slots of `prev`, push
/// the `n` kinds that follow. A map of more than `bound` kinds (the
/// method's frame bound: no instruction accepts one) rejects. Returns the
/// position after it.
pub fn x_read_map(s: &[u8], pos: usize, prev: &Vec<XKind>, out: &mut Vec<XKind>, bound: usize)
    -> (r: Result<usize, Stop>)
    ensures r matches Ok(q) ==> pos < q <= s@.len(),
{
    let (d, q) = match crate::v2::cert::x_varint(s, pos) { Some(x) => x, None => return Err(Stop::Reject) };
    let (n, q) = match crate::v2::cert::x_varint(s, q) { Some(x) => x, None => return Err(Stop::Reject) };
    if d as usize > prev.len() { return Err(Stop::Reject); }
    let keep = prev.len() - d as usize;
    if keep > bound || n as usize > bound - keep { return Err(Stop::Reject); }
    out.clear();
    let mut i = 0;
    while i < keep
        invariant keep <= prev.len(), 0 <= i <= keep,
        decreases keep - i,
    {
        if try_push(out, vix(prev, i)).is_err() { return Err(Stop::Oom); }
        i += 1;
    }
    let mut q = q;
    let mut i: usize = 0;
    while i < n as usize
        invariant pos < q <= s@.len(), 0 <= i <= n as usize,
        decreases n as usize - i,
    {
        let (k, q2) = match crate::v2::cert::x_read_kind(s, q) { Some(x) => x, None => return Err(Stop::Reject) };
        if try_push(out, k).is_err() { return Err(Stop::Oom); }
        q = q2;
        i += 1;
    }
    Ok(q)
}

/// The offset of the next shipped map: `e + 1 + d` for the next delta `d`
/// (or none left: `have` false).
pub fn x_next_map(s: &[u8], pos: usize, e: usize, left: u32) -> (r: Result<(usize, usize, bool, u32), Stop>)
    requires e <= u32::MAX,
    ensures
        r matches Ok((q, e2, have, left2)) ==> pos <= q <= s@.len() || (q == pos && left == 0),
        r matches Ok((q, e2, have, left2)) ==> e2 <= u32::MAX && (have ==> e < e2 && left2 < left)
            && (!have ==> left == 0 && left2 == 0),
{
    if left == 0 { return Ok((pos, e, false, 0)); }
    let (d, q) = match crate::v2::cert::x_varint(s, pos) { Some(x) => x, None => return Err(Stop::Reject) };
    if d as usize >= u32::MAX as usize - e { return Err(Stop::Reject); }
    Ok((q, e + 1 + d as usize, true, left - 1))
}

// ---------------------------------------------------------------------------
// The instruction's own checks.

/// `local_ok` of the instruction at `off` with kinds `k` against `c@`, and
/// its successor in `out`.
pub fn x_check_local(p: &VProgram, c: &XCert, m: usize, i: MethodInfo, off: usize, k: &Vec<XKind>, trusted: bool,
    out: &mut Vec<XKind>, buf: &mut Vec<XKind>, cache: &mut OuterCache, shape: ShapeFacts) -> (res: Result<(bool, u8, usize), Oom>)
    requires wf_program2(vview(p)), m < p.methods@.len(), g_ok(c.g), i == vinfo(p, m as int),
        cache_ok(vview(p), c@, m as int, *old(cache)), shape_facts(vview(p), c@, m as int, shape),
    ensures
        cache_ok(vview(p), c@, m as int, *final(cache)),
        res matches Ok((ok, op, len)) ==> (ok ==> {
            let pv = vview(p);
            &&& local_ok(pv, c@, m as int, off as int, kv(*k), trusted)
            &&& op == op_of(pv, m as int, off as int)
            &&& len as int == len_of(pv, m as int, off as int)
            &&& i.entry + off + opcode_length2(p.bytecodes[i.entry + off]) <= i.end
            &&& p.bytecodes[i.entry + off] < OPCODE_COUNT2
            &&& (is_terminator(op) ==> post(pv, c@, m as int, off as int, kv(*k), trusted) is None)
            &&& (!is_terminator(op) ==> post(pv, c@, m as int, off as int, kv(*k), trusted) == Some(kv(*final(out))))
            &&& 1 <= len <= 6
        }),
{
    if !(off < i.end - i.entry) { return Ok((false, 0, 0)); }
    let bci = i.entry + off;
    let raw = ix(p.bytecodes, bci);
    if raw >= OPCODE_COUNT2 { return Ok((false, 0, 0)); }
    if exec_is_twin(raw) && !p.unchecked { return Ok((false, 0, 0)); }
    proof { lemma_base_op(raw); }
    let op = exec_base_op(raw);
    let len = exec_opcode_length2(op);
    if bci + len > i.end { return Ok((false, 0, 0)); }
    if k.len() > i.arity as usize + i.max_height as usize { return Ok((false, 0, 0)); }
    if !x_shape_fast(Ghost(vview(p)), Ghost(c@), Ghost(m as int), k, shape) || !x_wf_kinds_c(p, c, m as i64, k, buf, cache)?
        || !x_ctx_ok(p, c, m as i64, k)? {
        return Ok((false, 0, 0));
    }
    let has_post = x_post_into(p, c, m, off, k, trusted, out)?;
    if x_is_terminator(op) {
        proof { lemma_term_post(vview(p), c@, m as int, off as int, kv(*k), trusted); }
        if !x_terminator_ok(p, c, m, off, k)? { return Ok((false, 0, 0)); }
    } else if !has_post {
        return Ok((false, 0, 0));
    }
    if BRANCH <= op && op <= BRANCH_IF_NOT_NULL {
        if x_u16(p, bci + 1) <= 0 { return Ok((false, 0, 0)); }
    }
    if op == HASH_FIND {
        if x_u16(p, bci + 1) <= 0 { return Ok((false, 0, 0)); }
    }
    Ok((true, op, len))
}

/// Every kept entry is a map of `mm`.
pub open spec fn sv_holds(mm: Maps, sv: Seq<(int, Seq<Kind>)>) -> bool {
    forall|j: int| 0 <= j < sv.len() ==> holds(mm, (#[trigger] sv[j]).0, sv[j].1)
}

/// The obligations of the instruction at `off` (checked by
/// `x_check_local`; opcode `op`, length `len`, kinds `k`, successor `out`):
/// a forward target becomes a pending obligation, a backward target is
/// compared with the kinds kept there. Returns false (rejected) if a
/// backward target has no kept kinds or other ones.
pub fn x_obls(p: &VProgram, c: &XCert, m: usize, info: MethodInfo, off: usize, op: u8, len: usize,
    k: &Vec<XKind>, out: &Vec<XKind>, trusted: bool,
    arena: &mut Vec<XKind>, pend: &mut Vec<Pend>, saved: &Vec<Pend>, pmin: &mut usize, Ghost(mm): Ghost<Maps>)
    -> (res: Result<bool, Oom>)
    requires
        wf_program2(vview(p)), m < p.methods@.len(), info == vinfo(p, m as int),
        op == op_of(vview(p), m as int, off as int), len as int == len_of(vview(p), m as int, off as int),
        info.entry + off + opcode_length2(p.bytecodes[info.entry + off]) <= info.end,
        p.bytecodes[info.entry + off] < OPCODE_COUNT2,
        is_terminator(op) ==> post(vview(p), c@, m as int, off as int, kv(*k), trusted) is None,
        !is_terminator(op) ==> post(vview(p), c@, m as int, off as int, kv(*k), trusted) == Some(kv(*out)),
        pend_ok(old(pend)@, old(arena)@), pend_ok(saved@, old(arena)@),
        sv_holds(mm, pview(saved@, old(arena)@)),
    ensures
        res matches Ok(true) ==> {
            let pv0 = pview(old(pend)@, old(arena)@);
            let pv1 = pview(final(pend)@, final(arena)@);
            let have2 = falls(op);
            &&& pend_ok(final(pend)@, final(arena)@)
            &&& pend_ok(saved@, final(arena)@)
            &&& pview(saved@, final(arena)@) == pview(saved@, old(arena)@)
            &&& pv0.len() <= pv1.len()
            &&& (forall|j: int| 0 <= j < pv0.len() ==> #[trigger] pv1[j] == pv0[j])
            &&& forall|i: int| 0 <= i < 4 ==> #[trigger] cov(mm, pv1, have2, off + len, kv(*out),
                    obl(vview(p), c@, m as int, off as int, kv(*k), trusted, i))
        },
{
    let ghost pvw = vview(p);
    let ghost kk = kv(*k);
    let ghost a0 = arena@;
    let ghost pe0 = pend@;
    let ghost pv0 = pview(pend@, arena@);
    let ghost have2 = falls(op);
    let ghost off2 = off + len;
    let ghost k2 = kv(*out);
    let (bci, _op, _len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    proof {
        // The fall-through obligation.
        let x = obl(pvw, c@, m as int, off as int, kk, trusted, 0);
        if have2 { assert(x == Some((off2, k2))); } else { assert(x is None); }
    }
    if BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        let n = if op == BRANCH || op == BRANCH_BACK { h } else { if h < 1 { return Ok(false); } h - 1 };
        proof {
            assert(branch_kinds(op, kk) =~= kk.subrange(0, n as int));
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 2) is None);
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 3) is None);
        }
        if op <= BRANCH_IF_NOT_NULL {
            let t = off + w1 as usize;
            let st = arena.len();
            x_seg_push(arena, k, n)?;
            proof {
                lemma_pview_grow(pe0, a0, arena@);
                lemma_pview_grow(saved@, a0, arena@);
            }
            let e = Pend { at: t, start: st, len: n };
            proof { lemma_pview_push(pend@, arena@, e); }
            try_push(pend, e)?;
            if t < *pmin { *pmin = t; }
            proof {
                let pv1 = pview(pend@, arena@);
                assert(pv1 == pv0.push((t as int, kk.subrange(0, n as int))));
                assert(obl(pvw, c@, m as int, off as int, kk, trusted, 1) == Some((t as int, kk.subrange(0, n as int))));
                assert(pv1[pv0.len() as int] == (t as int, kk.subrange(0, n as int)));
                assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv1, have2, off2, k2,
                    obl(pvw, c@, m as int, off as int, kk, trusted, i)) by {
                }
            }
        } else {
            if w1 as usize > off { return Ok(false); }
            let t = off - w1 as usize;
            match x_find(saved, t) {
                Some(j) => {
                    let sp = vix(saved, j);
                    if !x_seg_eq(arena, sp.start, sp.len, k, n) { return Ok(false); }
                    proof {
                        let sv = pview(saved@, arena@);
                        assert(sv[j as int] == (t as int, seg(arena@, sp.start as int, sp.len as int)));
                        assert(holds(mm, sv[j as int].0, sv[j as int].1));
                        assert(obl(pvw, c@, m as int, off as int, kk, trusted, 1) == Some((t as int, kk.subrange(0, n as int))));
                        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv0, have2, off2, k2,
                            obl(pvw, c@, m as int, off as int, kk, trusted, i)) by {
                        }
                    }
                },
                None => return Ok(false),
            }
        }
    } else if op == LOOP_REPEAT || op == LOOP_ARRAY {
        let lc = ix(p.bytecodes, bci + 3) as usize;
        if !(1 <= lc && lc + 1 < h) { return Ok(false); }
        let kt = x_loop_kinds(k, lc, lc + 1)?;
        if w1 as usize > off { return Ok(false); }
        let t = off - w1 as usize;
        match x_find(saved, t) {
            Some(j) => {
                let sp = vix(saved, j);
                if !x_seg_eq(arena, sp.start, sp.len, &kt, kt.len()) { return Ok(false); }
                proof {
                    let sv = pview(saved@, arena@);
                    assert(sv[j as int] == (t as int, seg(arena@, sp.start as int, sp.len as int)));
                    assert(holds(mm, sv[j as int].0, sv[j as int].1));
                    assert(kv(kt).subrange(0, kt.len() as int) =~= kv(kt));
                    assert(loop_operands(pvw, m as int, off as int).0 == lc);
                    assert(obl(pvw, c@, m as int, off as int, kk, trusted, 2) == Some((t as int, kv(kt))));
                    assert(obl(pvw, c@, m as int, off as int, kk, trusted, 1) is None);
                    assert(obl(pvw, c@, m as int, off as int, kk, trusted, 3) is None);
                    assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv0, have2, off2, k2,
                        obl(pvw, c@, m as int, off as int, kk, trusted, i)) by {
                    }
                }
            },
            None => return Ok(false),
        }
    } else if op == HASH_FIND {
        let t = off + w1 as usize;
        let st = arena.len();
        x_seg_push(arena, k, h)?;
        let ghost a1 = arena@;
        try_push(arena, XKind::Val)?;
        proof {
            assert(arena@.subrange(0, a0.len() as int) == a0) by {
                assert(arena@.subrange(0, a0.len() as int) =~= a0);
            }
            lemma_pview_grow(pe0, a0, arena@);
            lemma_pview_grow(saved@, a0, arena@);
            assert(seg(arena@, st as int, h + 1) =~= kk.push(Kind::Val)) by {
                assert forall|j: int| 0 <= j < h + 1 implies #[trigger] seg(arena@, st as int, h + 1)[j] == kk.push(Kind::Val)[j] by {
                    if j < h {
                        assert(seg(a1, st as int, h as int)[j] == kk.subrange(0, h as int)[j]);
                        assert(arena@[st + j] == a1[st + j]);
                    }
                }
            }
        }
        let e = Pend { at: t, start: st, len: h + 1 };
        proof { lemma_pview_push(pend@, arena@, e); }
        try_push(pend, e)?;
        if t < *pmin { *pmin = t; }
        proof {
            let pv1 = pview(pend@, arena@);
            assert(pv1 == pv0.push((t as int, kk.push(Kind::Val))));
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 3) == Some((t as int, kk.push(Kind::Val))));
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 1) is None);
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 2) is None);
            assert(pv1[pv0.len() as int] == (t as int, kk.push(Kind::Val)));
            assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv1, have2, off2, k2,
                obl(pvw, c@, m as int, off as int, kk, trusted, i)) by {
            }
        }
    } else {
        proof {
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 1) is None);
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 2) is None);
            assert(obl(pvw, c@, m as int, off as int, kk, trusted, 3) is None);
            assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm, pv0, have2, off2, k2,
                obl(pvw, c@, m as int, off as int, kk, trusted, i)) by {
            }
        }
    }
    Ok(true)
}

/// Removes the pending obligations at `off`, which must have the kinds
/// `k`; one at an offset below `off` (never placed) rejects. Returns the
/// lowest offset left pending (`usize::MAX`: none).
pub fn x_discharge(pend: &mut Vec<Pend>, pend2: &mut Vec<Pend>, arena: &Vec<XKind>, off: usize, k: &Vec<XKind>)
    -> (res: Result<Option<usize>, Oom>)
    requires pend_ok(old(pend)@, arena@),
    ensures
        res matches Ok(Some(_)) ==> pend_ok(final(pend)@, arena@)
            && kept_or_at(pview(old(pend)@, arena@), pview(final(pend)@, arena@), off as int, kv(*k)),
{
    let ghost pv = pview(pend@, arena@);
    pend2.clear();
    let mut lo = usize::MAX;
    let mut i = 0;
    while i < pend.len()
        invariant
            0 <= i <= pend.len(), pv == pview(pend@, arena@), pend_ok(pend@, arena@), pend_ok(pend2@, arena@),
            forall|j: int| #![trigger pv[j]] 0 <= j < i ==>
                (exists|l: int| 0 <= l < pview(pend2@, arena@).len() && #[trigger] pview(pend2@, arena@)[l] == pv[j])
                || pv[j] == (off as int, kv(*k)),
        decreases pend.len() - i,
    {
        let e = vix(pend, i);
        if e.at < off { return Ok(None); }
        if e.at == off {
            if !x_seg_eq(arena, e.start, e.len, k, k.len()) { return Ok(None); }
            proof {
                assert(kv(*k).subrange(0, k.len() as int) =~= kv(*k));
                assert(pv[i as int] == (off as int, kv(*k)));
            }
        } else {
            let ghost before = pview(pend2@, arena@);
            proof { lemma_pview_push(pend2@, arena@, e); }
            try_push(pend2, e)?;
            if e.at < lo { lo = e.at; }
            proof {
                let after = pview(pend2@, arena@);
                assert(after == before.push(pv[i as int]));
                assert forall|j: int| #![trigger pv[j]] 0 <= j < i + 1 implies
                    (exists|l: int| 0 <= l < after.len() && #[trigger] after[l] == pv[j]) || pv[j] == (off as int, kv(*k)) by {
                    if j == i {
                        assert(after[before.len() as int] == pv[j]);
                    } else if pv[j] != (off as int, kv(*k)) {
                        let l = choose|l: int| 0 <= l < before.len() && #[trigger] before[l] == pv[j];
                        assert(after[l] == pv[j]);
                    }
                }
            }
        }
        i += 1;
    }
    core::mem::swap(pend, pend2);
    Ok(Some(lo))
}

/// Consumes the pin of method `m` at offset `off` (pin `at`), which must
/// be the kinds `k`; a pin of `m` below `off` (never placed) rejects.
pub fn x_pin_step(g: &XGlobal, m: usize, off: usize, k: &Vec<XKind>, at: usize) -> (res: Result<Option<usize>, Oom>)
    requires at <= npins(g),
    ensures
        res matches Ok(Some(a2)) ==> at <= a2 <= npins(g) && a2 <= at + 1
            && (a2 == at + 1 ==> pin_m(g, at as int) == m && pin_off(g, at as int) == off
                && pin_kinds(g, at as int) == kv(*k)),
{
    let np = g.pins.len() / 12;
    if at < np && x_fld(g.pins, 12, at, 0) as usize == m {
        let o = x_fld(g.pins, 12, at, 4) as usize;
        if o < off { return Ok(None); }
        if o == off {
            let pk = x_fchain(g.nodes, x_fld(g.pins, 12, at, 8))?;
            if !x_kinds_eq(&pk, k) { return Ok(None); }
            return Ok(Some(at + 1));
        }
    }
    Ok(Some(at))
}

/// Marks in `back` (a bit per offset of the body of `m`, `size` bytes from
/// `entry`) the targets of the backward branches and loop steps that a
/// linear scan of the body finds; true if there is one. Only a hint: the
/// walk keeps the kinds at the marked offsets, and a backward target
/// without kept kinds rejects.
pub fn x_back_targets(p: &VProgram, entry: usize, size: usize, back: &mut Vec<u32>) -> (res: Result<bool, Oom>)
    requires entry + size <= p.bytecodes.len(),
    ensures res matches Ok(_) ==> final(back)@.len() == size / 32 + 1,
{
    back.clear();
    let words = size / 32 + 1;
    let mut i = 0;
    while i < words
        invariant 0 <= i <= words, back@.len() == i,
        decreases words - i,
    {
        try_push(back, 0u32)?;
        i += 1;
    }
    let mut any = false;
    let mut off = 0;
    while off < size
        invariant back@.len() == words, words == size / 32 + 1, entry + size <= p.bytecodes.len(),
        decreases size - off,
    {
        let raw = ix(p.bytecodes, entry + off);
        if raw >= OPCODE_COUNT2 {
            off += 1;
        } else {
            let op = exec_base_op(raw);
            let len = exec_opcode_length2(op);
            if len > size - off { return Ok(any); }
            if len >= 3 && ((BRANCH_BACK <= op && op <= BRANCH_BACK_IF_NOT_NULL) || op == LOOP_REPEAT || op == LOOP_ARRAY) {
                let w1 = x_u16(p, entry + off + 1) as usize;
                if w1 <= off {
                    let t = off - w1;
                    let wi = t / 32;
                    let bit = 1u32 << ((t % 32) as u32);
                    vput(back, wi, vix(back, wi) | bit);
                    any = true;
                }
            }
            off += len;
        }
    }
    Ok(any)
}

/// Whether `back` marks offset `off`.
pub fn x_back_at(back: &Vec<u32>, off: usize) -> bool {
    let wi = off / 32;
    wi < back.len() && (vix(back, wi) >> ((off % 32) as u32)) & 1u32 == 1u32
}

/// The buffers of the walk, kept from one method to the next (no
/// allocation once they have grown).
pub struct Walker {
    pub k: Vec<XKind>,
    pub prev: Vec<XKind>,
    pub out: Vec<XKind>,
    pub tmp: Vec<XKind>,
    pub buf: Vec<XKind>,
    pub pend: Vec<Pend>,
    pub pend2: Vec<Pend>,
    pub saved: Vec<Pend>,
    pub arena: Vec<XKind>,
    pub back: Vec<u32>,
    /// The offset of the last instruction placed (diagnostics).
    pub off: usize,
}

impl Walker {
    pub fn new() -> Walker {
        Walker {
            k: Vec::new(), prev: Vec::new(), out: Vec::new(), tmp: Vec::new(), buf: Vec::new(),
            pend: Vec::new(), pend2: Vec::new(), saved: Vec::new(), arena: Vec::new(), back: Vec::new(), off: 0,
        }
    }
}

/// The entry kinds of `m` (`check::x_entry_kinds`) into `out`.
pub fn x_entry_into(p: &VProgram, c: &XCert, m: usize, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    requires m < p.methods@.len(),
    ensures res is Ok ==> kv(*final(out)) == entry_kinds(vview(p), c@, m as int),
{
    let a = x_arity(p, m) as usize;
    let ghost e = entry_kinds(vview(p), c@, m as int);
    let block = x_kind(p, m) == 3;
    let first = if block {
        match x_ctx_of(c, m) { Some(ctx) => XKind::Block(1, ctx.slot), None => XKind::Param }
    } else { XKind::Val };
    out.clear();
    let mut i = 0;
    while i < a
        invariant m < p.methods@.len(), a == vinfo(p, m as int).arity, e == entry_kinds(vview(p), c@, m as int),
            block == (vinfo(p, m as int).kind == 3),
            block ==> first@ == match ctx_of(c@, m as int) { Some(ctx) => Kind::Block(1, ctx.slot), None => Kind::Param },
            0 <= i <= a, out@.len() == i, forall|ii: int| 0 <= ii < i ==> #[trigger] kv(*out)[ii] == e[ii],
        decreases a - i,
    {
        let ghost before = out@;
        let ghost before_k = kv(*out);
        let x = if block {
            if i == 0 { first } else { XKind::Val }
        } else if x_is_block_param(c, m, i) { XKind::Param } else { XKind::Val };
        try_push(out, x)?;
        proof {
            assert(kv(*out)[i as int] == out@[i as int]@);
            assert(kv(*out)[i as int] == e[i as int]);
            assert forall|ii: int| 0 <= ii < i + 1 implies #[trigger] kv(*out)[ii] == e[ii] by {
                if ii < i {
                    assert(out@[ii] == before[ii]);
                    assert(kv(*out)[ii] == out@[ii]@);
                    assert(before_k[ii] == before[ii]@);
                    assert(before_k[ii] == e[ii]);
                }
            }
        }
        i += 1;
    }
    proof { assert(kv(*out) =~= e); }
    Ok(())
}

/// Sorted pins: if pin `at` is not of method `m`, no pin from `at` on is.
pub proof fn lemma_pins_after(g: &XGlobal, at: int, m: int)
    requires
        pins_sorted(g), 0 <= at <= npins(g),
        forall|i: int| at <= i < npins(g) ==> #[trigger] pin_m(g, i) >= m,
        at == npins(g) || pin_m(g, at) != m,
    ensures forall|i: int| at <= i < npins(g) ==> #[trigger] pin_m(g, i) > m,
{
    assert forall|i: int| at <= i < npins(g) implies #[trigger] pin_m(g, i) > m by {
        assert(pin_m(g, at) >= m);
        if i > at {
            lemma_key(pin_m(g, at) as int, pin_off(g, at) as int, pin_m(g, i) as int, pin_off(g, i) as int);
            assert(pin_key(g, at) < pin_key(g, i));
        }
    }
}

/// The pins of `m` are those from `at0` to `at2`; they agree with `mm`.
pub proof fn lemma_pins_of(g: &XGlobal, m: int, mm: Maps, at0: int, at2: int)
    requires
        pins_sorted(g), 0 <= at0 <= at2 <= npins(g),
        forall|i: int| 0 <= i < at0 ==> #[trigger] pin_m(g, i) < m,
        forall|i: int| at2 <= i < npins(g) ==> #[trigger] pin_m(g, i) > m,
        forall|i: int| at0 <= i < at2 ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm),
    ensures pins_of_agree(g@, m, mm),
{
    assert forall|o: int| #[trigger] pin_at(g@, m, o) is Some implies 0 <= o < mm.len() && mm[o] == pin_at(g@, m, o) by {
        assert(pin_view(g, m, o) is Some);
        let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && pin_off(g, i) == o;
        lemma_pin_unique(g, i);
        assert(pin_agrees(g, i, mm));
    }
}

/// Checks method `m` in one walk, reading its part of the maps stream `s`
/// from `pos0` and its pins from `at0` on. Returns the stream position and
/// the pin index after them if the method is accepted against the ghost
/// maps it returns (and its pins agree with them); `None` if it is
/// rejected.
pub fn walk_method(w: &mut Walker, p: &VProgram, g: &XGlobal, s: &[u8], pos0: usize, m: usize, at0: usize, trusted: bool)
    -> (res: Result<(Option<(usize, usize)>, Ghost<Maps>), Oom>)
    requires
        wf_program2(vview(p)), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len(),
        at0 <= npins(g), pos0 <= s@.len(),
        forall|i: int| 0 <= i < at0 ==> #[trigger] pin_m(g, i) < m,
        forall|i: int| at0 <= i < npins(g) ==> #[trigger] pin_m(g, i) >= m,
    ensures
        match res {
            Ok((Some((pos2, at2)), mm)) =>
                method_ok(vview(p), local_cert(g@, m as int, mm@), m as int, trusted)
                && at0 <= at2 <= npins(g)
                && (forall|i: int| at2 <= i < npins(g) ==> #[trigger] pin_m(g, i) > m)
                && (forall|i: int| at0 <= i < at2 ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm@))
                && pos2 <= s@.len(),
            _ => true,
        },
{
    let ghost pvw = vview(p);
    let ghost gv = g@;
    let c = XCert { g };
    assert(c@ == tables_cert(gv));
    let info = x_info(p, m);
    if !(info.entry < info.end && info.end <= p.bytecodes.len()) { return Ok((None, Ghost(Seq::empty()))); }
    let size = info.end - info.entry;
    let ghost lc0 = local_cert(gv, m as int, Seq::new(size as nat, |o: int| None::<Seq<Kind>>));
    let ghost mut mm: Maps = Seq::new(size as nat, |o: int| None::<Seq<Kind>>);
    let (count, q) = match crate::v2::cert::x_varint(s, pos0) { Some(x) => x, None => return Ok((None, Ghost(mm))) };
    let mut pos = q;
    if x_bp_len(&c, m) != info.arity as usize { return Ok((None, Ghost(mm))); }
    let ctx = x_ctx_of(&c, m);
    if ctx.is_some() && info.kind != 3 { return Ok((None, Ghost(mm))); }
    let np = g.pins.len() / 12;
    if info.kind == 3 && ctx.is_none() {
        // A block that is never created: no maps, and no pins.
        if count != 0 { return Ok((None, Ghost(mm))); }
        if at0 < np && x_fld(g.pins, 12, at0, 0) as usize == m { return Ok((None, Ghost(mm))); }
        proof {
            lemma_pins_after(g, at0 as int, m as int);
            assert(lc0.maps[m as int] == mm);
            assert(lc0.contexts[m as int] is None);
        }
        return Ok((Some((pos, at0)), Ghost(mm)));
    }
    // The buffers.
    let mut k: Vec<XKind> = Vec::new();
    core::mem::swap(&mut k, &mut w.k);
    let mut prev: Vec<XKind> = Vec::new();
    core::mem::swap(&mut prev, &mut w.prev);
    let mut out: Vec<XKind> = Vec::new();
    core::mem::swap(&mut out, &mut w.out);
    let mut tmp: Vec<XKind> = Vec::new();
    core::mem::swap(&mut tmp, &mut w.tmp);
    let mut buf: Vec<XKind> = Vec::new();
    core::mem::swap(&mut buf, &mut w.buf);
    let mut pend: Vec<Pend> = Vec::new();
    core::mem::swap(&mut pend, &mut w.pend);
    let mut pend2: Vec<Pend> = Vec::new();
    core::mem::swap(&mut pend2, &mut w.pend2);
    let mut saved: Vec<Pend> = Vec::new();
    core::mem::swap(&mut saved, &mut w.saved);
    let mut arena: Vec<XKind> = Vec::new();
    core::mem::swap(&mut arena, &mut w.arena);
    let mut back: Vec<u32> = Vec::new();
    core::mem::swap(&mut back, &mut w.back);
    prev.clear();
    pend.clear();
    saved.clear();
    arena.clear();
    x_entry_into(p, &c, m, &mut k)?;
    let ghost entry = kv(k);
    let any_back = x_back_targets(p, info.entry, size, &mut back)?;
    // Facts of the method the instruction checks use.
    let shape = match x_shape_facts(p, &c, m) { Some(s) => s, None => return Ok((None, Ghost(mm))) };
    let mut cache = OuterCache { valid: false, d: 0, i: 0 };
    let bound = info.arity as usize + info.max_height as usize;
    let mut left = count;
    let mut have = false;
    let mut e: usize = 0;
    if left > 0 {
        let (d, q) = match crate::v2::cert::x_varint(s, pos) { Some(x) => x, None => return Ok((None, Ghost(mm))) };
        pos = q;
        e = d as usize;
        have = true;
        left = left - 1;
    }
    let mut have_cur = true;
    let mut off: usize = 0;
    let mut at = at0;
    let mut pmin: usize = usize::MAX;
    proof {
        assert(pview(pend@, arena@) =~= Seq::<(int, Seq<Kind>)>::empty());
        assert(pview(saved@, arena@) =~= Seq::<(int, Seq<Kind>)>::empty());
    }
    while off < size
        invariant
            pvw == vview(p), gv == g@, wf_program2(pvw), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len(),
            info == vinfo(p, m as int), info.entry < info.end <= p.bytecodes.len(), size == info.end - info.entry,
            c@ == tables_cert(gv), c.g == g,
            entry == entry_kinds(pvw, c@, m as int),
            np == npins(g),
            winv(pvw, gv, m as int, trusted, size as int, mm, pview(pend@, arena@), pview(saved@, arena@),
                have_cur, off as int, kv(k), entry),
            pend_ok(pend@, arena@), pend_ok(saved@, arena@),
            at0 <= at <= np,
            forall|i: int| 0 <= i < at0 ==> #[trigger] pin_m(g, i) < m,
            forall|i: int| at0 <= i < at ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm),
            forall|i: int| at <= i < np ==> #[trigger] pin_m(g, i) >= m,
            cache_ok(pvw, c@, m as int, cache), shape_facts(pvw, c@, m as int, shape),
            pos <= s@.len(), e <= u32::MAX, !have ==> left == 0,
        decreases (if off <= size { size - off } else { 0 }), (if have { 1int } else { 0int }) + left as int,
    {
        if have && e < off {
            // A shipped map behind the walk: read and ignored.
            pos = match x_read_map(s, pos, &prev, &mut tmp, bound) {
                Ok(q) => q, Err(Stop::Reject) => return Ok((None, Ghost(mm))), Err(Stop::Oom) => return Err(Oom),
            };
            match x_next_map(s, pos, e, left) {
                Ok((q, e2, h2, l2)) => { pos = q; e = e2; have = h2; left = l2; },
                Err(Stop::Reject) => return Ok((None, Ghost(mm))),
                Err(Stop::Oom) => return Err(Oom),
            }
            continue;
        }
        if have && e == off {
            pos = match x_read_map(s, pos, &prev, &mut tmp, bound) {
                Ok(q) => q, Err(Stop::Reject) => return Ok((None, Ghost(mm))), Err(Stop::Oom) => return Err(Oom),
            };
            if have_cur {
                // The previous instruction falls through: the shipped map
                // must be its successor (or the entry kinds).
                if !x_kinds_eq(&tmp, &k) { return Ok((None, Ghost(mm))); }
            } else {
                proof {
                    lemma_winv_load(pvw, gv, m as int, trusted, size as int, mm, pview(pend@, arena@), pview(saved@, arena@),
                        off as int, kv(k), entry, kv(tmp));
                }
                core::mem::swap(&mut k, &mut tmp);
                have_cur = true;
            }
            match x_next_map(s, pos, e, left) {
                Ok((q, e2, h2, l2)) => { pos = q; e = e2; have = h2; left = l2; },
                Err(Stop::Reject) => return Ok((None, Ghost(mm))),
                Err(Stop::Oom) => return Err(Oom),
            }
        } else if !have_cur {
            if !have { break; }
            // No instruction falls through to here: on to the next shipped map.
            proof {
                lemma_winv_jump(pvw, gv, m as int, trusted, size as int, mm, pview(pend@, arena@), pview(saved@, arena@),
                    off as int, kv(k), entry, e as int);
            }
            off = e;
            continue;
        }
        // The kinds `k` are placed at `off`; the instruction is checked.
        let (op, len, at2, Ghost(mm2)) = match x_place_step(p, g, &c, m, info, trusted, off, &k, &mut out, &mut buf,
            &mut arena, &mut pend, &mut pend2, &mut saved, &back, any_back, &mut pmin, at, &mut cache, shape,
            Ghost(mm), Ghost(entry), Ghost(size as int), Ghost(at0 as int))? {
            Some(x) => x,
            None => { w.off = off; return Ok((None, Ghost(mm))); },
        };
        proof {
            assert(at <= at2);
            assert(at2 <= npins(g));
            if at0 < at2 { assert(pin_m(g, at0 as int) == m); }
            mm = mm2;
        }
        at = at2;
        // The successor (if any) becomes the current kinds; the placed
        // kinds are the base of the next shipped map.
        let term = x_is_terminator(op);
        core::mem::swap(&mut prev, &mut k);
        core::mem::swap(&mut k, &mut out);
        have_cur = !term;
        off = off + len;
    }
    // The shipped maps past the end: read and ignored.
    while have
        invariant pos <= s@.len(), e <= u32::MAX, !have ==> left == 0,
        decreases (if have { 1int } else { 0int }) + left as int,
    {
        pos = match x_read_map(s, pos, &prev, &mut tmp, bound) {
            Ok(q) => q, Err(Stop::Reject) => return Ok((None, Ghost(mm))), Err(Stop::Oom) => return Err(Oom),
        };
        match x_next_map(s, pos, e, left) {
            Ok((q, e2, h2, l2)) => { pos = q; e = e2; have = h2; left = l2; },
            Err(Stop::Reject) => return Ok((None, Ghost(mm))),
            Err(Stop::Oom) => return Err(Oom),
        }
    }
    // No fall-through past the end, no pending obligation, no pin of `m`
    // left.
    if have_cur || pend.len() > 0 { return Ok((None, Ghost(mm))); }
    if at < np && x_fld(g.pins, 12, at, 0) as usize == m { return Ok((None, Ghost(mm))); }
    w.k = k;
    w.prev = prev;
    w.out = out;
    w.tmp = tmp;
    w.buf = buf;
    w.pend = pend;
    w.pend2 = pend2;
    w.saved = saved;
    w.arena = arena;
    w.back = back;
    proof {
        let lc = local_cert(gv, m as int, mm);
        lemma_pins_after(g, at as int, m as int);
        lemma_pins_of(g, m as int, mm, at0 as int, at as int);
        assert(pview(w.pend@, w.arena@) =~= Seq::<(int, Seq<Kind>)>::empty());
        lemma_winv_done(pvw, gv, m as int, trusted, size as int, mm, pview(w.saved@, w.arena@), off as int, kv(w.k), entry);
        assert(entry_kinds(pvw, c@, m as int) =~= entry_kinds(pvw, lc, m as int));
        assert(lc.maps[m as int] == mm);
        assert(lc.contexts[m as int] == ctx_of(c@, m as int));
        assert(lc.block_params[m as int] == c@.block_params[m as int]);
    }
    Ok((Some((pos, at)), Ghost(mm)))
}


/// Places the kinds `k` at offset `off` of `m` (the walk is at `off` with
/// a fall-through or a shipped map), consumes the pin and the pending
/// obligations there, keeps `k` if `off` is a backward target, checks the
/// instruction and records its obligations. Returns the opcode, the
/// instruction's length, the next pin index and the maps with `off`
/// placed; the successor (if the opcode falls through) is in `out`.
/// `None`: rejected.
pub fn x_place_step(p: &VProgram, g: &XGlobal, c: &XCert, m: usize, info: MethodInfo, trusted: bool, off: usize,
    k: &Vec<XKind>, out: &mut Vec<XKind>, buf: &mut Vec<XKind>, arena: &mut Vec<XKind>, pend: &mut Vec<Pend>,
    pend2: &mut Vec<Pend>, saved: &mut Vec<Pend>, back: &Vec<u32>, any_back: bool, pmin: &mut usize, at: usize,
    cache: &mut OuterCache, shape: ShapeFacts,
    Ghost(mm): Ghost<Maps>, Ghost(entry): Ghost<Seq<Kind>>, Ghost(size): Ghost<int>, Ghost(at0): Ghost<int>)
    -> (res: Result<Option<(u8, usize, usize, Ghost<Maps>)>, Oom>)
    requires
        cache_ok(vview(p), c@, m as int, *old(cache)), shape_facts(vview(p), c@, m as int, shape),
        wf_program2(vview(p)), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len(),
        info == vinfo(p, m as int), info.entry < info.end <= p.bytecodes.len(), size == info.end - info.entry,
        c@ == tables_cert(g@), c.g == g,
        off < size,
        winv(vview(p), g@, m as int, trusted, size, mm, pview(old(pend)@, old(arena)@), pview(old(saved)@, old(arena)@),
            true, off as int, kv(*k), entry),
        pend_ok(old(pend)@, old(arena)@), pend_ok(old(saved)@, old(arena)@),
        0 <= at0 <= at <= npins(g),
        forall|i: int| at0 <= i < at ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm),
        forall|i: int| at <= i < npins(g) ==> #[trigger] pin_m(g, i) >= m,
    ensures
        cache_ok(vview(p), c@, m as int, *final(cache)),
        match res {
            Ok(Some((op, len, at2, mm2))) => {
                &&& winv(vview(p), g@, m as int, trusted, size, mm2@, pview(final(pend)@, final(arena)@),
                        pview(final(saved)@, final(arena)@), falls(op), off + len, kv(*final(out)), entry)
                &&& pend_ok(final(pend)@, final(arena)@)
                &&& pend_ok(final(saved)@, final(arena)@)
                &&& at <= at2 <= npins(g)
                &&& (forall|i: int| at0 <= i < at2 ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm2@))
                &&& (forall|i: int| at2 <= i < npins(g) ==> #[trigger] pin_m(g, i) >= m)
                &&& op == op_of(vview(p), m as int, off as int)
                &&& 1 <= len <= 6
                &&& off + len <= size
            },
            _ => true,
        },
{
    let ghost pvw = vview(p);
    let ghost gv = g@;
    let ghost pv = pview(pend@, arena@);
    let ghost sv = pview(saved@, arena@);
    let ghost mm0 = mm;
    let ghost mm1 = mm.update(off as int, Some(kv(*k)));
    proof {
        lemma_winv_place(pvw, gv, m as int, trusted, size, mm, pv, sv, off as int, kv(*k), entry);
    }
    // The pin of `m` at `off`, if any.
    let at2 = match x_pin_step(g, m, off, k, at)? { Some(a) => a, None => return Ok(None) };
    proof {
        assert forall|i: int| at0 <= i < at2 implies #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mm1) by {
            if i < at {
                assert(pin_m(g, i) == m);
                assert(pin_agrees(g, i, mm0));
                assert(mm0[pin_off(g, i) as int] is Some);
            } else {
                assert(pin_off(g, i) == off);
            }
        }
    }
    // The pending obligations at `off`.
    if off >= *pmin {
        match x_discharge(pend, pend2, arena, off, k)? {
            Some(lo) => { *pmin = lo; },
            None => return Ok(None),
        }
        proof {
            lemma_mid_pv(pvw, gv, m as int, trusted, size, mm1, pv, sv, off as int, kv(*k), entry,
                pview(pend@, arena@), sv);
        }
    }
    // The kinds at a backward target.
    if any_back && x_back_at(back, off) {
        let st = arena.len();
        let h = k.len();
        let ghost a0 = arena@;
        let ghost pv1 = pview(pend@, arena@);
        let ghost sv1 = pview(saved@, arena@);
        x_seg_push(arena, k, h)?;
        proof {
            lemma_pview_grow(pend@, a0, arena@);
            lemma_pview_grow(saved@, a0, arena@);
        }
        let e2 = Pend { at: off, start: st, len: h };
        proof { lemma_pview_push(saved@, arena@, e2); }
        try_push(saved, e2)?;
        proof {
            assert(kv(*k).subrange(0, h as int) =~= kv(*k));
            let sv2 = pview(saved@, arena@);
            assert(sv2 == sv1.push((off as int, kv(*k))));
            assert forall|j: int| 0 <= j < sv2.len() implies holds(mm1, (#[trigger] sv2[j]).0, sv2[j].1) by {
                if j < sv1.len() { assert(sv2[j] == sv1[j]); }
            }
            assert forall|j: int| #![trigger pv1[j]] 0 <= j < pv1.len() implies
                (exists|l: int| 0 <= l < pv1.len() && #[trigger] pv1[l] == pv1[j]) || pv1[j] == (off as int, kv(*k)) by {
                assert(pv1[j] == pv1[j]);
            }
            lemma_mid_pv(pvw, gv, m as int, trusted, size, mm1, pv1, sv1, off as int, kv(*k), entry, pv1, sv2);
        }
    }
    // The instruction.
    let (ok, op, len) = x_check_local(p, c, m, info, off, k, trusted, out, buf, cache, shape)?;
    if !ok { return Ok(None); }
    let ghost pv2 = pview(pend@, arena@);
    let ghost sv2 = pview(saved@, arena@);
    if !x_obls(p, c, m, info, off, op, len, k, out, trusted, arena, pend, saved, pmin, Ghost(mm1))? {
        return Ok(None);
    }
    proof {
        let pv3 = pview(pend@, arena@);
        assert forall|j: int| #![trigger pv2[j]] 0 <= j < pv2.len() implies
            (exists|l: int| 0 <= l < pv3.len() && #[trigger] pv3[l] == pv2[j]) || pv2[j] == (off as int, kv(*k)) by {
            assert(pv3[j] == pv2[j]);
        }
        lemma_mid_pv(pvw, gv, m as int, trusted, size, mm1, pv2, sv2, off as int, kv(*k), entry, pv3, sv2);
        let have2 = falls(op);
        let off2 = off + len;
        assert forall|i: int| 0 <= i < 4 implies #[trigger] cov(mm1, pv3, have2, off2, kv(*out),
            obl(pvw, tables_cert(gv), m as int, off as int, kv(*k), trusted, i)) by {
            assert(cov(mm1, pv3, have2, off2, kv(*out), obl(pvw, c@, m as int, off as int, kv(*k), trusted, i)));
        }
        lemma_mid_advance(pvw, gv, m as int, trusted, size, mm1, pv3, sv2, off as int, kv(*k), entry,
            have2, off2, kv(*out));
    }
    Ok(Some((op, len, at2, Ghost(mm1))))
}

/// What the verifier reports between methods (implemented by the VM's glue:
/// verified/vmverify/src/ffi.rs).
pub trait Progress {
    /// Called before method `m` is checked, so once per method in order.
    fn method(&mut self, m: usize);
}

/// No progress reports.
pub struct NoProgress;

impl Progress for NoProgress {
    fn method(&mut self, m: usize) {}
}

/// The single-pass verifier of a shipped certificate: the global part `g`
/// (read in place from the certificate) and the maps stream `s`. Returns
/// true only if the sorted tables are sorted and `split_ok(vview(p), g@,
/// ms, trusted)` holds for the ghost maps `ms` it returns; by
/// `v2::split::lemma_split_sound` the certificate `with_maps(g@, ms)` is
/// then accepted. Also returns the method and the offset it stopped at
/// (diagnostics; the method count if the tables or the pins are rejected).
/// `progress` is told before each method is checked. `Err(Oom)`: an
/// allocation failed (rejected).
pub fn walk<P: Progress>(p: &VProgram, g: &XGlobal, s: &[u8], trusted: bool, progress: &mut P)
    -> (res: Result<(bool, usize, usize, Ghost<Seq<Maps>>), Oom>)
    ensures res matches Ok((ok, _, _, ms)) ==> (ok ==> g_ok(g) && split_ok(vview(p), g@, ms@, trusted)),
{
    let ghost pv = vview(p);
    let ghost pad = Seq::new(g.n as nat, |m: int| Seq::<Option<Seq<Kind>>>::empty());
    if !x_wf_program2(p) { return Ok((false, p.methods.len(), 0, Ghost(pad))); }
    if p.unchecked && !trusted { return Ok((false, p.methods.len(), 0, Ghost(pad))); }
    if g.n != p.methods.len() { return Ok((false, p.methods.len(), 0, Ghost(pad))); }
    if !x_g_ok(g) { return Ok((false, p.methods.len(), 0, Ghost(pad))); }
    let tc = XCert { g };
    if !x_tables_ok(p, &tc)? { return Ok((false, p.methods.len(), 0, Ghost(pad))); }
    let n = p.methods.len();
    let np = g.pins.len() / 12;
    let ghost mut ms: Seq<Maps> = Seq::empty();
    let mut w = Walker::new();
    let mut at: usize = 0;
    let mut pos: usize = 0;
    let mut m: usize = 0;
    while m < n
        invariant
            pv == vview(p), wf_program2(pv), n == p.methods@.len(), g.n == n, n < 0x1000_0000, g_ok(g),
            p.unchecked ==> trusted,
            np == npins(g),
            tables_ok(pv, tables_cert(g@)),
            0 <= m <= n, ms.len() == m, at <= np, pos <= s@.len(),
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_ok(pv, local_cert(g@, mm, ms[mm]), mm, trusted),
            forall|i: int| 0 <= i < at ==> #[trigger] pin_m(g, i) < m && pin_agrees(g, i, ms[pin_m(g, i) as int]),
            forall|i: int| at <= i < np ==> #[trigger] pin_m(g, i) >= m,
        decreases n - m,
    {
        progress.method(m);
        let (r, Ghost(mm)) = walk_method(&mut w, p, g, s, pos, m, at, trusted)?;
        match r {
            None => { return Ok((false, m, w.off, Ghost(ms))); },
            Some((pos2, at2)) => {
                proof {
                    let ms0 = ms;
                    ms = ms.push(mm);
                    assert forall|i: int| 0 <= i < at2 implies #[trigger] pin_m(g, i) < m + 1
                        && pin_agrees(g, i, ms[pin_m(g, i) as int]) by {
                        if i >= at {
                            assert(pin_m(g, i) == m);
                        } else {
                            assert(pin_m(g, i) < m);
                            assert(ms[pin_m(g, i) as int] == ms0[pin_m(g, i) as int]);
                        }
                    }
                    assert forall|mm2: int| 0 <= mm2 < m + 1 implies
                        #[trigger] method_ok(pv, local_cert(g@, mm2, ms[mm2]), mm2, trusted) by {
                        if mm2 < m { assert(ms[mm2] == ms0[mm2]); }
                    }
                }
                pos = pos2;
                at = at2;
            },
        }
        m += 1;
    }
    if at < np {
        // A pin of a method that does not exist.
        return Ok((false, n, 0, Ghost(ms)));
    }
    proof {
        let gv = g@;
        assert forall|m2: int, o2: int| #[trigger] pin_at(gv, m2, o2) is Some implies
            0 <= m2 < ms.len() && 0 <= o2 < ms[m2].len() && ms[m2][o2] == pin_at(gv, m2, o2) by {
            let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m2 && pin_off(g, i) == o2;
            lemma_pin_unique(g, i);
            assert(pin_agrees(g, i, ms[pin_m(g, i) as int]));
        }
    }
    Ok((true, n, 0, Ghost(ms)))
}


// ---------------------------------------------------------------------------
// Per-method facts that make the per-instruction checks cheaper.

/// A block reference `Block(d, i)` with `d != 0` in a frame of `m` is well
/// formed (`wf_kind`): a fact of the method, the depth and the slot only.
pub open spec fn outer_ok(p: Program2, c: Cert, m: int, d: int, i: int) -> bool {
    d > 0 && match ctx_kinds(c, m, d as nat) {
        Some(fk) => block_slot(p, c, ctx_method(c, m, d as nat), fk, i),
        None => false,
    }
}

/// The last outer block reference the walk of a method found well formed
/// (a block method's own reference, slot 0, is in every frame of it).
#[derive(Clone, Copy)]
pub struct OuterCache {
    pub valid: bool,
    pub d: u32,
    pub i: u32,
}

pub open spec fn cache_ok(p: Program2, c: Cert, m: int, x: OuterCache) -> bool {
    x.valid ==> outer_ok(p, c, m, x.d as int, x.i as int)
}

/// `check::x_wf_kinds`, with the last outer reference found well formed
/// cached in `cache`.
pub fn x_wf_kinds_c(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, buf: &mut Vec<XKind>, cache: &mut OuterCache)
    -> (res: Result<bool, Oom>)
    requires cache_ok(vview(p), c@, m as int, *old(cache)),
    ensures
        cache_ok(vview(p), c@, m as int, *final(cache)),
        res matches Ok(r) ==> r == wf_kinds(vview(p), c@, m as int, kv(*k)),
{
    let mut j = 0;
    while j < k.len()
        invariant
            0 <= j <= k.len(), cache_ok(vview(p), c@, m as int, *cache),
            forall|jj: int| 0 <= jj < j ==> #[trigger] wf_kind(vview(p), c@, m as int, kv(*k), jj),
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        match vix(k, j) {
            XKind::Block(d, i) => {
                if d == 0 {
                    if !((i as usize) < j && x_block_slot(p, c, m, k, i as i64)) {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return Ok(false);
                    }
                } else if !(cache.valid && cache.d == d && cache.i == i) {
                    let (found, om) = x_ctx_kinds_rev(c, m, d, buf)?;
                    if !found {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return Ok(false);
                    }
                    if !x_block_slot_rev(p, c, om, &*buf, i as i64) {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return Ok(false);
                    }
                    *cache = OuterCache { valid: true, d, i };
                }
            },
            _ => {},
        }
        proof { assert(wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
        j += 1;
    }
    Ok(true)
}

/// The facts of `shape_ok` that depend on the method only.
#[derive(Clone, Copy)]
pub struct ShapeFacts {
    pub need1: bool,
    pub block: bool,
    pub b0: XKind,
}

pub open spec fn shape_facts(p: Program2, c: Cert, m: int, f: ShapeFacts) -> bool {
    &&& f.need1 == (pinned0(p, m) && arity(p, m) >= 1)
    &&& f.block == (info(p, m).kind == KIND_BLOCK)
    &&& f.block ==> match ctx_of(c, m) { Some(ctx) => f.b0@ == Kind::Block(1, ctx.slot), None => false }
}

/// `shape_facts` of `m`, or `None` for a block method without a context.
pub fn x_shape_facts(p: &VProgram, c: &XCert, m: usize) -> (r: Option<ShapeFacts>)
    requires m < p.methods@.len(),
    ensures r matches Some(f) ==> shape_facts(vview(p), c@, m as int, f),
{
    let need1 = x_pinned0(p, m) && x_arity(p, m) >= 1;
    if x_kind(p, m) == 3 {
        match x_ctx_of(c, m) {
            Some(ctx) => Some(ShapeFacts { need1, block: true, b0: XKind::Block(1, ctx.slot) }),
            None => None,
        }
    } else {
        Some(ShapeFacts { need1, block: false, b0: XKind::Val })
    }
}

/// `shape_ok` from the method's `shape_facts`.
pub fn x_shape_fast(Ghost(pv): Ghost<Program2>, Ghost(cv): Ghost<Cert>, Ghost(m): Ghost<int>, k: &Vec<XKind>, f: ShapeFacts)
    -> (r: bool)
    requires shape_facts(pv, cv, m, f),
    ensures r == shape_ok(pv, cv, m, kv(*k)),
{
    if f.need1 && k.len() < 1 { return false; }
    if f.block {
        if k.len() < 1 { return false; }
        proof { assert(kv(*k)[0] == k@[0]@); }
        x_kind_eq(vix(k, 0), f.b0)
    } else {
        true
    }
}
} // verus!

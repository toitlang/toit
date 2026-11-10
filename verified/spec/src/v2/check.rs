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

//! The executable structural verifier: `verify(p, c, trusted)` is proven
//! to return exactly `v2::verifier::accepts(p, c, trusted)` (zero
//! `assume`/`admit`).
//!
//! The certificate is computed by `v2::infer` (untrusted). The checker
//! works one method at a time, one instruction at a time; it does not
//! recurse and allocates only the successor kinds of the instruction it
//! checks. The certificate is an array per method indexed by offset.
//!
//! `x_post` is exact except for one corner: a LOAD_OUTER whose depth sum
//! does not fit a u32 yields a kind no certificate can hold; `x_post` then
//! returns `None` (`post_rel`), and `x_instr_ok` still agrees with
//! `instr_ok` because no map can equal such a successor.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;
#[cfg(verus_only)]
use crate::spec_common::{instance_field_count, u16_at, u32_at, class_tag, smi_ok, builtin, INSTANCE_TAG,
    EXCEPTION_CLASS, STACK_CLASS, TASK_CLASS, DOUBLE_CLASS, SMI_CLASS, ENTRY_MAIN, ENTRY_TASK,
    RUN_GLOBAL_INITIALIZER};

verus! {

#[derive(PartialEq, Eq, Clone, Copy, Debug)]
pub enum XKind {
    Val,
    Method(u32),
    Block(u32, u32),
    Param,
    Token,
}

impl View for XKind {
    type V = Kind;
    open spec fn view(&self) -> Kind {
        match *self {
            XKind::Val => Kind::Val,
            XKind::Method(t) => Kind::Method(t as int),
            XKind::Block(d, s) => Kind::Block(d as int, s as int),
            XKind::Param => Kind::Param,
            XKind::Token => Kind::Token,
        }
    }
}

pub struct XContext {
    pub outer: u32,
    pub slot: u32,
    pub kinds: Vec<XKind>,
}

pub struct XCert {
    pub maps: Vec<Vec<Option<Vec<XKind>>>>,
    pub block_params: Vec<Vec<bool>>,
    pub contexts: Vec<Option<XContext>>,
    pub sel_rep: Vec<i64>,
    pub global_count: u64,
    pub prim_arity: Vec<Vec<u8>>,
}

pub open spec fn kv(k: Vec<XKind>) -> Seq<Kind> {
    k@.map_values(|x: XKind| x@)
}

pub open spec fn okv(o: Option<Vec<XKind>>) -> Option<Seq<Kind>> {
    match o { Some(k) => Some(kv(k)), None => None }
}

pub open spec fn ctxv(o: Option<XContext>) -> Option<Context> {
    match o { Some(x) => Some(Context { outer: x.outer as int, slot: x.slot as int, kinds: kv(x.kinds) }), None => None }
}

impl View for XCert {
    type V = Cert;
    open spec fn view(&self) -> Cert {
        Cert {
            maps: self.maps@.map_values(|v: Vec<Option<Vec<XKind>>>| v@.map_values(|o: Option<Vec<XKind>>| okv(o))),
            block_params: self.block_params@.map_values(|v: Vec<bool>| v@),
            contexts: self.contexts@.map_values(|o: Option<XContext>| ctxv(o)),
            sel_rep: self.sel_rep@.map_values(|r: i64| r as int),
            global_count: self.global_count as int,
            prim_arity: self.prim_arity@.map_values(|v: Vec<u8>| v@.map_values(|a: u8| a as int)),
        }
    }
}

// ---------------------------------------------------------------------------
// Representable kinds.

/// The kinds the certificate can hold: depths, slots and method ids fit in
/// a u32.
pub open spec fn representable(s: Seq<Kind>) -> bool {
    forall|i: int| 0 <= i < s.len() ==> match #[trigger] s[i] {
        Kind::Method(t) => 0 <= t <= u32::MAX as int,
        Kind::Block(d, x) => 0 <= d <= u32::MAX as int && 0 <= x <= u32::MAX as int,
        _ => true,
    }
}

pub proof fn lemma_representable(k: Vec<XKind>)
    ensures representable(kv(k)),
{
    assert forall|i: int| 0 <= i < kv(k).len() implies match #[trigger] kv(k)[i] {
        Kind::Method(t) => 0 <= t <= u32::MAX as int,
        Kind::Block(d, x) => 0 <= d <= u32::MAX as int && 0 <= x <= u32::MAX as int,
        _ => true,
    } by {
        assert(kv(k)[i] == k@[i]@);
    }
}

pub proof fn lemma_map_repr(c: &XCert, m: int, o: int)
    ensures map_at(c@, m, o) is Some ==> representable(map_at(c@, m, o)->0),
{
    if map_at(c@, m, o) is Some {
        let v = c.maps@[m]@[o]->0;
        assert(map_at(c@, m, o) == okv(c.maps@[m]@[o]));
        lemma_representable(v);
    }
}

/// `x_post`'s result: exact, except that a kind the certificate cannot
/// hold is reported as `None`.
pub open spec fn post_rel(r: Option<Vec<XKind>>, o: Option<Seq<Kind>>) -> bool {
    match r {
        Some(k2) => o == Some(kv(k2)),
        None => o is None || !representable(o->0),
    }
}

// ---------------------------------------------------------------------------
// Small helpers.

pub fn x_kind_eq(a: XKind, b: XKind) -> (r: bool)
    ensures r == (a@ == b@), r == (a == b),
{
    match (a, b) {
        (XKind::Val, XKind::Val) => true,
        (XKind::Method(x), XKind::Method(y)) => x == y,
        (XKind::Block(x1, x2), XKind::Block(y1, y2)) => x1 == y1 && x2 == y2,
        (XKind::Param, XKind::Param) => true,
        (XKind::Token, XKind::Token) => true,
        _ => false,
    }
}

pub fn x_is_token(a: XKind) -> (r: bool)
    ensures r == (a@ is Token),
{
    match a { XKind::Token => true, _ => false }
}

pub fn x_is_plain(a: XKind) -> (r: bool)
    ensures r == (a@ is Val),
{
    match a { XKind::Val => true, _ => false }
}

pub fn x_kinds_eq(a: &Vec<XKind>, b: &Vec<XKind>) -> (r: bool)
    ensures r == (kv(*a) == kv(*b)),
{
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len()
        invariant
            a.len() == b.len(),
            0 <= i <= a.len(),
            forall|j: int| 0 <= j < i ==> (#[trigger] a@[j])@ == b@[j]@,
        decreases a.len() - i,
    {
        if !x_kind_eq(a[i], b[i]) {
            proof { assert(kv(*a)[i as int] != kv(*b)[i as int]); }
            return false;
        }
        i += 1;
    }
    proof { assert(kv(*a) =~= kv(*b)); }
    true
}

pub fn x_copy(k: &Vec<XKind>) -> (r: Vec<XKind>)
    ensures r@ == k@, kv(r) == kv(*k),
{
    let mut r: Vec<XKind> = Vec::new();
    let mut i = 0;
    while i < k.len()
        invariant 0 <= i <= k.len(), r@ == k@.subrange(0, i as int),
        decreases k.len() - i,
    {
        r.push(k[i]);
        proof { assert(r@ =~= k@.subrange(0, i + 1)); }
        i += 1;
    }
    proof { assert(r@ =~= k@); }
    r
}

pub fn x_push(k: &Vec<XKind>, v: XKind) -> (r: Vec<XKind>)
    ensures kv(r) == kv(*k).push(v@),
{
    let mut r = x_copy(k);
    r.push(v);
    proof { assert(kv(r) =~= kv(*k).push(v@)); }
    r
}

pub fn x_prefix(k: &Vec<XKind>, n: usize) -> (r: Vec<XKind>)
    requires n <= k.len(),
    ensures kv(r) == kv(*k).subrange(0, n as int),
{
    let mut r: Vec<XKind> = Vec::new();
    let mut i = 0;
    while i < n
        invariant n <= k.len(), 0 <= i <= n, r@ == k@.subrange(0, i as int),
        decreases n - i,
    {
        r.push(k[i]);
        proof { assert(r@ =~= k@.subrange(0, i + 1)); }
        i += 1;
    }
    proof { assert(kv(r) =~= kv(*k).subrange(0, n as int)); }
    r
}

pub fn x_update(k: &Vec<XKind>, i: usize, v: XKind) -> (r: Vec<XKind>)
    requires i < k.len(),
    ensures kv(r) == kv(*k).update(i as int, v@),
{
    let mut r = x_copy(k);
    r.set(i, v);
    proof { assert(kv(r) =~= kv(*k).update(i as int, v@)); }
    r
}

/// `pop_push(k, n, Some(v))`.
pub fn x_pop_push(k: &Vec<XKind>, n: usize, v: XKind) -> (r: Vec<XKind>)
    requires n <= k.len(),
    ensures kv(r) == pop_push(kv(*k), n as int, Some(v@)),
{
    let mut r = x_prefix(k, k.len() - n);
    r.push(v);
    proof { assert(kv(r) =~= kv(*k).subrange(0, k.len() - n).push(v@)); }
    r
}

pub fn x_info(p: &ExecProgram, m: usize) -> (r: MethodInfo)
    requires m < p.methods.len(),
    ensures r == info(pview2(p), m as int),
{
    p.methods[m]
}

pub fn x_u16(p: &ExecProgram, i: usize) -> (r: i64)
    requires i + 2 <= p.bytecodes.len(),
    ensures r as int == u16_at(p1(pview2(p)), i as int), 0 <= r < 0x10000,
{
    (p.bytecodes[i] as i64) + 256 * (p.bytecodes[i + 1] as i64)
}

pub fn x_u32(p: &ExecProgram, i: usize) -> (r: i64)
    requires i + 4 <= p.bytecodes.len(),
    ensures r as int == u32_at(p1(pview2(p)), i as int), 0 <= r < 0x1_0000_0000,
{
    x_u16(p, i) + 65536 * x_u16(p, i + 2)
}

pub fn x_class_count(p: &ExecProgram) -> (r: usize)
    ensures r as int == class_count(pview2(p)),
{
    p.class_bits.len()
}

/// `class_count(p) + extra <= p.dispatch.len()` without overflow.
pub fn x_row_fits(p: &ExecProgram, extra: usize) -> (r: bool)
    ensures r == (class_count(pview2(p)) + extra <= p.dispatch.len()),
{
    extra <= p.dispatch.len() && p.class_bits.len() <= p.dispatch.len() - extra
}

pub fn x_is_instance_class(p: &ExecProgram, cl: i64) -> (r: bool)
    ensures r == is_instance_class(pview2(p), cl as int),
{
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && (p.class_bits[cl as usize] & 0xf) == 2
}

pub fn x_is_field_class(p: &ExecProgram, cl: i64) -> (r: bool)
    ensures r == is_field_class(pview2(p), cl as int),
{
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64)
        && ((p.class_bits[cl as usize] & 0xf) == 2 || (p.class_bits[cl as usize] & 0xf) == 8)
}

pub fn x_ifc(p: &ExecProgram, cl: usize) -> (r: i64)
    requires cl < p.class_bits.len(),
    ensures r as int == ifc(pview2(p), cl as int),
{
    (((p.class_bits[cl] >> 5u16) & 0x7ff) as i64) - 1
}

pub fn x_smi_ok(p: &ExecProgram, v: i64) -> (r: bool)
    requires 0 <= v < 0x1_0000_0000,
    ensures r == smi_ok(p1(pview2(p)), v as int),
{
    p.word_bits != 32 || v <= 0x3fff_ffff
}

pub fn x_valid(p: &ExecProgram, t: i64) -> (r: bool)
    ensures r == valid_method(pview2(p), t as int), r ==> (t as usize) as int == t as int,
{
    0 <= t && (t as u64) < (p.methods.len() as u64)
}

pub fn x_is_val(k: XKind) -> (r: bool)
    ensures r == is_val(k@),
{
    match k { XKind::Val => true, XKind::Method(_) => true, _ => false }
}

pub fn x_is_ref(k: XKind) -> (r: bool)
    ensures r == is_ref(k@),
{
    match k { XKind::Block(_, _) => true, XKind::Param => true, _ => false }
}

pub fn x_is_block_param(c: &XCert, m: usize, i: usize) -> (r: bool)
    ensures r == is_block_param(c@, m as int, i as int),
{
    m < c.block_params.len() && i < c.block_params[m].len() && c.block_params[m][i]
}

pub fn x_ctx_of(c: &XCert, t: usize) -> (r: Option<&XContext>)
    ensures ctxv(match r { Some(x) => Some(*x), None => None }) == ctx_of(c@, t as int),
{
    if t < c.contexts.len() {
        match &c.contexts[t] {
            Some(x) => Some(x),
            None => None,
        }
    } else {
        None
    }
}

pub fn x_dispatch_target(p: &ExecProgram, d: i64) -> (r: i64)
    ensures r as int == dispatch_target(pview2(p), d as int),
{
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { p.dispatch[d as usize] as i64 } else { -1 }
}

// ---------------------------------------------------------------------------
// Block slots and contexts.

pub fn x_block_slot(p: &ExecProgram, c: &XCert, om: i64, fk: &Vec<XKind>, i: i64) -> (r: bool)
    ensures r == block_slot(pview2(p), c@, om as int, kv(*fk), i as int),
{
    if i < 0 || (i as u64) >= (fk.len() as u64) {
        return false;
    }
    proof { assert(kv(*fk)[i as int] == fk@[i as int]@); }
    match fk[i as usize] {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && p.methods[t as usize].kind == 3) {
                return false;
            }
            match x_ctx_of(c, t as usize) {
                Some(ctx) => ctx.outer as i64 == om && ctx.slot as i64 == i,
                None => false,
            }
        },
        _ => false,
    }
}

pub fn x_block_slot_u(p: &ExecProgram, c: &XCert, om: i64, fk: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == block_slot(pview2(p), c@, om as int, kv(*fk), i as int),
{
    if i >= fk.len() {
        return false;
    }
    proof { assert(kv(*fk)[i as int] == fk@[i as int]@); }
    match fk[i] {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && p.methods[t as usize].kind == 3) {
                return false;
            }
            match x_ctx_of(c, t as usize) {
                Some(ctx) => ctx.outer as i64 == om && ctx.slot as u64 == i as u64,
                None => false,
            }
        },
        _ => false,
    }
}

/// The context `depth` levels out: its kinds and method.
pub fn x_ctx_kinds<'a>(c: &'a XCert, m: i64, depth: u32) -> (r: (Option<&'a Vec<XKind>>, i64))
    requires depth >= 1,
    ensures
        okv(match r.0 { Some(k) => Some(*k), None => None }) == ctx_kinds(c@, m as int, depth as nat),
        r.1 as int == ctx_method(c@, m as int, depth as nat),
{
    let mut cur = m;
    let mut d = depth;
    loop
        invariant
            d >= 1,
            ctx_kinds(c@, m as int, depth as nat) == ctx_kinds(c@, cur as int, d as nat),
            ctx_method(c@, m as int, depth as nat) == ctx_method(c@, cur as int, d as nat),
        decreases d,
    {
        if cur < 0 || (cur as u64) >= (c.contexts.len() as u64) {
            return (None, -1);
        }
        match &c.contexts[cur as usize] {
            None => return (None, -1),
            Some(ctx) => {
                if d == 1 {
                    proof { assert(ctx_method(c@, ctx.outer as int, 0) == ctx.outer as int); }
                    return (Some(&ctx.kinds), ctx.outer as i64);
                }
                cur = ctx.outer as i64;
                d = d - 1;
            },
        }
    }
}

pub fn x_wf_kinds(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == wf_kinds(pview2(p), c@, m as int, kv(*k)),
{
    let mut j = 0;
    while j < k.len()
        invariant 0 <= j <= k.len(), forall|jj: int| 0 <= jj < j ==> #[trigger] wf_kind(pview2(p), c@, m as int, kv(*k), jj),
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        match k[j] {
            XKind::Block(d, i) => {
                if d == 0 {
                    if !((i as usize) < j && x_block_slot(p, c, m, k, i as i64)) {
                        proof { assert(!wf_kind(pview2(p), c@, m as int, kv(*k), j as int)); }
                        return false;
                    }
                } else {
                    let (fk, om) = x_ctx_kinds(c, m, d);
                    match fk {
                        None => {
                            proof { assert(!wf_kind(pview2(p), c@, m as int, kv(*k), j as int)); }
                            return false;
                        },
                        Some(fk) => if !x_block_slot(p, c, om, fk, i as i64) {
                            proof { assert(!wf_kind(pview2(p), c@, m as int, kv(*k), j as int)); }
                            return false;
                        },
                    }
                }
            },
            _ => {},
        }
        proof { assert(wf_kind(pview2(p), c@, m as int, kv(*k), j as int)); }
        j += 1;
    }
    true
}

#[verifier::loop_isolation(false)]
pub fn x_ctx_ok_at(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>, i: usize) -> (r: bool)
    requires i < k.len(),
    ensures r == ctx_ok_at(pview2(p), c@, m as int, kv(*k), i as int),
{
    if !x_block_slot_u(p, c, m, k, i) {
        return true;
    }
    let t = match k[i] { XKind::Method(t) => t, _ => 0 };
    proof { assert(kv(*k)[i as int] == k@[i as int]@); assert(kind_method(kv(*k)[i as int]) == t as int); }
    match x_ctx_of(c, t as usize) {
        Some(ctx) => {
            let ck = &ctx.kinds;
            if ck.len() != i + 1 {
                proof { assert(kv(*k).subrange(0, i + 1).len() != kv(*ck).len()); }
                return false;
            }
            let mut j = 0;
            while j <= i
                invariant ck.len() == i + 1, i < k.len(), 0 <= j <= i + 1,
                    forall|jj: int| 0 <= jj < j ==> (#[trigger] k@[jj])@ == ck@[jj]@,
                decreases i + 1 - j,
            {
                if !x_kind_eq(k[j], ck[j]) {
                    proof { assert(kv(*k).subrange(0, i + 1)[j as int] != kv(*ck)[j as int]); }
                    return false;
                }
                j += 1;
            }
            proof { assert(kv(*k).subrange(0, i + 1) =~= kv(*ck)); }
            true
        },
        None => true,
    }
}

pub fn x_ctx_ok_upto(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == ctx_ok_upto(pview2(p), c@, m as int, kv(*k), n as int),
{
    let mut i = 0;
    while i <= n && i < k.len()
        invariant 0 <= i <= k.len(), i <= n + 1,
            forall|ii: int| 0 <= ii < i ==> #[trigger] ctx_ok_at(pview2(p), c@, m as int, kv(*k), ii),
        decreases k.len() - i,
    {
        if !x_ctx_ok_at(p, c, m, k, i) {
            return false;
        }
        i += 1;
    }
    true
}

/// The slot a local block reference points to, or -1.
pub open spec fn lref(kd: Kind) -> int {
    match kd { Kind::Block(d, s) => if d == 0 && s >= 0 { s } else { -1 }, _ => -1 }
}

pub fn x_ctx_ok(p: &ExecProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == ctx_ok(pview2(p), c@, m as int, kv(*k)),
{
    // The highest slot a reference of this frame points to.
    let mut top: i64 = -1;
    let mut j = 0;
    while j < k.len()
        invariant
            0 <= j <= k.len(), -1 <= top <= u32::MAX,
            forall|jj: int| 0 <= jj < j ==> lref(#[trigger] kv(*k)[jj]) <= top,
            top >= 0 ==> exists|jj: int| 0 <= jj < j && lref(#[trigger] kv(*k)[jj]) == top,
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        let ghost old_top = top;
        match k[j] {
            XKind::Block(0, s) => {
                if s as i64 > top {
                    top = s as i64;
                }
            },
            _ => {},
        }
        proof {
            if top >= 0 && top != old_top {
                assert(lref(kv(*k)[j as int]) == top);
            } else if top >= 0 {
                let w = choose|jj: int| 0 <= jj < j && lref(#[trigger] kv(*k)[jj]) == old_top;
                assert(0 <= w < j + 1 && lref(kv(*k)[w]) == top);
            }
        }
        j += 1;
    }
    let ghost kk = kv(*k);
    let ghost pv = pview2(p);
    if top < 0 {
        proof {
            assert forall|i: int| 0 <= i < kk.len() && live_from(kk, i) implies #[trigger] ctx_ok_at(pv, c@, m as int, kk, i) by {
                let w = choose|w: int| 0 <= w < kk.len() && match #[trigger] kk[w] { Kind::Block(d, s) => d == 0 && s >= i, _ => false };
                assert(lref(kk[w]) <= top);
            }
        }
        return true;
    }
    let r = x_ctx_ok_upto(p, c, m, k, top as usize);
    proof {
        if r {
            assert forall|i: int| 0 <= i < kk.len() && live_from(kk, i) implies #[trigger] ctx_ok_at(pv, c@, m as int, kk, i) by {
                let w = choose|w: int| 0 <= w < kk.len() && match #[trigger] kk[w] { Kind::Block(d, s) => d == 0 && s >= i, _ => false };
                assert(lref(kk[w]) <= top);
            }
        } else {
            let i = choose|i: int| 0 <= i <= top && i < kk.len() && !#[trigger] ctx_ok_at(pv, c@, m as int, kk, i);
            let w = choose|jj: int| 0 <= jj < k.len() && lref(#[trigger] kv(*k)[jj]) == top;
            assert(match kk[w] { Kind::Block(d, s) => d == 0 && s >= i, _ => false });
            assert(live_from(kk, i));
        }
    }
    r
}

pub fn x_referenced(k: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == referenced(kv(*k), i as int),
{
    if i as u64 >= 0x1_0000_0000u64 {
        proof {
            if referenced(kv(*k), i as int) {
                let j = choose|j: int| 0 <= j < kv(*k).len() && #[trigger] kv(*k)[j] == Kind::Block(0, i as int);
                assert(kv(*k)[j] == k@[j]@);
            }
        }
        return false;
    }
    let target = XKind::Block(0, i as u32);
    let mut j = 0;
    while j < k.len()
        invariant 0 <= j <= k.len(), i < 0x1_0000_0000, target == XKind::Block(0, i as u32),
            forall|jj: int| 0 <= jj < j ==> kv(*k)[jj] != Kind::Block(0, i as int),
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        if x_kind_eq(k[j], target) {
            return true;
        }
        j += 1;
    }
    false
}

pub fn x_below_token(k: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == below_token(kv(*k), i as int),
{
    if i >= k.len() {
        return false;
    }
    let mut j = i + 1;
    while j < k.len()
        invariant i < j <= k.len(), forall|jj: int| i < jj < j ==> !(kv(*k)[jj] is Token),
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        if x_is_token(k[j]) {
            return true;
        }
        j += 1;
    }
    false
}

pub fn x_pinned0(p: &ExecProgram, m: usize) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == pinned0(pview2(p), m as int),
{
    p.methods[m].recv_start != 0xffff || p.methods[m].kind == 3
}

pub fn x_writable(p: &ExecProgram, m: usize, k: &Vec<XKind>, i: usize, v: XKind) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == writable(pview2(p), m as int, kv(*k), i as int, v@),
{
    if i >= k.len() { return false; }
    proof { assert(kv(*k)[i as int] == k@[i as int]@); }
    if i == 0 && x_pinned0(p, m) { return false; }
    if x_referenced(k, i) { return false; }
    if x_is_token(k[i]) || x_is_token(v) { return false; }
    if x_below_token(k, i) && !(x_is_plain(k[i]) && x_is_plain(v)) { return false; }
    true
}

pub fn x_leaves0(p: &ExecProgram, m: usize, h: usize, n: usize) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == leaves0(pview2(p), m as int, h as int, n as int),
{
    !(x_pinned0(p, m) && p.methods[m].arity >= 1) || (n < h && h - n >= 1)
}

pub fn x_args_ok(c: &XCert, t: usize, k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == args_ok(c@, t as int, kv(*k), n as int),
{
    if n > k.len() { return false; }
    let base = k.len() - n;
    let mut x = 0;
    while x < n
        invariant n <= k.len(), base == k.len() - n, 0 <= x <= n,
            forall|xx: int| 0 <= xx < x ==> #[trigger] arg_ok(c@, t as int, kv(*k), n as int, xx),
        decreases n - x,
    {
        let kd = k[base + x];
        proof { assert(kv(*k)[base + x] == kd@); }
        if x_is_block_param(c, t, x) {
            if !x_is_ref(kd) {
                proof { assert(!arg_ok(c@, t as int, kv(*k), n as int, x as int)); }
                return false;
            }
        } else {
            if !x_is_val(kd) {
                proof { assert(!arg_ok(c@, t as int, kv(*k), n as int, x as int)); }
                return false;
            }
        }
        match kd {
            XKind::Block(d, i) => if d == 0 && (i as usize) >= base {
                proof { assert(!arg_ok(c@, t as int, kv(*k), n as int, x as int)); }
                return false;
            },
            _ => {},
        }
        proof { assert(arg_ok(c@, t as int, kv(*k), n as int, x as int)); }
        x += 1;
    }
    true
}

pub fn x_value_operands(k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == value_operands(kv(*k), n as int),
{
    if n > k.len() { return false; }
    let mut i = 0;
    while i < n
        invariant n <= k.len(), 0 <= i <= n, forall|ii: int| 0 <= ii < i ==> is_val(#[trigger] top_kind(kv(*k), ii)),
        decreases n - i,
    {
        proof { assert(kv(*k)[k.len() - 1 - i] == k@[k.len() - 1 - i]@); }
        if !x_is_val(k[k.len() - 1 - i]) {
            proof { assert(!is_val(top_kind(kv(*k), i as int))); }
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_sel_ok(p: &ExecProgram, c: &XCert, sel: i64, n: usize, k: &Vec<XKind>) -> (r: bool)
    ensures r == sel_ok(pview2(p), c@, sel as int, n as int, kv(*k)),
{
    if !(1 <= n && n <= k.len()) { return false; }
    if !(0 <= sel && sel < 0xffff) { return false; }
    if sel as usize >= c.sel_rep.len() { return false; }
    if !x_row_fits(p, sel as usize) { return false; }
    proof { assert(kv(*k)[k.len() - n] == k@[k.len() - n]@); }
    if !x_is_val(k[k.len() - n]) { return false; }
    let r = c.sel_rep[sel as usize];
    if r == -1 { return true; }
    if !x_valid(p, r) { return false; }
    let ru = r as usize;
    proof { assert(ru as int == r as int); }
    p.methods[ru].arity as usize == n && x_args_ok(c, ru, k, n)
}

pub fn x_typecheck_index_ok(p: &ExecProgram, op: u8, enc: i64) -> (r: bool)
    requires 0 <= enc < 0x10000,
    ensures r == typecheck_index_ok(pview2(p), op, enc as int),
{
    let index = enc / 2;
    if op == IS_INTERFACE || op == IS_INTERFACE_WIDE || op == AS_INTERFACE || op == AS_INTERFACE_WIDE {
        (index as usize) < p.interface_check_offsets.len()
    } else {
        ((2 * index + 1) as usize) < p.class_check_ids.len()
    }
}

pub fn x_this_field_ok(p: &ExecProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == this_field_ok(pview2(p), m as int, f as int),
{
    let i = p.methods[m];
    if i.recv_start == 0xffff || i.arity < 1 || !(i.kind == 0 || i.kind == 1) {
        return false;
    }
    if i.recv_end as usize > p.class_bits.len() {
        return false;
    }
    let mut cl = i.recv_start;
    while cl < i.recv_end
        invariant i == p.methods[m as int], i.recv_start <= cl,
            forall|c2: int| i.recv_start <= c2 < cl ==> #[trigger] is_field_class(pview2(p), c2) && f < ifc(pview2(p), c2),
        decreases i.recv_end - cl,
    {
        if !x_is_field_class(p, cl as i64) || !(f < x_ifc(p, cl as usize)) {
            return false;
        }
        cl += 1;
    }
    true
}

pub fn x_shift(k: XKind, d: u32) -> (r: Option<XKind>)
    ensures
        r is Some ==> r->0@ == shift(k@, d as int),
        r is None ==> match k@ { Kind::Block(d1, _) => d1 + d > u32::MAX, _ => false },
{
    match k {
        XKind::Block(d1, s) => if d1 <= u32::MAX - d { Some(XKind::Block(d1 + d, s)) } else { None },
        XKind::Method(_) => Some(XKind::Val),
        _ => Some(k),
    }
}

// ---------------------------------------------------------------------------
// Instructions.

/// The precondition of the transfer functions: a valid instruction inside
/// the method, and a frame of bounded height.
pub open spec fn post_pre(p: &ExecProgram, m: usize, off: usize, k: &Vec<XKind>) -> bool {
    &&& wf_program2(pview2(p))
    &&& m < p.methods.len()
    &&& p.methods[m as int].entry + off + opcode_length2(p.bytecodes[p.methods[m as int].entry + off]) <= p.methods[m as int].end
    &&& p.bytecodes[p.methods[m as int].entry + off] < OPCODE_COUNT2
    &&& k.len() <= 0x10_0000
}

/// Decodes the instruction at offset `off` of `m`.
pub fn x_decode(p: &ExecProgram, m: usize, off: usize) -> (r: (usize, u8, usize, i64, i64))
    requires
        wf_program2(pview2(p)),
        m < p.methods.len(),
        p.methods[m as int].entry + off + opcode_length2(p.bytecodes[p.methods[m as int].entry + off]) <= p.methods[m as int].end,
    ensures ({
        let (bci, op, len, b1, w1) = r;
        let pv = pview2(p);
        &&& bci as int == instr_at(pv, m as int, off as int)
        &&& op == op_of(pv, m as int, off as int)
        &&& len as int == opcode_length2(op)
        &&& bci + len <= p.methods[m as int].end
        &&& p.methods[m as int].end <= p.bytecodes.len()
        &&& p.bytecodes.len() < 0x1000_0000
        &&& 0 <= b1 < 256 && 0 <= w1 < 0x10000
        &&& (len >= 2 ==> b1 as int == b1_of(pv, m as int, off as int))
        &&& (len >= 3 ==> w1 as int == w1_of(pv, m as int, off as int))
    }),
{
    let bci = p.methods[m].entry + off;
    let op = p.bytecodes[bci];
    let len = exec_opcode_length2(op);
    let b1: i64 = if len >= 2 { p.bytecodes[bci + 1] as i64 } else { 0 };
    let w1: i64 = if len >= 3 { x_u16(p, bci + 1) } else { 0 };
    (bci, op, len, b1, w1)
}

pub fn x_post_locals(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
           || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        let n = if op == LOAD_LOCAL { b1 } else if op == LOAD_LOCAL_WIDE { w1 } else { (op - LOAD_LOCAL_0) as i64 };
        if (n as usize) < h {
            proof { assert(kv(*k)[h - 1 - n] == k@[h - 1 - n]@); }
            if !x_is_token(k[h - 1 - n as usize]) {
                Some(x_push(k, k[h - 1 - n as usize]))
            } else { None }
        } else {
            None
        }
    } else if op == POP_LOAD_LOCAL {
        if (b1 as usize) + 1 < h {
            proof { assert(kv(*k)[h - 2 - b1] == k@[h - 2 - b1]@); }
            if !x_is_token(k[h - 2 - b1 as usize]) {
                Some(x_update(k, h - 1, k[h - 2 - b1 as usize]))
            } else { None }
        } else {
            None
        }
    } else {
        if 1 <= b1 && (b1 as usize) < h {
            let i = h - 1 - b1 as usize;
            let v = k[h - 1];
            proof { assert(kv(*k)[h - 1] == v@); }
            if x_writable(p, m, k, i, v) {
                let k1 = x_update(k, i, v);
                if op == STORE_LOCAL_POP {
                    let k2 = x_prefix(&k1, k1.len() - 1);
                    Some(k2)
                } else {
                    Some(k1)
                }
            } else { None }
        } else { None }
    }
}

pub fn x_post_outer(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    let ghost pv = pview2(p);
    let ghost kk = kv(*k);
    if op == LOAD_BLOCK {
        let i = h as i64 - 1 - b1;
        if x_block_slot(p, c, m as i64, k, i) { Some(x_push(k, XKind::Block(0, i as u32))) } else { None }
    } else {
        let r: usize = if op == STORE_OUTER { 1 } else { 0 };
        if r >= h { return None; }
        proof { assert(kk[h - 1 - r] == k@[h - 1 - r]@); }
        match k[h - 1 - r] {
            XKind::Block(d, j) => {
                let (fk, om): (Option<&Vec<XKind>>, i64) = if d == 0 { (Some(k), m as i64) } else { x_ctx_kinds(c, m as i64, d) };
                proof {
                    assert(okv(match fk { Some(x) => Some(*x), None => None }) == ref_kinds(c@, m as int, kk, d as int));
                    assert(om as int == ref_method(c@, m as int, d as int));
                }
                match fk {
                    None => None,
                    Some(fk) => {
                        if !((b1 as u64) <= (j as u64) && (j as usize) < fk.len()) {
                            return None;
                        }
                        let i = (j as i64 - b1) as usize;
                        proof { assert(kv(*fk)[i as int] == fk@[i as int]@); }
                        if op == LOAD_OUTER {
                            if x_is_token(fk[i]) { None } else {
                                match x_shift(fk[i], d) {
                                    Some(sk) => Some(x_update(k, h - 1, sk)),
                                    None => {
                                        proof {
                                            let s2 = kk.update(h - 1, shift(kv(*fk)[i as int], d as int));
                                            assert(post(pv, c@, m as int, off as int, kk, trusted) == Some(s2));
                                            assert(!match #[trigger] s2[h - 1] {
                                                Kind::Method(t) => 0 <= t <= u32::MAX as int,
                                                Kind::Block(d, x) => 0 <= d <= u32::MAX as int && 0 <= x <= u32::MAX as int,
                                                _ => true,
                                            });
                                        }
                                        None
                                    },
                                }
                            }
                        } else if op == LOAD_OUTER_BLOCK {
                            if x_block_slot(p, c, om, fk, i as i64) { Some(x_update(k, h - 1, XKind::Block(d, i as u32))) } else { None }
                        } else {
                            proof { assert(kk[h - 1] == k@[h - 1]@); }
                            if d >= 1 && x_is_plain(fk[i]) && x_is_val(k[h - 1]) && x_valid(p, om)
                                    && !(i == 0 && x_pinned0(p, om as usize)) {
                                Some(x_pop_push(k, 2, XKind::Val))
                            } else {
                                None
                            }
                        }
                    },
                }
            },
            _ => None,
        }
    }
}

pub fn x_post_fields(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
           || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
           || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        if x_value_operands(k, 1) && x_leaves0(p, m, h, 1) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        let slot = if op == POP_LOAD_FIELD_LOCAL { (b1 % 16 + 1) as usize } else { (b1 % 16) as usize };
        if slot < h {
            proof { assert(kv(*k)[h - 1 - slot] == k@[h - 1 - slot]@); }
            if x_is_val(k[h - 1 - slot]) {
                Some(if op == LOAD_FIELD_LOCAL { x_push(k, XKind::Val) } else { x_update(k, h - 1, XKind::Val) })
            } else { None }
        } else {
            None
        }
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        if x_value_operands(k, 2) && x_leaves0(p, m, h, 2) {
            if op == STORE_FIELD_POP {
                let k1 = x_prefix(k, h - 2);
                Some(k1)
            } else {
                Some(x_pop_push(k, 2, XKind::Val))
            }
        } else { None }
    } else if op == LOAD_FIELD_THIS {
        if x_this_field_ok(p, m, b1) { Some(x_push(k, XKind::Val)) } else { None }
    } else {
        if x_this_field_ok(p, m, b1) && x_value_operands(k, 1) { Some(x_copy(k)) } else { None }
    }
}

pub fn x_post_consts(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           (LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
           || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL) }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        let i = if op == LOAD_LITERAL { b1 } else { w1 };
        if (i as usize) < p.literals.len() { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8 || op == LOAD_SMI_U16 {
        Some(x_push(k, XKind::Val))
    } else if op == LOAD_SMI_U32 {
        if x_smi_ok(p, x_u32(p, bci + 1)) { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_SMIS_0 {
        let mut k1 = x_copy(k);
        let mut i: i64 = 0;
        while i < b1
            invariant 0 <= i <= b1, b1 < 256, kv(k1) == kv(*k) + Seq::new(i as nat, |x: int| Kind::Val),
            decreases b1 - i,
        {
            let ghost before = kv(k1);
            k1.push(XKind::Val);
            proof {
                assert(kv(k1) =~= before.push(Kind::Val));
                assert(kv(*k) + Seq::new((i + 1) as nat, |x: int| Kind::Val)
                    =~= (kv(*k) + Seq::new(i as nat, |x: int| Kind::Val)).push(Kind::Val));
            }
            i += 1;
        }
        Some(k1)
    } else if op == LOAD_METHOD {
        let t = x_u32(p, bci + 1);
        if x_valid(p, t) && x_smi_ok(p, t) { Some(x_push(k, XKind::Method(t as u32))) } else { None }
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_LAZY {
        if (b1 as u64) < c.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        if (w1 as u64) < c.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        let g = if op == STORE_GLOBAL_VAR { b1 } else { w1 };
        if (g as u64) < c.global_count && x_value_operands(k, 1) { Some(x_copy(k)) } else { None }
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 1) && x_leaves0(p, m, h, 1) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 2) { Some(x_prefix(k, h - 2)) } else { None }
    } else if op == POP || op == POP_1 {
        let n = if op == POP { b1 as usize } else { 1 };
        if n <= h { Some(x_prefix(k, h - n)) } else { None }
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        let cl = if op == ALLOCATE { b1 } else { w1 };
        if x_is_instance_class(p, cl) && x_ifc(p, cl as usize) >= 0 { Some(x_push(k, XKind::Val)) } else { None }
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        if x_value_operands(k, 1) && (op > IS_INTERFACE_WIDE || x_leaves0(p, m, h, 1))
            && x_typecheck_index_ok(p, op, if op % 2 == 0 { b1 } else { w1 }) {
            Some(if op <= IS_INTERFACE_WIDE { x_update(k, h - 1, XKind::Val) } else { x_copy(k) })
        } else { None }
    } else {
        if ((b1 / 32) as usize) < h {
            proof { assert(kv(*k)[h - 1 - b1 / 32] == k@[h - 1 - b1 / 32]@); }
            if x_is_val(k[h - 1 - (b1 / 32) as usize]) && ((2 * (b1 % 32) + 1) as usize) < p.class_check_ids.len() {
                Some(x_copy(k))
            } else { None }
        } else {
            None
        }
    }
}

pub fn x_post_calls(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == INVOKE_STATIC {
        let t = x_dispatch_target(p, w1);
        if x_valid(p, t) && x_args_ok(c, t as usize, k, p.methods[t as usize].arity as usize)
            && x_leaves0(p, m, h, p.methods[t as usize].arity as usize) {
            let a = p.methods[t as usize].arity as usize;
            Some(x_pop_push(k, a, XKind::Val))
        } else { None }
    } else if op == INVOKE_BLOCK {
        if 1 <= b1 && (b1 as usize) <= h {
            let kd = k[h - b1 as usize];
            proof { assert(kv(*k)[h - b1] == kd@); }
            if x_is_ref(kd) && x_value_operands(k, (b1 - 1) as usize) && x_leaves0(p, m, h, b1 as usize)
                && match kd { XKind::Block(d, i) => !(d == 0 && (i as usize) >= h - b1 as usize), _ => true } {
                Some(x_pop_push(k, b1 as usize, XKind::Val))
            } else { None }
        } else { None }
    } else if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        let n = if op == INVOKE_VIRTUAL { b1 + 1 } else { w1 + 1 };
        let sel = if op == INVOKE_VIRTUAL { x_u16(p, bci + 2) } else { x_u16(p, bci + 3) };
        if x_sel_ok(p, c, sel, n as usize, k) && x_leaves0(p, m, h, n as usize) {
            Some(x_pop_push(k, n as usize, XKind::Val))
        } else { None }
    } else if op == INVOKE_VIRTUAL_GET || op == INVOKE_SIZE {
        if x_sel_ok(p, c, w1, 1, k) && x_leaves0(p, m, h, 1) { Some(x_update(k, h - 1, XKind::Val)) } else { None }
    } else if op == INVOKE_VIRTUAL_SET {
        if x_value_operands(k, 2) && x_sel_ok(p, c, w1, 2, k) && x_leaves0(p, m, h, 2) {
            Some(x_pop_push(k, 2, XKind::Val))
        } else { None }
    } else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT {
        let n: usize = if op == INVOKE_AT_PUT { 3 } else { 2 };
        let sel = p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
        if x_value_operands(k, n) && (sel < 0 || x_sel_ok(p, c, sel, n, k)) && x_leaves0(p, m, h, n) {
            Some(x_pop_push(k, n, XKind::Val))
        } else { None }
    } else {
        if x_value_operands(k, 2) && x_leaves0(p, m, h, 2) { Some(x_pop_push(k, 2, XKind::Val)) } else { None }
    }
}

pub fn x_post_misc(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(pview2(p), m as int, off as int);
           !(op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
             || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP)
           && !(op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK)
           && !(op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
             || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
             || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS)
           && !((LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
             || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL))
           && !(op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL) }),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if (BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL) {
        if x_value_operands(k, 1) { Some(x_prefix(k, h - 1)) } else { None }
    } else if op == PRIMITIVE {
        let index = x_u16(p, bci + 2);
        let a = p.methods[m].arity as usize;
        if !(h == a && p.methods[m].kind == 0) { return None; }
        if !((b1 as usize) < c.prim_arity.len() && (index as usize) < c.prim_arity[b1 as usize].len()
            && c.prim_arity[b1 as usize][index as usize] as usize == a) {
            return None;
        }
        if b1 == 0 && index == X_PRIM_TASK_NEW as i64 && a != 1 { return None; }
        if b1 == 0 && index == X_PRIM_TASK_TRANSFER as i64 {
            if a != 2 { return None; }
            proof { assert(kv(*k)[0] == k@[0]@); assert(kv(*k)[1] == k@[1]@); }
            if !(x_is_plain(k[0]) && x_is_plain(k[1]) && p.methods[m].recv_start == 0xffff) { return None; }
        }
        Some(x_push(k, XKind::Val))
    } else if op == TRY {
        if 1 <= h && x_block_slot(p, c, m as i64, k, (h - 1) as i64) {
            let t = match k[h - 1] { XKind::Method(t) => t, _ => 0 };
            proof { assert(kv(*k)[h - 1] == k@[h - 1]@); assert(kind_method(kv(*k)[h - 1]) == t as int); }
            if p.methods[t as usize].arity == 1 && x_ctx_ok_upto(p, c, m as i64, k, h - 1) {
                let k1 = x_push(k, XKind::Val);
                let k2 = x_push(&k1, XKind::Token);
                let k3 = x_push(&k2, XKind::Val);
                Some(k3)
            } else { None }
        } else { None }
    } else if op == UNWIND {
        if 3 <= h {
            proof { assert(kv(*k)[h - 2] == k@[h - 2]@); }
            if x_is_token(k[h - 2]) {
                Some(x_prefix(k, h - 3))
            } else { None }
        } else {
            None
        }
    } else if op == HALT {
        if b1 == 0 { Some(x_push(k, XKind::Val)) }
        else if b1 == 1 && x_value_operands(k, 1) { Some(x_prefix(k, h - 1)) }
        else if trusted && b1 == 2 && 1 <= h { Some(x_prefix(k, h - 1)) }
        else if trusted && b1 >= 3 { Some(x_copy(k)) }
        else { None }
    } else {
        None
    }
}

/// `post`: the fall-through successor kinds.
pub fn x_post(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires post_pre(p, m, off, k),
    ensures post_rel(r, post(pview2(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let op = p.bytecodes[p.methods[m].entry + off];
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
        || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP {
        x_post_locals(p, c, m, off, k, trusted)
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK {
        x_post_outer(p, c, m, off, k, trusted)
    } else if op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
        || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
        || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS {
        x_post_fields(p, c, m, off, k, trusted)
    } else if (LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
        || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL) {
        x_post_consts(p, c, m, off, k, trusted)
    } else if op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL {
        x_post_calls(p, c, m, off, k, trusted)
    } else {
        x_post_misc(p, c, m, off, k, trusted)
    }
}

pub fn x_is_terminator(op: u8) -> (r: bool)
    ensures r == is_terminator(op),
{
    op == RETURN || op == RETURN_NULL || op == THROW || op == BRANCH || op == BRANCH_BACK
        || op == INVOKE_STATIC_TAIL || op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
        || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH
}

pub fn x_map_at<'a>(c: &'a XCert, m: i64, off: i64) -> (r: Option<&'a Vec<XKind>>)
    ensures okv(match r { Some(k) => Some(*k), None => None }) == map_at(c@, m as int, off as int),
{
    if 0 <= m && (m as u64) < (c.maps.len() as u64) && 0 <= off && (off as u64) < (c.maps[m as usize].len() as u64) {
        match &c.maps[m as usize][off as usize] {
            Some(k) => Some(k),
            None => None,
        }
    } else {
        None
    }
}

pub fn x_map_is(c: &XCert, m: i64, off: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == (map_at(c@, m as int, off as int) == Some(kv(*k))),
{
    match x_map_at(c, m, off) {
        Some(k2) => x_kinds_eq(k2, k),
        None => false,
    }
}

#[verifier::loop_isolation(false)]
pub fn x_terminator_ok(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>) -> (r: bool)
    requires
        wf_program2(pview2(p)),
        m < p.methods.len(),
        p.methods[m as int].entry + off + opcode_length2(p.bytecodes[p.methods[m as int].entry + off]) <= p.methods[m as int].end,
        p.bytecodes[p.methods[m as int].entry + off] < OPCODE_COUNT2,
    ensures r == terminator_ok(pview2(p), c@, m as int, off as int, kv(*k)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    let ghost kk = kv(*k);
    if op == RETURN {
        if 1 <= h { proof { assert(kk[h - 1] == k@[h - 1]@); } }
        1 <= h && x_is_val(k[h - 1])
    } else if op == RETURN_NULL {
        true
    } else if op == THROW {
        x_value_operands(k, 1)
    } else if op == INVOKE_STATIC_TAIL {
        let t = x_dispatch_target(p, w1);
        if !x_valid(p, t) { return false; }
        let a = p.methods[t as usize].arity as usize;
        if !x_args_ok(c, t as usize, k, a) { return false; }
        let mut j = h - a;
        while j < h
            invariant a <= h, h == k.len(), h - a <= j <= h, kk == kv(*k),
                forall|jj: int| h - a <= jj < j ==> !is_local_ref(#[trigger] kk[jj]),
            decreases h - j,
        {
            proof { assert(kk[j as int] == k@[j as int]@); }
            match k[j] {
                XKind::Block(0, _) => {
                    proof { assert(is_local_ref(kk[j as int])); }
                    return false;
                },
                _ => {},
            }
            j += 1;
        }
        true
    } else if op == INVOKE_LAMBDA_TAIL {
        if !(p.methods[m].kind == 0 && h == p.methods[m].arity as usize && h >= 1) { return false; }
        let mut i = 0;
        while i < h
            invariant h == k.len(), 0 <= i <= h, kk == kv(*k), forall|ii: int| 0 <= ii < i ==> is_val(#[trigger] kk[ii]),
            decreases h - i,
        {
            proof { assert(kk[i as int] == k@[i as int]@); }
            if !x_is_val(k[i]) {
                proof { assert(!is_val(kk[i as int])); }
                return false;
            }
            i += 1;
        }
        true
    } else if op == INVOKE_INITIALIZER_TAIL {
        x_value_operands(k, 1)
    } else if op == NON_LOCAL_RETURN {
        if 2 <= h { proof { assert(kk[h - 1] == k@[h - 1]@); assert(kk[h - 2] == k@[h - 2]@); } }
        2 <= h && x_is_val(k[h - 2]) && match k[h - 1] { XKind::Block(d, _) => d >= 1, _ => false }
    } else if op == NON_LOCAL_BRANCH {
        if h < 1 { return false; }
        proof { assert(kk[h - 1] == k@[h - 1]@); }
        match k[h - 1] {
            XKind::Block(d, j) => {
                if d < 1 { return false; }
                let (fk, om) = x_ctx_kinds(c, m as i64, d);
                let target = x_u32(p, bci + 2);
                match (fk, x_map_at(c, om, target)) {
                    (Some(fk), Some(t)) => {
                        if !(x_valid(p, om) && b1 <= j as i64 + 1 && (j as usize) < fk.len()) { return false; }
                        let n = (j as i64 + 1 - b1) as usize;
                        if t.len() != n {
                            proof { assert(kv(*t).len() != kv(*fk).subrange(0, n as int).len()); }
                            return false;
                        }
                        let mut i = 0;
                        while i < n
                            invariant n == t.len(), n <= fk.len(), 0 <= i <= n,
                                forall|ii: int| 0 <= ii < i ==> (#[trigger] t@[ii])@ == fk@[ii]@,
                            decreases n - i,
                        {
                            if !x_kind_eq(t[i], fk[i]) {
                                proof { assert(kv(*t)[i as int] != kv(*fk).subrange(0, n as int)[i as int]); }
                                return false;
                            }
                            i += 1;
                        }
                        proof { assert(kv(*t) =~= kv(*fk).subrange(0, n as int)); }
                        true
                    },
                    _ => false,
                }
            },
            _ => false,
        }
    } else if op == BRANCH || op == BRANCH_BACK {
        true
    } else {
        false
    }
}

pub fn x_shape_ok(p: &ExecProgram, c: &XCert, m: usize, k: &Vec<XKind>) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == shape_ok(pview2(p), c@, m as int, kv(*k)),
{
    if x_pinned0(p, m) && p.methods[m].arity >= 1 && k.len() < 1 { return false; }
    if p.methods[m].kind == 3 {
        if k.len() < 1 { return false; }
        proof { assert(kv(*k)[0] == k@[0]@); }
        match x_ctx_of(c, m) {
            Some(ctx) => x_kind_eq(k[0], XKind::Block(1, ctx.slot)),
            None => false,
        }
    } else {
        true
    }
}

pub fn x_instr_ok(p: &ExecProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: bool)
    requires wf_program2(pview2(p)), m < p.methods.len(),
    ensures r == instr_ok(pview2(p), c@, m as int, off as int, kv(*k), trusted),
{
    let i = p.methods[m];
    if !(off < i.end - i.entry) { return false; }
    let bci = i.entry + off;
    let op = p.bytecodes[bci];
    if op >= OPCODE_COUNT2 { return false; }
    let len = exec_opcode_length2(op);
    if bci + len > i.end { return false; }
    if k.len() > i.arity as usize + i.max_height as usize { return false; }
    if !x_wf_kinds(p, c, m as i64, k) || !x_ctx_ok(p, c, m as i64, k) || !x_shape_ok(p, c, m, k) {
        return false;
    }
    let post = x_post(p, c, m, off, k, trusted);
    proof { lemma_map_repr(c, m as int, (off + len) as int); }
    if x_is_terminator(op) {
        if !x_terminator_ok(p, c, m, off, k) { return false; }
    } else if post.is_none() {
        return false;
    }
    match &post {
        Some(k2) => if !x_map_is(c, m as i64, (off + len) as i64, k2) { return false; },
        None => {},
    }
    if BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        let w1 = x_u16(p, bci + 1);
        let t = if op <= BRANCH_IF_NOT_NULL { off as i64 + w1 } else { off as i64 - w1 };
        if op <= BRANCH_IF_NOT_NULL && w1 <= 0 { return false; }
        if op == BRANCH || op == BRANCH_BACK {
            if !x_map_is(c, m as i64, t, k) { return false; }
        } else {
            if k.len() < 1 { return false; }
            let k1 = x_prefix(k, k.len() - 1);
            if !x_map_is(c, m as i64, t, &k1) { return false; }
        }
    }
    true
}

pub fn x_entry_kinds(p: &ExecProgram, c: &XCert, m: usize) -> (r: Vec<XKind>)
    requires m < p.methods.len(),
    ensures kv(r) == entry_kinds(pview2(p), c@, m as int),
{
    let a = p.methods[m].arity as usize;
    let ghost e = entry_kinds(pview2(p), c@, m as int);
    let mut r: Vec<XKind> = Vec::new();
    let mut i = 0;
    while i < a
        invariant m < p.methods.len(), a == p.methods[m as int].arity, e == entry_kinds(pview2(p), c@, m as int),
            0 <= i <= a, r.len() == i, forall|ii: int| 0 <= ii < i ==> #[trigger] kv(r)[ii] == e[ii],
        decreases a - i,
    {
        let ghost before = r@;
        let ghost before_k = kv(r);
        if p.methods[m].kind == 3 {
            if i == 0 {
                match x_ctx_of(c, m) {
                    Some(ctx) => r.push(XKind::Block(1, ctx.slot)),
                    None => r.push(XKind::Param),
                }
            } else {
                r.push(XKind::Val);
            }
        } else if x_is_block_param(c, m, i) {
            r.push(XKind::Param);
        } else {
            r.push(XKind::Val);
        }
        proof {
            assert(kv(r)[i as int] == r@[i as int]@);
            assert(kv(r)[i as int] == e[i as int]);
            assert forall|ii: int| 0 <= ii < i + 1 implies #[trigger] kv(r)[ii] == e[ii] by {
                if ii < i {
                    assert(r@[ii] == before[ii]);
                    assert(kv(r)[ii] == r@[ii]@);
                    assert(before_k[ii] == before[ii]@);
                    assert(before_k[ii] == e[ii]);
                }
            }
        }
        i += 1;
    }
    proof { assert(kv(r) =~= e); }
    r
}

/// Every mapped instruction of `m` is accepted.
pub fn x_method_body_ok(p: &ExecProgram, c: &XCert, m: usize, trusted: bool) -> (r: bool)
    requires wf_program2(pview2(p)), m < p.methods.len(), m < c.maps.len(),
    ensures r == forall|o: int| 0 <= o < c@.maps[m as int].len() && (#[trigger] c@.maps[m as int][o]) is Some ==>
        instr_ok(pview2(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
{
    let mut off = 0;
    while off < c.maps[m].len()
        invariant
            wf_program2(pview2(p)), m < p.methods.len(), m < c.maps.len(),
            0 <= off <= c.maps[m as int].len(),
            forall|o: int| 0 <= o < off && (#[trigger] c@.maps[m as int][o]) is Some ==>
                instr_ok(pview2(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
        decreases c.maps[m as int].len() - off,
    {
        match &c.maps[m][off] {
            Some(k) => if !x_instr_ok(p, c, m, off, k, trusted) {
                proof { assert(c@.maps[m as int][off as int] == Some(kv(*k))); }
                return false;
            },
            None => {},
        }
        off += 1;
    }
    true
}

pub fn x_method_ok(p: &ExecProgram, c: &XCert, m: usize, trusted: bool) -> (r: bool)
    requires
        wf_program2(pview2(p)), m < p.methods.len(),
        c.maps.len() == p.methods.len(), c.block_params.len() == p.methods.len(), c.contexts.len() == p.methods.len(),
    ensures r == method_ok(pview2(p), c@, m as int, trusted),
{
    let i = p.methods[m];
    if !(i.entry < i.end && i.end <= p.bytecodes.len()) { return false; }
    if c.maps[m].len() != i.end - i.entry { return false; }
    if c.block_params[m].len() != i.arity as usize { return false; }
    if c.contexts[m].is_some() && i.kind != 3 { return false; }
    if i.kind == 3 && c.contexts[m].is_none() { return true; }
    let e = x_entry_kinds(p, c, m);
    if !x_map_is(c, m as i64, 0, &e) { return false; }
    x_method_body_ok(p, c, m, trusted)
}

// ---------------------------------------------------------------------------
// Tables.

#[verifier::loop_isolation(false)]
pub fn x_no_block_params(c: &XCert, m: usize) -> (r: bool)
    requires m < c.block_params.len(),
    ensures r == no_block_params(c@, m as int),
{
    let mut i = 0;
    while i < c.block_params[m].len()
        invariant m < c.block_params.len(), 0 <= i <= c.block_params[m as int].len(),
            forall|ii: int| 0 <= ii < i ==> !(#[trigger] c@.block_params[m as int][ii]),
        decreases c.block_params[m as int].len() - i,
    {
        if c.block_params[m][i] {
            proof { assert(c@.block_params[m as int][i as int]); }
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_machine_class_ok(p: &ExecProgram, k: usize) -> (r: bool)
    requires k < p.builtin.len(),
    ensures r == machine_class_ok(pview2(p), k as int),
{
    let cl = p.builtin[k] as i64;
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && !(x_is_field_class(p, cl) && x_ifc(p, cl as usize) >= 1)
}

pub fn x_entry_method(p: &ExecProgram, k: usize) -> (r: i64)
    requires k < p.entry_points.len(),
    ensures r as int == entry_method(pview2(p), k as int),
{
    let d = p.entry_points[k] as i64;
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { p.dispatch[d as usize] as i64 } else { -1 }
}

pub fn x_entry_ok(p: &ExecProgram, c: &XCert, k: usize, a: u8) -> (r: bool)
    requires k < p.entry_points.len(), c.block_params.len() == p.methods.len(),
    ensures r == entry_ok(pview2(p), c@, k as int, a as int),
{
    let e = x_entry_method(p, k);
    x_valid(p, e) && p.methods[e as usize].kind == 0 && p.methods[e as usize].arity == a
        && x_no_block_params(c, e as usize)
}

pub fn x_dispatch_entry_ok(p: &ExecProgram, d: usize) -> (r: bool)
    requires d < p.dispatch.len(), p.dispatch.len() < 0x1000_0000,
    ensures r == dispatch_entry_ok(pview2(p), d as int),
{
    let t = p.dispatch[d] as i64;
    if t == -1 { return true; }
    if !x_valid(p, t) { return false; }
    let i = p.methods[t as usize];
    if !(i.kind == 0 || i.kind == 1) { return false; }
    let cl = d as i64 - i.selector as i64;
    if i.selector != 0xffff && 0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && i.recv_start != 0xffff {
        i.recv_start as i64 <= cl && cl < i.recv_end as i64
    } else {
        true
    }
}

pub fn x_bools_eq(a: &Vec<bool>, b: &Vec<bool>) -> (r: bool)
    ensures r == (a@ == b@),
{
    if a.len() != b.len() { return false; }
    let mut i = 0;
    while i < a.len()
        invariant a.len() == b.len(), 0 <= i <= a.len(), forall|j: int| 0 <= j < i ==> a@[j] == b@[j],
        decreases a.len() - i,
    {
        if a[i] != b[i] { return false; }
        i += 1;
    }
    proof { assert(a@ =~= b@); }
    true
}

pub fn x_method_table_ok(p: &ExecProgram, c: &XCert, m: usize) -> (r: bool)
    requires
        m < p.methods.len(),
        c.block_params.len() == p.methods.len(),
        c.contexts.len() == p.methods.len(),
    ensures r == method_table_ok(pview2(p), c@, m as int),
{
    let i = p.methods[m];
    let s = i.selector as usize;
    if c.block_params[m].len() != i.arity as usize { return false; }
    if i.selector != 0xffff {
        if s >= c.sel_rep.len() { return false; }
        let r = c.sel_rep[s];
        if !(x_valid(p, r) && p.methods[r as usize].arity == i.arity
            && x_bools_eq(&c.block_params[r as usize], &c.block_params[m])
            && x_row_fits(p, s)) {
            return false;
        }
    }
    if i.recv_start != 0xffff && !(i.arity >= 1 && !c.block_params[m][0]) { return false; }
    if i.kind == 3 && !(i.arity >= 1 && x_no_block_params(c, m)) { return false; }
    if i.kind == 2 && !x_no_block_params(c, m) { return false; }
    match &c.contexts[m] {
        Some(ctx) => x_valid(p, ctx.outer as i64),
        None => true,
    }
}

pub fn x_tables_ok(p: &ExecProgram, c: &XCert) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == tables_ok(pview2(p), c@),
{
    let ghost pv = pview2(p);
    let n = p.methods.len();
    if !(c.maps.len() == n && c.block_params.len() == n && c.contexts.len() == n) { return false; }
    if c.sel_rep.len() > 0xffff { return false; }
    let mut s = 0;
    while s < c.sel_rep.len()
        invariant 0 <= s <= c.sel_rep.len(), pv == pview2(p), forall|ss: int| 0 <= ss < s ==> #[trigger] sel_rep_ok(pv, c@, ss),
        decreases c.sel_rep.len() - s,
    {
        let r = c.sel_rep[s];
        if !(r == -1 || (x_valid(p, r) && p.methods[r as usize].selector as usize == s)) {
            proof { assert(!sel_rep_ok(pv, c@, s as int)); }
            return false;
        }
        s += 1;
    }
    let mut d = 0;
    while d < p.dispatch.len()
        invariant wf_program2(pv), pv == pview2(p), 0 <= d <= p.dispatch.len(),
            forall|dd: int| 0 <= dd < d ==> #[trigger] dispatch_entry_ok(pv, dd),
        decreases p.dispatch.len() - d,
    {
        if !x_dispatch_entry_ok(p, d) { return false; }
        d += 1;
    }
    let mut m = 0;
    while m < n
        invariant n == p.methods.len(), c.block_params.len() == n, c.contexts.len() == n, 0 <= m <= n, pv == pview2(p),
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_table_ok(pv, c@, mm),
        decreases n - m,
    {
        if !x_method_table_ok(p, c, m) { return false; }
        m += 1;
    }
    let mut k = 0;
    while k < p.interface_check_offsets.len()
        invariant 0 <= k <= p.interface_check_offsets.len(), pv == pview2(p),
            forall|kk: int| 0 <= kk < k ==> class_count(pv) + (#[trigger] pv.interface_check_offsets[kk]) as int <= pv.dispatch.len(),
        decreases p.interface_check_offsets.len() - k,
    {
        if !x_row_fits(p, p.interface_check_offsets[k] as usize) { return false; }
        k += 1;
    }
    if !(x_machine_class_ok(p, 15) && x_machine_class_ok(p, 11) && x_machine_class_ok(p, 16) && x_machine_class_ok(p, 18)) {
        return false;
    }
    let ex = p.builtin[22] as i64;
    if !(x_is_field_class(p, ex) && x_ifc(p, ex as usize) >= 2) { return false; }
    let tc = p.builtin[19] as i64;
    if !(x_is_field_class(p, tc) && x_ifc(p, tc as usize) >= 2) { return false; }
    if !x_entry_ok(p, c, 0, 1) { return false; }
    if p.methods[x_entry_method(p, 0) as usize].recv_start != 0xffff { return false; }
    if !x_entry_ok(p, c, 2, 1) { return false; }
    if p.methods[x_entry_method(p, 2) as usize].recv_start != 0xffff { return false; }
    let mut two: Vec<XKind> = Vec::new();
    two.push(XKind::Val);
    two.push(XKind::Val);
    proof { assert(kv(two) =~= seq![Kind::Val, Kind::Val]); }
    if !x_map_is(c, x_entry_method(p, 2), 1, &two) { return false; }
    x_entry_ok(p, c, 8, 2)
}

pub fn x_wf_program2(p: &ExecProgram) -> (r: bool)
    ensures r == wf_program2(pview2(p)),
{
    if !(p.word_bits == 32 || p.word_bits == 64) { return false; }
    if !(p.bytecodes.len() < 0x1000_0000 && p.methods.len() < 0x1000_0000 && p.dispatch.len() < 0x1000_0000) {
        return false;
    }
    let mut m = 0;
    while m < p.methods.len()
        invariant 0 <= m <= p.methods.len(),
            forall|mm: int| 0 <= mm < m ==> #[trigger] p.methods@[mm].entry <= p.methods@[mm].end <= p.bytecodes.len(),
        decreases p.methods.len() - m,
    {
        if !(p.methods[m].entry <= p.methods[m].end && p.methods[m].end <= p.bytecodes.len()) { return false; }
        m += 1;
    }
    p.roots.len() == 35 && p.invoke_offsets.len() == 19 && p.builtin.len() == 23 && p.entry_points.len() == 9
        && p.literals.len() >= 7
}

/// The structural verifier.
pub fn verify(p: &ExecProgram, c: &XCert, trusted: bool) -> (r: bool)
    ensures r == accepts(pview2(p), c@, trusted),
{
    if !x_wf_program2(p) { return false; }
    if !x_tables_ok(p, c) { return false; }
    let mut m = 0;
    while m < p.methods.len()
        invariant wf_program2(pview2(p)), tables_ok(pview2(p), c@), 0 <= m <= p.methods.len(),
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_ok(pview2(p), c@, mm, trusted),
        decreases p.methods.len() - m,
    {
        if !x_method_ok(p, c, m, trusted) { return false; }
        m += 1;
    }
    true
}

} // verus!

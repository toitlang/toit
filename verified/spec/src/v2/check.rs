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
use crate::v2::split::*;
use crate::v2::vprog::*;
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

/// A pinned map: the kinds of method `m` at offset `off`, which another
/// method's rules look up (`v2::split`).
pub struct XPin {
    pub m: u32,
    pub off: u32,
    pub kinds: Vec<XKind>,
}

/// The global part of the certificate (`v2::split::GCert`): small tables,
/// linear in the number of methods.
pub struct XGlobal {
    /// The number of methods.
    pub n: usize,
    /// The block-parameter mask of method `m` is `bp[bp_off[m]..bp_off[m + 1]]`.
    pub bp_off: Vec<u32>,
    pub bp: Vec<bool>,
    /// The context of block method `t` is `ctxs[ctx_idx[t]]` (none if out
    /// of range).
    pub ctx_idx: Vec<u32>,
    pub ctxs: Vec<XContext>,
    /// Selector representatives; selectors past the end have none (-1).
    pub sel_rep: Vec<i32>,
    pub global_count: u64,
    pub prim_arity: Vec<Vec<u8>>,
    /// Pinned maps, strictly sorted by (method, offset).
    pub pins: Vec<XPin>,
}

/// A node of the maps of one method: maps are lists of kinds that share
/// their bottoms. `parent >= ` the node's own index means none.
#[derive(Clone, Copy)]
pub struct XNode {
    pub parent: u32,
    pub kind: XKind,
}

/// No map at this offset.
pub const NO_MAP: u32 = 0xffff_ffff;
/// The empty map (any index past the nodes, other than `NO_MAP`).
pub const EMPTY_MAP: u32 = 0xffff_fffe;

/// The maps of one method: `idx[off]` is `NO_MAP` or the top node of the
/// map at offset `off`.
pub struct XMaps {
    pub idx: Vec<u32>,
    pub nodes: Vec<XNode>,
}

/// The certificate a method is checked against: the global part, and the
/// maps of method `cur` (`cur >= g.n`: the tables, pins only).
pub struct XCert<'a> {
    pub g: &'a XGlobal,
    pub cur: usize,
    pub maps: &'a XMaps,
}

pub open spec fn kv(k: Vec<XKind>) -> Seq<Kind> {
    k@.map_values(|x: XKind| x@)
}

pub open spec fn okv(o: Option<Vec<XKind>>) -> Option<Seq<Kind>> {
    match o { Some(k) => Some(kv(k)), None => None }
}

pub open spec fn ctx1(x: XContext) -> Context {
    Context { outer: x.outer as int, slot: x.slot as int, kinds: kv(x.kinds) }
}

pub open spec fn ctxv(o: Option<XContext>) -> Option<Context> {
    match o { Some(x) => Some(ctx1(x)), None => None }
}

/// The kinds of the list whose top node is `i`, bottom first.
pub open spec fn chain(nodes: Seq<XNode>, i: int) -> Seq<Kind>
    decreases i,
{
    if i < 0 || i >= nodes.len() {
        Seq::empty()
    } else {
        let par = nodes[i].parent as int;
        (if par < i { chain(nodes, par) } else { Seq::empty() }).push(nodes[i].kind@)
    }
}

pub open spec fn map_view(x: &XMaps, o: int) -> Option<Seq<Kind>> {
    if x.idx@[o] == NO_MAP { None } else { Some(chain(x.nodes@, x.idx@[o] as int)) }
}

pub open spec fn mapsv(x: &XMaps) -> Maps {
    Seq::new(x.idx@.len(), |o: int| map_view(x, o))
}

pub open spec fn bp_view(g: &XGlobal, m: int) -> Seq<bool> {
    if 0 <= m && m + 1 < g.bp_off@.len() && g.bp_off@[m] <= g.bp_off@[m + 1] && (g.bp_off@[m + 1] as int) <= g.bp@.len() {
        g.bp@.subrange(g.bp_off@[m] as int, g.bp_off@[m + 1] as int)
    } else {
        Seq::empty()
    }
}

pub open spec fn ctx_view(g: &XGlobal, t: int) -> Option<Context> {
    if 0 <= t < g.ctx_idx@.len() && (g.ctx_idx@[t] as int) < g.ctxs@.len() {
        Some(ctx1(g.ctxs@[g.ctx_idx@[t] as int]))
    } else {
        None
    }
}

pub open spec fn sel_view(g: &XGlobal, s: int) -> int {
    if 0 <= s < g.sel_rep@.len() { g.sel_rep@[s] as int } else { -1 }
}

pub open spec fn pin_key(x: XPin) -> int {
    x.m as int * 0x1_0000_0000 + x.off as int
}

pub open spec fn has_pin(g: &XGlobal, m: int, o: int) -> bool {
    exists|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m && g.pins@[i].off == o
}

pub open spec fn pin_view(g: &XGlobal, m: int, o: int) -> Option<Seq<Kind>> {
    if has_pin(g, m, o) {
        let i = choose|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m && g.pins@[i].off == o;
        Some(kv(g.pins@[i].kinds))
    } else {
        None
    }
}

/// The pins are strictly sorted by (method, offset).
pub open spec fn pins_sorted(g: &XGlobal) -> bool {
    forall|i: int, j: int| 0 <= i < j < g.pins@.len() ==> pin_key(#[trigger] g.pins@[i]) < pin_key(#[trigger] g.pins@[j])
}

impl View for XGlobal {
    type V = GCert;
    open spec fn view(&self) -> GCert {
        GCert {
            n: self.n as int,
            block_params: Seq::new(self.n as nat, |m: int| bp_view(self, m)),
            contexts: Seq::new(self.n as nat, |t: int| ctx_view(self, t)),
            sel_rep: Seq::new(0xffff, |s: int| sel_view(self, s)),
            global_count: self.global_count as int,
            prim_arity: self.prim_arity@.map_values(|v: Vec<u8>| v@.map_values(|a: u8| a as int)),
            pins: |m: int, o: int| pin_view(self, m, o),
        }
    }
}

impl<'a> View for XCert<'a> {
    type V = Cert;
    open spec fn view(&self) -> Cert {
        if self.cur < self.g.n { local_cert(self.g@, self.cur as int, mapsv(self.maps)) } else { tables_cert(self.g@) }
    }
}

// ---------------------------------------------------------------------------
// Representable kinds.

/// The kinds the certificate can hold: depths, slots and method ids fit in
/// a u32.
pub open spec fn representable(s: Seq<Kind>) -> bool {
    forall|i: int| 0 <= i < s.len() ==> kind_repr(#[trigger] s[i])
}

pub open spec fn kind_repr(k: Kind) -> bool {
    match k {
        Kind::Method(t) => 0 <= t <= u32::MAX as int,
        Kind::Block(d, x) => 0 <= d <= u32::MAX as int && 0 <= x <= u32::MAX as int,
        _ => true,
    }
}

pub proof fn lemma_representable(k: Vec<XKind>)
    ensures representable(kv(k)),
{
    assert forall|i: int| 0 <= i < kv(k).len() implies kind_repr(#[trigger] kv(k)[i]) by {
        assert(kv(k)[i] == k@[i]@);
    }
}

pub proof fn lemma_chain_repr(nodes: Seq<XNode>, i: int)
    ensures representable(chain(nodes, i)),
    decreases i,
{
    if 0 <= i < nodes.len() {
        let par = nodes[i].parent as int;
        if par < i { lemma_chain_repr(nodes, par); }
        let s = chain(nodes, i);
        let b = if par < i { chain(nodes, par) } else { Seq::empty() };
        assert(s == b.push(nodes[i].kind@));
        assert forall|j: int| 0 <= j < s.len() implies kind_repr(#[trigger] s[j]) by {
            if j < b.len() { assert(s[j] == b[j]); assert(kind_repr(b[j])); }
        }
    }
}

pub proof fn lemma_map_repr(c: &XCert, m: int, o: int)
    ensures map_at(c@, m, o) is Some ==> representable(map_at(c@, m, o)->0),
{
    if map_at(c@, m, o) is Some {
        if c.cur < c.g.n && m == c.cur {
            lemma_chain_repr(c.maps.nodes@, c.maps.idx@[o] as int);
        } else {
            let g = c.g;
            let i = choose|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m && g.pins@[i].off == o;
            lemma_representable(g.pins@[i].kinds);
        }
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

pub fn x_u16(p: &VProgram, i: usize) -> (r: i64)
    requires i + 2 <= p.bytecodes.len(),
    ensures r as int == u16_at(p1(vview(p)), i as int), 0 <= r < 0x10000,
{
    (p.bytecodes[i] as i64) + 256 * (p.bytecodes[i + 1] as i64)
}

pub fn x_u32(p: &VProgram, i: usize) -> (r: i64)
    requires i + 4 <= p.bytecodes.len(),
    ensures r as int == u32_at(p1(vview(p)), i as int), 0 <= r < 0x1_0000_0000,
{
    x_u16(p, i) + 65536 * x_u16(p, i + 2)
}

pub fn x_class_count(p: &VProgram) -> (r: usize)
    ensures r as int == class_count(vview(p)),
{
    p.class_bits.len()
}

/// `class_count(p) + extra <= p.dispatch.len()` without overflow.
pub fn x_row_fits(p: &VProgram, extra: usize) -> (r: bool)
    ensures r == (class_count(vview(p)) + extra <= p.dispatch.len()),
{
    extra <= p.dispatch.len() && p.class_bits.len() <= p.dispatch.len() - extra
}

pub fn x_is_instance_class(p: &VProgram, cl: i64) -> (r: bool)
    ensures r == is_instance_class(vview(p), cl as int),
{
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && (p.class_bits[cl as usize] & 0xf) == 2
}

pub fn x_is_field_class(p: &VProgram, cl: i64) -> (r: bool)
    ensures r == is_field_class(vview(p), cl as int),
{
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64)
        && ((p.class_bits[cl as usize] & 0xf) == 2 || (p.class_bits[cl as usize] & 0xf) == 8)
}

pub fn x_ifc(p: &VProgram, cl: usize) -> (r: i64)
    requires cl < p.class_bits.len(),
    ensures r as int == ifc(vview(p), cl as int),
{
    (((p.class_bits[cl] >> 5u16) & 0x7ff) as i64) - 1
}

pub fn x_smi_ok(p: &VProgram, v: i64) -> (r: bool)
    requires 0 <= v < 0x1_0000_0000,
    ensures r == smi_ok(p1(vview(p)), v as int),
{
    p.word_bits != 32 || v <= 0x3fff_ffff
}

pub fn x_valid(p: &VProgram, t: i64) -> (r: bool)
    ensures r == valid_method(vview(p), t as int), r ==> (t as usize) as int == t as int,
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

/// The bounds of method `m`'s block-parameter mask in `g.bp`, if valid.
pub fn x_bp_range(g: &XGlobal, m: usize) -> (r: Option<(usize, usize)>)
    ensures
        match r {
            Some((a, b)) => a <= b <= g.bp@.len() && bp_view(g, m as int) == g.bp@.subrange(a as int, b as int),
            None => bp_view(g, m as int) == Seq::<bool>::empty(),
        },
{
    if m < g.bp_off.len() && m + 1 < g.bp_off.len() {
        let a = g.bp_off[m] as usize;
        let b = g.bp_off[m + 1] as usize;
        if a <= b && b <= g.bp.len() {
            return Some((a, b));
        }
    }
    None
}

/// `c@.block_params[m].len()` for a method `m < g.n`.
pub fn x_bp_len(c: &XCert, m: usize) -> (r: usize)
    requires m < c.g.n,
    ensures r == c@.block_params[m as int].len(),
{
    match x_bp_range(c.g, m) {
        Some((a, b)) => b - a,
        None => 0,
    }
}

pub fn x_is_block_param(c: &XCert, m: usize, i: usize) -> (r: bool)
    ensures r == is_block_param(c@, m as int, i as int),
{
    if m >= c.g.n { return false; }
    match x_bp_range(c.g, m) {
        Some((a, b)) => i < b - a && c.g.bp[a + i],
        None => false,
    }
}

/// `c@.block_params[r] == c@.block_params[m]`.
pub fn x_bp_eq(c: &XCert, r: usize, m: usize) -> (res: bool)
    requires r < c.g.n, m < c.g.n,
    ensures res == (c@.block_params[r as int] == c@.block_params[m as int]),
{
    let ghost br = c@.block_params[r as int];
    let ghost bm = c@.block_params[m as int];
    let (ra, rb) = match x_bp_range(c.g, r) { Some(x) => x, None => (0, 0) };
    let (ma, mb) = match x_bp_range(c.g, m) { Some(x) => x, None => (0, 0) };
    assert(br =~= c.g.bp@.subrange(ra as int, rb as int));
    assert(bm =~= c.g.bp@.subrange(ma as int, mb as int));
    if rb - ra != mb - ma { return false; }
    let mut i = 0;
    while i < rb - ra
        invariant
            ra <= rb <= c.g.bp@.len(), ma <= mb <= c.g.bp@.len(), rb - ra == mb - ma, 0 <= i <= rb - ra,
            br == c.g.bp@.subrange(ra as int, rb as int), bm == c.g.bp@.subrange(ma as int, mb as int),
            br == c@.block_params[r as int], bm == c@.block_params[m as int],
            forall|j: int| 0 <= j < i ==> br[j] == bm[j],
        decreases rb - ra - i,
    {
        if c.g.bp[ra + i] != c.g.bp[ma + i] {
            assert(br[i as int] == c.g.bp@[ra + i]);
            assert(bm[i as int] == c.g.bp@[ma + i]);
            assert(br[i as int] != bm[i as int]);
            return false;
        }
        i += 1;
    }
    assert(br =~= bm);
    true
}

pub fn x_no_block_params(c: &XCert, m: usize) -> (r: bool)
    requires m < c.g.n,
    ensures r == no_block_params(c@, m as int),
{
    let ghost b = c@.block_params[m as int];
    let (a, e) = match x_bp_range(c.g, m) { Some(x) => x, None => (0, 0) };
    assert(b =~= c.g.bp@.subrange(a as int, e as int));
    let mut i = a;
    while i < e
        invariant a <= i <= e <= c.g.bp@.len(), b == c.g.bp@.subrange(a as int, e as int), b == c@.block_params[m as int],
            forall|j: int| 0 <= j < i - a ==> !b[j],
        decreases e - i,
    {
        if c.g.bp[i] {
            assert(b[i - a] == c.g.bp@[i as int]);
            assert(b[i - a]);
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_ctx_of<'a>(c: &XCert<'a>, t: usize) -> (r: Option<&'a XContext>)
    ensures ctxv(match r { Some(x) => Some(*x), None => None }) == ctx_of(c@, t as int),
{
    let g = c.g;
    if t < g.n && t < g.ctx_idx.len() && (g.ctx_idx[t] as usize) < g.ctxs.len() {
        Some(&g.ctxs[g.ctx_idx[t] as usize])
    } else {
        None
    }
}

/// `c@.sel_rep[s]` for `s < 0xffff`.
pub fn x_sel_rep(c: &XCert, s: usize) -> (r: i64)
    requires s < 0xffff,
    ensures r as int == c@.sel_rep[s as int],
{
    if s < c.g.sel_rep.len() { c.g.sel_rep[s] as i64 } else { -1 }
}

pub fn x_dispatch_target(p: &VProgram, d: i64) -> (r: i64)
    ensures r as int == dispatch_target(vview(p), d as int),
{
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { p.dispatch[d as usize] as i64 } else { -1 }
}

// ---------------------------------------------------------------------------
// Block slots and contexts.

pub fn x_block_slot(p: &VProgram, c: &XCert, om: i64, fk: &Vec<XKind>, i: i64) -> (r: bool)
    ensures r == block_slot(vview(p), c@, om as int, kv(*fk), i as int),
{
    if i < 0 || (i as u64) >= (fk.len() as u64) {
        return false;
    }
    proof { assert(kv(*fk)[i as int] == fk@[i as int]@); }
    match fk[i as usize] {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && x_info(p, t as usize).kind == 3) {
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

pub fn x_block_slot_u(p: &VProgram, c: &XCert, om: i64, fk: &Vec<XKind>, i: usize) -> (r: bool)
    ensures r == block_slot(vview(p), c@, om as int, kv(*fk), i as int),
{
    if i >= fk.len() {
        return false;
    }
    proof { assert(kv(*fk)[i as int] == fk@[i as int]@); }
    match fk[i] {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && x_info(p, t as usize).kind == 3) {
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
pub fn x_ctx_kinds<'a>(c: &XCert<'a>, m: i64, depth: u32) -> (r: (Option<&'a Vec<XKind>>, i64))
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
        if cur < 0 || (cur as u64) >= (c.g.n as u64) {
            return (None, -1);
        }
        match x_ctx_of(c, cur as usize) {
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

pub fn x_wf_kinds(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == wf_kinds(vview(p), c@, m as int, kv(*k)),
{
    let mut j = 0;
    while j < k.len()
        invariant 0 <= j <= k.len(), forall|jj: int| 0 <= jj < j ==> #[trigger] wf_kind(vview(p), c@, m as int, kv(*k), jj),
        decreases k.len() - j,
    {
        proof { assert(kv(*k)[j as int] == k@[j as int]@); }
        match k[j] {
            XKind::Block(d, i) => {
                if d == 0 {
                    if !((i as usize) < j && x_block_slot(p, c, m, k, i as i64)) {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return false;
                    }
                } else {
                    let (fk, om) = x_ctx_kinds(c, m, d);
                    match fk {
                        None => {
                            proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                            return false;
                        },
                        Some(fk) => if !x_block_slot(p, c, om, fk, i as i64) {
                            proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                            return false;
                        },
                    }
                }
            },
            _ => {},
        }
        proof { assert(wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
        j += 1;
    }
    true
}

#[verifier::loop_isolation(false)]
pub fn x_ctx_ok_at(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, i: usize) -> (r: bool)
    requires i < k.len(),
    ensures r == ctx_ok_at(vview(p), c@, m as int, kv(*k), i as int),
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

pub fn x_ctx_ok_upto(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, n: usize) -> (r: bool)
    ensures r == ctx_ok_upto(vview(p), c@, m as int, kv(*k), n as int),
{
    let mut i = 0;
    while i <= n && i < k.len()
        invariant 0 <= i <= k.len(), i <= n + 1,
            forall|ii: int| 0 <= ii < i ==> #[trigger] ctx_ok_at(vview(p), c@, m as int, kv(*k), ii),
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

pub fn x_ctx_ok(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (r: bool)
    ensures r == ctx_ok(vview(p), c@, m as int, kv(*k)),
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
    let ghost pv = vview(p);
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

pub fn x_pinned0(p: &VProgram, m: usize) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == pinned0(vview(p), m as int),
{
    x_info(p, m).recv_start != 0xffff || x_info(p, m).kind == 3
}

pub fn x_writable(p: &VProgram, m: usize, k: &Vec<XKind>, i: usize, v: XKind) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == writable(vview(p), m as int, kv(*k), i as int, v@),
{
    if i >= k.len() { return false; }
    proof { assert(kv(*k)[i as int] == k@[i as int]@); }
    if i == 0 && x_pinned0(p, m) { return false; }
    if x_referenced(k, i) { return false; }
    if x_is_token(k[i]) || x_is_token(v) { return false; }
    if x_below_token(k, i) && !(x_is_plain(k[i]) && x_is_plain(v)) { return false; }
    true
}

pub fn x_leaves0(p: &VProgram, m: usize, h: usize, n: usize) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == leaves0(vview(p), m as int, h as int, n as int),
{
    !(x_pinned0(p, m) && x_info(p, m).arity >= 1) || (n < h && h - n >= 1)
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

pub fn x_sel_ok(p: &VProgram, c: &XCert, sel: i64, n: usize, k: &Vec<XKind>) -> (r: bool)
    ensures r == sel_ok(vview(p), c@, sel as int, n as int, kv(*k)),
{
    if !(1 <= n && n <= k.len()) { return false; }
    if !(0 <= sel && sel < 0xffff) { return false; }
    if !x_row_fits(p, sel as usize) { return false; }
    proof { assert(kv(*k)[k.len() - n] == k@[k.len() - n]@); }
    if !x_is_val(k[k.len() - n]) { return false; }
    let r = x_sel_rep(c, sel as usize);
    if r == -1 { return true; }
    if !x_valid(p, r) { return false; }
    let ru = r as usize;
    proof { assert(ru as int == r as int); }
    x_info(p, ru).arity as usize == n && x_args_ok(c, ru, k, n)
}

pub fn x_typecheck_index_ok(p: &VProgram, op: u8, enc: i64) -> (r: bool)
    requires 0 <= enc < 0x10000,
    ensures r == typecheck_index_ok(vview(p), op, enc as int),
{
    let index = enc / 2;
    if op == IS_INTERFACE || op == IS_INTERFACE_WIDE || op == AS_INTERFACE || op == AS_INTERFACE_WIDE {
        (index as usize) < p.interface_check_offsets.len()
    } else {
        ((2 * index + 1) as usize) < p.class_check_ids.len()
    }
}

pub fn x_this_field_ok(p: &VProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == this_field_ok(vview(p), m as int, f as int),
{
    let i = x_info(p, m);
    if i.recv_start == 0xffff || i.arity < 1 || !(i.kind == 0 || i.kind == 1) {
        return false;
    }
    if i.recv_end as usize > p.class_bits.len() {
        return false;
    }
    let mut cl = i.recv_start;
    while cl < i.recv_end
        invariant i == vinfo(p, m as int), i.recv_start <= cl,
            forall|c2: int| i.recv_start <= c2 < cl ==> #[trigger] is_field_class(vview(p), c2) && f < ifc(vview(p), c2),
        decreases i.recv_end - cl,
    {
        if !x_is_field_class(p, cl as i64) || !(f < x_ifc(p, cl as usize)) {
            return false;
        }
        cl += 1;
    }
    true
}

pub fn x_range_has_task(p: &VProgram, m: usize) -> (r: bool)
    requires m < p.methods.len(), wf_program2(vview(p)),
    ensures r == range_has_task(vview(p), vinfo(p, m as int)),
{
    let i = x_info(p, m);
    let tc = p.builtin[19];
    i.recv_start <= tc && tc < i.recv_end
}

pub fn x_this_load_ok(p: &VProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods.len(), wf_program2(vview(p)),
    ensures r == this_load_ok(vview(p), m as int, f as int),
{
    x_this_field_ok(p, m, f) && !(x_range_has_task(p, m) && f == 0)
}

pub fn x_this_store_ok(p: &VProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods.len(), wf_program2(vview(p)),
    ensures r == this_store_ok(vview(p), m as int, f as int),
{
    x_this_field_ok(p, m, f) && !(x_range_has_task(p, m) && f <= 1)
}

pub fn x_task_class_ok(p: &VProgram) -> (r: bool)
    requires wf_program2(vview(p)),
    ensures r == task_class_ok(vview(p)),
{
    let ghost pv = vview(p);
    let tc = p.builtin[19] as usize;
    assert(tc as int == builtin(p1(pv), TASK_CLASS));
    if !(tc < p.class_bits.len() && (p.class_bits[tc] & 0xf) == 8) {
        proof {
            if tc < p.class_bits.len() { assert(class_tag(p1(pv), tc as int) == p.class_bits[tc as int] & 0xf); }
        }
        return false;
    }
    assert(class_tag(p1(pv), tc as int) == TASK_TAG);
    if p.builtin[22] as usize == tc { return false; }
    let mut cl = 0;
    while cl < p.class_bits.len()
        invariant 0 <= cl <= p.class_bits.len(), tc as int == builtin(p1(pv), TASK_CLASS), pv == vview(p),
            forall|c2: int| 0 <= c2 < cl && #[trigger] class_tag(p1(pv), c2) == TASK_TAG ==> c2 == tc,
        decreases p.class_bits.len() - cl,
    {
        if (p.class_bits[cl] & 0xf) == 8 && cl != tc {
            proof { assert(class_tag(p1(pv), cl as int) == TASK_TAG); }
            return false;
        }
        proof { assert(class_tag(p1(pv), cl as int) == p.class_bits[cl as int] & 0xf); }
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
pub open spec fn post_pre(p: &VProgram, m: usize, off: usize, k: &Vec<XKind>) -> bool {
    &&& wf_program2(vview(p))
    &&& m < p.methods.len()
    &&& vinfo(p, m as int).entry + off + opcode_length2(p.bytecodes[vinfo(p, m as int).entry + off]) <= vinfo(p, m as int).end
    &&& p.bytecodes[vinfo(p, m as int).entry + off] < OPCODE_COUNT2
    &&& k.len() <= 0x10_0000
}

/// Decodes the instruction at offset `off` of `m`.
pub fn x_decode(p: &VProgram, m: usize, off: usize) -> (r: (usize, u8, usize, i64, i64))
    requires
        wf_program2(vview(p)),
        m < p.methods.len(),
        vinfo(p, m as int).entry + off + opcode_length2(p.bytecodes[vinfo(p, m as int).entry + off]) <= vinfo(p, m as int).end,
    ensures ({
        let (bci, op, len, b1, w1) = r;
        let pv = vview(p);
        &&& bci as int == instr_at(pv, m as int, off as int)
        &&& op == op_of(pv, m as int, off as int)
        &&& len as int == opcode_length2(op)
        &&& bci + len <= vinfo(p, m as int).end
        &&& vinfo(p, m as int).end <= p.bytecodes.len()
        &&& p.bytecodes.len() < 0x1000_0000
        &&& 0 <= b1 < 256 && 0 <= w1 < 0x10000
        &&& (len >= 2 ==> b1 as int == b1_of(pv, m as int, off as int))
        &&& (len >= 3 ==> w1 as int == w1_of(pv, m as int, off as int))
    }),
{
    let bci = x_info(p, m).entry + off;
    let op = p.bytecodes[bci];
    let len = exec_opcode_length2(op);
    let b1: i64 = if len >= 2 { p.bytecodes[bci + 1] as i64 } else { 0 };
    let w1: i64 = if len >= 3 { x_u16(p, bci + 1) } else { 0 };
    (bci, op, len, b1, w1)
}

pub fn x_post_locals(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
           || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
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

pub fn x_post_outer(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    let ghost pv = vview(p);
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

pub fn x_post_fields(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
           || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
           || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
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
        if x_this_load_ok(p, m, b1) { Some(x_push(k, XKind::Val)) } else { None }
    } else {
        if x_this_store_ok(p, m, b1) && x_value_operands(k, 1) { Some(x_copy(k)) } else { None }
    }
}

pub fn x_post_consts(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           (LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
           || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL) }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
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
        if (b1 as u64) < c.g.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        if (w1 as u64) < c.g.global_count { Some(x_push(k, XKind::Val)) } else { None }
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        let g = if op == STORE_GLOBAL_VAR { b1 } else { w1 };
        if (g as u64) < c.g.global_count && x_value_operands(k, 1) { Some(x_copy(k)) } else { None }
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

pub fn x_post_calls(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == INVOKE_STATIC {
        let t = x_dispatch_target(p, w1);
        if x_valid(p, t) && x_args_ok(c, t as usize, k, x_info(p, t as usize).arity as usize)
            && x_leaves0(p, m, h, x_info(p, t as usize).arity as usize) {
            let a = x_info(p, t as usize).arity as usize;
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

pub fn x_post_misc(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           !(op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
             || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP)
           && !(op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK)
           && !(op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
             || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
             || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS)
           && !((LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
             || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL))
           && !(op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL) }),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if (BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL) {
        if x_value_operands(k, 1) { Some(x_prefix(k, h - 1)) } else { None }
    } else if op == PRIMITIVE {
        let index = x_u16(p, bci + 2);
        let a = x_info(p, m).arity as usize;
        if !(h == a && x_info(p, m).kind == 0) { return None; }
        if !((b1 as usize) < c.g.prim_arity.len() && (index as usize) < c.g.prim_arity[b1 as usize].len()
            && c.g.prim_arity[b1 as usize][index as usize] as usize == a) {
            return None;
        }
        if b1 == 0 && index == X_PRIM_TASK_NEW as i64 && a != 1 { return None; }
        if b1 == 0 && index == X_PRIM_TASK_TRANSFER as i64 {
            if a != 2 { return None; }
            proof { assert(kv(*k)[0] == k@[0]@); assert(kv(*k)[1] == k@[1]@); }
            if !(x_is_plain(k[0]) && x_is_plain(k[1]) && x_info(p, m).recv_start == 0xffff) { return None; }
        }
        Some(x_push(k, XKind::Val))
    } else if op == TRY {
        if 1 <= h && x_block_slot(p, c, m as i64, k, (h - 1) as i64) {
            let t = match k[h - 1] { XKind::Method(t) => t, _ => 0 };
            proof { assert(kv(*k)[h - 1] == k@[h - 1]@); assert(kind_method(kv(*k)[h - 1]) == t as int); }
            if x_info(p, t as usize).arity == 1 && x_ctx_ok_upto(p, c, m as i64, k, h - 1) {
                let k1 = x_push(k, XKind::Val);
                let k2 = x_push(&k1, XKind::Token);
                let k3 = x_push(&k2, XKind::Val);
                Some(k3)
            } else { None }
        } else { None }
    } else if op == UNWIND {
        if 3 <= h {
            proof { assert(kv(*k)[h - 2] == k@[h - 2]@); assert(kv(*k)[h - 3] == k@[h - 3]@); }
            if x_is_token(k[h - 2]) && x_is_val(k[h - 3]) {
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
pub fn x_post(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: Option<Vec<XKind>>)
    requires post_pre(p, m, off, k),
    ensures post_rel(r, post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let op = p.bytecodes[x_info(p, m).entry + off];
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

pub open spec fn rev_kinds(r: Seq<XKind>) -> Seq<Kind> {
    Seq::new(r.len(), |j: int| r[r.len() - 1 - j]@)
}

/// The kinds of the list with top node `i` (`chain`), bottom first.
pub fn x_chain(nodes: &Vec<XNode>, i: u32) -> (r: Vec<XKind>)
    ensures kv(r) == chain(nodes@, i as int),
{
    // The kinds from the top down, then reversed.
    let mut rev: Vec<XKind> = Vec::new();
    let mut cur = i as usize;
    let mut done = cur >= nodes.len();
    while !done
        invariant
            done ==> chain(nodes@, i as int) == rev_kinds(rev@),
            !done ==> cur < nodes@.len() && chain(nodes@, i as int) == chain(nodes@, cur as int) + rev_kinds(rev@),
        decreases (if done { 0int } else { cur as int + 1 }),
    {
        let nd = nodes[cur];
        let ghost before = rev@;
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes@, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes@, cur as int) == base.push(nd.kind@));
        rev.push(nd.kind);
        assert(base.push(nd.kind@) + rev_kinds(before) =~= base + rev_kinds(rev@));
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            assert(base + rev_kinds(rev@) =~= rev_kinds(rev@));
            done = true;
        }
    }
    let mut r: Vec<XKind> = Vec::new();
    let mut j = rev.len();
    while j > 0
        invariant 0 <= j <= rev@.len(), kv(r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int),
        decreases j,
    {
        j -= 1;
        let ghost old = kv(r);
        r.push(rev[j]);
        assert(kv(r) =~= old.push(rev@[j as int]@));
        assert(rev_kinds(rev@)[rev@.len() - 1 - j] == rev@[j as int]@);
        assert(kv(r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int));
    }
    assert(kv(r) =~= rev_kinds(rev@));
    r
}

pub proof fn lemma_key(m1: int, o1: int, m2: int, o2: int)
    requires 0 <= o1 < 0x1_0000_0000, 0 <= o2 < 0x1_0000_0000, 0 <= m1, 0 <= m2,
    ensures
        (m1 * 0x1_0000_0000 + o1 == m2 * 0x1_0000_0000 + o2) == (m1 == m2 && o1 == o2),
        (m1 * 0x1_0000_0000 + o1 < m2 * 0x1_0000_0000 + o2) == (m1 < m2 || (m1 == m2 && o1 < o2)),
{
    if m1 < m2 {
        assert(m1 * 0x1_0000_0000 + 0x1_0000_0000 <= m2 * 0x1_0000_0000) by (nonlinear_arith) requires m1 < m2;
    } else if m2 < m1 {
        assert(m2 * 0x1_0000_0000 + 0x1_0000_0000 <= m1 * 0x1_0000_0000) by (nonlinear_arith) requires m2 < m1;
    }
}

pub fn x_pin_key(x: &XPin) -> (r: u64)
    ensures r as int == pin_key(*x),
{
    assert(x.m as int * 0x1_0000_0000 <= 0xffff_ffff * 0x1_0000_0000) by (nonlinear_arith) requires x.m <= 0xffff_ffff;
    (x.m as u64) * 0x1_0000_0000 + x.off as u64
}

/// The pin of method `m` at offset `off`.
pub fn x_pin_find(g: &XGlobal, m: u32, off: u32) -> (r: Option<usize>)
    requires pins_sorted(g),
    ensures
        match r {
            Some(i) => i < g.pins@.len() && g.pins@[i as int].m == m && g.pins@[i as int].off == off
                && pin_view(g, m as int, off as int) == Some(kv(g.pins@[i as int].kinds)),
            None => pin_view(g, m as int, off as int) is None,
        },
{
    assert(m as int * 0x1_0000_0000 <= 0xffff_ffff * 0x1_0000_0000) by (nonlinear_arith) requires m <= 0xffff_ffff;
    let key: u64 = (m as u64) * 0x1_0000_0000 + off as u64;
    let mut lo: usize = 0;
    let mut hi: usize = g.pins.len();
    while lo < hi
        invariant
            0 <= lo <= hi <= g.pins@.len(), pins_sorted(g), key as int == m as int * 0x1_0000_0000 + off as int,
            forall|i: int| 0 <= i < lo ==> pin_key(#[trigger] g.pins@[i]) < key,
            forall|i: int| hi <= i < g.pins@.len() ==> pin_key(#[trigger] g.pins@[i]) > key,
        decreases hi - lo,
    {
        let mid = lo + (hi - lo) / 2;
        let k = x_pin_key(&g.pins[mid]);
        if k == key {
            proof {
                let x = g.pins@[mid as int];
                lemma_key(x.m as int, x.off as int, m as int, off as int);
                assert(has_pin(g, m as int, off as int));
                let j = choose|j: int| 0 <= j < g.pins@.len() && (#[trigger] g.pins@[j]).m == m && g.pins@[j].off == off;
                lemma_key(g.pins@[j].m as int, g.pins@[j].off as int, m as int, off as int);
                if j < mid { assert(pin_key(g.pins@[j]) < pin_key(g.pins@[mid as int])); }
                if j > mid { assert(pin_key(g.pins@[mid as int]) < pin_key(g.pins@[j])); }
            }
            return Some(mid);
        } else if k < key {
            proof {
                assert forall|i: int| 0 <= i < mid + 1 implies pin_key(#[trigger] g.pins@[i]) < key by {
                    if i < mid { assert(pin_key(g.pins@[i]) < pin_key(g.pins@[mid as int])); }
                }
            }
            lo = mid + 1;
        } else {
            proof {
                assert forall|i: int| mid <= i < g.pins@.len() implies pin_key(#[trigger] g.pins@[i]) > key by {
                    if i > mid { assert(pin_key(g.pins@[mid as int]) < pin_key(g.pins@[i])); }
                }
            }
            hi = mid;
        }
    }
    proof {
        if has_pin(g, m as int, off as int) {
            let j = choose|j: int| 0 <= j < g.pins@.len() && (#[trigger] g.pins@[j]).m == m && g.pins@[j].off == off;
            lemma_key(g.pins@[j].m as int, g.pins@[j].off as int, m as int, off as int);
        }
    }
    None
}

pub fn x_map_at(c: &XCert, m: i64, off: i64) -> (r: Option<Vec<XKind>>)
    requires pins_sorted(c.g),
    ensures okv(r) == map_at(c@, m as int, off as int),
{
    let ghost cc = c@;
    if m < 0 || (m as u64) >= (c.g.n as u64) || off < 0 {
        return None;
    }
    assert(cc.maps.len() == c.g.n);
    if c.cur < c.g.n && m as usize == c.cur {
        assert(cc.maps[m as int] == mapsv(c.maps));
        if (off as u64) >= (c.maps.idx.len() as u64) {
            return None;
        }
        assert(cc.maps[m as int][off as int] == map_view(c.maps, off as int));
        let i = c.maps.idx[off as usize];
        if i == NO_MAP {
            None
        } else {
            let k = x_chain(&c.maps.nodes, i);
            assert(map_at(cc, m as int, off as int) == Some(kv(k)));
            Some(k)
        }
    } else {
        assert(cc.maps[m as int] == pin_maps(c.g@)[m as int]);
        if off >= 0x1000_0000 {
            assert(cc.maps[m as int].len() == PIN_SPAN);
            return None;
        }
        if m > 0xffff_ffff {
            // Pins are of methods below 2^32.
            assert(!has_pin(c.g, m as int, off as int));
            return None;
        }
        assert(cc.maps[m as int][off as int] == pin_at(c.g@, m as int, off as int));
        assert(pin_at(c.g@, m as int, off as int) == pin_view(c.g, m as int, off as int));
        match x_pin_find(c.g, m as u32, off as u32) {
            Some(i) => {
                let k = x_copy(&c.g.pins[i].kinds);
                assert(pin_view(c.g, m as int, off as int) == Some(kv(k)));
                assert(cc.maps[m as int][off as int] == Some(kv(k)));
                assert(0 <= off < cc.maps[m as int].len());
                assert(map_at(cc, m as int, off as int) == Some(kv(k)));
                Some(k)
            },
            None => None,
        }
    }
}

pub fn x_map_is(c: &XCert, m: i64, off: i64, k: &Vec<XKind>) -> (r: bool)
    requires pins_sorted(c.g),
    ensures r == (map_at(c@, m as int, off as int) == Some(kv(*k))),
{
    match x_map_at(c, m, off) {
        Some(k2) => x_kinds_eq(&k2, k),
        None => false,
    }
}

#[verifier::loop_isolation(false)]
pub fn x_terminator_ok(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>) -> (r: bool)
    requires
        pins_sorted(c.g),
        wf_program2(vview(p)),
        m < p.methods.len(),
        vinfo(p, m as int).entry + off + opcode_length2(p.bytecodes[vinfo(p, m as int).entry + off]) <= vinfo(p, m as int).end,
        p.bytecodes[vinfo(p, m as int).entry + off] < OPCODE_COUNT2,
    ensures r == terminator_ok(vview(p), c@, m as int, off as int, kv(*k)),
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
        let a = x_info(p, t as usize).arity as usize;
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
        if !(x_info(p, m).kind == 0 && h == x_info(p, m).arity as usize && h >= 1) { return false; }
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
                            proof { assert(kv(t).len() != kv(*fk).subrange(0, n as int).len()); }
                            return false;
                        }
                        let mut i = 0;
                        while i < n
                            invariant n == t.len(), n <= fk.len(), 0 <= i <= n,
                                forall|ii: int| 0 <= ii < i ==> (#[trigger] t@[ii])@ == fk@[ii]@,
                            decreases n - i,
                        {
                            if !x_kind_eq(t[i], fk[i]) {
                                proof { assert(kv(t)[i as int] != kv(*fk).subrange(0, n as int)[i as int]); }
                                return false;
                            }
                            i += 1;
                        }
                        proof { assert(kv(t) =~= kv(*fk).subrange(0, n as int)); }
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

pub fn x_shape_ok(p: &VProgram, c: &XCert, m: usize, k: &Vec<XKind>) -> (r: bool)
    requires m < p.methods.len(),
    ensures r == shape_ok(vview(p), c@, m as int, kv(*k)),
{
    if x_pinned0(p, m) && x_info(p, m).arity >= 1 && k.len() < 1 { return false; }
    if x_info(p, m).kind == 3 {
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

pub fn x_instr_ok(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> (r: bool)
    requires wf_program2(vview(p)), m < p.methods.len(), pins_sorted(c.g),
    ensures r == instr_ok(vview(p), c@, m as int, off as int, kv(*k), trusted),
{
    let i = x_info(p, m);
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

pub fn x_entry_kinds(p: &VProgram, c: &XCert, m: usize) -> (r: Vec<XKind>)
    requires m < p.methods.len(),
    ensures kv(r) == entry_kinds(vview(p), c@, m as int),
{
    let a = x_info(p, m).arity as usize;
    let ghost e = entry_kinds(vview(p), c@, m as int);
    let mut r: Vec<XKind> = Vec::new();
    let mut i = 0;
    while i < a
        invariant m < p.methods.len(), a == vinfo(p, m as int).arity, e == entry_kinds(vview(p), c@, m as int),
            0 <= i <= a, r.len() == i, forall|ii: int| 0 <= ii < i ==> #[trigger] kv(r)[ii] == e[ii],
        decreases a - i,
    {
        let ghost before = r@;
        let ghost before_k = kv(r);
        if x_info(p, m).kind == 3 {
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
pub fn x_method_body_ok(p: &VProgram, c: &XCert, m: usize, trusted: bool) -> (r: bool)
    requires wf_program2(vview(p)), m < p.methods.len(), m == c.cur, c.cur < c.g.n, pins_sorted(c.g),
    ensures r == forall|o: int| 0 <= o < c@.maps[m as int].len() && (#[trigger] c@.maps[m as int][o]) is Some ==>
        instr_ok(vview(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
{
    let ghost cm = c@.maps[m as int];
    assert(cm == mapsv(c.maps));
    let mut off = 0;
    while off < c.maps.idx.len()
        invariant
            wf_program2(vview(p)), m < p.methods.len(), m == c.cur, c.cur < c.g.n, pins_sorted(c.g),
            cm == c@.maps[m as int], cm == mapsv(c.maps),
            0 <= off <= c.maps.idx@.len(),
            forall|o: int| 0 <= o < off && (#[trigger] c@.maps[m as int][o]) is Some ==>
                instr_ok(vview(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
        decreases c.maps.idx@.len() - off,
    {
        let i = c.maps.idx[off];
        if i != NO_MAP {
            let k = x_chain(&c.maps.nodes, i);
            assert(cm[off as int] == Some(kv(k)));
            if !x_instr_ok(p, c, m, off, &k, trusted) {
                return false;
            }
        }
        off += 1;
    }
    true
}

pub fn x_method_ok(p: &VProgram, c: &XCert, m: usize, trusted: bool) -> (r: bool)
    requires
        wf_program2(vview(p)), m < p.methods.len(), c.g.n == p.methods.len(), m == c.cur, pins_sorted(c.g),
    ensures r == method_ok(vview(p), c@, m as int, trusted),
{
    let ghost cc = c@;
    assert(cc.maps[m as int] == mapsv(c.maps));
    let i = x_info(p, m);
    if !(i.entry < i.end && i.end <= p.bytecodes.len()) { return false; }
    if c.maps.idx.len() != i.end - i.entry { return false; }
    if x_bp_len(c, m) != i.arity as usize { return false; }
    let ctx = x_ctx_of(c, m);
    assert(cc.contexts[m as int] == ctx_of(cc, m as int));
    if ctx.is_some() && i.kind != 3 { return false; }
    if i.kind == 3 && ctx.is_none() { return true; }
    let e = x_entry_kinds(p, c, m);
    if !x_map_is(c, m as i64, 0, &e) { return false; }
    x_method_body_ok(p, c, m, trusted)
}

// ---------------------------------------------------------------------------
// Tables.

pub fn x_machine_class_ok(p: &VProgram, k: usize) -> (r: bool)
    requires k < p.builtin.len(),
    ensures r == machine_class_ok(vview(p), k as int),
{
    let cl = p.builtin[k] as i64;
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && !(x_is_field_class(p, cl) && x_ifc(p, cl as usize) >= 1)
}

pub fn x_entry_method(p: &VProgram, k: usize) -> (r: i64)
    requires k < p.entry_points.len(),
    ensures r as int == entry_method(vview(p), k as int),
{
    let d = p.entry_points[k] as i64;
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { p.dispatch[d as usize] as i64 } else { -1 }
}

pub fn x_entry_ok(p: &VProgram, c: &XCert, k: usize, a: u8) -> (r: bool)
    requires k < p.entry_points.len(), c.g.n == p.methods.len(),
    ensures r == entry_ok(vview(p), c@, k as int, a as int),
{
    let e = x_entry_method(p, k);
    x_valid(p, e) && x_info(p, e as usize).kind == 0 && x_info(p, e as usize).arity == a
        && x_no_block_params(c, e as usize)
}

pub fn x_dispatch_entry_ok(p: &VProgram, d: usize) -> (r: bool)
    requires d < p.dispatch.len(), p.dispatch.len() < 0x1000_0000,
    ensures r == dispatch_entry_ok(vview(p), d as int),
{
    let t = p.dispatch[d] as i64;
    if t == -1 { return true; }
    if !x_valid(p, t) { return false; }
    let i = x_info(p, t as usize);
    if !(i.kind == 0 || i.kind == 1) { return false; }
    let cl = d as i64 - i.selector as i64;
    if i.selector != 0xffff && 0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && i.recv_start != 0xffff {
        i.recv_start as i64 <= cl && cl < i.recv_end as i64
    } else {
        true
    }
}

pub fn x_method_table_ok(p: &VProgram, c: &XCert, m: usize) -> (r: bool)
    requires m < p.methods.len(), c.g.n == p.methods.len(),
    ensures r == method_table_ok(vview(p), c@, m as int),
{
    let ghost cc = c@;
    let i = x_info(p, m);
    let s = i.selector as usize;
    if x_bp_len(c, m) != i.arity as usize { return false; }
    if i.selector != 0xffff {
        let r = x_sel_rep(c, s);
        if !(x_valid(p, r) && x_info(p, r as usize).arity == i.arity
            && x_bp_eq(c, r as usize, m)
            && x_row_fits(p, s)) {
            return false;
        }
    }
    if i.recv_start != 0xffff && !(i.arity >= 1 && !x_is_block_param(c, m, 0)) { return false; }
    if i.kind == 3 && !(i.arity >= 1 && x_no_block_params(c, m)) { return false; }
    if i.kind == 2 && !x_no_block_params(c, m) { return false; }
    assert(cc.contexts[m as int] == ctx_of(cc, m as int));
    match x_ctx_of(c, m) {
        Some(ctx) => x_valid(p, ctx.outer as i64),
        None => true,
    }
}

pub fn x_tables_ok(p: &VProgram, c: &XCert) -> (r: bool)
    requires wf_program2(vview(p)), c.cur >= c.g.n, pins_sorted(c.g),
    ensures r == tables_ok(vview(p), c@),
{
    let ghost pv = vview(p);
    let ghost cc = c@;
    let n = p.methods.len();
    if c.g.n != n { return false; }
    let lim = if c.g.sel_rep.len() < 0xffff { c.g.sel_rep.len() } else { 0xffff };
    let mut s = 0;
    while s < lim
        invariant 0 <= s <= lim, lim <= 0xffff, lim <= c.g.sel_rep@.len(), cc == c@, pv == vview(p),
            lim == 0xffff || lim == c.g.sel_rep@.len(),
            forall|ss: int| 0 <= ss < s ==> #[trigger] sel_rep_ok(pv, cc, ss),
        decreases lim - s,
    {
        let r = c.g.sel_rep[s] as i64;
        if !(r == -1 || (x_valid(p, r) && x_info(p, r as usize).selector as usize == s)) {
            proof { assert(!sel_rep_ok(pv, cc, s as int)); }
            return false;
        }
        s += 1;
    }
    proof {
        assert forall|ss: int| 0 <= ss < cc.sel_rep.len() implies #[trigger] sel_rep_ok(pv, cc, ss) by {
            if ss >= lim { assert(cc.sel_rep[ss] == -1); }
        }
    }
    let mut d = 0;
    while d < p.dispatch.len()
        invariant wf_program2(pv), pv == vview(p), 0 <= d <= p.dispatch.len(),
            forall|dd: int| 0 <= dd < d ==> #[trigger] dispatch_entry_ok(pv, dd),
        decreases p.dispatch.len() - d,
    {
        if !x_dispatch_entry_ok(p, d) { return false; }
        d += 1;
    }
    let mut m = 0;
    while m < n
        invariant n == p.methods.len(), c.g.n == n, 0 <= m <= n, pv == vview(p), cc == c@,
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_table_ok(pv, cc, mm),
        decreases n - m,
    {
        if !x_method_table_ok(p, c, m) { return false; }
        m += 1;
    }
    let mut k = 0;
    while k < p.interface_check_offsets.len()
        invariant 0 <= k <= p.interface_check_offsets.len(), pv == vview(p),
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
    if !x_task_class_ok(p) { return false; }
    if !x_entry_ok(p, c, 0, 1) { return false; }
    if x_info(p, x_entry_method(p, 0) as usize).recv_start != 0xffff { return false; }
    if !x_entry_ok(p, c, 2, 1) { return false; }
    if x_info(p, x_entry_method(p, 2) as usize).recv_start != 0xffff { return false; }
    let mut two: Vec<XKind> = Vec::new();
    two.push(XKind::Val);
    two.push(XKind::Val);
    proof { assert(kv(two) =~= seq![Kind::Val, Kind::Val]); }
    if !x_map_is(c, x_entry_method(p, 2), 1, &two) { return false; }
    x_entry_ok(p, c, 8, 2)
}

pub fn x_wf_program2(p: &VProgram) -> (r: bool)
    ensures r == wf_program2(vview(p)),
{
    let ghost pv = vview(p);
    if !(p.word_bits == 32 || p.word_bits == 64) { return false; }
    if !(p.bytecodes.len() < 0x1000_0000 && p.methods.len() < 0x1000_0000 && p.dispatch.len() < 0x1000_0000) {
        return false;
    }
    let mut m = 0;
    while m < p.methods.len()
        invariant 0 <= m <= p.methods.len(), pv == vview(p),
            forall|mm: int| 0 <= mm < m ==> #[trigger] pv.methods[mm].entry <= pv.methods[mm].end <= pv.bytecodes.len(),
        decreases p.methods.len() - m,
    {
        let i = x_info(p, m);
        if !(i.entry <= i.end && i.end <= p.bytecodes.len()) { return false; }
        m += 1;
    }
    p.roots.len() == 35 && p.invoke_offsets.len() == 19 && p.builtin.len() == 23 && p.entry_points.len() == 9
        && p.literals.len() >= 7
}

// ---------------------------------------------------------------------------
// The streaming verifier.

/// The pins are strictly sorted.
pub fn x_pins_sorted(g: &XGlobal) -> (r: bool)
    ensures r == pins_sorted(g),
{
    let mut i = 1;
    if g.pins.len() == 0 { return true; }
    while i < g.pins.len()
        invariant 1 <= i <= g.pins@.len(),
            forall|a: int, b: int| 0 <= a < b < i ==> pin_key(#[trigger] g.pins@[a]) < pin_key(#[trigger] g.pins@[b]),
        decreases g.pins@.len() - i,
    {
        if x_pin_key(&g.pins[i - 1]) >= x_pin_key(&g.pins[i]) {
            return false;
        }
        proof {
            assert forall|a: int, b: int| 0 <= a < b < i + 1 implies pin_key(#[trigger] g.pins@[a]) < pin_key(#[trigger] g.pins@[b]) by {
                if b == i && a < i - 1 {
                    assert(pin_key(g.pins@[a]) < pin_key(g.pins@[i - 1]));
                }
            }
        }
        i += 1;
    }
    true
}

/// Computes the maps of a method for the checker (`v2::infer`, untrusted:
/// the checker decides whatever it returns).
pub trait MapOracle {
    fn method_maps(&mut self, m: usize) -> XMaps;
}

/// The pins of method `m` (from `pins[at]` on, where the pins of the
/// methods below `m` end) agree with its maps. Returns where the pins of
/// `m` end, or `None` if one disagrees.
pub fn x_pins_agree(g: &XGlobal, m: usize, maps: &XMaps, at: usize) -> (r: Option<usize>)
    requires
        pins_sorted(g), at <= g.pins@.len(),
        forall|i: int| at <= i < g.pins@.len() ==> (#[trigger] g.pins@[i]).m >= m,
    ensures
        match r {
            Some(e) => at <= e <= g.pins@.len()
                && (forall|i: int| e <= i < g.pins@.len() ==> (#[trigger] g.pins@[i]).m > m)
                && (forall|i: int| at <= i < e ==> (#[trigger] g.pins@[i]).m == m && (g.pins@[i].off as int) < maps.idx@.len()
                        && mapsv(maps)[g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds))),
            None => exists|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m
                && !((g.pins@[i].off as int) < maps.idx@.len() && mapsv(maps)[g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds))),
        },
{
    let mut i = at;
    while i < g.pins.len() && g.pins[i].m as usize == m
        invariant
            pins_sorted(g), at <= i <= g.pins@.len(),
            forall|j: int| at <= j < g.pins@.len() ==> (#[trigger] g.pins@[j]).m >= m,
            forall|j: int| at <= j < i ==> (#[trigger] g.pins@[j]).m == m && (g.pins@[j].off as int) < maps.idx@.len()
                && mapsv(maps)[g.pins@[j].off as int] == Some(kv(g.pins@[j].kinds)),
        decreases g.pins@.len() - i,
    {
        let x = &g.pins[i];
        if (x.off as usize) >= maps.idx.len() {
            return None;
        }
        let top = maps.idx[x.off as usize];
        if top == NO_MAP {
            return None;
        }
        let k = x_chain(&maps.nodes, top);
        if !x_kinds_eq(&k, &x.kinds) {
            return None;
        }
        i += 1;
    }
    proof {
        assert forall|j: int| i <= j < g.pins@.len() implies (#[trigger] g.pins@[j]).m > m by {
            if j > i {
                lemma_key(g.pins@[i as int].m as int, g.pins@[i as int].off as int, g.pins@[j].m as int, g.pins@[j].off as int);
                assert(pin_key(g.pins@[i as int]) < pin_key(g.pins@[j]));
            }
        }
    }
    Some(i)
}

/// The structural verifier, one method at a time: the global part of the
/// certificate is `g`, the maps of each method come from `o` and are
/// dropped after the method is checked. Returns exactly whether the pins
/// are sorted and `split_ok` holds for the maps it was given (`ms`); by
/// `v2::split`, `split_ok` implies `accepts` of the assembled certificate,
/// and an accepted certificate always splits.
pub fn verify<O: MapOracle>(p: &VProgram, g: &XGlobal, o: &mut O, trusted: bool) -> (r: (bool, Ghost<Seq<Maps>>))
    ensures r.0 == (pins_sorted(g) && split_ok(vview(p), g@, r.1@, trusted)),
{
    let ghost pv = vview(p);
    let ghost pad = Seq::new(g.n as nat, |m: int| Seq::<Option<Seq<Kind>>>::empty());
    if !x_wf_program2(p) { return (false, Ghost(pad)); }
    if g.n != p.methods.len() { return (false, Ghost(pad)); }
    if !x_pins_sorted(g) { return (false, Ghost(pad)); }
    let empty = XMaps { idx: Vec::new(), nodes: Vec::new() };
    let tc = XCert { g, cur: g.n, maps: &empty };
    if !x_tables_ok(p, &tc) { return (false, Ghost(pad)); }
    let n = p.methods.len();
    let ghost mut ms: Seq<Maps> = Seq::empty();
    let mut at: usize = 0;
    let mut m: usize = 0;
    while m < n
        invariant
            pv == vview(p), wf_program2(pv), n == p.methods.len(), g.n == n, n < 0x1000_0000, pins_sorted(g),
            tables_ok(pv, tables_cert(g@)),
            0 <= m <= n, ms.len() == m, at <= g.pins@.len(),
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_ok(pv, local_cert(g@, mm, ms[mm]), mm, trusted),
            forall|i: int| 0 <= i < at ==> (#[trigger] g.pins@[i]).m < m && (g.pins@[i].off as int) < ms[g.pins@[i].m as int].len()
                && ms[g.pins@[i].m as int][g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds)),
            forall|i: int| at <= i < g.pins@.len() ==> (#[trigger] g.pins@[i]).m >= m,
        decreases n - m,
    {
        let maps = o.method_maps(m);
        let c = XCert { g, cur: m, maps: &maps };
        let ghost mm = mapsv(&maps);
        let ghost ms2 = ms.push(mm) + Seq::new((n - m - 1) as nat, |i: int| Seq::<Option<Seq<Kind>>>::empty());
        assert(ms2.len() == n);
        assert(ms2[m as int] == mm);
        if !x_method_ok(p, &c, m, trusted) {
            assert(!method_ok(pv, local_cert(g@, m as int, ms2[m as int]), m as int, trusted));
            return (false, Ghost(ms2));
        }
        match x_pins_agree(g, m, &maps, at) {
            None => {
                proof {
                    let i = choose|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m
                        && !((g.pins@[i].off as int) < maps.idx@.len() && mapsv(&maps)[g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds)));
                    lemma_pin_agree_witness(g, i, ms2);
                }
                return (false, Ghost(ms2));
            },
            Some(e) => {
                proof {
                    ms = ms.push(mm);
                    assert forall|i: int| 0 <= i < e implies (#[trigger] g.pins@[i]).m < m + 1 && (g.pins@[i].off as int) < ms[g.pins@[i].m as int].len()
                        && ms[g.pins@[i].m as int][g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds)) by {
                        if i >= at { assert(g.pins@[i].m == m); }
                    }
                }
                at = e;
            },
        }
        m += 1;
    }
    if at < g.pins.len() {
        // A pin of a method that does not exist.
        proof {
            lemma_pin_unique(g, at as int);
            let x = g.pins@[at as int];
            assert(pin_at(g@, x.m as int, x.off as int) is Some);
        }
        return (false, Ghost(ms));
    }
    proof {
        let gv = g@;
        assert forall|m2: int, o2: int| #[trigger] pin_at(gv, m2, o2) is Some implies
            0 <= m2 < ms.len() && 0 <= o2 < ms[m2].len() && ms[m2][o2] == pin_at(gv, m2, o2) by {
            let i = choose|i: int| 0 <= i < g.pins@.len() && (#[trigger] g.pins@[i]).m == m2 && g.pins@[i].off == o2;
            lemma_pin_unique(g, i);
            if i >= at { assert(g.pins@[i].m >= n); }
        }
    }
    (true, Ghost(ms))
}

/// With sorted pins, the pin view at a pin's key is that pin.
pub proof fn lemma_pin_unique(g: &XGlobal, i: int)
    requires pins_sorted(g), 0 <= i < g.pins@.len(),
    ensures pin_view(g, g.pins@[i].m as int, g.pins@[i].off as int) == Some(kv(g.pins@[i].kinds)),
{
    let x = g.pins@[i];
    assert(has_pin(g, x.m as int, x.off as int));
    let j = choose|j: int| 0 <= j < g.pins@.len() && (#[trigger] g.pins@[j]).m == x.m && g.pins@[j].off == x.off;
    lemma_key(g.pins@[j].m as int, g.pins@[j].off as int, x.m as int, x.off as int);
    if j < i { assert(pin_key(g.pins@[j]) < pin_key(g.pins@[i])); }
    if j > i { assert(pin_key(g.pins@[i]) < pin_key(g.pins@[j])); }
}

/// A pin of method `m` that disagrees with `ms[m]` breaks `pins_agree`.
pub proof fn lemma_pin_agree_witness(g: &XGlobal, i: int, ms: Seq<Maps>)
    requires
        pins_sorted(g), 0 <= i < g.pins@.len(), (g.pins@[i].m as int) < ms.len(),
        !((g.pins@[i].off as int) < ms[g.pins@[i].m as int].len()
            && ms[g.pins@[i].m as int][g.pins@[i].off as int] == Some(kv(g.pins@[i].kinds))),
    ensures !pins_agree(g@, ms),
{
    lemma_pin_unique(g, i);
    let x = g.pins@[i];
    assert(pin_at(g@, x.m as int, x.off as int) == Some(kv(x.kinds)));
}


} // verus!

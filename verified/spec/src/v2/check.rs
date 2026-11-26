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

//! The executable structural verifier, one method at a time:
//! `verify(p, g, oracle, trusted)` is proven to return exactly
//! `pins_sorted(g) && split_ok(vview(p), g@, ms, trusted)` for the maps
//! `ms` the oracle yields (zero `assume`/`admit`); `v2::split` proves that
//! `split_ok` implies `accepts` of the assembled certificate and that
//! every accepted certificate splits.
//!
//! The program is borrowed (`v2::vprog::VProgram`). The certificate's
//! global part (`XGlobal`: block-parameter masks, contexts, selector
//! representatives, pins) is small; the maps of one method at a time come
//! from a `MapOracle` (`v2::infer`, untrusted) as lists of kinds sharing
//! their bottoms (`XMaps`), and are dropped after the method. The checker
//! does not recurse and allocates only the kinds of the instruction it
//! checks and of its successors.
//!
//! `x_post` is exact except for one corner: a LOAD_OUTER whose depth sum
//! does not fit a u32 yields a kind no certificate can hold; `x_post` then
//! returns `None` (`post_rel`), and `x_instr_ok` still agrees with
//! `instr_ok` because no map can equal such a successor.
//!
//! No panic paths (devices: verified/vmverify/README.md, "No panics on
//! devices"): elements are read through `crate::xvec`'s accessors (the
//! index is a proven precondition), and the functions that allocate return
//! `Result<_, Oom>`: `Err(Oom)` when an allocation failed, otherwise the
//! exact result above. `verify` passes `Oom` up; the verdict rejects.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::xvec::*;
pub use crate::cvec::CVec;
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

/// The global part of the certificate (`v2::split::GCert`) as byte tables
/// (format/18-shipped-certificate.md): borrowed, so that a shipped
/// certificate is read in place (memory-mapped flash) and the inference
/// can hand its own buffers. Numbers are 32-bit little endian; every read
/// is total (`rd`: 0 outside the table), so any bytes have a meaning.
pub struct XGlobal<'a> {
    /// The number of methods.
    pub n: usize,
    /// The method table: the length of method `m`'s block-parameter mask
    /// is its arity.
    pub methods: MTable<'a>,
    /// A word per method: for a block method (kind 3) its context (0 is
    /// none, `j + 1` is record `j` of `crec`; blocks have no block
    /// parameters); for other methods the block-parameter mask (bit `i`,
    /// below 32, is parameter `i`; they have no context).
    pub mw: &'a [u8],
    /// Context records (12 bytes): outer method, slot, top node of the kinds.
    pub crec: &'a [u8],
    /// Selector representatives (8 bytes): selector, method; strictly
    /// sorted by selector. Selectors without a record have none (-1).
    pub sel: &'a [u8],
    /// Pinned maps (12 bytes): method, offset, top node of the kinds;
    /// strictly sorted by (method, offset).
    pub pins: &'a [u8],
    /// Kind nodes (12 bytes): parent, kind word, operand (`dk`); lists of
    /// kinds share their bottoms like the maps (`chain`).
    pub nodes: &'a [u8],
    /// Trusted: the number of globals and the VM's primitive table.
    pub global_count: u64,
    pub prim_arity: &'a [Vec<u8>],
}

/// The head of a context: the kinds are the list of node `top`.
#[derive(Clone, Copy)]
pub struct XCtx {
    pub outer: u32,
    pub slot: u32,
    pub top: u32,
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
/// map at offset `off`. In chunks (`CVec`): a large method's maps need no
/// contiguous block of their size.
pub struct XMaps {
    pub idx: CVec<u32>,
    pub nodes: CVec<XNode>,
}

/// The certificate a method is checked against: the global part, and the
/// maps of method `cur` (`cur >= g.n`: the tables, pins only).
pub struct XCert<'a> {
    pub g: &'a XGlobal<'a>,
    pub cur: usize,
    pub maps: &'a XMaps,
}

pub open spec fn kv(k: Vec<XKind>) -> Seq<Kind> {
    k@.map_values(|x: XKind| x@)
}

pub open spec fn okv(o: Option<Vec<XKind>>) -> Option<Seq<Kind>> {
    match o { Some(k) => Some(kv(k)), None => None }
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

// ---------------------------------------------------------------------------
// Byte tables.

/// The 32-bit little-endian word at byte `i` of `s`, 0 if out of range.
pub open spec fn rd(s: Seq<u8>, i: int) -> u32 {
    if 0 <= i && i + 4 <= s.len() {
        (s[i] as u32) | ((s[i + 1] as u32) << 8u32) | ((s[i + 2] as u32) << 16u32) | ((s[i + 3] as u32) << 24u32)
    } else {
        0
    }
}

pub fn x_rd(s: &[u8], i: usize) -> (r: u32)
    ensures r == rd(s@, i as int),
{
    let l = s.len();
    if i <= l && l - i >= 4 {
        (ix(s, i) as u32) | ((ix(s, i + 1) as u32) << 8u32) | ((ix(s, i + 2) as u32) << 16u32) | ((ix(s, i + 3) as u32) << 24u32)
    } else {
        0
    }
}

/// The word at byte `f` of record `i` of a table of `w`-byte records.
pub open spec fn fld(s: Seq<u8>, w: int, i: int, f: int) -> u32 {
    rd(s, i * w + f)
}

pub fn x_fld(s: &[u8], w: usize, i: usize, f: usize) -> (r: u32)
    ensures r == fld(s@, w as int, i as int, f as int),
{
    let l = s.len();
    match i.checked_mul(w) {
        Some(b) => match b.checked_add(f) {
            Some(o) => x_rd(s, o),
            None => 0,
        },
        None => {
            assert(i as int * w as int + f as int > l) by (nonlinear_arith)
                requires i as int * w as int > usize::MAX, l <= usize::MAX, f >= 0;
            0
        },
    }
}

/// The kind a node holds: the kind word's low 3 bits are the tag (0 value,
/// 1 block parameter, 2 token, 3 method `b`, 4 block of depth `a >> 3` and
/// slot `b`; others: value).
pub open spec fn dk(a: u32, b: u32) -> XKind {
    let t = a & 7u32;
    if t == 1 { XKind::Param }
    else if t == 2 { XKind::Token }
    else if t == 3 { XKind::Method(b) }
    else if t == 4 { XKind::Block(a >> 3u32, b) }
    else { XKind::Val }
}

pub fn x_dk(a: u32, b: u32) -> (r: XKind)
    ensures r == dk(a, b),
{
    let t = a & 7u32;
    if t == 1 { XKind::Param }
    else if t == 2 { XKind::Token }
    else if t == 3 { XKind::Method(b) }
    else if t == 4 { XKind::Block(a >> 3u32, b) }
    else { XKind::Val }
}

pub open spec fn fnode(s: Seq<u8>, i: int) -> XNode {
    XNode { parent: fld(s, 12, i, 0), kind: dk(fld(s, 12, i, 4), fld(s, 12, i, 8)) }
}

/// The nodes of a node table.
pub open spec fn fnodes(s: Seq<u8>) -> Seq<XNode> {
    Seq::new((s.len() / 12) as nat, |i: int| fnode(s, i))
}

/// The kinds of the list with top node `i` of a node table.
pub open spec fn fchain(s: Seq<u8>, i: int) -> Seq<Kind> {
    chain(fnodes(s), i)
}

pub fn x_fnode(s: &[u8], i: usize) -> (r: XNode)
    ensures i < s@.len() / 12 ==> r == fnodes(s@)[i as int],
{
    XNode { parent: x_fld(s, 12, i, 0), kind: x_dk(x_fld(s, 12, i, 4), x_fld(s, 12, i, 8)) }
}

// ---------------------------------------------------------------------------
// Views of the global part.

pub open spec fn bit(x: u32, i: int) -> bool {
    0 <= i < 32 && ((x >> (i as u32)) & 1u32) == 1u32
}

pub fn x_bit(x: u32, i: usize) -> (r: bool)
    ensures r == bit(x, i as int),
{
    i < 32 && ((x >> (i as u32)) & 1u32) == 1u32
}

pub open spec fn is_block_m(g: &XGlobal, m: int) -> bool {
    0 <= m < g.methods@.len() && g.methods@[m].kind == 3
}

/// The block-parameter mask of method `m`.
pub open spec fn bp_mask(g: &XGlobal, m: int) -> u32 {
    if is_block_m(g, m) { 0 } else { fld(g.mw@, 4, m, 0) }
}

pub fn x_bp_mask(g: &XGlobal, m: usize) -> (r: u32)
    ensures r == bp_mask(g, m as int),
{
    if m < g.methods.len() && g.methods.kind(m) == 3 { 0 } else { x_fld(g.mw, 4, m, 0) }
}

pub open spec fn bp_view(g: &XGlobal, m: int) -> Seq<bool> {
    if 0 <= m < g.methods@.len() {
        Seq::new(g.methods@[m].arity as nat, |i: int| bit(bp_mask(g, m), i))
    } else {
        Seq::empty()
    }
}

pub open spec fn ncrec(g: &XGlobal) -> int {
    (g.crec@.len() / 12) as int
}

/// The context record of method `t` plus one (0: none).
pub open spec fn ctx_word(g: &XGlobal, t: int) -> u32 {
    fld(g.mw@, 4, t, 0)
}

pub open spec fn has_ctx(g: &XGlobal, t: int) -> bool {
    is_block_m(g, t) && 1 <= ctx_word(g, t) && ctx_word(g, t) - 1 < ncrec(g)
}

pub open spec fn xctx_view(g: &XGlobal, h: XCtx) -> Context {
    Context { outer: h.outer as int, slot: h.slot as int, kinds: fchain(g.nodes@, h.top as int) }
}

pub open spec fn ctx_head(g: &XGlobal, t: int) -> XCtx {
    let j = ctx_word(g, t) - 1;
    XCtx { outer: fld(g.crec@, 12, j, 0), slot: fld(g.crec@, 12, j, 4), top: fld(g.crec@, 12, j, 8) }
}

pub open spec fn ctx_view(g: &XGlobal, t: int) -> Option<Context> {
    if has_ctx(g, t) { Some(xctx_view(g, ctx_head(g, t))) } else { None }
}

pub open spec fn nsel(g: &XGlobal) -> int {
    (g.sel@.len() / 8) as int
}

pub open spec fn sel_key(g: &XGlobal, j: int) -> u32 {
    fld(g.sel@, 8, j, 0)
}

pub open spec fn sel_val(g: &XGlobal, j: int) -> u32 {
    fld(g.sel@, 8, j, 4)
}

pub open spec fn has_sel(g: &XGlobal, s: int) -> bool {
    exists|j: int| 0 <= j < nsel(g) && #[trigger] sel_key(g, j) == s
}

pub open spec fn sel_view(g: &XGlobal, s: int) -> int {
    if has_sel(g, s) {
        let j = choose|j: int| 0 <= j < nsel(g) && #[trigger] sel_key(g, j) == s;
        sel_val(g, j) as int
    } else {
        -1
    }
}

/// The selector records are strictly sorted.
pub open spec fn sel_sorted(g: &XGlobal) -> bool {
    forall|i: int, j: int| 0 <= i < j < nsel(g) ==> #[trigger] sel_key(g, i) < #[trigger] sel_key(g, j)
}

pub open spec fn npins(g: &XGlobal) -> int {
    (g.pins@.len() / 12) as int
}

pub open spec fn pin_m(g: &XGlobal, i: int) -> u32 {
    fld(g.pins@, 12, i, 0)
}

pub open spec fn pin_off(g: &XGlobal, i: int) -> u32 {
    fld(g.pins@, 12, i, 4)
}

pub open spec fn pin_top(g: &XGlobal, i: int) -> u32 {
    fld(g.pins@, 12, i, 8)
}

pub open spec fn pin_kinds(g: &XGlobal, i: int) -> Seq<Kind> {
    fchain(g.nodes@, pin_top(g, i) as int)
}

pub open spec fn pin_key(g: &XGlobal, i: int) -> int {
    pin_m(g, i) as int * 0x1_0000_0000 + pin_off(g, i) as int
}

pub open spec fn has_pin(g: &XGlobal, m: int, o: int) -> bool {
    exists|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && pin_off(g, i) == o
}

pub open spec fn pin_view(g: &XGlobal, m: int, o: int) -> Option<Seq<Kind>> {
    if has_pin(g, m, o) {
        let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && pin_off(g, i) == o;
        Some(pin_kinds(g, i))
    } else {
        None
    }
}

/// The pins are strictly sorted by (method, offset).
pub open spec fn pins_sorted(g: &XGlobal) -> bool {
    forall|i: int, j: int| 0 <= i < j < npins(g) ==> #[trigger] pin_key(g, i) < #[trigger] pin_key(g, j)
}

/// The sorted tables are sorted (the lookups need it).
pub open spec fn g_ok(g: &XGlobal) -> bool {
    sel_sorted(g) && pins_sorted(g)
}

impl<'a> View for XGlobal<'a> {
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
            let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && pin_off(g, i) == o;
            lemma_chain_repr(fnodes(g.nodes@), pin_top(g, i) as int);
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

/// `post_rel` for `x_post_into`: `b` tells whether the successor is in the
/// buffer `out`.
pub open spec fn post_rel_into(b: bool, out: Vec<XKind>, o: Option<Seq<Kind>>) -> bool {
    if b { o == Some(kv(out)) } else { o is None || !representable(o->0) }
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
        if !x_kind_eq(vix(a, i), vix(b, i)) {
            proof { assert(kv(*a)[i as int] != kv(*b)[i as int]); }
            return false;
        }
        i += 1;
    }
    proof { assert(kv(*a) =~= kv(*b)); }
    true
}

/// The first `n` kinds of `k`, with room for `extra` more.
pub fn x_prefix_room(k: &Vec<XKind>, n: usize, extra: usize) -> (res: Result<Vec<XKind>, Oom>)
    requires n <= k.len(),
    ensures res matches Ok(r) ==> r@ == k@.subrange(0, n as int),
{
    let mut r: Vec<XKind> = try_with_capacity(if extra <= usize::MAX - n { n + extra } else { n })?;
    let mut i = 0;
    while i < n
        invariant n <= k.len(), 0 <= i <= n, r@ == k@.subrange(0, i as int),
        decreases n - i,
    {
        try_push(&mut r, vix(k, i))?;
        proof { assert(r@ =~= k@.subrange(0, i + 1)); }
        i += 1;
    }
    Ok(r)
}

pub fn x_copy(k: &Vec<XKind>) -> (res: Result<Vec<XKind>, Oom>)
    ensures res matches Ok(r) ==> r@ == k@ && kv(r) == kv(*k),
{
    let r = x_prefix_room(k, k.len(), 0)?;
    proof { assert(r@ =~= k@); }
    Ok(r)
}

pub fn x_push(k: &Vec<XKind>, v: XKind) -> (res: Result<Vec<XKind>, Oom>)
    ensures res matches Ok(r) ==> kv(r) == kv(*k).push(v@),
{
    let mut r = x_prefix_room(k, k.len(), 1)?;
    proof { assert(r@ =~= k@); }
    try_push(&mut r, v)?;
    proof { assert(kv(r) =~= kv(*k).push(v@)); }
    Ok(r)
}

pub fn x_prefix(k: &Vec<XKind>, n: usize) -> (res: Result<Vec<XKind>, Oom>)
    requires n <= k.len(),
    ensures res matches Ok(r) ==> kv(r) == kv(*k).subrange(0, n as int),
{
    let r = x_prefix_room(k, n, 0)?;
    proof { assert(kv(r) =~= kv(*k).subrange(0, n as int)); }
    Ok(r)
}

pub fn x_update(k: &Vec<XKind>, i: usize, v: XKind) -> (res: Result<Vec<XKind>, Oom>)
    requires i < k.len(),
    ensures res matches Ok(r) ==> kv(r) == kv(*k).update(i as int, v@),
{
    let mut r = x_copy(k)?;
    vput(&mut r, i, v);
    proof { assert(kv(r) =~= kv(*k).update(i as int, v@)); }
    Ok(r)
}

// The same operations into a buffer that the caller keeps (cleared and
// refilled: no allocation once it has grown), for `x_post_into`.

/// `out` becomes the first `n` kinds of `k`.
pub fn x_prefix_into(k: &Vec<XKind>, n: usize, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    requires n <= k.len(),
    ensures res is Ok ==> final(out)@ == k@.subrange(0, n as int) && kv(*final(out)) == kv(*k).subrange(0, n as int),
{
    out.clear();
    proof { assert(out@ =~= k@.subrange(0, 0)); }
    let mut i = 0;
    while i < n
        invariant n <= k.len(), 0 <= i <= n, out@ == k@.subrange(0, i as int),
        decreases n - i,
    {
        try_push(out, vix(k, i))?;
        proof { assert(out@ =~= k@.subrange(0, i + 1)); }
        i += 1;
    }
    proof { assert(kv(*out) =~= kv(*k).subrange(0, n as int)); }
    Ok(())
}

/// `out` becomes a copy of `k`.
pub fn x_copy_into(k: &Vec<XKind>, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    ensures res is Ok ==> final(out)@ == k@ && kv(*final(out)) == kv(*k),
{
    x_prefix_into(k, k.len(), out)?;
    proof { assert(out@ =~= k@); assert(kv(*out) =~= kv(*k)); }
    Ok(())
}

/// `out` becomes `k` with `v` pushed.
pub fn x_push_into(k: &Vec<XKind>, v: XKind, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    ensures res is Ok ==> kv(*final(out)) == kv(*k).push(v@),
{
    x_copy_into(k, out)?;
    try_push(out, v)?;
    proof { assert(kv(*out) =~= kv(*k).push(v@)); }
    Ok(())
}

/// `out` becomes `k` with slot `i` set to `v`.
pub fn x_update_into(k: &Vec<XKind>, i: usize, v: XKind, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    requires i < k.len(),
    ensures res is Ok ==> kv(*final(out)) == kv(*k).update(i as int, v@),
{
    x_copy_into(k, out)?;
    vput(out, i, v);
    proof { assert(kv(*out) =~= kv(*k).update(i as int, v@)); }
    Ok(())
}

/// `out` becomes `pop_push(k, n, Some(v))`.
pub fn x_pop_push_into(k: &Vec<XKind>, n: usize, v: XKind, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    requires n <= k.len(),
    ensures res is Ok ==> kv(*final(out)) == pop_push(kv(*k), n as int, Some(v@)),
{
    x_prefix_into(k, k.len() - n, out)?;
    try_push(out, v)?;
    proof { assert(kv(*out) =~= kv(*k).subrange(0, k.len() - n).push(v@)); }
    Ok(())
}

/// Drops all but the first `n` kinds of `out`.
pub fn x_truncate(out: &mut Vec<XKind>, n: usize)
    requires n <= old(out)@.len(),
    ensures final(out)@ == old(out)@.subrange(0, n as int), kv(*final(out)) == kv(*old(out)).subrange(0, n as int),
{
    let ghost o = out@;
    out.truncate(n);
    proof {
        assert(out@ =~= o.subrange(0, n as int));
        assert(kv(*out) =~= kv(*old(out)).subrange(0, n as int));
    }
}

pub fn x_u16(p: &VProgram, i: usize) -> (r: i64)
    requires i + 2 <= p.bytecodes.len(),
    ensures r as int == u16_at(p1(vview(p)), i as int), 0 <= r < 0x10000,
{
    (ix(p.bytecodes, i) as i64) + 256 * (ix(p.bytecodes, i + 1) as i64)
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
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && (ix(p.class_bits, cl as usize) & 0xf) == 2
}

pub fn x_is_field_class(p: &VProgram, cl: i64) -> (r: bool)
    ensures r == is_field_class(vview(p), cl as int),
{
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64)
        && ((ix(p.class_bits, cl as usize) & 0xf) == 2 || (ix(p.class_bits, cl as usize) & 0xf) == 8)
}

pub fn x_ifc(p: &VProgram, cl: usize) -> (r: i64)
    requires cl < p.class_bits.len(),
    ensures r as int == ifc(vview(p), cl as int),
{
    (((ix(p.class_bits, cl) >> 5u16) & 0x7ff) as i64) - 1
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

/// The arity of `g.methods[m]` (the length of its mask), 0 past the table.
pub fn x_bp_arity(g: &XGlobal, m: usize) -> (r: usize)
    ensures r == bp_view(g, m as int).len(),
{
    if m < g.methods.len() { g.methods.arity(m) as usize } else { 0 }
}

/// `c@.block_params[m].len()` for a method `m < g.n`.
pub fn x_bp_len(c: &XCert, m: usize) -> (r: usize)
    requires m < c.g.n,
    ensures r == c@.block_params[m as int].len(),
{
    x_bp_arity(c.g, m)
}

pub fn x_is_block_param(c: &XCert, m: usize, i: usize) -> (r: bool)
    ensures r == is_block_param(c@, m as int, i as int),
{
    if m >= c.g.n { return false; }
    let a = x_bp_arity(c.g, m);
    if i >= a { return false; }
    let mask = x_bp_mask(c.g, m);
    x_bit(mask, i)
}

/// `c@.block_params[r] == c@.block_params[m]`.
pub fn x_bp_eq(c: &XCert, r: usize, m: usize) -> (res: bool)
    requires r < c.g.n, m < c.g.n,
    ensures res == (c@.block_params[r as int] == c@.block_params[m as int]),
{
    let ghost br = c@.block_params[r as int];
    let ghost bm = c@.block_params[m as int];
    let a = x_bp_arity(c.g, r);
    if a != x_bp_arity(c.g, m) { return false; }
    let mr = x_bp_mask(c.g, r);
    let mm = x_bp_mask(c.g, m);
    let mut i = 0;
    while i < a
        invariant
            0 <= i <= a, br.len() == a, bm.len() == a,
            br == c@.block_params[r as int], bm == c@.block_params[m as int],
            forall|j: int| 0 <= j < a ==> br[j] == bit(mr, j) && bm[j] == bit(mm, j),
            forall|j: int| 0 <= j < i ==> br[j] == bm[j],
        decreases a - i,
    {
        if x_bit(mr, i) != x_bit(mm, i) {
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
    let a = x_bp_arity(c.g, m);
    let mask = x_bp_mask(c.g, m);
    let mut i = 0;
    while i < a
        invariant 0 <= i <= a, b.len() == a, b == c@.block_params[m as int],
            forall|j: int| 0 <= j < a ==> b[j] == bit(mask, j),
            forall|j: int| 0 <= j < i ==> !b[j],
        decreases a - i,
    {
        if x_bit(mask, i) {
            assert(b[i as int]);
            return false;
        }
        i += 1;
    }
    true
}

/// The context of method `t`: its head (the kinds are the list of
/// `top`).
pub fn x_ctx_of(c: &XCert, t: usize) -> (r: Option<XCtx>)
    ensures
        match r {
            Some(h) => ctx_of(c@, t as int) == Some(xctx_view(c.g, h)),
            None => ctx_of(c@, t as int) is None,
        },
{
    let g = c.g;
    if t >= g.n { return None; }
    if !(t < g.methods.len() && g.methods.kind(t) == 3) { return None; }
    let w = x_fld(g.mw, 4, t, 0);
    if w == 0 || ((w - 1) as usize) >= g.crec.len() / 12 { return None; }
    let j = (w - 1) as usize;
    let h = XCtx { outer: x_fld(g.crec, 12, j, 0), slot: x_fld(g.crec, 12, j, 4), top: x_fld(g.crec, 12, j, 8) };
    assert(h == ctx_head(g, t as int));
    Some(h)
}

/// The kinds of a node table's list with top `i` (`fchain`), bottom first.
pub fn x_fchain(s: &[u8], i: u32) -> (res: Result<Vec<XKind>, Oom>)
    ensures res matches Ok(r) ==> kv(r) == fchain(s@, i as int),
{
    let ghost nodes = fnodes(s@);
    let n = s.len() / 12;
    assert(nodes.len() == n);
    let mut rev: Vec<XKind> = Vec::new();
    let mut cur = i as usize;
    let mut done = cur >= n;
    while !done
        invariant
            nodes == fnodes(s@), nodes.len() == n,
            done ==> chain(nodes, i as int) == rev_kinds(rev@),
            !done ==> cur < n && chain(nodes, i as int) == chain(nodes, cur as int) + rev_kinds(rev@),
        decreases (if done { 0int } else { cur as int + 1 }),
    {
        let nd = x_fnode(s, cur);
        let ghost before = rev@;
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes, cur as int) == base.push(nd.kind@));
        try_push(&mut rev, nd.kind)?;
        assert(base.push(nd.kind@) + rev_kinds(before) =~= base + rev_kinds(rev@));
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            assert(base + rev_kinds(rev@) =~= rev_kinds(rev@));
            done = true;
        }
    }
    proof { if i as int >= n { assert(chain(nodes, i as int) =~= rev_kinds(rev@)); } }
    x_reversed(&rev)
}

/// The kinds of a node table's list with top `i`, top first, into `rev`
/// (its buffer reused): `x_fchain` without the reversed copy.
pub fn x_fchain_rev(s: &[u8], i: u32, rev: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    ensures res is Ok ==> fchain(s@, i as int) == rev_kinds(final(rev)@),
{
    let ghost nodes = fnodes(s@);
    let n = s.len() / 12;
    assert(nodes.len() == n);
    rev.clear();
    let mut cur = i as usize;
    let mut done = cur >= n;
    while !done
        invariant
            nodes == fnodes(s@), nodes.len() == n,
            done ==> chain(nodes, i as int) == rev_kinds(rev@),
            !done ==> cur < n && chain(nodes, i as int) == chain(nodes, cur as int) + rev_kinds(rev@),
        decreases (if done { 0int } else { cur as int + 1 }),
    {
        let nd = x_fnode(s, cur);
        let ghost before = rev@;
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes, cur as int) == base.push(nd.kind@));
        try_push(rev, nd.kind)?;
        assert(base.push(nd.kind@) + rev_kinds(before) =~= base + rev_kinds(rev@));
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            assert(base + rev_kinds(rev@) =~= rev_kinds(rev@));
            done = true;
        }
    }
    proof { if i as int >= n { assert(chain(nodes, i as int) =~= rev_kinds(rev@)); } }
    Ok(())
}

/// The kinds of `rev` in reverse order.
pub fn x_reversed(rev: &Vec<XKind>) -> (res: Result<Vec<XKind>, Oom>)
    ensures res matches Ok(r) ==> kv(r) == rev_kinds(rev@),
{
    let mut r: Vec<XKind> = try_with_capacity(rev.len())?;
    let mut j = rev.len();
    while j > 0
        invariant 0 <= j <= rev@.len(), kv(r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int),
        decreases j,
    {
        j -= 1;
        let ghost old = kv(r);
        try_push(&mut r, vix(rev, j))?;
        assert(kv(r) =~= old.push(rev@[j as int]@));
        assert(rev_kinds(rev@)[rev@.len() - 1 - j] == rev@[j as int]@);
        assert(kv(r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int));
    }
    assert(kv(r) =~= rev_kinds(rev@));
    Ok(r)
}

/// The selector record with key `s`.
pub fn x_sel_find(g: &XGlobal, s: u32) -> (r: Option<usize>)
    requires sel_sorted(g),
    ensures
        match r {
            Some(j) => j < nsel(g) && sel_key(g, j as int) == s && sel_view(g, s as int) == sel_val(g, j as int) as int,
            None => !has_sel(g, s as int) && sel_view(g, s as int) == -1,
        },
{
    let mut lo: usize = 0;
    let mut hi: usize = g.sel.len() / 8;
    while lo < hi
        invariant
            0 <= lo <= hi <= nsel(g), sel_sorted(g),
            forall|i: int| 0 <= i < lo ==> #[trigger] sel_key(g, i) < s,
            forall|i: int| hi <= i < nsel(g) ==> #[trigger] sel_key(g, i) > s,
        decreases hi - lo,
    {
        let mid = lo + (hi - lo) / 2;
        let k = x_fld(g.sel, 8, mid, 0);
        if k == s {
            proof {
                assert(sel_key(g, mid as int) == s);
                assert(has_sel(g, s as int));
                let j = choose|j: int| 0 <= j < nsel(g) && #[trigger] sel_key(g, j) == s;
                if j < mid { assert(sel_key(g, j) < sel_key(g, mid as int)); }
                if j > mid { assert(sel_key(g, mid as int) < sel_key(g, j)); }
            }
            return Some(mid);
        } else if k < s {
            proof {
                assert forall|i: int| 0 <= i < mid + 1 implies #[trigger] sel_key(g, i) < s by {
                    if i < mid { assert(sel_key(g, i) < sel_key(g, mid as int)); }
                }
            }
            lo = mid + 1;
        } else {
            proof {
                assert forall|i: int| mid <= i < nsel(g) implies #[trigger] sel_key(g, i) > s by {
                    if i > mid { assert(sel_key(g, mid as int) < sel_key(g, i)); }
                }
            }
            hi = mid;
        }
    }
    None
}

/// `c@.sel_rep[s]` for `s < 0xffff`.
pub fn x_sel_rep(c: &XCert, s: usize) -> (r: i64)
    requires s < 0xffff, g_ok(c.g),
    ensures r as int == c@.sel_rep[s as int],
{
    match x_sel_find(c.g, s as u32) {
        Some(j) => x_fld(c.g.sel, 8, j, 4) as i64,
        None => -1,
    }
}

pub fn x_dispatch_target(p: &VProgram, d: i64) -> (r: i64)
    ensures r as int == dispatch_target(vview(p), d as int),
{
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { ix(p.dispatch, d as usize) as i64 } else { -1 }
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
    match vix(fk, i as usize) {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && x_kind(p, t as usize) == 3) {
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
    match vix(fk, i) {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && x_kind(p, t as usize) == 3) {
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
pub fn x_ctx_kinds(c: &XCert, m: i64, depth: u32) -> (res: Result<(Option<Vec<XKind>>, i64), Oom>)
    requires depth >= 1,
    ensures
        res matches Ok(r) ==> okv(r.0) == ctx_kinds(c@, m as int, depth as nat)
            && r.1 as int == ctx_method(c@, m as int, depth as nat),
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
            return Ok((None, -1));
        }
        match x_ctx_of(c, cur as usize) {
            None => return Ok((None, -1)),
            Some(ctx) => {
                if d == 1 {
                    proof { assert(ctx_method(c@, ctx.outer as int, 0) == ctx.outer as int); }
                    return Ok((Some(x_fchain(c.g.nodes, ctx.top)?), ctx.outer as i64));
                }
                cur = ctx.outer as i64;
                d = d - 1;
            },
        }
    }
}

/// `x_ctx_kinds` with the kinds top first in `rev` (its buffer reused):
/// whether the context exists, and its method.
pub fn x_ctx_kinds_rev(c: &XCert, m: i64, depth: u32, rev: &mut Vec<XKind>) -> (res: Result<(bool, i64), Oom>)
    requires depth >= 1,
    ensures
        res matches Ok(r) ==> r.1 as int == ctx_method(c@, m as int, depth as nat)
            && (if r.0 { ctx_kinds(c@, m as int, depth as nat) == Some(rev_kinds(final(rev)@)) }
                else { ctx_kinds(c@, m as int, depth as nat) is None }),
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
            return Ok((false, -1));
        }
        match x_ctx_of(c, cur as usize) {
            None => return Ok((false, -1)),
            Some(ctx) => {
                if d == 1 {
                    proof { assert(ctx_method(c@, ctx.outer as int, 0) == ctx.outer as int); }
                    x_fchain_rev(c.g.nodes, ctx.top, rev)?;
                    return Ok((true, ctx.outer as i64));
                }
                cur = ctx.outer as i64;
                d = d - 1;
            },
        }
    }
}

/// `block_slot` of the list whose kinds are `rev` top first.
pub fn x_block_slot_rev(p: &VProgram, c: &XCert, om: i64, rev: &Vec<XKind>, i: i64) -> (r: bool)
    ensures r == block_slot(vview(p), c@, om as int, rev_kinds(rev@), i as int),
{
    if i < 0 || (i as u64) >= (rev.len() as u64) {
        return false;
    }
    let j = rev.len() - 1 - i as usize;
    proof { assert(rev_kinds(rev@)[i as int] == rev@[j as int]@); }
    match vix(rev, j) {
        XKind::Method(t) => {
            if !(x_valid(p, t as i64) && x_kind(p, t as usize) == 3) {
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

pub fn x_wf_kinds(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, buf: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    ensures res matches Ok(r) ==> r == wf_kinds(vview(p), c@, m as int, kv(*k)),
{
    let mut j = 0;
    while j < k.len()
        invariant 0 <= j <= k.len(), forall|jj: int| 0 <= jj < j ==> #[trigger] wf_kind(vview(p), c@, m as int, kv(*k), jj),
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
                } else {
                    let (found, om) = x_ctx_kinds_rev(c, m, d, buf)?;
                    if !found {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return Ok(false);
                    }
                    if !x_block_slot_rev(p, c, om, &*buf, i as i64) {
                        proof { assert(!wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
                        return Ok(false);
                    }
                }
            },
            _ => {},
        }
        proof { assert(wf_kind(vview(p), c@, m as int, kv(*k), j as int)); }
        j += 1;
    }
    Ok(true)
}

#[verifier::loop_isolation(false)]
pub fn x_ctx_ok_at(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, i: usize) -> (res: Result<bool, Oom>)
    requires i < k.len(),
    ensures res matches Ok(r) ==> r == ctx_ok_at(vview(p), c@, m as int, kv(*k), i as int),
{
    if !x_block_slot_u(p, c, m, k, i) {
        return Ok(true);
    }
    let t = match vix(k, i) { XKind::Method(t) => t, _ => 0 };
    proof { assert(kv(*k)[i as int] == k@[i as int]@); assert(kind_method(kv(*k)[i as int]) == t as int); }
    match x_ctx_of(c, t as usize) {
        Some(ctx) => {
            let ck = &x_fchain(c.g.nodes, ctx.top)?;
            if ck.len() != i + 1 {
                proof { assert(kv(*k).subrange(0, i + 1).len() != kv(*ck).len()); }
                return Ok(false);
            }
            let mut j = 0;
            while j <= i
                invariant ck.len() == i + 1, i < k.len(), 0 <= j <= i + 1,
                    forall|jj: int| 0 <= jj < j ==> (#[trigger] k@[jj])@ == ck@[jj]@,
                decreases i + 1 - j,
            {
                if !x_kind_eq(vix(k, j), vix(ck, j)) {
                    proof { assert(kv(*k).subrange(0, i + 1)[j as int] != kv(*ck)[j as int]); }
                    return Ok(false);
                }
                j += 1;
            }
            proof { assert(kv(*k).subrange(0, i + 1) =~= kv(*ck)); }
            Ok(true)
        },
        None => Ok(true),
    }
}

pub fn x_ctx_ok_upto(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, n: usize) -> (res: Result<bool, Oom>)
    ensures res matches Ok(r) ==> r == ctx_ok_upto(vview(p), c@, m as int, kv(*k), n as int),
{
    let mut i = 0;
    while i <= n && i < k.len()
        invariant 0 <= i <= k.len(), i <= n + 1,
            forall|ii: int| 0 <= ii < i ==> #[trigger] ctx_ok_at(vview(p), c@, m as int, kv(*k), ii),
        decreases k.len() - i,
    {
        if !x_ctx_ok_at(p, c, m, k, i)? {
            return Ok(false);
        }
        i += 1;
    }
    Ok(true)
}

/// The slot a local block reference points to, or -1.
pub open spec fn lref(kd: Kind) -> int {
    match kd { Kind::Block(d, s) => if d == 0 && s >= 0 { s } else { -1 }, _ => -1 }
}

pub fn x_ctx_ok(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>) -> (res: Result<bool, Oom>)
    ensures res matches Ok(r) ==> r == ctx_ok(vview(p), c@, m as int, kv(*k)),
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
        match vix(k, j) {
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
        return Ok(true);
    }
    let r = x_ctx_ok_upto(p, c, m, k, top as usize)?;
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
    Ok(r)
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
        if x_kind_eq(vix(k, j), target) {
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
        if x_is_token(vix(k, j)) {
            return true;
        }
        j += 1;
    }
    false
}

pub fn x_pinned0(p: &VProgram, m: usize) -> (r: bool)
    requires m < p.methods@.len(),
    ensures r == pinned0(vview(p), m as int),
{
    x_recv_start(p, m) != 0xffff || x_kind(p, m) == 3
}

pub fn x_writable(p: &VProgram, m: usize, k: &Vec<XKind>, i: usize, v: XKind) -> (r: bool)
    requires m < p.methods@.len(),
    ensures r == writable(vview(p), m as int, kv(*k), i as int, v@),
{
    if i >= k.len() { return false; }
    proof { assert(kv(*k)[i as int] == k@[i as int]@); }
    if i == 0 && x_pinned0(p, m) { return false; }
    if x_referenced(k, i) { return false; }
    if x_is_token(vix(k, i)) || x_is_token(v) { return false; }
    if x_below_token(k, i) && !(x_is_plain(vix(k, i)) && x_is_plain(v)) { return false; }
    true
}

pub fn x_leaves0(p: &VProgram, m: usize, h: usize, n: usize) -> (r: bool)
    requires m < p.methods@.len(),
    ensures r == leaves0(vview(p), m as int, h as int, n as int),
{
    !(x_pinned0(p, m) && x_arity(p, m) >= 1) || (n < h && h - n >= 1)
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
        let kd = vix(k, base + x);
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
        if !x_is_val(vix(k, k.len() - 1 - i)) {
            proof { assert(!is_val(top_kind(kv(*k), i as int))); }
            return false;
        }
        i += 1;
    }
    true
}

pub fn x_sel_ok(p: &VProgram, c: &XCert, sel: i64, n: usize, k: &Vec<XKind>) -> (r: bool)
    requires g_ok(c.g),
    ensures r == sel_ok(vview(p), c@, sel as int, n as int, kv(*k)),
{
    if !(1 <= n && n <= k.len()) { return false; }
    if !(0 <= sel && sel < 0xffff) { return false; }
    if !x_row_fits(p, sel as usize) { return false; }
    proof { assert(kv(*k)[k.len() - n] == k@[k.len() - n]@); }
    if !x_is_val(vix(k, k.len() - n)) { return false; }
    let r = x_sel_rep(c, sel as usize);
    if r == -1 { return true; }
    if !x_valid(p, r) { return false; }
    let ru = r as usize;
    proof { assert(ru as int == r as int); }
    x_arity(p, ru) as usize == n && x_args_ok(c, ru, k, n)
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
    requires m < p.methods@.len(),
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
    requires m < p.methods@.len(), wf_program2(vview(p)),
    ensures r == range_has_task(vview(p), vinfo(p, m as int)),
{
    let i = x_info(p, m);
    let tc = ix(p.builtin, 19);
    i.recv_start <= tc && tc < i.recv_end
}

pub fn x_this_load_ok(p: &VProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods@.len(), wf_program2(vview(p)),
    ensures r == this_load_ok(vview(p), m as int, f as int),
{
    x_this_field_ok(p, m, f) && !(x_range_has_task(p, m) && f == 0)
}

pub fn x_this_store_ok(p: &VProgram, m: usize, f: i64) -> (r: bool)
    requires m < p.methods@.len(), wf_program2(vview(p)),
    ensures r == this_store_ok(vview(p), m as int, f as int),
{
    x_this_field_ok(p, m, f) && !(x_range_has_task(p, m) && f <= 1)
}

pub fn x_task_class_ok(p: &VProgram) -> (r: bool)
    requires wf_program2(vview(p)),
    ensures r == task_class_ok(vview(p)),
{
    let ghost pv = vview(p);
    let tc = ix(p.builtin, 19) as usize;
    assert(tc as int == builtin(p1(pv), TASK_CLASS));
    if !(tc < p.class_bits.len() && (ix(p.class_bits, tc) & 0xf) == 8) {
        proof {
            if tc < p.class_bits.len() { assert(class_tag(p1(pv), tc as int) == p.class_bits[tc as int] & 0xf); }
        }
        return false;
    }
    assert(class_tag(p1(pv), tc as int) == TASK_TAG);
    if ix(p.builtin, 22) as usize == tc { return false; }
    let mut cl = 0;
    while cl < p.class_bits.len()
        invariant 0 <= cl <= p.class_bits.len(), tc as int == builtin(p1(pv), TASK_CLASS), pv == vview(p),
            forall|c2: int| 0 <= c2 < cl && #[trigger] class_tag(p1(pv), c2) == TASK_TAG ==> c2 == tc,
        decreases p.class_bits.len() - cl,
    {
        if (ix(p.class_bits, cl) & 0xf) == 8 && cl != tc {
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
    &&& m < p.methods@.len()
    &&& vinfo(p, m as int).entry + off + opcode_length2(p.bytecodes[vinfo(p, m as int).entry + off]) <= vinfo(p, m as int).end
    &&& p.bytecodes[vinfo(p, m as int).entry + off] < OPCODE_COUNT2
    &&& k.len() <= 0x10_0000
}

/// Decodes the instruction at offset `off` of `m`.
pub fn x_decode(p: &VProgram, m: usize, off: usize) -> (r: (usize, u8, usize, i64, i64))
    requires
        wf_program2(vview(p)),
        m < p.methods@.len(),
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
    let bci = x_entry(p, m) + off;
    let raw = ix(p.bytecodes, bci);
    proof { lemma_base_op(raw); }
    let op = exec_base_op(raw);
    let len = exec_opcode_length2(op);
    let b1: i64 = if len >= 2 { ix(p.bytecodes, bci + 1) as i64 } else { 0 };
    let w1: i64 = if len >= 3 { x_u16(p, bci + 1) } else { 0 };
    (bci, op, len, b1, w1)
}

pub fn x_post_locals(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
           || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP }),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        let n = if op == LOAD_LOCAL { b1 } else if op == LOAD_LOCAL_WIDE { w1 } else { (op - LOAD_LOCAL_0) as i64 };
        if (n as usize) < h {
            proof { assert(kv(*k)[h - 1 - n] == k@[h - 1 - n]@); }
            if !x_is_token(vix(k, h - 1 - n as usize)) {
                { x_push_into(k, vix(k, h - 1 - n as usize), out)?; Ok(true) }
            } else { Ok(false) }
        } else {
            Ok(false)
        }
    } else if op == POP_LOAD_LOCAL {
        if (b1 as usize) + 1 < h {
            proof { assert(kv(*k)[h - 2 - b1] == k@[h - 2 - b1]@); }
            if !x_is_token(vix(k, h - 2 - b1 as usize)) {
                { x_update_into(k, h - 1, vix(k, h - 2 - b1 as usize), out)?; Ok(true) }
            } else { Ok(false) }
        } else {
            Ok(false)
        }
    } else {
        if 1 <= b1 && (b1 as usize) < h {
            let i = h - 1 - b1 as usize;
            let v = vix(k, h - 1);
            proof { assert(kv(*k)[h - 1] == v@); }
            if x_writable(p, m, k, i, v) {
                x_update_into(k, i, v, out)?;
                if op == STORE_LOCAL_POP {
                    x_truncate(out, h - 1);
                }
                Ok(true)
            } else { Ok(false) }
        } else { Ok(false) }
    }
}

pub fn x_post_outer(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK }),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    let ghost pv = vview(p);
    let ghost kk = kv(*k);
    if op == LOAD_BLOCK {
        let i = h as i64 - 1 - b1;
        if x_block_slot(p, c, m as i64, k, i) { { x_push_into(k, XKind::Block(0, i as u32), out)?; Ok(true) } } else { Ok(false) }
    } else {
        let r: usize = if op == STORE_OUTER { 1 } else { 0 };
        if r >= h { return Ok(false); }
        proof { assert(kk[h - 1 - r] == k@[h - 1 - r]@); }
        match vix(k, h - 1 - r) {
            XKind::Block(d, j) => {
                // The frame's kinds `fk`: this frame's (`k`), or an outer
                // context's, read top first into `out` (no copy; `out`
                // gets the successor only at the end).
                let (found, om): (bool, i64) = if d == 0 { (true, m as i64) } else { x_ctx_kinds_rev(c, m as i64, d, out)? };
                let ghost fkv: Seq<Kind> = if d == 0 { kk } else { rev_kinds(out@) };
                proof {
                    if found { assert(ref_kinds(c@, m as int, kk, d as int) == Some(fkv)); }
                    else { assert(ref_kinds(c@, m as int, kk, d as int) is None); }
                    assert(om as int == ref_method(c@, m as int, d as int));
                }
                if !found { return Ok(false); }
                let flen = if d == 0 { h } else { out.len() };
                if !((b1 as u64) <= (j as u64) && (j as usize) < flen) {
                    return Ok(false);
                }
                let i = (j as i64 - b1) as usize;
                let fki = if d == 0 { vix(k, i) } else { vix(out, flen - 1 - i) };
                proof {
                    if d == 0 { assert(fkv[i as int] == fki@); }
                    else { assert(rev_kinds(out@)[i as int] == out@[flen - 1 - i]@); assert(fkv[i as int] == fki@); }
                }
                if op == LOAD_OUTER {
                    if x_is_token(fki) { Ok(false) } else {
                        match x_shift(fki, d) {
                            Some(sk) => { x_update_into(k, h - 1, sk, out)?; Ok(true) },
                            None => {
                                proof {
                                    let s2 = kk.update(h - 1, shift(fkv[i as int], d as int));
                                    assert(post(pv, c@, m as int, off as int, kk, trusted) == Some(s2));
                                    assert(!match #[trigger] s2[h - 1] {
                                        Kind::Method(t) => 0 <= t <= u32::MAX as int,
                                        Kind::Block(d, x) => 0 <= d <= u32::MAX as int && 0 <= x <= u32::MAX as int,
                                        _ => true,
                                    });
                                }
                                Ok(false)
                            },
                        }
                    }
                } else if op == LOAD_OUTER_BLOCK {
                    let slot = if d == 0 { x_block_slot(p, c, om, k, i as i64) } else { x_block_slot_rev(p, c, om, &*out, i as i64) };
                    proof { assert(slot == block_slot(pv, c@, om as int, fkv, i as int)); }
                    if slot { { x_update_into(k, h - 1, XKind::Block(d, i as u32), out)?; Ok(true) } } else { Ok(false) }
                } else {
                    proof { assert(kk[h - 1] == k@[h - 1]@); }
                    if d >= 1 && x_is_plain(fki) && x_is_val(vix(k, h - 1)) && x_valid(p, om)
                            && !(i == 0 && x_pinned0(p, om as usize)) {
                        { x_pop_push_into(k, 2, XKind::Val, out)?; Ok(true) }
                    } else {
                        Ok(false)
                    }
                }
            },
            _ => Ok(false),
        }
    }
}

pub fn x_post_fields(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
           || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
           || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS }),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        if x_value_operands(k, 1) && x_leaves0(p, m, h, 1) { { x_update_into(k, h - 1, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        let slot = if op == POP_LOAD_FIELD_LOCAL { (b1 % 16 + 1) as usize } else { (b1 % 16) as usize };
        if slot < h {
            proof { assert(kv(*k)[h - 1 - slot] == k@[h - 1 - slot]@); }
            if x_is_val(vix(k, h - 1 - slot)) {
                if op == LOAD_FIELD_LOCAL { x_push_into(k, XKind::Val, out)?; } else { x_update_into(k, h - 1, XKind::Val, out)?; }
                Ok(true)
            } else { Ok(false) }
        } else {
            Ok(false)
        }
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        if x_value_operands(k, 2) && x_leaves0(p, m, h, 2) {
            if op == STORE_FIELD_POP {
                x_prefix_into(k, h - 2, out)?;
                Ok(true)
            } else {
                { x_pop_push_into(k, 2, XKind::Val, out)?; Ok(true) }
            }
        } else { Ok(false) }
    } else if op == LOAD_FIELD_THIS {
        if x_this_load_ok(p, m, b1) { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else {
        if x_this_store_ok(p, m, b1) && x_value_operands(k, 1) { { x_copy_into(k, out)?; Ok(true) } } else { Ok(false) }
    }
}

pub fn x_post_consts(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           (LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
           || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL) }),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        let i = if op == LOAD_LITERAL { b1 } else { w1 };
        if (i as usize) < p.literals.len() { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8 || op == LOAD_SMI_U16 {
        { x_push_into(k, XKind::Val, out)?; Ok(true) }
    } else if op == LOAD_SMI_U32 {
        if x_smi_ok(p, x_u32(p, bci + 1)) { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_SMIS_0 {
        x_copy_into(k, out)?;
        proof { assert(kv(*out) =~= kv(*k) + Seq::new(0 as nat, |x: int| Kind::Val)); }
        let mut i: i64 = 0;
        while i < b1
            invariant 0 <= i <= b1, b1 < 256, kv(*out) == kv(*k) + Seq::new(i as nat, |x: int| Kind::Val),
            decreases b1 - i,
        {
            let ghost before = kv(*out);
            try_push(out, XKind::Val)?;
            proof {
                assert(kv(*out) =~= before.push(Kind::Val));
                assert(kv(*k) + Seq::new((i + 1) as nat, |x: int| Kind::Val)
                    =~= (kv(*k) + Seq::new(i as nat, |x: int| Kind::Val)).push(Kind::Val));
            }
            i += 1;
        }
        Ok(true)
    } else if op == LOAD_METHOD {
        let t = x_u32(p, bci + 1);
        if x_valid(p, t) && x_smi_ok(p, t) { { x_push_into(k, XKind::Method(t as u32), out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_LAZY {
        if (b1 as u64) < c.g.global_count { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_GLOBAL_VAR_WIDE || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        if (w1 as u64) < c.g.global_count { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        let g = if op == STORE_GLOBAL_VAR { b1 } else { w1 };
        if (g as u64) < c.g.global_count && x_value_operands(k, 1) { { x_copy_into(k, out)?; Ok(true) } } else { Ok(false) }
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 1) && x_leaves0(p, m, h, 1) { { x_update_into(k, h - 1, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        if x_value_operands(k, 2) { { x_prefix_into(k, h - 2, out)?; Ok(true) } } else { Ok(false) }
    } else if op == POP || op == POP_1 {
        let n = if op == POP { b1 as usize } else { 1 };
        if n <= h { { x_prefix_into(k, h - n, out)?; Ok(true) } } else { Ok(false) }
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        let cl = if op == ALLOCATE { b1 } else { w1 };
        if x_is_instance_class(p, cl) && x_ifc(p, cl as usize) >= 0 { { x_push_into(k, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        if x_value_operands(k, 1) && (op > IS_INTERFACE_WIDE || x_leaves0(p, m, h, 1))
            && x_typecheck_index_ok(p, op, if op % 2 == 0 { b1 } else { w1 }) {
            if op <= IS_INTERFACE_WIDE { x_update_into(k, h - 1, XKind::Val, out)?; } else { x_copy_into(k, out)?; }
            Ok(true)
        } else { Ok(false) }
    } else {
        if ((b1 / 32) as usize) < h {
            proof { assert(kv(*k)[h - 1 - b1 / 32] == k@[h - 1 - b1 / 32]@); }
            if x_is_val(vix(k, h - 1 - (b1 / 32) as usize)) && ((2 * (b1 % 32) + 1) as usize) < p.class_check_ids.len() {
                { x_copy_into(k, out)?; Ok(true) }
            } else { Ok(false) }
        } else {
            Ok(false)
        }
    }
}

pub fn x_post_calls(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        g_ok(c.g),
        post_pre(p, m, off, k),
        ({ let op = op_of(vview(p), m as int, off as int);
           op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL }),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if op == INVOKE_STATIC {
        let t = x_dispatch_target(p, w1);
        if x_valid(p, t) && x_args_ok(c, t as usize, k, x_arity(p, t as usize) as usize)
            && x_leaves0(p, m, h, x_arity(p, t as usize) as usize) {
            let a = x_arity(p, t as usize) as usize;
            { x_pop_push_into(k, a, XKind::Val, out)?; Ok(true) }
        } else { Ok(false) }
    } else if op == INVOKE_BLOCK {
        if 1 <= b1 && (b1 as usize) <= h {
            let kd = vix(k, h - b1 as usize);
            proof { assert(kv(*k)[h - b1] == kd@); }
            if x_is_ref(kd) && x_value_operands(k, (b1 - 1) as usize) && x_leaves0(p, m, h, b1 as usize)
                && match kd { XKind::Block(d, i) => !(d == 0 && (i as usize) >= h - b1 as usize), _ => true } {
                { x_pop_push_into(k, b1 as usize, XKind::Val, out)?; Ok(true) }
            } else { Ok(false) }
        } else { Ok(false) }
    } else if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        let n = if op == INVOKE_VIRTUAL { b1 + 1 } else { w1 + 1 };
        let sel = if op == INVOKE_VIRTUAL { x_u16(p, bci + 2) } else { x_u16(p, bci + 3) };
        if x_sel_ok(p, c, sel, n as usize, k) && x_leaves0(p, m, h, n as usize) {
            { x_pop_push_into(k, n as usize, XKind::Val, out)?; Ok(true) }
        } else { Ok(false) }
    } else if op == INVOKE_VIRTUAL_GET || op == INVOKE_SIZE {
        if x_sel_ok(p, c, w1, 1, k) && x_leaves0(p, m, h, 1) { { x_update_into(k, h - 1, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    } else if op == INVOKE_VIRTUAL_SET {
        if x_value_operands(k, 2) && x_sel_ok(p, c, w1, 2, k) && x_leaves0(p, m, h, 2) {
            { x_pop_push_into(k, 2, XKind::Val, out)?; Ok(true) }
        } else { Ok(false) }
    } else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT {
        let n: usize = if op == INVOKE_AT_PUT { 3 } else { 2 };
        let sel = ix(p.invoke_offsets, (op - INVOKE_EQ) as usize) as i64;
        if x_value_operands(k, n) && (sel < 0 || x_sel_ok(p, c, sel, n, k)) && x_leaves0(p, m, h, n) {
            { x_pop_push_into(k, n, XKind::Val, out)?; Ok(true) }
        } else { Ok(false) }
    } else {
        if x_value_operands(k, 2) && x_leaves0(p, m, h, 2) { { x_pop_push_into(k, 2, XKind::Val, out)?; Ok(true) } } else { Ok(false) }
    }
}

/// `loop_ok` (proposal, format note 19).
pub fn x_loop_ok(p: &VProgram, m: usize, k: &Vec<XKind>, c: usize, b: usize, x: usize, y: usize) -> (r: bool)
    requires m < p.methods@.len(),
    ensures r == loop_ok(vview(p), m as int, kv(*k), c as int, b as int, x as int, y as int),
{
    let h = k.len();
    if !(1 <= c && c < h && 1 <= b && b < h && 1 <= x && x < h && 1 <= y && y < h) { return false; }
    proof {
        assert(kv(*k)[h - 1 - c] == k@[h - 1 - c]@);
        assert(kv(*k)[h - 1 - b] == k@[h - 1 - b]@);
        assert(kv(*k)[h - 1 - x] == k@[h - 1 - x]@);
        assert(kv(*k)[h - 1 - y] == k@[h - 1 - y]@);
    }
    x_is_val(vix(k, h - 1 - c)) && x_is_val(vix(k, h - 1 - x)) && x_is_val(vix(k, h - 1 - y))
        && !x_is_token(vix(k, h - 1 - b)) && x_writable(p, m, k, h - 1 - c, XKind::Val)
}

/// `loop_kinds`.
pub fn x_loop_kinds(k: &Vec<XKind>, c: usize, b: usize) -> (res: Result<Vec<XKind>, Oom>)
    requires 1 <= c < k.len(), b < k.len(),
    ensures res matches Ok(r) ==> kv(r) == loop_kinds(kv(*k), c as int, b as int),
{
    let h = k.len();
    let kb = vix(k, h - 1 - b);
    proof { assert(kv(*k)[h - 1 - b] == kb@); }
    let k1 = x_update(k, h - 1 - c, XKind::Val)?;
    assert(kv(k1).len() == h);
    let k2 = x_prefix(&k1, h - 1)?;
    let k3 = x_push(&k2, kb)?;
    x_push(&k3, XKind::Val)
}

/// `hf_ok` (proposal, format note 19).
pub fn x_hf_ok(p: &VProgram, m: usize, k: &Vec<XKind>, n: usize, mm: usize) -> (r: bool)
    requires m < p.methods@.len(), n < 256, mm < 256,
    ensures r == hf_ok(vview(p), m as int, kv(*k), n as int, mm as int),
{
    let h = k.len();
    if !(n + 2 < h && mm + 2 < h) { return false; }
    proof {
        assert(kv(*k)[h - 1 - n] == k@[h - 1 - n]@);
        assert(kv(*k)[h - 2 - n] == k@[h - 2 - n]@);
        assert(kv(*k)[h - 3 - n] == k@[h - 3 - n]@);
        assert(kv(*k)[h - 1 - mm] == k@[h - 1 - mm]@);
        assert(kv(*k)[h - 3 - mm] == k@[h - 3 - mm]@);
    }
    x_is_val(vix(k, h - 1 - n)) && x_is_val(vix(k, h - 2 - n)) && x_is_val(vix(k, h - 3 - n))
        && x_is_val(vix(k, h - 1 - mm)) && x_is_val(vix(k, h - 3 - mm))
        && x_writable(p, m, k, h - 1 - n, XKind::Val)
        && x_writable(p, m, k, h - 2 - n, XKind::Val)
        && x_writable(p, m, k, h - 3 - n, XKind::Val)
}

/// `hf_kinds`, into `out`.
pub fn x_hf_kinds_into(k: &Vec<XKind>, n: usize, out: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    requires n + 2 < k.len(),
    ensures res is Ok ==> kv(*final(out)) == hf_kinds(kv(*k), n as int),
{
    let h = k.len();
    x_copy_into(k, out)?;
    vput(out, h - 1 - n, XKind::Val);
    vput(out, h - 2 - n, XKind::Val);
    vput(out, h - 3 - n, XKind::Val);
    try_push(out, XKind::Val)?;
    try_push(out, XKind::Val)?;
    proof {
        assert(kv(*out) =~= kv(*k).update(h - 1 - n, Kind::Val).update(h - 2 - n, Kind::Val).update(h - 3 - n, Kind::Val)
            .push(Kind::Val).push(Kind::Val));
    }
    Ok(())
}

pub fn x_post_misc(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
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
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    if (BRANCH_IF_TRUE <= op && op <= BRANCH_IF_NOT_NULL) || (BRANCH_BACK_IF_TRUE <= op && op <= BRANCH_BACK_IF_NOT_NULL)
        || (BRANCH_IF_TRUE_S <= op && op <= BRANCH_IF_NOT_NULL_S) {
        if x_value_operands(k, 1) { { x_prefix_into(k, h - 1, out)?; Ok(true) } } else { Ok(false) }
    } else if op == PRIMITIVE {
        let index = x_u16(p, bci + 2);
        let a = x_arity(p, m) as usize;
        if !(h == a && x_kind(p, m) == 0) { return Ok(false); }
        if !((b1 as usize) < c.g.prim_arity.len() && (index as usize) < ix_ref(c.g.prim_arity, b1 as usize).len()
            && vix(ix_ref(c.g.prim_arity, b1 as usize), index as usize) as usize == a) {
            return Ok(false);
        }
        if b1 == 0 && index == X_PRIM_TASK_NEW as i64 && a != 1 { return Ok(false); }
        if b1 == 0 && index == X_PRIM_TASK_TRANSFER as i64 {
            if a != 2 { return Ok(false); }
            proof { assert(kv(*k)[0] == k@[0]@); assert(kv(*k)[1] == k@[1]@); }
            if !(x_is_plain(vix(k, 0)) && x_is_plain(vix(k, 1)) && x_recv_start(p, m) == 0xffff) { return Ok(false); }
        }
        { x_push_into(k, XKind::Val, out)?; Ok(true) }
    } else if op == TRY {
        if 1 <= h && x_block_slot(p, c, m as i64, k, (h - 1) as i64) {
            let t = match vix(k, h - 1) { XKind::Method(t) => t, _ => 0 };
            proof { assert(kv(*k)[h - 1] == k@[h - 1]@); assert(kind_method(kv(*k)[h - 1]) == t as int); }
            if x_arity(p, t as usize) == 1 && x_ctx_ok_upto(p, c, m as i64, k, h - 1)? {
                x_copy_into(k, out)?;
                let ghost k0 = kv(*out);
                try_push(out, XKind::Val)?;
                try_push(out, XKind::Token)?;
                try_push(out, XKind::Val)?;
                proof {
                    assert(k0 =~= kv(*k));
                    assert(kv(*out) =~= kv(*k).push(Kind::Val).push(Kind::Token).push(Kind::Val));
                }
                Ok(true)
            } else { Ok(false) }
        } else { Ok(false) }
    } else if op == UNWIND {
        if 3 <= h {
            proof { assert(kv(*k)[h - 2] == k@[h - 2]@); assert(kv(*k)[h - 3] == k@[h - 3]@); }
            if x_is_token(vix(k, h - 2)) && x_is_val(vix(k, h - 3)) {
                { x_prefix_into(k, h - 3, out)?; Ok(true) }
            } else { Ok(false) }
        } else {
            Ok(false)
        }
    } else if op == HALT {
        if b1 == 0 { { x_push_into(k, XKind::Val, out)?; Ok(true) } }
        else if b1 == 1 && x_value_operands(k, 1) { { x_prefix_into(k, h - 1, out)?; Ok(true) } }
        else if trusted && b1 == 2 && 1 <= h { { x_prefix_into(k, h - 1, out)?; Ok(true) } }
        else if trusted && b1 >= 3 { { x_copy_into(k, out)?; Ok(true) } }
        else { Ok(false) }
    } else if op == LOOP_REPEAT || op == LOOP_ARRAY {
        let lc = ix(p.bytecodes, bci + 3) as usize;
        let ly = if op == LOOP_ARRAY { lc + 3 } else { lc + 2 };
        if x_loop_ok(p, m, k, lc, lc + 1, lc + 2, ly) { { x_prefix_into(k, h - 1, out)?; Ok(true) } } else { Ok(false) }
    } else if op == HASH_FIND {
        let n = ix(p.bytecodes, bci + 3) as usize;
        let mm = ix(p.bytecodes, bci + 4) as usize;
        if x_hf_ok(p, m, k, n, mm) { { x_hf_kinds_into(k, n, out)?; Ok(true) } } else { Ok(false) }
    } else {
        Ok(false)
    }
}

/// `post`, the fall-through successor kinds, into the buffer `out` (cleared and refilled): true if there is a
/// successor (then in `out`).
pub fn x_post_into(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires post_pre(p, m, off, k), g_ok(c.g),
    ensures res matches Ok(b) ==> post_rel_into(b, *final(out), post(vview(p), c@, m as int, off as int, kv(*k), trusted)),
{
    let raw = ix(p.bytecodes, x_entry(p, m) + off);
    proof { lemma_base_op(raw); }
    let op = exec_base_op(raw);
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
        || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP {
        x_post_locals(p, c, m, off, k, trusted, out)
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_OUTER_BLOCK || op == LOAD_BLOCK {
        x_post_outer(p, c, m, off, k, trusted, out)
    } else if op == LOAD_FIELD || op == LOAD_FIELD_WIDE || op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL
        || op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP
        || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS {
        x_post_fields(p, c, m, off, k, trusted, out)
    } else if (LOAD_LITERAL <= op && op <= STORE_GLOBAL_VAR_DYNAMIC) || op == POP || op == POP_1
        || op == ALLOCATE || op == ALLOCATE_WIDE || (IS_CLASS <= op && op <= AS_LOCAL) {
        x_post_consts(p, c, m, off, k, trusted, out)
    } else if op == INVOKE_STATIC || op == INVOKE_BLOCK || (INVOKE_VIRTUAL <= op && op <= INVOKE_SIZE) || op == IDENTICAL {
        x_post_calls(p, c, m, off, k, trusted, out)
    } else {
        x_post_misc(p, c, m, off, k, trusted, out)
    }
}

pub fn x_is_terminator(op: u8) -> (r: bool)
    ensures r == is_terminator(op),
{
    op == RETURN || op == RETURN_NULL || op == THROW || op == BRANCH || op == BRANCH_BACK
        || op == INVOKE_STATIC_TAIL || op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
        || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH
        || op == BRANCH_S || op == BRANCH_BACK_S
}

pub open spec fn rev_kinds(r: Seq<XKind>) -> Seq<Kind> {
    Seq::new(r.len(), |j: int| r[r.len() - 1 - j]@)
}

/// The kinds of the list with top node `i` (`chain`), bottom first.
pub fn x_chain(nodes: &CVec<XNode>, i: u32) -> (res: Result<Vec<XKind>, Oom>)
    ensures res matches Ok(r) ==> kv(r) == chain(nodes@, i as int),
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
        let nd = nodes.at(cur);
        let ghost before = rev@;
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes@, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes@, cur as int) == base.push(nd.kind@));
        try_push(&mut rev, nd.kind)?;
        assert(base.push(nd.kind@) + rev_kinds(before) =~= base + rev_kinds(rev@));
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            assert(base + rev_kinds(rev@) =~= rev_kinds(rev@));
            done = true;
        }
    }
    x_reversed(&rev)
}

/// The kinds of the list with top node `i`, top first, into `rev` (its
/// buffer reused): `x_chain` without allocating once `rev` has grown.
pub fn x_chain_rev(nodes: &CVec<XNode>, i: u32, rev: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    ensures res is Ok ==> chain(nodes@, i as int) == rev_kinds(final(rev)@),
{
    rev.clear();
    let mut cur = i as usize;
    let mut done = cur >= nodes.len();
    proof { if done { assert(chain(nodes@, i as int) =~= rev_kinds(rev@)); } }
    while !done
        invariant
            done ==> chain(nodes@, i as int) == rev_kinds(rev@),
            !done ==> cur < nodes@.len() && chain(nodes@, i as int) == chain(nodes@, cur as int) + rev_kinds(rev@),
        decreases (if done { 0int } else { cur as int + 1 }),
    {
        let nd = nodes.at(cur);
        let ghost before = rev@;
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes@, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes@, cur as int) == base.push(nd.kind@));
        try_push(rev, nd.kind)?;
        assert(base.push(nd.kind@) + rev_kinds(before) =~= base + rev_kinds(rev@));
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            assert(base + rev_kinds(rev@) =~= rev_kinds(rev@));
            done = true;
        }
    }
    Ok(())
}

/// The kinds of `rev` in reverse order, into `r` (its buffer reused).
pub fn x_reversed_into(rev: &Vec<XKind>, r: &mut Vec<XKind>) -> (res: Result<(), Oom>)
    ensures res is Ok ==> kv(*final(r)) == rev_kinds(rev@),
{
    r.clear();
    let mut j = rev.len();
    proof { assert(kv(*r) =~= rev_kinds(rev@).subrange(0, 0)); }
    while j > 0
        invariant 0 <= j <= rev@.len(), kv(*r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int),
        decreases j,
    {
        j -= 1;
        let ghost old_r = kv(*r);
        try_push(r, vix(rev, j))?;
        assert(kv(*r) =~= old_r.push(rev@[j as int]@));
        assert(rev_kinds(rev@)[rev@.len() - 1 - j] == rev@[j as int]@);
        assert(kv(*r) =~= rev_kinds(rev@).subrange(0, (rev@.len() - j) as int));
    }
    assert(kv(*r) =~= rev_kinds(rev@));
    Ok(())
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

pub fn x_pin_key(g: &XGlobal, i: usize) -> (r: u64)
    ensures r as int == pin_key(g, i as int),
{
    let pm = x_fld(g.pins, 12, i, 0);
    let po = x_fld(g.pins, 12, i, 4);
    assert(pm as int * 0x1_0000_0000 <= 0xffff_ffff * 0x1_0000_0000) by (nonlinear_arith) requires pm <= 0xffff_ffff;
    (pm as u64) * 0x1_0000_0000 + po as u64
}

/// The pin of method `m` at offset `off`.
pub fn x_pin_find(g: &XGlobal, m: u32, off: u32) -> (r: Option<usize>)
    requires pins_sorted(g),
    ensures
        match r {
            Some(i) => i < npins(g) && pin_m(g, i as int) == m && pin_off(g, i as int) == off
                && pin_view(g, m as int, off as int) == Some(pin_kinds(g, i as int)),
            None => pin_view(g, m as int, off as int) is None,
        },
{
    assert(m as int * 0x1_0000_0000 <= 0xffff_ffff * 0x1_0000_0000) by (nonlinear_arith) requires m <= 0xffff_ffff;
    let key: u64 = (m as u64) * 0x1_0000_0000 + off as u64;
    let mut lo: usize = 0;
    let mut hi: usize = g.pins.len() / 12;
    while lo < hi
        invariant
            0 <= lo <= hi <= npins(g), pins_sorted(g), key as int == m as int * 0x1_0000_0000 + off as int,
            forall|i: int| 0 <= i < lo ==> #[trigger] pin_key(g, i) < key,
            forall|i: int| hi <= i < npins(g) ==> #[trigger] pin_key(g, i) > key,
        decreases hi - lo,
    {
        let mid = lo + (hi - lo) / 2;
        let k = x_pin_key(g, mid);
        if k == key {
            proof {
                lemma_key(pin_m(g, mid as int) as int, pin_off(g, mid as int) as int, m as int, off as int);
                assert(has_pin(g, m as int, off as int));
                let j = choose|j: int| 0 <= j < npins(g) && #[trigger] pin_m(g, j) == m && pin_off(g, j) == off;
                lemma_key(pin_m(g, j) as int, pin_off(g, j) as int, m as int, off as int);
                if j < mid { assert(pin_key(g, j) < pin_key(g, mid as int)); }
                if j > mid { assert(pin_key(g, mid as int) < pin_key(g, j)); }
            }
            return Some(mid);
        } else if k < key {
            proof {
                assert forall|i: int| 0 <= i < mid + 1 implies #[trigger] pin_key(g, i) < key by {
                    if i < mid { assert(pin_key(g, i) < pin_key(g, mid as int)); }
                }
            }
            lo = mid + 1;
        } else {
            proof {
                assert forall|i: int| mid <= i < npins(g) implies #[trigger] pin_key(g, i) > key by {
                    if i > mid { assert(pin_key(g, mid as int) < pin_key(g, i)); }
                }
            }
            hi = mid;
        }
    }
    proof {
        if has_pin(g, m as int, off as int) {
            let j = choose|j: int| 0 <= j < npins(g) && #[trigger] pin_m(g, j) == m && pin_off(g, j) == off;
            lemma_key(pin_m(g, j) as int, pin_off(g, j) as int, m as int, off as int);
            assert(pin_key(g, j) == key);
        }
    }
    None
}

pub fn x_map_at(c: &XCert, m: i64, off: i64) -> (res: Result<Option<Vec<XKind>>, Oom>)
    requires g_ok(c.g),
    ensures res matches Ok(r) ==> okv(r) == map_at(c@, m as int, off as int),
{
    let ghost cc = c@;
    if m < 0 || (m as u64) >= (c.g.n as u64) || off < 0 {
        return Ok(None);
    }
    assert(cc.maps.len() == c.g.n);
    if c.cur < c.g.n && m as usize == c.cur {
        assert(cc.maps[m as int] == mapsv(c.maps));
        if (off as u64) >= (c.maps.idx.len() as u64) {
            return Ok(None);
        }
        assert(cc.maps[m as int][off as int] == map_view(c.maps, off as int));
        let i = c.maps.idx.at(off as usize);
        if i == NO_MAP {
            Ok(None)
        } else {
            let k = x_chain(&c.maps.nodes, i)?;
            assert(map_at(cc, m as int, off as int) == Some(kv(k)));
            Ok(Some(k))
        }
    } else {
        assert(cc.maps[m as int] == pin_maps(c.g@)[m as int]);
        if off >= 0x1000_0000 {
            assert(cc.maps[m as int].len() == PIN_SPAN);
            return Ok(None);
        }
        if m > 0xffff_ffff {
            // Pins are of methods below 2^32.
            assert(!has_pin(c.g, m as int, off as int));
            return Ok(None);
        }
        assert(cc.maps[m as int][off as int] == pin_at(c.g@, m as int, off as int));
        assert(pin_at(c.g@, m as int, off as int) == pin_view(c.g, m as int, off as int));
        match x_pin_find(c.g, m as u32, off as u32) {
            Some(i) => {
                let k = x_fchain(c.g.nodes, x_fld(c.g.pins, 12, i, 8))?;
                assert(pin_view(c.g, m as int, off as int) == Some(kv(k)));
                assert(cc.maps[m as int][off as int] == Some(kv(k)));
                assert(0 <= off < cc.maps[m as int].len());
                assert(map_at(cc, m as int, off as int) == Some(kv(k)));
                Ok(Some(k))
            },
            None => Ok(None),
        }
    }
}

/// `chain(nodes, i) == kv(k)`, without building the chain.
pub fn x_chain_is(nodes: &CVec<XNode>, i: u32, k: &Vec<XKind>) -> (r: bool)
    ensures r == (chain(nodes@, i as int) == kv(*k)),
{
    let ghost s = kv(*k);
    let mut j = k.len();
    let mut cur = i as usize;
    let mut done = cur >= nodes.len();
    proof {
        assert(s.subrange(0, j as int) =~= s);
        if done {
            assert(chain(nodes@, i as int) =~= Seq::<Kind>::empty());
            if j > 0 { assert(s.len() > 0); }
            else { assert(s =~= Seq::<Kind>::empty()); }
        }
    }
    while !done
        invariant
            0 <= j <= k@.len(), s == kv(*k),
            done ==> (chain(nodes@, i as int) == s) == (j == 0),
            !done ==> cur < nodes@.len()
                && (chain(nodes@, i as int) == s) == (chain(nodes@, cur as int) == s.subrange(0, j as int)),
        decreases (if done { 0int } else { cur as int + 1 }),
    {
        let nd = nodes.at(cur);
        let ghost par = nd.parent as int;
        let ghost base = if par < cur { chain(nodes@, par) } else { Seq::<Kind>::empty() };
        assert(chain(nodes@, cur as int) == base.push(nd.kind@));
        if j == 0 {
            assert(chain(nodes@, cur as int).len() > 0);
            assert(chain(nodes@, cur as int) != s.subrange(0, 0));
            return false;
        }
        assert(s[j - 1] == k@[j - 1]@);
        if !x_kind_eq(nd.kind, vix(k, j - 1)) {
            proof {
                assert(chain(nodes@, cur as int)[base.len() as int] == nd.kind@);
                if chain(nodes@, cur as int) == s.subrange(0, j as int) {
                    assert(base.len() == j - 1);
                    assert(s.subrange(0, j as int)[j - 1] == s[j - 1]);
                }
            }
            return false;
        }
        proof {
            let full = chain(nodes@, cur as int);
            let pre = s.subrange(0, j as int);
            if base == s.subrange(0, j - 1) {
                assert(full =~= pre);
            }
            if full == pre {
                assert(base =~= full.drop_last());
                assert(pre.drop_last() =~= s.subrange(0, j - 1));
            }
        }
        j -= 1;
        if (nd.parent as usize) < cur {
            cur = nd.parent as usize;
        } else {
            proof {
                if j == 0 { assert(s.subrange(0, 0) =~= Seq::<Kind>::empty()); }
                else { assert(s.subrange(0, j as int).len() > 0); }
            }
            done = true;
        }
    }
    j == 0
}

pub fn x_map_is(c: &XCert, m: i64, off: i64, k: &Vec<XKind>) -> (res: Result<bool, Oom>)
    requires g_ok(c.g),
    ensures res matches Ok(r) ==> r == (map_at(c@, m as int, off as int) == Some(kv(*k))),
{
    let ghost cc = c@;
    if c.cur < c.g.n && m >= 0 && (m as u64) < (c.g.n as u64) && m as usize == c.cur && off >= 0 {
        // The current method's maps: compare in place.
        assert(cc.maps.len() == c.g.n);
        assert(cc.maps[m as int] == mapsv(c.maps));
        if (off as u64) >= (c.maps.idx.len() as u64) {
            return Ok(false);
        }
        assert(cc.maps[m as int][off as int] == map_view(c.maps, off as int));
        let i = c.maps.idx.at(off as usize);
        if i == NO_MAP { return Ok(false); }
        return Ok(x_chain_is(&c.maps.nodes, i, k));
    }
    match x_map_at(c, m, off)? {
        Some(k2) => Ok(x_kinds_eq(&k2, k)),
        None => Ok(false),
    }
}

#[verifier::loop_isolation(false)]
pub fn x_terminator_ok(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>) -> (res: Result<bool, Oom>)
    requires
        g_ok(c.g),
        wf_program2(vview(p)),
        m < p.methods@.len(),
        vinfo(p, m as int).entry + off + opcode_length2(p.bytecodes[vinfo(p, m as int).entry + off]) <= vinfo(p, m as int).end,
        p.bytecodes[vinfo(p, m as int).entry + off] < OPCODE_COUNT2,
    ensures res matches Ok(r) ==> r == terminator_ok(vview(p), c@, m as int, off as int, kv(*k)),
{
    let (bci, op, len, b1, w1) = x_decode(p, m, off);
    let h = k.len();
    let ghost kk = kv(*k);
    if op == RETURN {
        if 1 <= h { proof { assert(kk[h - 1] == k@[h - 1]@); } }
        Ok(1 <= h && x_is_val(vix(k, h - 1)))
    } else if op == RETURN_NULL {
        Ok(true)
    } else if op == THROW {
        Ok(x_value_operands(k, 1))
    } else if op == INVOKE_STATIC_TAIL {
        let t = x_dispatch_target(p, w1);
        if !x_valid(p, t) { return Ok(false); }
        let a = x_arity(p, t as usize) as usize;
        if !x_args_ok(c, t as usize, k, a) { return Ok(false); }
        let mut j = h - a;
        while j < h
            invariant a <= h, h == k.len(), h - a <= j <= h, kk == kv(*k),
                forall|jj: int| h - a <= jj < j ==> !is_local_ref(#[trigger] kk[jj]),
            decreases h - j,
        {
            proof { assert(kk[j as int] == k@[j as int]@); }
            match vix(k, j) {
                XKind::Block(0, _) => {
                    proof { assert(is_local_ref(kk[j as int])); }
                    return Ok(false);
                },
                _ => {},
            }
            j += 1;
        }
        Ok(true)
    } else if op == INVOKE_LAMBDA_TAIL {
        if !(x_kind(p, m) == 0 && h == x_arity(p, m) as usize && h >= 1) { return Ok(false); }
        let mut i = 0;
        while i < h
            invariant h == k.len(), 0 <= i <= h, kk == kv(*k), forall|ii: int| 0 <= ii < i ==> is_val(#[trigger] kk[ii]),
            decreases h - i,
        {
            proof { assert(kk[i as int] == k@[i as int]@); }
            if !x_is_val(vix(k, i)) {
                proof { assert(!is_val(kk[i as int])); }
                return Ok(false);
            }
            i += 1;
        }
        Ok(true)
    } else if op == INVOKE_INITIALIZER_TAIL {
        Ok(x_value_operands(k, 1))
    } else if op == NON_LOCAL_RETURN {
        if 2 <= h { proof { assert(kk[h - 1] == k@[h - 1]@); assert(kk[h - 2] == k@[h - 2]@); } }
        Ok(2 <= h && x_is_val(vix(k, h - 2)) && match vix(k, h - 1) { XKind::Block(d, _) => d >= 1, _ => false })
    } else if op == NON_LOCAL_BRANCH {
        if h < 1 { return Ok(false); }
        proof { assert(kk[h - 1] == k@[h - 1]@); }
        match vix(k, h - 1) {
            XKind::Block(d, j) => {
                if d < 1 { return Ok(false); }
                let (fk, om) = x_ctx_kinds(c, m as i64, d)?;
                let target = x_u32(p, bci + 2);
                match (fk, x_map_at(c, om, target)?) {
                    (Some(fk), Some(t)) => {
                        if !(x_valid(p, om) && b1 <= j as i64 + 1 && (j as usize) < fk.len()) { return Ok(false); }
                        let n = (j as i64 + 1 - b1) as usize;
                        if t.len() != n {
                            proof { assert(kv(t).len() != kv(fk).subrange(0, n as int).len()); }
                            return Ok(false);
                        }
                        let mut i = 0;
                        while i < n
                            invariant n == t.len(), n <= fk.len(), 0 <= i <= n,
                                forall|ii: int| 0 <= ii < i ==> (#[trigger] t@[ii])@ == fk@[ii]@,
                            decreases n - i,
                        {
                            if !x_kind_eq(vix(&t, i), vix(&fk, i)) {
                                proof { assert(kv(t)[i as int] != kv(fk).subrange(0, n as int)[i as int]); }
                                return Ok(false);
                            }
                            i += 1;
                        }
                        proof { assert(kv(t) =~= kv(fk).subrange(0, n as int)); }
                        Ok(true)
                    },
                    _ => Ok(false),
                }
            },
            _ => Ok(false),
        }
    } else if op == BRANCH || op == BRANCH_BACK || op == BRANCH_S || op == BRANCH_BACK_S {
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn x_shape_ok(p: &VProgram, c: &XCert, m: usize, k: &Vec<XKind>) -> (r: bool)
    requires m < p.methods@.len(),
    ensures r == shape_ok(vview(p), c@, m as int, kv(*k)),
{
    if x_pinned0(p, m) && x_arity(p, m) >= 1 && k.len() < 1 { return false; }
    if x_kind(p, m) == 3 {
        if k.len() < 1 { return false; }
        proof { assert(kv(*k)[0] == k@[0]@); }
        match x_ctx_of(c, m) {
            Some(ctx) => x_kind_eq(vix(k, 0), XKind::Block(1, ctx.slot)),
            None => false,
        }
    } else {
        true
    }
}

pub fn x_instr_ok(p: &VProgram, c: &XCert, m: usize, i: MethodInfo, off: usize, k: &Vec<XKind>, trusted: bool, out: &mut Vec<XKind>) -> (res: Result<bool, Oom>)
    requires wf_program2(vview(p)), m < p.methods@.len(), g_ok(c.g), i == vinfo(p, m as int),
    ensures res matches Ok(r) ==> r == instr_ok(vview(p), c@, m as int, off as int, kv(*k), trusted),
{
    // `i`: the method's info, decoded once per method by the caller.
    if !(off < i.end - i.entry) { return Ok(false); }
    let bci = i.entry + off;
    let raw = ix(p.bytecodes, bci);
    if raw >= OPCODE_COUNT2 { return Ok(false); }
    // The unchecked twins only in the unchecked mode (format note 20).
    if exec_is_twin(raw) && !p.unchecked { return Ok(false); }
    proof { lemma_base_op(raw); }
    let op = exec_base_op(raw);
    let len = exec_opcode_length2(op);
    if bci + len > i.end { return Ok(false); }
    if k.len() > i.arity as usize + i.max_height as usize { return Ok(false); }
    if !x_wf_kinds(p, c, m as i64, k, out)? || !x_ctx_ok(p, c, m as i64, k)? || !x_shape_ok(p, c, m, k) {
        return Ok(false);
    }
    // The successor goes into `out` (a buffer of the caller).
    let has_post = x_post_into(p, c, m, off, k, trusted, out)?;
    proof { lemma_map_repr(c, m as int, (off + len) as int); }
    if x_is_terminator(op) {
        if !x_terminator_ok(p, c, m, off, k)? { return Ok(false); }
    } else if !has_post {
        return Ok(false);
    }
    if has_post {
        if !x_map_is(c, m as i64, (off + len) as i64, &*out)? { return Ok(false); }
    }
    if (BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL) || (BRANCH_S <= op && op <= BRANCH_BACK_S) {
        // The distance: a u16, or one byte for a short branch (note 22).
        let short = BRANCH_S <= op;
        let w1 = if short { ix(p.bytecodes, bci + 1) as i64 } else { x_u16(p, bci + 1) };
        let fwd = op <= BRANCH_IF_NOT_NULL || (short && op <= BRANCH_IF_NOT_NULL_S);
        let t = if fwd { off as i64 + w1 } else { off as i64 - w1 };
        if fwd && w1 <= 0 { return Ok(false); }
        if op == BRANCH || op == BRANCH_BACK || op == BRANCH_S || op == BRANCH_BACK_S {
            if !x_map_is(c, m as i64, t, k)? { return Ok(false); }
        } else {
            if k.len() < 1 { return Ok(false); }
            x_prefix_into(k, k.len() - 1, out)?;
            if !x_map_is(c, m as i64, t, &*out)? { return Ok(false); }
        }
    }
    if op == LOOP_REPEAT || op == LOOP_ARRAY {
        // `post` accepted the operands (`loop_ok`).
        let w1 = x_u16(p, bci + 1);
        let lc = ix(p.bytecodes, bci + 3) as usize;
        let kt = x_loop_kinds(k, lc, lc + 1)?;
        if !x_map_is(c, m as i64, off as i64 - w1, &kt)? { return Ok(false); }
    }
    if op == HASH_FIND {
        let w1 = x_u16(p, bci + 1);
        if w1 <= 0 { return Ok(false); }
        let kt = x_push(k, XKind::Val)?;
        if !x_map_is(c, m as i64, off as i64 + w1, &kt)? { return Ok(false); }
    }
    Ok(true)
}

pub fn x_entry_kinds(p: &VProgram, c: &XCert, m: usize) -> (res: Result<Vec<XKind>, Oom>)
    requires m < p.methods@.len(),
    ensures res matches Ok(r) ==> kv(r) == entry_kinds(vview(p), c@, m as int),
{
    let a = x_arity(p, m) as usize;
    let ghost e = entry_kinds(vview(p), c@, m as int);
    let mut r: Vec<XKind> = try_with_capacity(a)?;
    let mut i = 0;
    while i < a
        invariant m < p.methods@.len(), a == vinfo(p, m as int).arity, e == entry_kinds(vview(p), c@, m as int),
            0 <= i <= a, r.len() == i, forall|ii: int| 0 <= ii < i ==> #[trigger] kv(r)[ii] == e[ii],
        decreases a - i,
    {
        let ghost before = r@;
        let ghost before_k = kv(r);
        if x_kind(p, m) == 3 {
            if i == 0 {
                match x_ctx_of(c, m) {
                    Some(ctx) => try_push(&mut r, XKind::Block(1, ctx.slot))?,
                    None => try_push(&mut r, XKind::Param)?,
                }
            } else {
                try_push(&mut r, XKind::Val)?;
            }
        } else if x_is_block_param(c, m, i) {
            try_push(&mut r, XKind::Param)?;
        } else {
            try_push(&mut r, XKind::Val)?;
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
    Ok(r)
}

/// Every mapped instruction of `m` is accepted.
/// Scratch buffers of the checker, kept across instructions and methods
/// (no allocation once they have grown): the kinds of an instruction (`k`,
/// built top first in `rev`) and its successor or other derived kinds.
pub struct XBufs {
    pub rev: Vec<XKind>,
    pub k: Vec<XKind>,
    pub post: Vec<XKind>,
}

pub fn x_method_body_ok(p: &VProgram, c: &XCert, m: usize, trusted: bool, bufs: &mut XBufs) -> (res: Result<bool, Oom>)
    requires wf_program2(vview(p)), m < p.methods@.len(), m == c.cur, c.cur < c.g.n, g_ok(c.g),
    ensures res matches Ok(r) ==> r == forall|o: int| 0 <= o < c@.maps[m as int].len() && (#[trigger] c@.maps[m as int][o]) is Some ==>
        instr_ok(vview(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
{
    // Only the name matters here (x_instr_ok decides it).
    hide(instr_ok);
    let ghost cm = c@.maps[m as int];
    assert(cm == mapsv(c.maps));
    let mut off = 0;
    // Each instruction's map is built in the reused buffers.
    let info = x_info(p, m);
    while off < c.maps.idx.len()
        invariant
            wf_program2(vview(p)), m < p.methods@.len(), m == c.cur, c.cur < c.g.n, g_ok(c.g),
            info == vinfo(p, m as int),
            cm == c@.maps[m as int], cm == mapsv(c.maps),
            0 <= off <= c.maps.idx@.len(),
            forall|o: int| 0 <= o < off && (#[trigger] c@.maps[m as int][o]) is Some ==>
                instr_ok(vview(p), c@, m as int, o, c@.maps[m as int][o]->0, trusted),
        decreases c.maps.idx@.len() - off,
    {
        let i = c.maps.idx.at(off);
        if i != NO_MAP {
            x_chain_rev(&c.maps.nodes, i, &mut bufs.rev)?;
            x_reversed_into(&bufs.rev, &mut bufs.k)?;
            assert(kv(bufs.k) == chain(c.maps.nodes@, i as int));
            assert(cm[off as int] == Some(kv(bufs.k)));
            if !x_instr_ok(p, c, m, info, off, &bufs.k, trusted, &mut bufs.post)? {
                return Ok(false);
            }
        }
        off += 1;
    }
    Ok(true)
}

pub fn x_method_ok(p: &VProgram, c: &XCert, m: usize, trusted: bool, bufs: &mut XBufs) -> (res: Result<bool, Oom>)
    requires
        wf_program2(vview(p)), m < p.methods@.len(), c.g.n == p.methods@.len(), m == c.cur, g_ok(c.g),
    ensures res matches Ok(r) ==> r == method_ok(vview(p), c@, m as int, trusted),
{
    let ghost cc = c@;
    assert(cc.maps[m as int] == mapsv(c.maps));
    let i = x_info(p, m);
    if !(i.entry < i.end && i.end <= p.bytecodes.len()) { return Ok(false); }
    if c.maps.idx.len() != i.end - i.entry { return Ok(false); }
    if x_bp_len(c, m) != i.arity as usize { return Ok(false); }
    let ctx = x_ctx_of(c, m);
    assert(cc.contexts[m as int] == ctx_of(cc, m as int));
    if ctx.is_some() && i.kind != 3 { return Ok(false); }
    if i.kind == 3 && ctx.is_none() { return Ok(true); }
    let e = x_entry_kinds(p, c, m)?;
    if !x_map_is(c, m as i64, 0, &e)? { return Ok(false); }
    x_method_body_ok(p, c, m, trusted, bufs)
}

// ---------------------------------------------------------------------------
// Tables.

pub fn x_machine_class_ok(p: &VProgram, k: usize) -> (r: bool)
    requires k < p.builtin.len(),
    ensures r == machine_class_ok(vview(p), k as int),
{
    let cl = ix(p.builtin, k) as i64;
    0 <= cl && (cl as u64) < (p.class_bits.len() as u64) && !(x_is_field_class(p, cl) && x_ifc(p, cl as usize) >= 1)
}

pub fn x_entry_method(p: &VProgram, k: usize) -> (r: i64)
    requires k < p.entry_points.len(),
    ensures r as int == entry_method(vview(p), k as int),
{
    let d = ix(p.entry_points, k) as i64;
    if 0 <= d && (d as u64) < (p.dispatch.len() as u64) { ix(p.dispatch, d as usize) as i64 } else { -1 }
}

pub fn x_entry_ok(p: &VProgram, c: &XCert, k: usize, a: u8) -> (r: bool)
    requires k < p.entry_points.len(), c.g.n == p.methods@.len(),
    ensures r == entry_ok(vview(p), c@, k as int, a as int),
{
    let e = x_entry_method(p, k);
    x_valid(p, e) && x_kind(p, e as usize) == 0 && x_arity(p, e as usize) == a
        && x_no_block_params(c, e as usize)
}

pub fn x_dispatch_entry_ok(p: &VProgram, d: usize) -> (r: bool)
    requires d < p.dispatch.len(), p.dispatch.len() < 0x1000_0000,
    ensures r == dispatch_entry_ok(vview(p), d as int),
{
    let t = ix(p.dispatch, d) as i64;
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
    requires m < p.methods@.len(), c.g.n == p.methods@.len(), g_ok(c.g),
    ensures r == method_table_ok(vview(p), c@, m as int),
{
    let ghost cc = c@;
    let i = x_info(p, m);
    let s = i.selector as usize;
    if x_bp_len(c, m) != i.arity as usize { return false; }
    if i.selector != 0xffff {
        let r = x_sel_rep(c, s);
        if !(x_valid(p, r) && x_arity(p, r as usize) == i.arity
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

pub fn x_tables_ok(p: &VProgram, c: &XCert) -> (res: Result<bool, Oom>)
    requires wf_program2(vview(p)), c.cur >= c.g.n, g_ok(c.g),
    ensures res matches Ok(r) ==> r == tables_ok(vview(p), c@),
{
    let ghost pv = vview(p);
    let ghost cc = c@;
    let n = p.methods.len();
    if c.g.n != n { return Ok(false); }
    let ns = c.g.sel.len() / 8;
    let mut j = 0;
    while j < ns
        invariant 0 <= j <= ns, ns == nsel(c.g), g_ok(c.g), cc == c@, pv == vview(p),
            forall|jj: int| 0 <= jj < j && sel_key(c.g, jj) < 0xffff ==> #[trigger] sel_rep_ok(pv, cc, sel_key(c.g, jj) as int),
        decreases ns - j,
    {
        let s = x_fld(c.g.sel, 8, j, 0);
        if s < 0xffff {
            let r = x_fld(c.g.sel, 8, j, 4) as i64;
            proof { lemma_sel_unique(c.g, j as int); assert(cc.sel_rep[s as int] == r as int); }
            if !(x_valid(p, r) && x_info(p, r as usize).selector as u64 == s as u64) {
                proof { assert(!sel_rep_ok(pv, cc, s as int)); }
                return Ok(false);
            }
        }
        j += 1;
    }
    proof {
        assert forall|ss: int| 0 <= ss < cc.sel_rep.len() implies #[trigger] sel_rep_ok(pv, cc, ss) by {
            if has_sel(c.g, ss) {
                let jj = choose|jj: int| 0 <= jj < nsel(c.g) && #[trigger] sel_key(c.g, jj) == ss;
                assert(sel_rep_ok(pv, cc, sel_key(c.g, jj) as int));
            } else {
                assert(cc.sel_rep[ss] == -1);
            }
        }
    }
    let mut d = 0;
    while d < p.dispatch.len()
        invariant wf_program2(pv), pv == vview(p), 0 <= d <= p.dispatch.len(),
            forall|dd: int| 0 <= dd < d ==> #[trigger] dispatch_entry_ok(pv, dd),
        decreases p.dispatch.len() - d,
    {
        if !x_dispatch_entry_ok(p, d) { return Ok(false); }
        d += 1;
    }
    let mut m = 0;
    while m < n
        invariant n == p.methods@.len(), c.g.n == n, 0 <= m <= n, pv == vview(p), cc == c@,
            g_ok(c.g),
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_table_ok(pv, cc, mm),
        decreases n - m,
    {
        if !x_method_table_ok(p, c, m) { return Ok(false); }
        m += 1;
    }
    let mut k = 0;
    while k < p.interface_check_offsets.len()
        invariant 0 <= k <= p.interface_check_offsets.len(), pv == vview(p),
            forall|kk: int| 0 <= kk < k ==> class_count(pv) + (#[trigger] pv.interface_check_offsets[kk]) as int <= pv.dispatch.len(),
        decreases p.interface_check_offsets.len() - k,
    {
        if !x_row_fits(p, ix(p.interface_check_offsets, k) as usize) { return Ok(false); }
        k += 1;
    }
    if !(x_machine_class_ok(p, 15) && x_machine_class_ok(p, 11) && x_machine_class_ok(p, 16) && x_machine_class_ok(p, 18)) {
        return Ok(false);
    }
    let ex = ix(p.builtin, 22) as i64;
    if !(x_is_field_class(p, ex) && x_ifc(p, ex as usize) >= 2) { return Ok(false); }
    let tc = ix(p.builtin, 19) as i64;
    if !(x_is_field_class(p, tc) && x_ifc(p, tc as usize) >= 2) { return Ok(false); }
    if !x_task_class_ok(p) { return Ok(false); }
    if !x_entry_ok(p, c, 0, 1) { return Ok(false); }
    if x_info(p, x_entry_method(p, 0) as usize).recv_start != 0xffff { return Ok(false); }
    if !x_entry_ok(p, c, 2, 1) { return Ok(false); }
    if x_info(p, x_entry_method(p, 2) as usize).recv_start != 0xffff { return Ok(false); }
    let mut two: Vec<XKind> = try_with_capacity(2)?;
    try_push(&mut two, XKind::Val)?;
    try_push(&mut two, XKind::Val)?;
    proof { assert(kv(two) =~= seq![Kind::Val, Kind::Val]); }
    if !x_map_is(c, x_entry_method(p, 2), 1, &two)? { return Ok(false); }
    Ok(x_entry_ok(p, c, 8, 2))
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
        invariant 0 <= m <= p.methods@.len(), pv == vview(p),
            forall|mm: int| 0 <= mm < m ==> #[trigger] pv.methods[mm].entry <= pv.methods[mm].end <= pv.bytecodes.len(),
        decreases p.methods@.len() - m,
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
    let n = g.pins.len() / 12;
    let mut i = 1;
    if n == 0 { return true; }
    while i < n
        invariant 1 <= i <= n, n == npins(g),
            forall|a: int, b: int| 0 <= a < b < i ==> #[trigger] pin_key(g, a) < #[trigger] pin_key(g, b),
        decreases n - i,
    {
        if x_pin_key(g, i - 1) >= x_pin_key(g, i) {
            return false;
        }
        proof {
            assert forall|a: int, b: int| 0 <= a < b < i + 1 implies #[trigger] pin_key(g, a) < #[trigger] pin_key(g, b) by {
                if b == i && a < i - 1 {
                    assert(pin_key(g, a) < pin_key(g, i - 1));
                }
            }
        }
        i += 1;
    }
    true
}

/// The selector records are strictly sorted.
pub fn x_sel_sorted(g: &XGlobal) -> (r: bool)
    ensures r == sel_sorted(g),
{
    let n = g.sel.len() / 8;
    let mut i = 1;
    if n == 0 { return true; }
    while i < n
        invariant 1 <= i <= n, n == nsel(g),
            forall|a: int, b: int| 0 <= a < b < i ==> #[trigger] sel_key(g, a) < #[trigger] sel_key(g, b),
        decreases n - i,
    {
        if x_fld(g.sel, 8, i - 1, 0) >= x_fld(g.sel, 8, i, 0) {
            proof { assert(sel_key(g, i - 1) >= sel_key(g, i as int)); }
            return false;
        }
        proof {
            assert forall|a: int, b: int| 0 <= a < b < i + 1 implies #[trigger] sel_key(g, a) < #[trigger] sel_key(g, b) by {
                if b == i && a < i - 1 {
                    assert(sel_key(g, a) < sel_key(g, i - 1));
                }
            }
        }
        i += 1;
    }
    true
}

/// `g_ok(g)`.
pub fn x_g_ok(g: &XGlobal) -> (r: bool)
    ensures r == g_ok(g),
{
    x_sel_sorted(g) && x_pins_sorted(g)
}

/// Computes the maps of a method for the checker (untrusted: `v2::infer`
/// or the decoder of a shipped certificate, `v2::cert`; the checker
/// decides whatever it returns). `Err(Oom)`: out of memory.
pub trait MapOracle {
    fn method_maps(&mut self, p: &VProgram, g: &XGlobal, m: usize) -> Result<XMaps, Oom>
        requires wf_program2(vview(p)), g_ok(g), m < p.methods@.len(), g.n == p.methods@.len();
}

/// Pin `i` agrees with the maps `mm`.
pub open spec fn pin_agrees(g: &XGlobal, i: int, mm: Maps) -> bool {
    (pin_off(g, i) as int) < mm.len() && mm[pin_off(g, i) as int] == Some(pin_kinds(g, i))
}

/// The pins of method `m` (from `pins[at]` on, where the pins of the
/// methods below `m` end) agree with its maps. Returns where the pins of
/// `m` end, or `None` if one disagrees.
pub fn x_pins_agree(g: &XGlobal, m: usize, maps: &XMaps, at: usize) -> (res: Result<Option<usize>, Oom>)
    requires
        pins_sorted(g), at <= npins(g),
        forall|i: int| at <= i < npins(g) ==> #[trigger] pin_m(g, i) >= m,
    ensures
        res matches Ok(r) ==> match r {
            Some(e) => at <= e <= npins(g)
                && (forall|i: int| e <= i < npins(g) ==> #[trigger] pin_m(g, i) > m)
                && (forall|i: int| at <= i < e ==> #[trigger] pin_m(g, i) == m && pin_agrees(g, i, mapsv(maps))),
            None => exists|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && !pin_agrees(g, i, mapsv(maps)),
        },
{
    let n = g.pins.len() / 12;
    let mut i = at;
    while i < n && x_fld(g.pins, 12, i, 0) as usize == m
        invariant
            pins_sorted(g), at <= i <= n, n == npins(g),
            forall|j: int| at <= j < npins(g) ==> #[trigger] pin_m(g, j) >= m,
            forall|j: int| at <= j < i ==> #[trigger] pin_m(g, j) == m && pin_agrees(g, j, mapsv(maps)),
        decreases n - i,
    {
        let off = x_fld(g.pins, 12, i, 4);
        proof { assert(pin_m(g, i as int) == m); assert(pin_off(g, i as int) == off); }
        if (off as usize) >= maps.idx.len() {
            proof { assert(!pin_agrees(g, i as int, mapsv(maps))); }
            return Ok(None);
        }
        let top = maps.idx.at(off as usize);
        proof { assert(mapsv(maps)[off as int] == map_view(maps, off as int)); }
        if top == NO_MAP {
            proof { assert(!pin_agrees(g, i as int, mapsv(maps))); }
            return Ok(None);
        }
        let k = x_chain(&maps.nodes, top)?;
        let pk = x_fchain(g.nodes, x_fld(g.pins, 12, i, 8))?;
        proof { assert(kv(pk) == pin_kinds(g, i as int)); assert(mapsv(maps)[off as int] == Some(kv(k))); }
        if !x_kinds_eq(&k, &pk) {
            proof { assert(!pin_agrees(g, i as int, mapsv(maps))); }
            return Ok(None);
        }
        proof {
            assert(pin_agrees(g, i as int, mapsv(maps)));
            // The invariant for i + 1 (stated explicitly: without it the
            // proof was unstable under `cargo verus verify`).
            assert forall|j: int| at <= j < i + 1 implies #[trigger] pin_m(g, j) == m && pin_agrees(g, j, mapsv(maps)) by {
                if j == i as int { assert(pin_m(g, i as int) == m); }
            }
        }
        i += 1;
    }
    proof {
        if i < n { assert(pin_m(g, i as int) >= m); assert(pin_m(g, i as int) as usize != m); assert(pin_m(g, i as int) > m); }
        assert forall|j: int| i <= j < npins(g) implies #[trigger] pin_m(g, j) > m by {
            if j > i {
                lemma_key(pin_m(g, i as int) as int, pin_off(g, i as int) as int, pin_m(g, j) as int, pin_off(g, j) as int);
                assert(pin_key(g, i as int) < pin_key(g, j));
            }
        }
    }
    Ok(Some(i))
}

/// The structural verifier, one method at a time: the global part of the
/// certificate is `g`, the maps of each method come from `o` and are
/// dropped after the method is checked. Returns exactly whether the sorted
/// tables are sorted and `split_ok` holds for the maps it was given (`ms`),
/// or `Err(Oom)` if an allocation failed; by `v2::split`, `split_ok`
/// implies `accepts` of the assembled certificate, and an accepted
/// certificate always splits.
pub fn verify<O: MapOracle>(p: &VProgram, g: &XGlobal, o: &mut O, trusted: bool) -> (res: Result<(bool, Ghost<Seq<Maps>>), Oom>)
    ensures res matches Ok(r) ==> r.0 == (g_ok(g) && split_ok(vview(p), g@, r.1@, trusted)),
{
    let ghost pv = vview(p);
    let ghost pad = Seq::new(g.n as nat, |m: int| Seq::<Option<Seq<Kind>>>::empty());
    if !x_wf_program2(p) { return Ok((false, Ghost(pad))); }
    if p.unchecked && !trusted { return Ok((false, Ghost(pad))); }
    if g.n != p.methods.len() { return Ok((false, Ghost(pad))); }
    if !x_g_ok(g) { return Ok((false, Ghost(pad))); }
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    let tc = XCert { g, cur: g.n, maps: &empty };
    if !x_tables_ok(p, &tc)? { return Ok((false, Ghost(pad))); }
    let n = p.methods.len();
    let np = g.pins.len() / 12;
    let ghost mut ms: Seq<Maps> = Seq::empty();
    let mut bufs = XBufs { rev: Vec::new(), k: Vec::new(), post: Vec::new() };
    let mut at: usize = 0;
    let mut m: usize = 0;
    while m < n
        invariant
            pv == vview(p), wf_program2(pv), n == p.methods@.len(), g.n == n, n < 0x1000_0000, g_ok(g),
            np == npins(g),
            tables_ok(pv, tables_cert(g@)),
            0 <= m <= n, ms.len() == m, at <= np,
            forall|mm: int| 0 <= mm < m ==> #[trigger] method_ok(pv, local_cert(g@, mm, ms[mm]), mm, trusted),
            forall|i: int| 0 <= i < at ==> #[trigger] pin_m(g, i) < m && pin_agrees(g, i, ms[pin_m(g, i) as int]),
            forall|i: int| at <= i < np ==> #[trigger] pin_m(g, i) >= m,
        decreases n - m,
    {
        let maps = o.method_maps(p, g, m)?;
        let c = XCert { g, cur: m, maps: &maps };
        let ghost mm = mapsv(&maps);
        let ghost ms2 = ms.push(mm) + Seq::new((n - m - 1) as nat, |i: int| Seq::<Option<Seq<Kind>>>::empty());
        assert(ms2.len() == n);
        assert(ms2[m as int] == mm);
        if !x_method_ok(p, &c, m, trusted, &mut bufs)? {
            assert(!method_ok(pv, local_cert(g@, m as int, ms2[m as int]), m as int, trusted));
            return Ok((false, Ghost(ms2)));
        }
        match x_pins_agree(g, m, &maps, at)? {
            None => {
                proof {
                    let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m && !pin_agrees(g, i, mapsv(&maps));
                    lemma_pin_agree_witness(g, i, ms2);
                }
                return Ok((false, Ghost(ms2)));
            },
            Some(e) => {
                proof {
                    ms = ms.push(mm);
                    assert forall|i: int| 0 <= i < e implies #[trigger] pin_m(g, i) < m + 1 && pin_agrees(g, i, ms[pin_m(g, i) as int]) by {
                        if i >= at { assert(pin_m(g, i) == m); }
                    }
                }
                at = e;
            },
        }
        m += 1;
    }
    if at < np {
        // A pin of a method that does not exist.
        proof {
            lemma_pin_unique(g, at as int);
            assert(pin_at(g@, pin_m(g, at as int) as int, pin_off(g, at as int) as int) is Some);
        }
        return Ok((false, Ghost(ms)));
    }
    proof {
        let gv = g@;
        assert forall|m2: int, o2: int| #[trigger] pin_at(gv, m2, o2) is Some implies
            0 <= m2 < ms.len() && 0 <= o2 < ms[m2].len() && ms[m2][o2] == pin_at(gv, m2, o2) by {
            let i = choose|i: int| 0 <= i < npins(g) && #[trigger] pin_m(g, i) == m2 && pin_off(g, i) == o2;
            lemma_pin_unique(g, i);
            if i >= at { assert(pin_m(g, i) >= n); }
            assert(pin_agrees(g, i, ms[pin_m(g, i) as int]));
        }
    }
    Ok((true, Ghost(ms)))
}

/// With sorted pins, the pin view at a pin's key is that pin.
pub proof fn lemma_pin_unique(g: &XGlobal, i: int)
    requires pins_sorted(g), 0 <= i < npins(g),
    ensures pin_view(g, pin_m(g, i) as int, pin_off(g, i) as int) == Some(pin_kinds(g, i)),
{
    assert(has_pin(g, pin_m(g, i) as int, pin_off(g, i) as int));
    let j = choose|j: int| 0 <= j < npins(g) && #[trigger] pin_m(g, j) == pin_m(g, i) && pin_off(g, j) == pin_off(g, i);
    lemma_key(pin_m(g, j) as int, pin_off(g, j) as int, pin_m(g, i) as int, pin_off(g, i) as int);
    if j < i { assert(pin_key(g, j) < pin_key(g, i)); }
    if j > i { assert(pin_key(g, i) < pin_key(g, j)); }
}

/// With sorted selector records, the representative of a record's
/// selector is that record's.
pub proof fn lemma_sel_unique(g: &XGlobal, i: int)
    requires sel_sorted(g), 0 <= i < nsel(g),
    ensures sel_view(g, sel_key(g, i) as int) == sel_val(g, i) as int,
{
    assert(has_sel(g, sel_key(g, i) as int));
    let j = choose|j: int| 0 <= j < nsel(g) && #[trigger] sel_key(g, j) == sel_key(g, i);
    if j < i { assert(sel_key(g, j) < sel_key(g, i)); }
    if j > i { assert(sel_key(g, i) < sel_key(g, j)); }
}

/// A pin of method `m` that disagrees with `ms[m]` breaks `pins_agree`.
pub proof fn lemma_pin_agree_witness(g: &XGlobal, i: int, ms: Seq<Maps>)
    requires
        pins_sorted(g), 0 <= i < npins(g), (pin_m(g, i) as int) < ms.len(),
        !pin_agrees(g, i, ms[pin_m(g, i) as int]),
    ensures !pins_agree(g@, ms),
{
    lemma_pin_unique(g, i);
    assert(pin_at(g@, pin_m(g, i) as int, pin_off(g, i) as int) == Some(pin_kinds(g, i)));
}


} // verus!

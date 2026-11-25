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

//! Certificate inference for the structural verifier (untrusted).
//!
//! Computes a certificate for `v2::check::verify` by abstract
//! interpretation with the verified transfer function `x_post`. Nothing
//! here is trusted: the checker decides whatever this produces, and a
//! wrong certificate can only make it reject.
//!
//! Memory is bounded by the largest method, not the program:
//!
//! 1. `infer_global` computes the global part of the certificate
//!    (`XGlobal`: block-parameter masks, contexts, selector
//!    representatives, pins). Block-parameter masks are a fixpoint over
//!    the whole program (a parameter becomes a block parameter when a block
//!    is passed for it or when the method invokes it); block methods are
//!    analyzed after the method that creates them, whose maps give their
//!    context; non-local branches seed the maps of outer methods. Every
//!    method's maps are computed and dropped right away; only the global
//!    facts survive a method.
//! 2. `Oracle` (a `check::MapOracle`) recomputes one method's maps at a
//!    time for the checker, with the global part frozen.
//!
//! Per method the analysis is a worklist over instruction offsets, lowest
//! offset first; the map at an offset is a node of a list of kinds that
//! shares its bottom with the maps it came from (`XMaps`); the origins
//! the global phase tracks are lists of the same shape in their own arena.
//! A method costs about 9 bytes per bytecode byte plus 16 bytes per kind
//! node and 5 per origin node, within budgets (`node_budget`).
//!
//! The inference is total: it never indexes without a bounds check and
//! calls the verified functions only within their preconditions; any
//! malformed input ends in an error (and a rejection by the checker), not
//! a panic.

use alloc::collections::BTreeMap;
use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;
use crate::v2::bytecodes::*;
use crate::v2::check::*;
use crate::v2::vprog::*;
use crate::v2::gbuf::GBuf;
use crate::xvec::Oom;

/// The value of a checker function, which reports a failed allocation as
/// `Err(Oom)`. The inference runs on hosts only, where the verifier's
/// panics are caught and reject the program (vmverify's ffi.rs), like the
/// standard library's own allocation failures.
pub fn ok<T>(r: Result<T, Oom>) -> T {
    match r {
        Ok(x) => x,
        Err(_) => panic!("out of memory"),
    }
}

/// The elements of `v` in chunks.
fn cvec_of<T: Copy>(v: &[T]) -> CVec<T> {
    let mut b = ok(crate::cvec::CBuild::try_new(v.len()));
    for &x in v { ok(b.try_push(x)); }
    ok(b.try_finish())
}

/// The checker's form of the maps of one method.
fn xmaps(maps: &Maps) -> XMaps {
    XMaps { idx: cvec_of(&maps.idx), nodes: cvec_of(&maps.nodes) }
}

/// The checker's `post` (`x_post_into`) as a fresh vector, for the
/// inference and the encoder.
pub fn x_post(p: &VProgram, c: &XCert, m: usize, off: usize, k: &Vec<XKind>, trusted: bool) -> Result<Option<Vec<XKind>>, Oom> {
    let mut out = Vec::new();
    if x_post_into(p, c, m, off, k, trusted, &mut out)? { Ok(Some(out)) } else { Ok(None) }
}

const KIND_BLOCK: u8 = 3;
/// At most this many inference errors are kept (diagnostics only).
const MAX_ERRORS: usize = 16;
/// The block-parameter fixpoint gives up after this many rounds.
const MAX_ROUNDS: usize = 64;
const NO_ORIGIN: u8 = 0xff;

fn u16_at(p: &VProgram, i: usize) -> Option<usize> {
    let lo = *p.bytecodes.get(i)? as usize;
    let hi = *p.bytecodes.get(i.checked_add(1)?)? as usize;
    Some(lo | hi << 8)
}

fn byte_at(p: &VProgram, i: usize) -> Option<usize> {
    p.bytecodes.get(i).map(|b| *b as usize)
}

fn method(p: &VProgram, m: usize) -> Option<VMethod> {
    p.methods.get(m)
}

/// The join of two kinds lists of the same height (method ids that differ
/// become values); `None` if they are incompatible.
fn join(a: &[XKind], b: &[XKind]) -> Option<Vec<XKind>> {
    if a.len() != b.len() {
        return None;
    }
    let mut r = Vec::with_capacity(a.len());
    for (x, y) in a.iter().zip(b.iter()) {
        r.push(if x == y {
            *x
        } else {
            match (x, y) {
                (XKind::Method(_), XKind::Method(_)) | (XKind::Method(_), XKind::Val) | (XKind::Val, XKind::Method(_)) => XKind::Val,
                _ => return None,
            }
        });
    }
    Some(r)
}

/// Seeds: maps of outer methods at the targets of non-local branches.
pub type Seeds = BTreeMap<(u32, u32), Vec<Vec<XKind>>>;

/// The result of the global phase.
pub struct Global {
    pub g: GBuf,
    /// Methods analyzed in the last round (blocks nobody creates are not).
    pub done: Vec<bool>,
    pub seeds: Seeds,
    /// Why the analysis could not build a certificate the checker accepts
    /// (method, offset, message); at most `MAX_ERRORS`.
    pub errors: Vec<(usize, usize, String)>,
    /// Rounds of the block-parameter fixpoint.
    pub rounds: usize,
}

/// What the analysis of one method does to the global facts.
trait Facts {
    fn g(&self) -> &GBuf;
    /// Block method `t` is created at slot `slot` of `m` with `kinds`.
    fn context(&mut self, t: usize, m: usize, slot: usize, kinds: &[XKind]);
    /// Parameter `x` of `t` (and its selector group) is a block parameter.
    fn mark(&mut self, t: usize, x: usize);
    /// A non-local branch enters `om` at `target` with `kinds`.
    fn seed(&mut self, om: usize, target: usize, kinds: Vec<XKind>);
    fn tracks_origins(&self) -> bool;
    /// The seeds of method `m`: (offset, kinds).
    fn seeds_of(&self, m: usize) -> Vec<(usize, Vec<XKind>)>;
}

fn seeds_in(seeds: &Seeds, m: usize) -> Vec<(usize, Vec<XKind>)> {
    if m > u32::MAX as usize { return Vec::new(); }
    seeds.range((m as u32, 0)..=(m as u32, u32::MAX))
        .filter_map(|(&(_, t), list)| list.first().map(|k| (t as usize, k.clone())))
        .collect()
}

/// The global phase: mutates the facts.
struct Building<'a> {
    p: &'a VProgram<'a>,
    g: GBuf,
    /// Methods with a selector, sorted by (selector, method).
    by_sel: Vec<u32>,
    seeds: Seeds,
    block_marks: Vec<(usize, usize)>,
    changed: bool,
}

impl<'a> Facts for Building<'a> {
    fn g(&self) -> &GBuf {
        &self.g
    }

    fn context(&mut self, t: usize, m: usize, slot: usize, kinds: &[XKind]) {
        if t >= self.g.n || m > u32::MAX as usize || slot > u32::MAX as usize { return; }
        self.g.set_ctx(t, m as u32, slot as u32, kinds);
    }

    fn mark(&mut self, t: usize, x: usize) {
        let p = self.p;
        let Some(info) = method(p, t) else { return };
        let (lo, hi) = if info.selector != 0xffff {
            let s = info.selector as u32;
            let key = |&id: &u32| p.methods.get(id as usize).map(|i| i.selector as u32).unwrap_or(u32::MAX);
            let lo = self.by_sel.partition_point(|id| key(id) < s);
            let hi = self.by_sel.partition_point(|id| key(id) <= s);
            (lo, hi)
        } else {
            (0, 0)
        };
        let single = [t as u32];
        let targets: &[u32] = if lo < hi { &self.by_sel[lo..hi] } else { &single };
        for &t in targets {
            let t = t as usize;
            let Some(info) = method(p, t) else { continue };
            if info.kind == KIND_BLOCK {
                if !self.block_marks.contains(&(t, x)) && self.block_marks.len() < MAX_ERRORS {
                    self.block_marks.push((t, x));
                }
                continue;
            }
            if x < info.arity as usize && self.g.set_bit(t, x) {
                self.changed = true;
            }
        }
    }

    fn seed(&mut self, om: usize, target: usize, kinds: Vec<XKind>) {
        if om > u32::MAX as usize || target > u32::MAX as usize {
            return;
        }
        let list = self.seeds.entry((om as u32, target as u32)).or_default();
        if !list.contains(&kinds) {
            list.push(kinds);
            self.changed = true;
        }
    }

    fn tracks_origins(&self) -> bool {
        true
    }

    fn seeds_of(&self, m: usize) -> Vec<(usize, Vec<XKind>)> {
        seeds_in(&self.seeds, m)
    }
}

/// The checking phase: the facts are frozen.
struct Frozen<'a> {
    g: &'a GBuf,
    seeds: &'a Seeds,
}

impl<'a> Facts for Frozen<'a> {
    fn g(&self) -> &GBuf {
        self.g
    }
    fn context(&mut self, _t: usize, _m: usize, _slot: usize, _kinds: &[XKind]) {}
    fn mark(&mut self, _t: usize, _x: usize) {}
    fn seed(&mut self, _om: usize, _target: usize, _kinds: Vec<XKind>) {}
    fn tracks_origins(&self) -> bool {
        false
    }
    fn seeds_of(&self, m: usize) -> Vec<(usize, Vec<XKind>)> {
        seeds_in(self.seeds, m)
    }
}

/// The maps of one method under construction.
struct Maps {
    /// Per offset: the top node of its kinds, or `NO_MAP`.
    idx: Vec<u32>,
    nodes: Vec<XNode>,
    /// Per offset (when origins are tracked): the top node of its origins,
    /// a list like the kinds (same height), in its own arena (`opar`,
    /// `oval`). Origins say which parameter a slot is an unchanged copy of
    /// (for inferring block parameters that are invoked or passed on);
    /// apart from the kinds, a change of origins does not copy the kinds.
    org_at: Vec<u32>,
    opar: Vec<u32>,
    oval: Vec<u8>,
    /// Upper bounds on the kind and origin nodes (memory budget).
    budget: usize,
    org_budget: usize,
}

/// The number of kind nodes a method of `size` bytes with frames of at
/// most `limit` slots may create (origin nodes: twice that): far above
/// what compiled code needs (2026-11-10, the suite, the system snapshots
/// and the toit CLI: at most 3 kind nodes per byte, under 1 for methods of
/// 64 bytes and more, and 6.6 origin nodes per byte), so that a malformed
/// method cannot make the inference allocate without bound.
fn node_budget(size: usize, limit: usize) -> usize {
    size.saturating_mul(16).saturating_add(limit.saturating_mul(4)).saturating_add(256)
}

/// Walks a list from `top` (parents below their children), bottom first.
fn walk<T: Copy>(top: u32, len: usize, parent: impl Fn(usize) -> u32, value: impl Fn(usize) -> T, out: &mut Vec<T>, ids: &mut Vec<u32>) {
    out.clear();
    ids.clear();
    let mut cur = top as usize;
    while cur < len {
        out.push(value(cur));
        ids.push(cur as u32);
        let par = parent(cur) as usize;
        if par >= cur { break; }
        cur = par;
    }
    out.reverse();
    ids.reverse();
}

impl Maps {
    /// The kinds and node ids of the map at `off`, bottom first.
    fn read(&self, off: usize, k: &mut Vec<XKind>, ids: &mut Vec<u32>) {
        let top = self.idx.get(off).copied().unwrap_or(NO_MAP);
        walk(top, self.nodes.len(), |i| self.nodes[i].parent, |i| self.nodes[i].kind, k, ids);
    }

    /// The origins of `off` (dense, `NO_ORIGIN` for none; `h` slots) and
    /// their node ids (empty when untracked).
    fn read_origins(&self, off: usize, h: usize, o: &mut Vec<u8>, oids: &mut Vec<u32>) {
        let top = self.org_at.get(off).copied().unwrap_or(NO_MAP);
        walk(top, self.oval.len(), |i| self.opar[i], |i| self.oval[i], o, oids);
        if o.len() != h {
            o.clear();
            oids.clear();
            o.resize(h, NO_ORIGIN);
        }
    }

    /// Sets the origins of `off` (dense), sharing the first `share` with the
    /// list whose node ids are `oids`. Returns whether they changed, or
    /// `None` if the budget is spent.
    fn set_origins(&mut self, off: usize, o: &[u8], oids: &[u32], share: usize) -> Option<bool> {
        if off >= self.org_at.len() { return Some(false); }
        let (mut cur, mut cur_ids) = (Vec::new(), Vec::new());
        self.read_origins(off, o.len(), &mut cur, &mut cur_ids);
        if self.org_at[off] != NO_MAP && cur == o { return Some(false); }
        let share = share.min(oids.len()).min(o.len());
        let mut top = if share == 0 { EMPTY_MAP } else { oids[share - 1] };
        for &x in &o[share..] {
            let id = self.oval.len();
            if id >= self.org_budget || id >= EMPTY_MAP as usize { return None; }
            self.opar.push(if top == EMPTY_MAP { id as u32 } else { top });
            self.oval.push(x);
            top = id as u32;
        }
        self.org_at[off] = top;
        Some(true)
    }

    /// The top node of the kinds `k`, sharing the first `share` slots with
    /// the map whose node ids are `ids`. `None` if the budget is spent.
    fn intern(&mut self, ids: &[u32], share: usize, k: &[XKind]) -> Option<u32> {
        let share = share.min(ids.len()).min(k.len());
        let mut top = if share == 0 { EMPTY_MAP } else { ids[share - 1] };
        for &kind in &k[share..] {
            let id = self.nodes.len();
            if id >= self.budget || id >= EMPTY_MAP as usize {
                return None;
            }
            self.nodes.push(XNode { parent: if top == EMPTY_MAP { id as u32 } else { top }, kind });
            top = id as u32;
        }
        Some(top)
    }
}

/// The length of the common prefix of `k1` and `k2`.
fn common<T: PartialEq>(k1: &[T], k2: &[T]) -> usize {
    let mut i = 0;
    while i < k1.len() && i < k2.len() && k1[i] == k2[i] {
        i += 1;
    }
    i
}

type Error = (usize, String);

/// Analyzes method `m`: its maps, or the offset and reason of the first
/// problem. Calls `x_post` and `x_terminator_ok` only within their
/// preconditions (the program is `wf_program2`, checked by the caller).
fn analyze<F: Facts>(p: &VProgram, f: &mut F, m: usize, trusted: bool) -> Result<Maps, Error> {
    let Some(info) = method(p, m) else { return Err((0, "no such method".into())) };
    let (entry, end) = (info.entry as usize, info.end());
    if !(entry < end && end <= p.bytecodes.len()) {
        return Err((0, "empty method body or body outside the bytecodes".into()));
    }
    let size = end - entry;
    let limit = info.arity as usize + p.max_height as usize;
    let origins = f.tracks_origins();
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    let mut maps = Maps {
        idx: vec![NO_MAP; size],
        nodes: Vec::new(),
        org_at: if origins { vec![NO_MAP; size] } else { Vec::new() },
        opar: Vec::new(),
        oval: Vec::new(),
        budget: node_budget(size, limit),
        org_budget: node_budget(size, limit).saturating_mul(2),
    };
    let mut queued = vec![false; size];
    // The work list: the queued offsets, lowest first (`lo`: none below),
    // so that straight-line code sees all its predecessors before it is
    // analyzed and changes are not propagated twice.
    let mut lo = 0usize;
    // The entry map.
    let e = {
        let c = XCert { g: &f.g().view(p.methods), cur: m, maps: &empty };
        ok(x_entry_kinds(p, &c, m))
    };
    if e.len() > limit {
        return Err((0, "too many parameters".into()));
    }
    let eo: Vec<u8> = (0..e.len()).map(|i| if origins && i < NO_ORIGIN as usize { i as u8 } else { NO_ORIGIN }).collect();
    maps.idx[0] = maps.intern(&[], 0, &e).ok_or((0, String::from("maps too large")))?;
    maps.set_origins(0, &eo, &[], 0).ok_or((0, String::from("maps too large")))?;
    queued[0] = true;

    for (t, kt) in f.seeds_of(m) {
        if t >= size || t == 0 || kt.len() > limit { continue; }
        maps.idx[t] = maps.intern(&[], 0, &kt).ok_or((t, String::from("maps too large")))?;
        if !queued[t] {
            queued[t] = true;
        }
    }
    let (mut k, mut org, mut ids, mut oids) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let (mut k_old, mut o_old, mut ids_old, mut oids_old) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let too_large = |t: usize| (t, String::from("maps too large"));
    loop {
        while lo < size && !queued[lo] { lo += 1; }
        if lo >= size { break; }
        let off = lo;
        queued[off] = false;
        maps.read(off, &mut k, &mut ids);
        maps.read_origins(off, k.len(), &mut org, &mut oids);
        let bci = entry + off;
        let raw = p.bytecodes[bci];
        if raw >= OPCODE_COUNT2 {
            return Err((off, format!("invalid opcode {}", raw)));
        }
        if exec_is_twin(raw) && !p.unchecked {
            return Err((off, format!("unchecked opcode {} in a program not in the unchecked mode", raw)));
        }
        // An unchecked twin is typed as its base (format note 20).
        let op = exec_base_op(raw);
        let len = OPCODE_LENGTHS2[op as usize] as usize;
        if bci + len > end {
            return Err((off, "instruction crosses the method end".into()));
        }
        let h = k.len();
        // Contexts: a block method pushed at slot h is created here.
        if op == LOAD_METHOD {
            let t = byte_at(p, bci + 1).unwrap_or(0) | byte_at(p, bci + 2).unwrap_or(0) << 8
                | u16_at(p, bci + 3).unwrap_or(0) << 16;
            if method(p, t).is_some_and(|i| i.kind == KIND_BLOCK) && t <= u32::MAX as usize {
                let mut kinds = k.clone();
                kinds.push(XKind::Method(t as u32));
                f.context(t, m, h, &kinds);
            }
        }
        // Block parameters.
        if origins {
            match op {
                INVOKE_BLOCK => {
                    let n = byte_at(p, bci + 1).unwrap_or(0);
                    if 1 <= n && n <= h && k[h - n] == XKind::Val && org[h - n] != NO_ORIGIN {
                        f.mark(m, org[h - n] as usize);
                    }
                }
                INVOKE_STATIC | INVOKE_STATIC_TAIL => {
                    if let Some(d) = u16_at(p, bci + 1) {
                        if let Some(&t) = p.dispatch.get(d) {
                            if t >= 0 {
                                if let Some(ti) = method(p, t as usize) {
                                    mark_args(p, f, m, t as usize, &k, &org, ti.arity as usize);
                                }
                            }
                        }
                    }
                }
                INVOKE_VIRTUAL | INVOKE_VIRTUAL_WIDE => {
                    let ns = if op == INVOKE_VIRTUAL {
                        byte_at(p, bci + 1).map(|b| b + 1).zip(u16_at(p, bci + 2))
                    } else {
                        u16_at(p, bci + 1).map(|w| w + 1).zip(u16_at(p, bci + 3))
                    };
                    if let Some((n, sel)) = ns {
                        if sel < 0xffff {
                            let r = x_sel_rep(&XCert { g: &f.g().view(p.methods), cur: m, maps: &empty }, sel);
                            if r >= 0 {
                                if let Some(ri) = method(p, r as usize) {
                                    if ri.arity as usize == n {
                                        mark_args(p, f, m, r as usize, &k, &org, n);
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        if op == NON_LOCAL_BRANCH && h >= 1 {
            if let XKind::Block(d, j) = k[h - 1] {
                if d >= 1 {
                    let c = XCert { g: &f.g().view(p.methods), cur: m, maps: &empty };
                    let (fk, om) = ok(x_ctx_kinds(&c, m as i64, d));
                    let hd = byte_at(p, bci + 1).unwrap_or(usize::MAX);
                    let target = u16_at(p, bci + 2).zip(u16_at(p, bci + 4)).map(|(lo, hi)| lo | hi << 16);
                    if let (Some(fk), Some(target)) = (fk, target) {
                        let j = j as usize;
                        if om >= 0 && j < fk.len() && hd <= j + 1 {
                            let t = fk[..j + 1 - hd].to_vec();
                            f.seed(om as usize, target, t);
                        }
                    }
                }
            }
        }
        // x_post's precondition: a frame of bounded height (the checker
        // rejects anything above arity + max_height anyway).
        if h > limit {
            return Err((off, "frame too high".into()));
        }
        let (post, term_ok) = {
            let c = XCert { g: &f.g().view(p.methods), cur: m, maps: &empty };
            let post = ok(x_post(p, &c, m, off, &k, trusted));
            let term = matches!(op, RETURN | RETURN_NULL | THROW | BRANCH | BRANCH_BACK | INVOKE_STATIC_TAIL
                | INVOKE_LAMBDA_TAIL | INVOKE_INITIALIZER_TAIL | NON_LOCAL_RETURN | NON_LOCAL_BRANCH);
            let term_ok = if term {
                Some(matches!(op, BRANCH | BRANCH_BACK | NON_LOCAL_BRANCH) || ok(x_terminator_ok(p, &c, m, off, &k)))
            } else {
                None
            };
            (post, term_ok)
        };
        match term_ok {
            Some(false) => return Err((off, format!("{} rejected with kinds {:?}", OPCODE_NAMES2[op as usize], k))),
            None if post.is_none() => return Err((off, format!("{} rejected with kinds {:?}", OPCODE_NAMES2[op as usize], k))),
            _ => {}
        }
        let mut succ: Vec<(usize, Vec<XKind>, Vec<u8>)> = Vec::new();
        if let Some(k2) = post {
            let o2 = if origins { transfer_origins(p, bci, &org, &k, &k2) } else { vec![NO_ORIGIN; k2.len()] };
            succ.push((off + len, k2, o2));
        }
        if (BRANCH..=BRANCH_BACK_IF_NOT_NULL).contains(&op) {
            let w = u16_at(p, bci + 1).unwrap_or(0);
            let t = if op <= BRANCH_IF_NOT_NULL { off.checked_add(w) } else { off.checked_sub(w) };
            let cond = !(op == BRANCH || op == BRANCH_BACK);
            if h < cond as usize {
                return Err((off, "branch without condition".into()));
            }
            let Some(t) = t else { return Err((off, "branch before the method".into())) };
            let kt = if cond { k[..h - 1].to_vec() } else { k.clone() };
            let ot = if cond { org[..h - 1].to_vec() } else { org.clone() };
            succ.push((t, kt, ot));
        }
        if op == HASH_FIND {
            // The miss branch pushes a value (`post` accepted the operands).
            let w = u16_at(p, bci + 1).unwrap_or(0);
            let Some(t) = off.checked_add(w) else { return Err((off, "branch outside the method".into())) };
            let mut kt = k.clone();
            kt.push(XKind::Val);
            let mut ot: Vec<u8> = if origins { org.clone() } else { vec![NO_ORIGIN; h] };
            ot.push(NO_ORIGIN);
            succ.push((t, kt, ot));
        }
        if op == LOOP_REPEAT || op == LOOP_ARRAY {
            // The taken loop step (`loop_kinds`); `post` accepted the
            // operands, so the counter and the block are below the top.
            let w = u16_at(p, bci + 1).unwrap_or(0);
            let n = byte_at(p, bci + 3).unwrap_or(usize::MAX);
            let Some(t) = off.checked_sub(w) else { return Err((off, "branch before the method".into())) };
            if !(1 <= n && n + 1 < h) {
                return Err((off, "loop operands outside the frame".into()));
            }
            let kt = ok(x_loop_kinds(&k, n, n + 1));
            let mut ot: Vec<u8> = Vec::with_capacity(h + 1);
            if origins {
                ot.extend_from_slice(&org[..h - 1]);
                ot[h - 1 - n] = NO_ORIGIN;
                ot.push(org[h - 2 - n]);
                ot.push(NO_ORIGIN);
            } else {
                ot.resize(h + 1, NO_ORIGIN);
            }
            succ.push((t, kt, ot));
        }
        for (t, k2, o2) in succ {
            if t >= size {
                return Err((off, "successor outside the method".into()));
            }
            if k2.len() > limit {
                return Err((off, "frame too high".into()));
            }
            let mut changed = false;
            if maps.idx[t] == NO_MAP {
                let share = common(&k, &k2);
                maps.idx[t] = maps.intern(&ids, share, &k2).ok_or(too_large(t))?;
                if origins {
                    let share = common(&org, &o2);
                    maps.set_origins(t, &o2, &oids, share).ok_or(too_large(t))?;
                }
                changed = true;
            } else {
                maps.read(t, &mut k_old, &mut ids_old);
                let Some(j) = join(&k_old, &k2) else {
                    return Err((t, format!("incompatible kinds at merge: {:?} and {:?}", k_old, k2)));
                };
                if j != k_old {
                    // Share the bottom with the old map or with the incoming
                    // one (the predecessor's chain), whichever is longer.
                    let share_old = common(&k_old, &j);
                    let share_in = common(&k, &j).min(ids.len());
                    let top = if share_in > share_old {
                        maps.intern(&ids, share_in, &j)
                    } else {
                        maps.intern(&ids_old, share_old, &j)
                    };
                    maps.idx[t] = top.ok_or(too_large(t))?;
                    changed = true;
                }
                if origins {
                    maps.read_origins(t, k_old.len(), &mut o_old, &mut oids_old);
                    let o_new: Vec<u8> = o_old.iter().zip(o2.iter()).map(|(x, y)| if x == y { *x } else { NO_ORIGIN }).collect();
                    if o_new != o_old {
                        let share_old = common(&o_old, &o_new).min(oids_old.len());
                        let share_in = common(&org, &o_new).min(oids.len());
                        let r = if share_in > share_old {
                            maps.set_origins(t, &o_new, &oids, share_in)
                        } else {
                            maps.set_origins(t, &o_new, &oids_old, share_old)
                        };
                        changed |= r.ok_or(too_large(t))?;
                    }
                }
            }
            if changed && !queued[t] {
                queued[t] = true;
                if t < lo { lo = t; }
            }
        }
    }
    Ok(maps)
}

/// Marks the parameters of `t` that receive blocks, and the parameters of
/// `m` that are passed on unchanged for block parameters.
fn mark_args<F: Facts>(p: &VProgram, f: &mut F, m: usize, t: usize, k: &[XKind], org: &[u8], n: usize) {
    if n > k.len() { return; }
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    for x in 0..n {
        let i = k.len() - n + x;
        if matches!(k[i], XKind::Block(..) | XKind::Param) {
            f.mark(t, x);
        } else if k[i] == XKind::Val && org.get(i).is_some_and(|o| *o != NO_ORIGIN)
            && x_is_block_param(&XCert { g: &f.g().view(p.methods), cur: m, maps: &empty }, t, x) {
            f.mark(m, org[i] as usize);
        }
    }
}

/// Parameter origins after an instruction: copies of a local keep it,
/// everything else is new.
fn transfer_origins(p: &VProgram, bci: usize, org: &[u8], k: &[XKind], k2: &[XKind]) -> Vec<u8> {
    let op = p.bytecodes.get(bci).copied().unwrap_or(0);
    let h = k.len();
    let h2 = k2.len();
    let mut o: Vec<u8> = org.to_vec();
    o.resize(h, NO_ORIGIN);
    if op == POP_LOAD_LOCAL {
        let n = byte_at(p, bci + 1).unwrap_or(usize::MAX);
        if n < h && n + 2 <= h && h2 == h {
            o[h - 1] = o[h - 2 - n];
        }
        o.resize(h2, NO_ORIGIN);
        return o;
    }
    let preserving = matches!(op, AS_CLASS | AS_CLASS_WIDE | AS_INTERFACE | AS_INTERFACE_WIDE | AS_LOCAL
        | STORE_FIELD_THIS | STORE_GLOBAL_VAR | STORE_GLOBAL_VAR_WIDE | HALT);
    if k == k2 && preserving {
        return o;
    }
    if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        let n = byte_at(p, bci + 1).unwrap_or(usize::MAX);
        if n < h && h >= 1 {
            o[h - 1 - n] = o[h - 1];
        }
        o.resize(h2, NO_ORIGIN);
        return o;
    }
    if h2 > h && k2[..h] == *k {
        o.resize(h2, NO_ORIGIN);
        if (op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0..=LOAD_LOCAL_5).contains(&op)) && h2 == h + 1 {
            let n = if op == LOAD_LOCAL { byte_at(p, bci + 1) } else if op == LOAD_LOCAL_WIDE { u16_at(p, bci + 1) } else { Some((op - LOAD_LOCAL_0) as usize) };
            o[h] = match n { Some(n) if n < h => o[h - 1 - n], _ => NO_ORIGIN };
        }
        return o;
    }
    let mut r: Vec<u8> = Vec::with_capacity(h2);
    for i in 0..h2 {
        r.push(if i + 1 < h2 && i < h && k[i] == k2[i] { o[i] } else { NO_ORIGIN });
    }
    r
}

fn push_error(errors: &mut Vec<(usize, usize, String)>, m: usize, off: usize, msg: String) {
    if errors.len() < MAX_ERRORS {
        errors.push((m, off, msg));
    }
}

/// The global part of the certificate (phase 1). `global_count` and
/// `prim_arity` are the trusted inputs (the program's globals, the VM's
/// primitive table).
pub fn infer_global(p: &VProgram, global_count: u64, prim_arity: Vec<Vec<u8>>, trusted: bool) -> Global {
    let n = p.methods.len();
    let mut g = GBuf::new(n, global_count, prim_arity);
    let mut errors = Vec::new();
    // The analysis needs well-formed tables (and so does the checker,
    // which rejects without them).
    if !x_wf_program2(p) || n >= u32::MAX as usize {
        errors.push((0, 0, String::from("malformed program tables (wf_program2)")));
        return Global { g, done: vec![false; n], seeds: Seeds::new(), errors, rounds: 0 };
    }
    let mut by_sel: Vec<u32> = (0..n as u32).filter(|&m| p.methods.at(m as usize).selector != 0xffff).collect();
    by_sel.sort_by_key(|&m| (p.methods.at(m as usize).selector, m));
    let mut reps: Vec<(u32, u32)> = Vec::new();
    for &m in &by_sel {
        let s = p.methods.at(m as usize).selector as u32;
        if reps.last().map(|r| r.0) != Some(s) { reps.push((s, m)); }
    }
    g.set_sels(&reps);
    let task_entry = p.entry_points.get(2).and_then(|&d| usize::try_from(d).ok())
        .and_then(|d| p.dispatch.get(d)).and_then(|&t| usize::try_from(t).ok());
    let mut b = Building { p, g, by_sel, seeds: Seeds::new(), block_marks: Vec::new(), changed: false };
    let mut rounds = 0;
    let mut done = vec![false; n];
    let mut pins: Vec<(u32, u32, Vec<XKind>)> = Vec::new();
    loop {
        rounds += 1;
        b.changed = false;
        errors.clear();
        b.g.clear_ctxs(p.methods);
        pins.clear();
        done.iter_mut().for_each(|d| *d = false);
        // Methods first, then blocks once their creator is done.
        let mut progress = true;
        while progress {
            progress = false;
            for m in 0..n {
                if done[m] { continue; }
                if p.methods.at(m).kind == KIND_BLOCK {
                    let ready = match b.g.ctx(m) {
                        Some((outer, _, _)) => done.get(outer as usize).copied().unwrap_or(false),
                        None => false,
                    };
                    if !ready { continue; }
                }
                done[m] = true;
                progress = true;
                match analyze(p, &mut b, m, trusted) {
                    Err((off, msg)) => push_error(&mut errors, m, off, msg),
                    Ok(maps) => {
                        // Pins: the maps other methods look up.
                        let mut want: Vec<usize> = b.seeds_of(m).into_iter().map(|(t, _)| t).collect();
                        if task_entry == Some(m) { want.push(1); }
                        for t in want {
                            if let Some(&top) = maps.idx.get(t) {
                                if top != NO_MAP && t <= u32::MAX as usize {
                                    let (mut k, mut ids) = (Vec::new(), Vec::new());
                                    maps.read(t, &mut k, &mut ids);
                                    pins.push((m as u32, t as u32, k));
                                }
                            }
                        }
                    }
                }
            }
        }
        if !b.changed || rounds >= MAX_ROUNDS {
            if b.changed {
                push_error(&mut errors, 0, 0, String::from("block parameter inference does not converge"));
            }
            break;
        }
    }
    for &(t, x) in &b.block_marks {
        push_error(&mut errors, t, 0, format!("block method with a block parameter {}", x));
    }
    pins.sort_by_key(|x| (x.0, x.1));
    pins.dedup_by_key(|x| (x.0, x.1));
    b.g.set_pins(&pins);
    Global { g: b.g, done, seeds: b.seeds, errors, rounds }
}

/// The checker's source of maps (phase 2): recomputes one method's maps at
/// a time with the global part frozen.
pub struct Oracle<'a> {
    p: &'a VProgram<'a>,
    frozen: Frozen<'a>,
    done: &'a [bool],
    trusted: bool,
    wf: bool,
    /// The last method whose maps were asked for (the checker goes in
    /// order and stops at the first rejected method).
    pub last: Option<usize>,
}

impl<'a> Oracle<'a> {
    pub fn new(p: &'a VProgram<'a>, global: &'a Global, trusted: bool) -> Oracle<'a> {
        Oracle {
            p,
            frozen: Frozen { g: &global.g, seeds: &global.seeds },
            done: &global.done,
            trusted,
            wf: x_wf_program2(p),
            last: None,
        }
    }

    fn maps(&mut self, m: usize) -> Result<Maps, Error> {
        if !self.wf || !self.done.get(m).copied().unwrap_or(false) {
            return Err((0, String::from("not analyzed (no context, or the creator was rejected)")));
        }
        analyze(self.p, &mut self.frozen, m, self.trusted)
    }
}

impl<'a> MapOracle for Oracle<'a> {
    fn method_maps(&mut self, _p: &VProgram, _g: &XGlobal, m: usize) -> Result<XMaps, Oom> {
        self.last = Some(m);
        Ok(match self.maps(m) {
            Ok(maps) => xmaps(&maps),
            Err(_) => {
                let size = method(self.p, m).map(|i| i.end().saturating_sub(i.entry as usize)).unwrap_or(0);
                XMaps { idx: cvec_of(&vec![NO_MAP; size.min(self.p.bytecodes.len())]), nodes: CVec::new() }
            }
        })
    }
}

/// The verdict of the proven checker (`check::verify`) on the certificate
/// of `global`, and the method it stopped at when it rejected one.
pub fn check(p: &VProgram, global: &Global, trusted: bool) -> (bool, Option<usize>) {
    let mut o = Oracle::new(p, global, trusted);
    let g = global.g.view(p.methods);
    let (ok, _) = ok(crate::v2::check::verify(p, &g, &mut o, trusted));
    (ok, if ok { None } else { o.last })
}

/// Why method `m` is rejected: the offset of the first instruction the
/// inference or the checker rejects, and a reason (diagnostics only).
pub fn diagnose(p: &VProgram, global: &Global, m: usize, trusted: bool) -> (Option<usize>, String) {
    if let Some((_, off, msg)) = global.errors.iter().find(|e| e.0 == m) {
        return (Some(*off), msg.clone());
    }
    let mut o = Oracle::new(p, global, trusted);
    let maps = match o.maps(m) {
        Err((off, msg)) => return (Some(off), msg),
        Ok(maps) => xmaps(&maps),
    };
    let g = global.g.view(p.methods);
    if !o.wf || m >= p.methods.len() || !x_g_ok(&g) || global.g.n != p.methods.len() {
        return (None, String::from("malformed tables or certificate"));
    }
    let c = XCert { g: &g, cur: m, maps: &maps };
    for off in 0..maps.idx.len() {
        let top = maps.idx.at(off);
        if top == NO_MAP { continue; }
        let k = ok(x_chain(&maps.nodes, top));
        if !ok(x_instr_ok(p, &c, m, x_info(p, m), off, &k, trusted, &mut Vec::new())) {
            return (Some(off), format!("rejected by the checker with kinds {:?}", k));
        }
    }
    let at = global.g.pin_list().iter().filter(|x| (x.0 as usize) < m).count();
    match ok(x_pins_agree(&g, m, &maps, at)) {
        None => (None, String::from("a pinned map differs from the method's map")),
        Some(_) => (None, String::from("entry kinds or certificate shape rejected by the checker")),
    }
}

/// Infers and checks a program given as an `ExecProgram` (the dump path)
/// with the verifier's generated primitive table: `check::verify`'s
/// verdict (the heap is not checked here).
pub fn verify_exec(e: &crate::types::ExecProgram, global_count: u64, trusted: bool) -> bool {
    let h = max_height_of(e);
    let Some(methods) = vmethods_of(e, h) else { return false };
    let p = vprogram_of(e, methods, h);
    let prim_arity: Vec<Vec<u8>> = crate::v2::prim_arity::PRIM_TABLE.iter()
        .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect();
    let global = infer_global(&p, global_count, prim_arity, trusted);
    check(&p, &global, trusted).0
}

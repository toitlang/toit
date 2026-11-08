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
//! Computes the stack maps, block-parameter masks, block contexts and
//! selector representatives of `v2::verifier::Cert` by abstract
//! interpretation, using the verified transfer function `x_post`. Nothing
//! here is trusted: `v2::check::verify` checks the result, and a wrong
//! certificate can only make the verifier reject.
//!
//! Per method the analysis is a worklist over instruction offsets with one
//! map per offset (arrays, no recursion). Block-parameter masks are a
//! fixpoint over the whole program: a parameter becomes a block parameter
//! when a block is passed for it or when the method invokes it. Block
//! methods are analyzed after the method that creates them, whose maps
//! give their context.

use crate::types::*;
use crate::v2::bytecodes::*;
use crate::v2::check::*;

pub struct Inferred {
    pub cert: XCert,
    /// Why the analysis could not build a certificate the checker accepts
    /// (method, offset, message). Empty when it found one.
    pub errors: Vec<(usize, usize, String)>,
    /// Rounds of the block-parameter fixpoint.
    pub rounds: usize,
}

const KIND_BLOCK: u8 = 3;

fn u16_at(p: &ExecProgram, i: usize) -> usize {
    p.bytecodes[i] as usize | (p.bytecodes[i + 1] as usize) << 8
}

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

struct Analysis<'a> {
    p: &'a ExecProgram,
    trusted: bool,
    /// Methods sharing each selector offset.
    groups: Vec<Vec<usize>>,
    errors: Vec<(usize, usize, String)>,
    /// Block methods that would need a block parameter (unsupported).
    block_marks: Vec<(usize, usize)>,
    /// Entry points of non-local branches into each method: (offset, kinds).
    seeds: Vec<Vec<(usize, Vec<XKind>)>>,
    cur: (usize, usize),
    /// A block-parameter mask changed: the round must be redone.
    changed: bool,
}

impl<'a> Analysis<'a> {
    fn mark(&mut self, c: &mut XCert, t: usize, x: usize) {
        let sel = self.p.methods[t].selector as usize;
        let targets: Vec<usize> = if self.p.methods[t].selector != 0xffff { self.groups[sel].clone() } else { vec![t] };
        for t in targets {
            if self.p.methods[t].kind == KIND_BLOCK {
                if !self.block_marks.contains(&(t, x)) {
                    self.block_marks.push((t, x));
                }
                continue;
            }
            if x < c.block_params[t].len() && !c.block_params[t][x] {
                c.block_params[t][x] = true;
                self.changed = true;
                if std::env::var("INFER_DEBUG").is_ok() { eprintln!("mark {} {} at {:?}", t, x, self.cur); }
            }
        }
    }

    /// Marks the parameters of `t` that receive blocks, and the
    /// parameters of `m` that are passed on unchanged for block parameters.
    fn mark_args(&mut self, c: &mut XCert, m: usize, t: usize, k: &[XKind], org: &[Option<u8>], n: usize) {
        if n > k.len() { return; }
        for x in 0..n {
            let i = k.len() - n + x;
            if matches!(k[i], XKind::Block(..) | XKind::Param) {
                self.mark(c, t, x);
            } else if x < c.block_params[t].len() && c.block_params[t][x] && k[i] == XKind::Val {
                if let Some(j) = org[i] {
                    self.mark(c, m, j as usize);
                }
            }
        }
    }

    /// Analyzes method `m`; returns false when it hit an error (recorded)
    /// or a mask changed.
    fn method(&mut self, c: &mut XCert, m: usize) -> bool {
        let p = self.p;
        let info = p.methods[m];
        let size = info.end - info.entry;
        let mut maps: Vec<Option<Vec<XKind>>> = vec![None; size];
        // The parameter a slot is an unchanged copy of (for inferring
        // block parameters that are invoked).
        let mut origins: Vec<Option<Vec<Option<u8>>>> = vec![None; size];
        let entry = x_entry_kinds(p, c, m);
        let a = entry.len();
        origins[0] = Some((0..a).map(|i| Some(i as u8)).collect());
        maps[0] = Some(entry);
        let mut work: Vec<usize> = vec![0];
        let mut queued = vec![false; size];
        queued[0] = true;
        for (t, kt) in self.seeds[m].clone() {
            if t >= size || t == 0 { continue; }
            maps[t] = Some(kt.clone());
            origins[t] = Some(vec![None; kt.len()]);
            if !queued[t] {
                queued[t] = true;
                work.push(t);
            }
        }
        while let Some(off) = work.pop() {
            queued[off] = false;
            let k = maps[off].clone().unwrap();
            let org = origins[off].clone().unwrap();
            let bci = info.entry + off;
            let op = p.bytecodes[bci];
            if op >= 101 {
                self.errors.push((m, off, format!("invalid opcode {}", op)));
                return false;
            }
            let len = OPCODE_LENGTHS2[op as usize] as usize;
            if bci + len > info.end {
                self.errors.push((m, off, "instruction crosses the method end".into()));
                return false;
            }
            let h = k.len();
            self.cur = (m, off);
            // Contexts: a block method pushed at slot h is created here.
            if op == LOAD_METHOD {
                let t = p.bytecodes[bci + 1] as usize | (u16_at(p, bci + 3) << 16) | ((p.bytecodes[bci + 2] as usize) << 8);
                if t < p.methods.len() && p.methods[t].kind == KIND_BLOCK {
                    let mut kinds = k.clone();
                    kinds.push(XKind::Method(t as u32));
                    match &mut c.contexts[t] {
                        None => c.contexts[t] = Some(XContext { outer: m as u32, slot: h as u32, kinds }),
                        Some(ctx) => if ctx.outer as usize == m && ctx.slot as usize == h { ctx.kinds = kinds; },
                    }
                }
            }
            // Block parameters.
            match op {
                INVOKE_BLOCK => {
                    let n = p.bytecodes[bci + 1] as usize;
                    if 1 <= n && n <= h && k[h - n] == XKind::Val {
                        if let Some(j) = org[h - n] {
                            self.mark(c, m, j as usize);
                        }
                    }
                }
                INVOKE_STATIC | INVOKE_STATIC_TAIL => {
                    let d = u16_at(p, bci + 1);
                    if d < p.dispatch.len() && p.dispatch[d] >= 0 {
                        let t = p.dispatch[d] as usize;
                        self.mark_args(c, m, t, &k, &org, p.methods[t].arity as usize);
                    }
                }
                INVOKE_VIRTUAL | INVOKE_VIRTUAL_WIDE => {
                    let (n, sel) = if op == INVOKE_VIRTUAL {
                        (p.bytecodes[bci + 1] as usize + 1, u16_at(p, bci + 2))
                    } else {
                        (u16_at(p, bci + 1) + 1, u16_at(p, bci + 3))
                    };
                    if sel < self.groups.len() {
                        if let Some(&t) = self.groups[sel].first() {
                            if p.methods[t].arity as usize == n {
                                self.mark_args(c, m, t, &k, &org, n);
                            }
                        }
                    }
                }
                _ => {}
            }
            if op == NON_LOCAL_BRANCH && h >= 1 {
                if let XKind::Block(d, j) = k[h - 1] {
                    if d >= 1 {
                        let (fk, om) = x_ctx_kinds(c, m as i64, d);
                        let hd = p.bytecodes[bci + 1] as usize;
                        let target = u16_at(p, bci + 2) | u16_at(p, bci + 4) << 16;
                        if let Some(fk) = fk {
                            if om >= 0 && (j as usize) < fk.len() && hd <= j as usize + 1 {
                                let t = fk[..j as usize + 1 - hd].to_vec();
                                let om = om as usize;
                                if !self.seeds[om].iter().any(|(o, kt)| *o == target && *kt == t) {
                                    self.seeds[om].push((target, t));
                                    self.changed = true;
                                }
                            }
                        }
                    }
                }
            }
            // x_post's precondition: a frame of bounded height (the checker
            // rejects anything above arity + max_height anyway).
            if h > 0x10_0000 {
                self.errors.push((m, off, "frame too high".into()));
                return false;
            }
            let post = x_post(p, c, m, off, &k, self.trusted);
            let term = matches!(op, RETURN | RETURN_NULL | THROW | BRANCH | BRANCH_BACK | INVOKE_STATIC_TAIL
                | INVOKE_LAMBDA_TAIL | INVOKE_INITIALIZER_TAIL | NON_LOCAL_RETURN | NON_LOCAL_BRANCH);
            if term {
                if !matches!(op, BRANCH | BRANCH_BACK | NON_LOCAL_BRANCH) && !x_terminator_ok(p, c, m, off, &k) {
                    self.errors.push((m, off, format!("{} rejected with kinds {:?}", OPCODE_NAMES2[op as usize], k)));
                    return false;
                }
            } else if post.is_none() {
                self.errors.push((m, off, format!("{} rejected with kinds {:?}", OPCODE_NAMES2[op as usize], k)));
                return false;
            }
            let mut succ: Vec<(usize, Vec<XKind>, Vec<Option<u8>>)> = Vec::new();
            if let Some(k2) = post {
                let o2 = transfer_origins(p, bci, &org, &k, &k2);
                succ.push((off + len, k2, o2));
            }
            if (BRANCH..=BRANCH_BACK_IF_NOT_NULL).contains(&op) {
                let w = u16_at(p, bci + 1) as i64;
                let t = if op <= BRANCH_IF_NOT_NULL { off as i64 + w } else { off as i64 - w };
                let cond = !(op == BRANCH || op == BRANCH_BACK);
                if h < cond as usize {
                    self.errors.push((m, off, "branch without condition".into()));
                    return false;
                }
                let kt = if cond { k[..h - 1].to_vec() } else { k.clone() };
                let ot = if cond { org[..h - 1].to_vec() } else { org.clone() };
                if t < 0 {
                    self.errors.push((m, off, "branch before the method".into()));
                    return false;
                }
                succ.push((t as usize, kt, ot));
            }
            for (t, k2, o2) in succ {
                if t >= size {
                    self.errors.push((m, off, "successor outside the method".into()));
                    return false;
                }
                let merged = match &maps[t] {
                    None => Some(k2),
                    Some(old) => {
                        if *old == k2 {
                            None
                        } else {
                            match join(old, &k2) {
                                Some(j) => if j == *old { None } else { Some(j) },
                                None => {
                                    self.errors.push((m, t, format!("incompatible kinds at merge: {:?} and {:?}", old, k2)));
                                    return false;
                                }
                            }
                        }
                    }
                };
                let o_new = match &origins[t] {
                    None => o2,
                    Some(o) => o.iter().zip(o2.iter()).map(|(x, y)| if x == y { *x } else { None }).collect(),
                };
                let o_changed = origins[t].as_ref() != Some(&o_new);
                origins[t] = Some(o_new);
                let k_changed = merged.is_some();
                if let Some(j) = merged {
                    maps[t] = Some(j);
                }
                if (k_changed || o_changed) && !queued[t] {
                    queued[t] = true;
                    work.push(t);
                }
            }
        }
        c.maps[m] = maps;
        true
    }
}

/// Parameter origins after an instruction: copies of a local keep it,
/// everything else is new.
fn transfer_origins(p: &ExecProgram, bci: usize, org: &[Option<u8>], k: &[XKind], k2: &[XKind]) -> Vec<Option<u8>> {
    let op = p.bytecodes[bci];
    let h = k.len();
    let h2 = k2.len();
    if op == POP_LOAD_LOCAL {
        let n = p.bytecodes[bci + 1] as usize;
        let mut o = org.to_vec();
        if n + 2 <= h && h2 == h {
            o[h - 1] = org[h - 2 - n];
        }
        return o;
    }
    let preserving = matches!(op, AS_CLASS | AS_CLASS_WIDE | AS_INTERFACE | AS_INTERFACE_WIDE | AS_LOCAL
        | STORE_FIELD_THIS | STORE_GLOBAL_VAR | STORE_GLOBAL_VAR_WIDE | HALT);
    if k == k2 && preserving {
        return org.to_vec();
    }
    if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        let n = p.bytecodes[bci + 1] as usize;
        let mut o = org.to_vec();
        if n < h {
            o[h - 1 - n] = org[h - 1];
        }
        o.truncate(h2);
        return o;
    }
    if h2 > h && k2[..h] == *k {
        let mut o = org.to_vec();
        while o.len() < h2 {
            o.push(None);
        }
        if (op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0..=LOAD_LOCAL_5).contains(&op)) && h2 == h + 1 {
            o[h] = load_local_origin(p, bci, org);
        }
        return o;
    }
    let mut o: Vec<Option<u8>> = Vec::with_capacity(h2);
    for i in 0..h2 {
        o.push(if i + 1 < h2 && i < h && k[i] == k2[i] { org[i] } else { None });
    }
    o
}

/// Sets the origin of a LOAD_LOCAL's pushed slot.
fn load_local_origin(p: &ExecProgram, bci: usize, org: &[Option<u8>]) -> Option<u8> {
    let op = p.bytecodes[bci];
    let n = if op == LOAD_LOCAL { p.bytecodes[bci + 1] as usize } else if op == LOAD_LOCAL_WIDE { u16_at(p, bci + 1) } else { (op - LOAD_LOCAL_0) as usize };
    if n < org.len() { org[org.len() - 1 - n] } else { None }
}

pub fn infer(p: &ExecProgram, global_count: usize, trusted: bool) -> Inferred {
    let n = p.methods.len();
    let mut sel_rep = vec![-1i64; 0xffff];
    let mut groups: Vec<Vec<usize>> = vec![Vec::new(); 0xffff];
    for (m, info) in p.methods.iter().enumerate() {
        if info.selector != 0xffff {
            let s = info.selector as usize;
            if sel_rep[s] == -1 {
                sel_rep[s] = m as i64;
            }
            groups[s].push(m);
        }
    }
    let mut c = XCert {
        maps: (0..n).map(|_| Vec::new()).collect(),
        block_params: p.methods.iter().map(|i| vec![false; i.arity as usize]).collect(),
        contexts: (0..n).map(|_| None).collect(),
        sel_rep,
        global_count: global_count as u64,
        prim_arity: crate::v2::prim_arity::PRIM_TABLE.iter()
            .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect(),
    };
    let mut a = Analysis { p, trusted, groups, errors: Vec::new(), block_marks: Vec::new(), seeds: vec![Vec::new(); n], cur: (0, 0), changed: false };
    let mut rounds = 0;
    loop {
        rounds += 1;
        a.changed = false;
        a.errors.clear();
        for m in 0..n {
            c.maps[m] = Vec::new();
            c.contexts[m] = None;
        }
        let mut done = vec![false; n];
        // Methods first, then blocks once their creator is done.
        let mut progress = true;
        while progress {
            progress = false;
            for m in 0..n {
                if done[m] { continue; }
                if p.methods[m].kind == KIND_BLOCK {
                    let ready = match &c.contexts[m] {
                        Some(ctx) => done[ctx.outer as usize],
                        None => false,
                    };
                    if !ready { continue; }
                }
                done[m] = true;
                progress = true;
                let ok = a.method(&mut c, m);
                if ok {
                    fill_contexts(&mut c, p, m);
                }
            }
        }
        if !a.changed {
            // Blocks no analyzed code creates are dead: no maps.
            for m in 0..n {
                if !done[m] {
                    c.maps[m] = vec![None; p.methods[m].end - p.methods[m].entry];
                }
            }
            break;
        }
        if rounds > 64 {
            a.errors.push((0, 0, "block parameter inference does not converge".into()));
            break;
        }
    }
    for (t, x) in &a.block_marks {
        a.errors.push((*t, 0, format!("block method with a block parameter {}", x)));
    }
    Inferred { cert: c, errors: a.errors, rounds }
}

/// The contexts of the blocks method `m` creates: the kinds below and at
/// the block's slot where the slot holds it (the first such map).
fn fill_contexts(c: &mut XCert, p: &ExecProgram, m: usize) {
    let mut found: Vec<(usize, Vec<XKind>)> = Vec::new();
    for k in c.maps[m].iter().flatten() {
        for (i, kd) in k.iter().enumerate() {
            if let XKind::Method(t) = kd {
                let t = *t as usize;
                if t < p.methods.len() && p.methods[t].kind == KIND_BLOCK {
                    if let Some(ctx) = &c.contexts[t] {
                        if ctx.outer as usize == m && ctx.slot as usize == i && ctx.kinds.is_empty()
                            && !found.iter().any(|(x, _)| *x == t) {
                            found.push((t, k[..=i].to_vec()));
                        }
                    }
                }
            }
        }
    }
    for (t, kinds) in found {
        if let Some(ctx) = &mut c.contexts[t] {
            ctx.kinds = kinds;
        }
    }
}

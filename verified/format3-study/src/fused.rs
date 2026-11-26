// Copyright (C) 2026 Toit contributors.

//! UNPROVED PROTOTYPE (format-3 study): a single-pass checker of today's
//! shipped certificate (format/18-shipped-certificate.md, version 1).
//!
//! Today `cert::verify_shipped` decodes each method's maps with
//! `ShippedOracle` (a walk that recomputes every fall-through map with
//! `x_post_into` and interns it into a node arena), then `check::verify`
//! walks the maps again: for every mapped instruction it rebuilds the
//! kinds from the nodes, runs the per-instruction checks, recomputes the
//! successor and compares it with the map placed there.
//!
//! This prototype does the decoder's walk once and checks each instruction
//! on the walk's current kinds: no node arena, no index of `size` words, no
//! second successor computation. Branch targets are handled with deferred
//! comparisons (forward: the kinds are kept until the walk reaches the
//! target; backward: the kinds at every backward target, found by a
//! pre-scan of the opcodes, are kept when the walk passes it). Pins are
//! compared as the walk passes them. It is meant to accept exactly what
//! `verify_shipped` accepts (tested on the study's programs and on mutated
//! certificates, `f3study fused --cross`), and reuses the proven checker's
//! per-instruction functions (`x_post_into`, `x_wf_kinds`, `x_ctx_ok`,
//! `x_shape_ok`, `x_terminator_ok`, `x_entry_kinds`, `x_tables_ok`, ...).
//!
//! `incremental`: the per-instruction context checks (`wf_kinds`,
//! `ctx_ok`) only for the slots that changed since the last instruction
//! (both are properties of each slot and the slots below it).

use toit_spec::cvec::CVec;
use toit_spec::v2::bytecodes::*;
use toit_spec::v2::cert;
use toit_spec::v2::check::{self, XCert, XGlobal, XKind, XMaps};
use toit_spec::v2::vprog::{x_info, VProgram};

#[derive(Default, Debug, Clone, Copy)]
pub struct FStats {
    pub methods: usize,
    pub instructions: usize,
    pub max_pending: usize,
    pub saved_maps: usize,
    pub max_arena: usize,
    pub shipped: usize,
    pub slot_checks: usize,
}

struct Walker {
    k: Vec<XKind>,
    out: Vec<XKind>,
    prev: Vec<XKind>,
    tmp: Vec<XKind>,
    buf: Vec<XKind>,
    // Pending forward comparisons: (target, start, len) into `arena`.
    pending: Vec<(usize, usize, usize)>,
    // Kinds kept at backward targets: (offset, start, len) into `arena`.
    saved: Vec<(usize, usize, usize)>,
    back: Vec<usize>,
    arena: Vec<XKind>,
    // Incremental checks: slots [0, valid) of `k` are known to satisfy
    // `wf_kind`; `ctx_at[j]` is `ctx_ok_at(j)`, `rmax[j]` the highest local
    // block reference among slots 0..=j (-1: none), `fbad[j]` the lowest
    // slot <= j whose `ctx_ok_at` is false (usize::MAX: none).
    valid: usize,
    ctx_at: Vec<bool>,
    rmax: Vec<i64>,
    fbad: Vec<usize>,
    stats: FStats,
    // `opt`: the incremental checks with fast paths for plain kinds and
    // the shape facts of a method computed once.
    opt: bool,
}

fn rd(s: &[u8], pos: usize) -> Option<(u32, usize)> {
    cert::x_varint(s, pos)
}

/// Reads one shipped map (drop, push, kinds) relative to `prev` into `out`.
fn read_map(s: &[u8], pos: usize, prev: &[XKind], out: &mut Vec<XKind>) -> Option<usize> {
    let (d, q) = rd(s, pos)?;
    let (n, q) = rd(s, q)?;
    if d as usize > prev.len() { return None; }
    let keep = prev.len() - d as usize;
    if n as usize > cert::MAX_KINDS - keep { return None; }
    out.clear();
    out.extend_from_slice(&prev[..keep]);
    let mut q = q;
    for _ in 0..n {
        let (k, q2) = cert::x_read_kind(s, q)?;
        out.push(k);
        q = q2;
    }
    Some(q)
}

fn u16_at(p: &VProgram, i: usize) -> usize {
    p.bytecodes.get(i).copied().unwrap_or(0) as usize | (p.bytecodes.get(i + 1).copied().unwrap_or(0) as usize) << 8
}

fn lref(k: XKind) -> i64 {
    match k { XKind::Block(0, s) => s as i64, _ => -1 }
}

impl Walker {
    fn new() -> Walker {
        Walker {
            k: Vec::new(), out: Vec::new(), prev: Vec::new(), tmp: Vec::new(), buf: Vec::new(),
            pending: Vec::new(), saved: Vec::new(), back: Vec::new(), arena: Vec::new(),
            valid: 0, ctx_at: Vec::new(), rmax: Vec::new(), fbad: Vec::new(), stats: FStats::default(), opt: false,
        }
    }

    /// `wf_kind` of slot `j` of `k` (the body of `x_wf_kinds`' loop).
    fn wf_slot(p: &VProgram, c: &XCert, m: i64, k: &Vec<XKind>, j: usize, buf: &mut Vec<XKind>) -> bool {
        match k[j] {
            XKind::Block(d, i) => {
                if d == 0 {
                    (i as usize) < j && check::x_block_slot(p, c, m, k, i as i64)
                } else {
                    match check::x_ctx_kinds_rev(c, m, d, buf) {
                        Ok((true, om)) => check::x_block_slot_rev(p, c, om, buf, i as i64),
                        _ => false,
                    }
                }
            }
            _ => true,
        }
    }

    /// The context checks of `k` (`wf_kinds && ctx_ok`), incrementally:
    /// `changed` is the lowest slot that may differ from the kinds the
    /// last call checked.
    fn ctx_checks(&mut self, p: &VProgram, c: &XCert, m: usize, changed: usize) -> bool {
        let h = self.k.len();
        if self.valid > changed { self.valid = changed; }
        if self.valid > h { self.valid = h; }
        self.ctx_at.truncate(self.valid);
        self.rmax.truncate(self.valid);
        self.fbad.truncate(self.valid);
        for j in self.valid..h {
            self.stats.slot_checks += 1;
            let plain = matches!(self.k[j], XKind::Val | XKind::Param | XKind::Token);
            let ok = if self.opt && plain {
                // A plain kind is well formed, and `ctx_ok_at` holds for it
                // (only a block method's slot has a context to agree with).
                true
            } else {
                if !Self::wf_slot(p, c, m as i64, &self.k, j, &mut self.buf) { self.valid = j; return false; }
                match check::x_ctx_ok_at(p, c, m as i64, &self.k, j) { Ok(b) => b, Err(_) => return false }
            };
            let below_r = if j == 0 { -1 } else { self.rmax[j - 1] };
            let below_b = if j == 0 { usize::MAX } else { self.fbad[j - 1] };
            self.ctx_at.push(ok);
            self.rmax.push(below_r.max(lref(self.k[j])));
            self.fbad.push(if !ok && below_b == usize::MAX { j } else { below_b });
        }
        self.valid = h;
        if h == 0 { return true; }
        let top = self.rmax[h - 1];
        top < 0 || self.fbad[h - 1] > top as usize
    }

    fn keep(&mut self, kinds_from_k: bool, prefix: usize) -> (usize, usize) {
        let start = self.arena.len();
        if kinds_from_k { self.arena.extend_from_slice(&self.k[..prefix]); } else { self.arena.extend_from_slice(&self.tmp[..prefix]); }
        if self.arena.len() > self.stats.max_arena { self.stats.max_arena = self.arena.len(); }
        (start, prefix)
    }

    fn arena_eq(&self, start: usize, len: usize, k: &[XKind]) -> bool {
        len == k.len() && &self.arena[start..start + len] == k
    }

    /// Checks method `m`, consuming its part of the maps stream at `*pos`
    /// and the pins of `m` from `*at`.
    #[allow(clippy::too_many_arguments)]
    fn method(&mut self, p: &VProgram, g: &XGlobal, s: &[u8], pos: &mut usize, m: usize, trusted: bool,
              at: &mut usize, incremental: bool) -> bool {
        let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
        let c = XCert { g, cur: m, maps: &empty };
        let info = x_info(p, m);
        if !(info.entry < info.end && info.end <= p.bytecodes.len()) { return false; }
        let size = info.end - info.entry;
        let Some((count, q)) = rd(s, *pos) else { return false };
        *pos = q;
        // Method-level checks (x_method_ok).
        if check::x_bp_len(&c, m) != info.arity as usize { return false; }
        let ctx = check::x_ctx_of(&c, m);
        if ctx.is_some() && info.kind != 3 { return false; }
        let np = g.pins.len() / 12;
        if info.kind == 3 && ctx.is_none() {
            // No maps; a pin of this method cannot agree.
            if count != 0 { return false; }
            return !(*at < np && check::x_fld(g.pins, 12, *at, 0) as usize == m);
        }
        let Ok(entry) = check::x_entry_kinds(p, &c, m) else { return false };
        // The shape facts of `m` (x_shape_ok), once per method.
        let need1 = check::x_pinned0(p, m) && info.arity >= 1;
        let block0 = if info.kind == 3 { ctx.map(|x| XKind::Block(1, x.slot)) } else { None };
        self.stats.methods += 1;
        // Pre-scan: the backward targets.
        self.back.clear();
        {
            let mut off = 0;
            while off < size {
                let raw = p.bytecodes[info.entry + off];
                if raw >= OPCODE_COUNT2 { off += 1; continue; }
                let op = exec_base_op(raw);
                let len = exec_opcode_length2(op);
                if (BRANCH_BACK..=BRANCH_BACK_IF_NOT_NULL).contains(&op) || op == LOOP_REPEAT || op == LOOP_ARRAY {
                    let w1 = u16_at(p, info.entry + off + 1);
                    if w1 <= off { self.back.push(off - w1); }
                }
                off += len;
            }
            self.back.sort_unstable();
            self.back.dedup();
        }
        self.pending.clear();
        self.saved.clear();
        self.arena.clear();
        self.valid = 0;
        self.prev.clear();
        self.k.clear();
        self.k.extend_from_slice(&entry);
        let mut left = count;
        let mut have = false;
        let mut e: usize = 0;
        if left > 0 {
            let Some((d, q)) = rd(s, *pos) else { return false };
            *pos = q;
            e = d as usize;
            have = true;
            left -= 1;
        }
        let mut have_cur = true;
        let mut changed = 0usize;
        let mut off = 0usize;
        let mut ok = true;
        // A terminator's successor that must equal the map at its next
        // offset (x_instr_ok checks `has_post` even for terminators).
        let mut bi = 0usize;
        while off < size {
            if have && e < off {
                // Behind the walk: read and ignored (as the decoder does).
                let Some(q) = read_map(s, *pos, &self.prev, &mut self.tmp) else { return false };
                *pos = q;
                if left > 0 {
                    let Some((d, q)) = rd(s, *pos) else { return false };
                    *pos = q;
                    e = e + 1 + d as usize;
                    left -= 1;
                } else { have = false; }
                continue;
            }
            if have && e == off {
                let Some(q) = read_map(s, *pos, &self.prev, &mut self.tmp) else { return false };
                *pos = q;
                self.stats.shipped += 1;
                if have_cur {
                    // The previous instruction's successor (or the entry
                    // kinds) must be the shipped map.
                    if self.tmp != self.k { ok = false; break; }
                } else {
                    std::mem::swap(&mut self.k, &mut self.tmp);
                    changed = 0;
                    have_cur = true;
                }
                if left > 0 {
                    let Some((d, q)) = rd(s, *pos) else { return false };
                    *pos = q;
                    e = e + 1 + d as usize;
                    left -= 1;
                } else { have = false; }
            } else if !have_cur {
                if !have { break; }
                off = e;
                continue;
            }
            // The map at `off` is `self.k`.
            if off == 0 && self.k != entry { ok = false; break; }
            while *at < np && check::x_fld(g.pins, 12, *at, 0) as usize == m && (check::x_fld(g.pins, 12, *at, 4) as usize) < off {
                // A pin at an offset the walk did not place.
                ok = false;
                break;
            }
            if !ok { break; }
            if *at < np && check::x_fld(g.pins, 12, *at, 0) as usize == m && check::x_fld(g.pins, 12, *at, 4) as usize == off {
                let Ok(pk) = check::x_fchain(g.nodes, check::x_fld(g.pins, 12, *at, 8)) else { return false };
                if pk != self.k { ok = false; break; }
                *at += 1;
            }
            if !self.pending.is_empty() {
                let mut i = 0;
                while i < self.pending.len() {
                    let (t, st, l) = self.pending[i];
                    if t == off {
                        if !self.arena_eq(st, l, &self.k) { ok = false; break; }
                        self.pending.swap_remove(i);
                    } else { i += 1; }
                }
                if !ok { break; }
            }
            while bi < self.back.len() && self.back[bi] < off { bi += 1; }
            if bi < self.back.len() && self.back[bi] == off {
                let h = self.k.len();
                let (st, l) = self.keep(true, h);
                self.saved.push((off, st, l));
                self.stats.saved_maps += 1;
            }
            // x_instr_ok without the map lookups.
            self.stats.instructions += 1;
            let bci = info.entry + off;
            let raw = p.bytecodes[bci];
            if raw >= OPCODE_COUNT2 { ok = false; break; }
            if exec_is_twin(raw) && !p.unchecked { ok = false; break; }
            let op = exec_base_op(raw);
            let len = exec_opcode_length2(op);
            if bci + len > info.end { ok = false; break; }
            if self.k.len() > info.arity as usize + info.max_height as usize { ok = false; break; }
            let ctx_ok = if incremental {
                self.ctx_checks(p, &c, m, changed)
            } else {
                matches!(check::x_wf_kinds(p, &c, m as i64, &self.k, &mut self.buf), Ok(true))
                    && matches!(check::x_ctx_ok(p, &c, m as i64, &self.k), Ok(true))
            };
            let shape_ok = if self.opt {
                !(need1 && self.k.is_empty()) && match block0 { Some(b) => !self.k.is_empty() && self.k[0] == b, None => info.kind != 3 }
            } else { check::x_shape_ok(p, &c, m, &self.k) };
            if !ctx_ok || !shape_ok { ok = false; break; }
            let has_post = match check::x_post_into(p, &c, m, off, &self.k, trusted, &mut self.out) { Ok(b) => b, Err(_) => return false };
            let term = check::x_is_terminator(op);
            if term {
                if !matches!(check::x_terminator_ok(p, &c, m, off, &self.k), Ok(true)) { ok = false; break; }
                if has_post {
                    std::mem::swap(&mut self.tmp, &mut self.out);
                    let h = self.tmp.len();
                    let (st, l) = self.keep(false, h);
                    self.pending.push((off + len, st, l));
                    std::mem::swap(&mut self.tmp, &mut self.out);
                }
            } else if !has_post { ok = false; break; }
            // The successor's offset must have a map (x_map_is): a
            // fall-through past the body's end has none.
            if !term && off + len >= size { ok = false; break; }
            if (BRANCH..=BRANCH_BACK_IF_NOT_NULL).contains(&op) {
                let w1 = u16_at(p, bci + 1);
                let forward = op <= BRANCH_IF_NOT_NULL;
                if forward && w1 == 0 { ok = false; break; }
                let h = self.k.len();
                let n = if op == BRANCH || op == BRANCH_BACK { h } else { if h < 1 { ok = false; break; } h - 1 };
                if forward {
                    let (st, l) = self.keep(true, n);
                    self.pending.push((off + w1, st, l));
                } else {
                    if w1 > off { ok = false; break; }
                    let t = off - w1;
                    match self.saved.iter().find(|x| x.0 == t) {
                        Some(&(_, st, l)) => { if !self.arena_eq(st, l, &self.k[..n]) { ok = false; break; } }
                        None => { ok = false; break; }
                    }
                }
            }
            if op == LOOP_REPEAT || op == LOOP_ARRAY {
                let w1 = u16_at(p, bci + 1);
                let lc = p.bytecodes[bci + 3] as usize;
                let Ok(kt) = check::x_loop_kinds(&self.k, lc, lc + 1) else { return false };
                if w1 > off { ok = false; break; }
                let t = off - w1;
                match self.saved.iter().find(|x| x.0 == t) {
                    Some(&(_, st, l)) => { if !self.arena_eq(st, l, &kt) { ok = false; break; } }
                    None => { ok = false; break; }
                }
            }
            if op == HASH_FIND {
                let w1 = u16_at(p, bci + 1);
                if w1 == 0 { ok = false; break; }
                self.tmp.clear();
                self.tmp.extend_from_slice(&self.k);
                self.tmp.push(XKind::Val);
                let h = self.tmp.len();
                let (st, l) = self.keep(false, h);
                self.pending.push((off + w1, st, l));
            }
            if self.pending.len() > self.stats.max_pending { self.stats.max_pending = self.pending.len(); }
            // Advance: the successor becomes the current kinds.
            std::mem::swap(&mut self.prev, &mut self.k);
            if !term && has_post {
                std::mem::swap(&mut self.k, &mut self.out);
                // The lowest slot that differs from the kinds just checked.
                let a = &self.prev;
                let b = &self.k;
                let mut d = 0;
                let lim = a.len().min(b.len());
                while d < lim && a[d] == b[d] { d += 1; }
                changed = d;
                have_cur = true;
            } else {
                have_cur = false;
            }
            off += len;
        }
        // The rest of the stream.
        while ok && (have || left > 0) {
            let Some(q) = read_map(s, *pos, &self.prev, &mut self.tmp) else { return false };
            *pos = q;
            if left > 0 {
                let Some((_, q)) = rd(s, *pos) else { return false };
                *pos = q;
                left -= 1;
            } else { have = false; }
        }
        if !ok { return false; }
        // Every forward target was reached; every pin of `m` was placed.
        if !self.pending.is_empty() { return false; }
        if *at < np && check::x_fld(g.pins, 12, *at, 0) as usize == m { return false; }
        true
    }
}

/// The verdict of the single-pass checker on `p` with the shipped
/// certificate `bytes` (no heap check: `x_loaded_ok_stream` is separate).
pub fn verify(p: &VProgram, bytes: &[u8], global_count: u64, prim_arity: &[Vec<u8>], trusted: bool, incremental: bool, opt: bool)
    -> (bool, FStats) {
    let mut w = Walker::new();
    w.opt = opt && incremental;
    let Some((g, maps)) = cert::parse_cert(p, bytes, global_count, prim_arity) else { return (false, w.stats) };
    if !check::x_wf_program2(p) { return (false, w.stats); }
    if p.unchecked && !trusted { return (false, w.stats); }
    if g.n != p.methods.len() { return (false, w.stats); }
    if !check::x_g_ok(&g) { return (false, w.stats); }
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    let tc = XCert { g: &g, cur: g.n, maps: &empty };
    if !matches!(check::x_tables_ok(p, &tc), Ok(true)) { return (false, w.stats); }
    let mut pos = 0usize;
    let mut at = 0usize;
    for m in 0..p.methods.len() {
        if !w.method(p, &g, maps, &mut pos, m, trusted, &mut at, incremental) { return (false, w.stats); }
    }
    let np = g.pins.len() / 12;
    (at == np, w.stats)
}

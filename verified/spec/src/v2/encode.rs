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

//! The producer of shipped certificates (untrusted, host only): encodes
//! the certificate the inference computed (`v2::infer`) in the format of
//! format/18-shipped-certificate.md, which `v2::cert::verify_shipped`
//! checks. Nothing here is trusted: a wrong encoding is rejected.
//!
//! The global tables are copied, with the kind lists of the contexts and
//! pins interned in one node table (lists share their common bottoms).
//! The maps stream keeps, per method, only the maps the decoder cannot
//! recompute by falling through (`v2::cert::ShippedOracle::decode`); this
//! encoder walks each method exactly as the decoder does.

use alloc::collections::BTreeMap;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;
use crate::v2::bytecodes::*;
use crate::v2::cert::*;
use crate::v2::check::*;
use crate::v2::gbuf::*;
use crate::v2::infer::{self, Global};
use crate::v2::vprog::*;

/// Sizes of the parts of an encoded certificate (measurements).
#[derive(Default, Debug, Clone)]
pub struct Sizes {
    pub total: usize,
    pub header: usize,
    pub mw: usize,
    pub crec: usize,
    pub sel: usize,
    pub pins: usize,
    pub nodes: usize,
    pub maps: usize,
    /// Shipped maps (merge points) and the maps the decoder recomputes.
    pub shipped_maps: usize,
    pub implicit_maps: usize,
}

pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// A kind of the maps stream (`cert::x_read_kind`).
fn put_kind(out: &mut Vec<u8>, k: XKind) -> Result<(), String> {
    let (tag, x, d) = match k {
        XKind::Val => (0u64, 0u64, None),
        XKind::Param => (0, 1, None),
        XKind::Token => (0, 2, None),
        XKind::Method(t) => (1, t as u64, None),
        XKind::Block(0, s) => (2, s as u64, None),
        XKind::Block(d, s) => (3, s as u64, Some(d)),
    };
    let v = x * 4 + tag;
    if v > u32::MAX as u64 {
        return Err(format!("kind operand too large: {:?}", k));
    }
    put_varint(out, v);
    if let Some(d) = d { put_varint(out, d as u64); }
    Ok(())
}

/// One node table for the lists of the contexts and pins.
struct Interner {
    nodes: Vec<u8>,
    index: BTreeMap<(u32, u32, u32), u32>,
}

impl Interner {
    fn list(&mut self, kinds: &[XKind]) -> Result<u32, String> {
        let mut top = EMPTY_MAP;
        for &k in kinds {
            let (a, b) = kind_words(k).ok_or_else(|| format!("kind not representable: {:?}", k))?;
            let next = self.nodes.len() as u32 / 12;
            let parent = if top == EMPTY_MAP { next } else { top };
            // A root's parent is itself, so roots are keyed by `NO_MAP`.
            let key = (if top == EMPTY_MAP { NO_MAP } else { top }, a, b);
            top = match self.index.get(&key) {
                Some(&id) => id,
                None => {
                    if next >= EMPTY_MAP - 1 { return Err(String::from("too many nodes")); }
                    push32(&mut self.nodes, parent);
                    push32(&mut self.nodes, a);
                    push32(&mut self.nodes, b);
                    self.index.insert(key, next);
                    next
                }
            };
        }
        Ok(top)
    }
}

fn kinds_at(maps: &XMaps, off: usize) -> Option<Vec<XKind>> {
    match (off < maps.idx.len()).then(|| maps.idx.at(off)) {
        Some(top) if top != NO_MAP => Some(infer::ok(x_chain(&maps.nodes, top))),
        _ => None,
    }
}

fn is_terminator(op: u8) -> bool {
    matches!(op, RETURN | RETURN_NULL | THROW | BRANCH | BRANCH_BACK | INVOKE_STATIC_TAIL
        | INVOKE_LAMBDA_TAIL | INVOKE_INITIALIZER_TAIL | NON_LOCAL_RETURN | NON_LOCAL_BRANCH
        | BRANCH_S | BRANCH_BACK_S)
}

/// The stream entries of method `m` with maps `maps`: (offset, slots
/// dropped from the previous map, kinds pushed).
fn method_entries(p: &VProgram, g: &XGlobal, m: usize, maps: &XMaps, trusted: bool, sizes: &mut Sizes)
        -> Vec<(usize, usize, Vec<XKind>)> {
    let mut out = Vec::new();
    let Some(info) = p.methods.get(m) else { return out };
    let (entry, end) = (info.entry as usize, info.end());
    if !(entry < end && end <= p.bytecodes.len()) { return out; }
    let size = end - entry;
    let empty = XMaps { idx: CVec::new(), nodes: CVec::new() };
    let c = XCert { g, cur: m, maps: &empty };
    if info.kind == 3 && x_ctx_of(&c, m).is_none() { return out; }
    let mut cur: Option<Vec<XKind>> = Some(infer::ok(x_entry_kinds(p, &c, m)));
    let mut prev: Vec<XKind> = Vec::new();
    let mut off = 0;
    while off < size {
        let want = kinds_at(maps, off);
        let placed = match (want, cur.take()) {
            (Some(w), Some(c)) if w == c => { sizes.implicit_maps += 1; c }
            (Some(w), _) => {
                let keep = prev.iter().zip(w.iter()).take_while(|(a, b)| a == b).count();
                out.push((off, prev.len() - keep, w[keep..].to_vec()));
                sizes.shipped_maps += 1;
                w
            }
            (None, Some(c)) => c,
            (None, None) => {
                match (off + 1..size).find(|&o| o < maps.idx.len() && maps.idx.at(o) != NO_MAP) {
                    Some(o) => { off = o; continue; }
                    None => break,
                }
            }
        };
        let bci = entry + off;
        let op = exec_base_op(p.bytecodes[bci]);
        if op >= OPCODE_COUNT2 || OPCODE_LENGTHS2[op as usize] as usize > end - bci {
            prev = placed;
            off += 1;
            continue;
        }
        let len = OPCODE_LENGTHS2[op as usize] as usize;
        if !is_terminator(op) && placed.len() <= 0x10_0000 {
            cur = infer::ok(infer::x_post(p, &c, m, off, &placed, trusted));
        }
        prev = placed;
        off += len;
    }
    out
}

/// Encodes the certificate of `global` (with the maps the inference
/// computes for the frozen global part). The sections are 4-byte aligned.
pub fn encode(p: &VProgram, global: &Global, trusted: bool) -> Result<(Vec<u8>, Sizes), String> {
    let g = &global.g;
    if g.unrepresentable {
        return Err(String::from("the inferred certificate has a kind the format cannot represent"));
    }
    let n = p.methods.len();
    let mut sizes = Sizes::default();
    // The node table: contexts first, then pins.
    let mut interner = Interner { nodes: Vec::new(), index: BTreeMap::new() };
    let mut crec = Vec::with_capacity(g.crec.len());
    for j in 0..g.crec.len() / 12 {
        let (outer, slot, top) = (rd32(&g.crec, j * 12), rd32(&g.crec, j * 12 + 4), rd32(&g.crec, j * 12 + 8));
        let top = interner.list(&g.list(top))?;
        push32(&mut crec, outer);
        push32(&mut crec, slot);
        push32(&mut crec, top);
    }
    let mut pins = Vec::with_capacity(g.pins.len());
    for (m, off, top) in g.pin_list() {
        let top = interner.list(&g.list(top))?;
        push32(&mut pins, m);
        push32(&mut pins, off);
        push32(&mut pins, top);
    }
    // The maps stream.
    let view = g.view(p.methods);
    let mut oracle = infer::Oracle::new(p, global, trusted);
    let mut stream = Vec::new();
    for m in 0..n {
        let maps = infer::ok(<infer::Oracle as MapOracle>::method_maps(&mut oracle, p, &view, m));
        let entries = method_entries(p, &view, m, &maps, trusted, &mut sizes);
        put_varint(&mut stream, entries.len() as u64);
        let mut last: Option<usize> = None;
        for (off, drop, push) in entries {
            put_varint(&mut stream, match last { None => off, Some(l) => off - l - 1 } as u64);
            last = Some(off);
            put_varint(&mut stream, drop as u64);
            put_varint(&mut stream, push.len() as u64);
            for k in push { put_kind(&mut stream, k)?; }
        }
    }
    let sections: [&[u8]; 6] = [&g.mw, &crec, &g.sel, &pins, &interner.nodes, &stream];
    let mut out = Vec::new();
    push32(&mut out, CERT_MAGIC);
    push32(&mut out, CERT_VERSION);
    push32(&mut out, n as u32);
    let mut at = CERT_HEADER_SIZE;
    for s in sections {
        push32(&mut out, at as u32);
        push32(&mut out, s.len() as u32);
        at += (s.len() + 3) & !3;
    }
    for s in sections {
        out.extend_from_slice(s);
        while out.len() % 4 != 0 { out.push(0); }
    }
    if out.len() > u32::MAX as usize {
        return Err(String::from("certificate too large"));
    }
    sizes.total = out.len();
    sizes.header = CERT_HEADER_SIZE;
    sizes.mw = g.mw.len();
    sizes.crec = crec.len();
    sizes.sel = g.sel.len();
    sizes.pins = pins.len();
    sizes.nodes = interner.nodes.len();
    sizes.maps = stream.len();
    Ok((out, sizes))
}

/// Infers and encodes the certificate of `p`; `Err` if the inference does
/// not find one the checker accepts.
pub fn certify(p: &VProgram, global_count: u64, prim_arity: Vec<Vec<u8>>, trusted: bool) -> Result<(Vec<u8>, Sizes), String> {
    let global = infer::infer_global(p, global_count, prim_arity, trusted);
    encode(p, &global, trusted)
}

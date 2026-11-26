// Copyright (C) 2026 Toit contributors.

//! Certificate statistics and size options: today's shipped certificate
//! (version 1) by section, the inferred maps (every mapped instruction,
//! branch targets, joins), per-method max heights against the program's
//! single bound, and the stream sizes of alternative map placements.

use crate::stats::{instructions, len_of, u16_at};
use toit_spec::v2::bytecodes::*;
use toit_spec::v2::check::{self, MapOracle, XKind};
use toit_spec::v2::{encode, infer};
use toit_spec::v2::vprog::VProgram;

fn varint_len(mut v: u64) -> usize {
    let mut n = 1;
    while v >= 0x80 { v >>= 7; n += 1; }
    n
}

fn kind_len(k: XKind) -> usize {
    match k {
        XKind::Val => 1,
        XKind::Param => 1,
        XKind::Token => 1,
        XKind::Method(t) => varint_len((t as u64) * 4 + 1),
        XKind::Block(0, s) => varint_len((s as u64) * 4 + 2),
        XKind::Block(d, s) => varint_len((s as u64) * 4 + 3) + varint_len(d as u64),
    }
}

/// Bytes of a map `k` encoded relative to `prev` (drop, push, kinds).
fn map_len(prev: &[XKind], k: &[XKind]) -> usize {
    let mut c = 0;
    while c < prev.len() && c < k.len() && prev[c] == k[c] { c += 1; }
    let drop = prev.len() - c;
    let push = &k[c..];
    varint_len(drop as u64) + varint_len(push.len() as u64) + push.iter().map(|x| kind_len(*x)).sum::<usize>()
}

pub fn run(path: &str, p: &VProgram, global_count: u64, prim_arity: &[Vec<u8>], trusted: bool) {
    let (cert, sizes) = encode::certify(p, global_count, prim_arity.to_vec(), trusted).expect("certify");
    let n = p.methods.len();
    println!("== certificate {}", path);
    println!("v1 total {} B ({:.1} % of {} B bytecodes): header {} method-words {} contexts {} selectors {} pins {} nodes {} maps {} (shipped maps {}, implicit {})",
        sizes.total, 100.0 * sizes.total as f64 / p.bytecodes.len() as f64, p.bytecodes.len(), sizes.header, sizes.mw,
        sizes.crec, sizes.sel, sizes.pins, sizes.nodes, sizes.maps, sizes.shipped_maps, sizes.implicit_maps);
    let _ = cert;
    let global = infer::infer_global(p, global_count, prim_arity.to_vec(), trusted);
    let g = global.g.view(p.methods);
    let mut oracle = infer::Oracle::new(p, &global, trusted);
    let mut nonzero_mw = 0;
    for m in 0..n { if check::x_fld(g.mw, 4, m, 0) != 0 { nonzero_mw += 1; } }
    println!("method words: {} of {} non-zero (a sparse table: {} B instead of {} B)", nonzero_mw, n, nonzero_mw * 8, n * 4);
    let mut mapped = 0usize;
    let mut instrs = 0usize;
    let mut targets = 0usize;
    let mut joins = 0usize;
    let mut back_targets = 0usize;
    let mut all_bytes = 0usize;
    let mut target_bytes = 0usize;
    let mut heights: Vec<usize> = Vec::new();
    let mut slots: Vec<usize> = Vec::new();
    let mut max_kinds_total = 0usize;
    let mut nonval_maps = 0usize;
    let mut idx_words = 0usize;
    for m in 0..n {
        let maps = oracle.method_maps(p, &g, m).ok().expect("maps");
        let v = p.methods.at(m);
        let ins = instructions(p, m);
        instrs += ins.len();
        idx_words += maps.idx.len();
        let mut is_target = std::collections::HashSet::new();
        let mut is_back = std::collections::HashSet::new();
        let mut preds: std::collections::HashMap<usize, usize> = std::collections::HashMap::new();
        let mut prev_term = true;
        for &(off, op) in &ins {
            let b = exec_base_op(op);
            if !prev_term { *preds.entry(off).or_insert(0) += 1; }
            let bci = v.entry as usize + off;
            let w = if len_of(op) >= 3 { u16_at(p, bci + 1) } else { 0 };
            if (BRANCH..=BRANCH_IF_NOT_NULL).contains(&b) || b == HASH_FIND {
                is_target.insert(off + w);
                *preds.entry(off + w).or_insert(0) += 1;
            }
            if (BRANCH_BACK..=BRANCH_BACK_IF_NOT_NULL).contains(&b) || b == LOOP_REPEAT || b == LOOP_ARRAY {
                if w <= off { is_target.insert(off - w); is_back.insert(off - w); *preds.entry(off - w).or_insert(0) += 1; }
            }
            prev_term = check::x_is_terminator(b);
        }
        let mut prev: Vec<XKind> = Vec::new();
        let mut maxh = 0usize;
        let mut maxs = 0usize;
        let mut any = false;
        for &(off, _) in &ins {
            if off >= maps.idx.len() { break; }
            let i = maps.idx.at(off);
            if i == check::NO_MAP { continue; }
            let k = check::x_chain(&maps.nodes, i).ok().expect("chain");
            any = true;
            mapped += 1;
            if k.iter().any(|x| *x != XKind::Val) { nonval_maps += 1; }
            let h = k.len().saturating_sub(v.arity as usize);
            if h > maxh { maxh = h; }
            if k.len() > maxs { maxs = k.len(); }
            let l = map_len(&prev, &k) + 1;
            all_bytes += l;
            if is_target.contains(&off) {
                targets += 1;
                target_bytes += l;
                if is_back.contains(&off) { back_targets += 1; }
                if preds.get(&off).copied().unwrap_or(0) >= 2 { joins += 1; }
            }
            prev = k;
        }
        if any { heights.push(maxh); slots.push(maxs); max_kinds_total += maxs; }
    }
    println!("instructions {}, mapped (reachable) {} ({:.1} %), maps with a non-value kind {} ({:.1} %)", instrs, mapped,
        100.0 * mapped as f64 / instrs as f64, nonval_maps, 100.0 * nonval_maps as f64 / mapped.max(1) as f64);
    println!("branch targets {} (backward {}), joins (>= 2 predecessors) {}", targets, back_targets, joins);
    println!("stream sizes: every map {} B ({:.2} B/instruction), every branch target {} B, today's {} B",
        all_bytes, all_bytes as f64 / mapped.max(1) as f64, target_bytes, sizes.maps);
    println!("decoder's per-method index today: {} words = {} B summed over methods (largest method {} B)",
        idx_words, idx_words * 4, (0..n).map(|m| { let v = p.methods.at(m); v.end() - v.entry as usize }).max().unwrap_or(0) * 4);
    heights.sort();
    let q = |f: f64| heights[((heights.len() - 1) as f64 * f) as usize];
    println!("per-method max height (slots above the arguments): median {} p90 {} p99 {} max {}; program bound H = {}",
        q(0.5), q(0.9), q(0.99), heights[heights.len() - 1], p.max_height);
    let mean_slots = max_kinds_total as f64 / slots.len() as f64;
    println!("per-method max frame slots (arguments + height): mean {:.1}; a per-method height in the record: {} methods", mean_slots, slots.len());
}

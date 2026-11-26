// Copyright (C) 2026 Toit contributors.

//! Static statistics of a format-2 program: methods, sizes, opcodes,
//! operands, calls, try/finally, blocks, literals, static pairs.

use std::collections::{BTreeMap, HashMap, HashSet};
use toit_spec::v2::bytecodes::*;
use toit_spec::v2::vprog::VProgram;

pub fn name(op: u8) -> &'static str {
    if (op as usize) < OPCODE_NAMES2.len() { OPCODE_NAMES2[op as usize] } else { "?" }
}

pub fn len_of(op: u8) -> usize {
    if (op as usize) < OPCODE_LENGTHS2.len() { OPCODE_LENGTHS2[op as usize] as usize } else { 1 }
}

/// The instructions of method `m`: (offset, raw opcode).
pub fn instructions(p: &VProgram, m: usize) -> Vec<(usize, u8)> {
    let v = p.methods.at(m);
    let (entry, end) = (v.entry as usize, v.end());
    let mut out = Vec::new();
    let mut bci = entry;
    while bci < end {
        let op = p.bytecodes[bci];
        out.push((bci - entry, op));
        bci += len_of(op);
    }
    out
}

pub fn u16_at(p: &VProgram, i: usize) -> usize {
    p.bytecodes[i] as usize | (p.bytecodes[i + 1] as usize) << 8
}

fn pct(v: &mut Vec<usize>, q: f64) -> usize {
    if v.is_empty() { return 0; }
    v.sort();
    v[((v.len() - 1) as f64 * q) as usize]
}

pub fn is_call(op: u8) -> bool {
    let b = exec_base_op(op);
    (INVOKE_STATIC..=INVOKE_SIZE).contains(&b) || b == TRY || b == PRIMITIVE
}

pub fn run(path: &str, p: &VProgram) {
    let n = p.methods.len();
    let mut kinds = [0usize; 5];
    let mut body_bytes = 0usize;
    let mut sizes = Vec::new();
    let mut ops: BTreeMap<u8, (usize, usize)> = BTreeMap::new();
    let mut pairs: HashMap<(u8, u8), usize> = HashMap::new();
    let mut try_methods = 0usize;
    let mut tries = 0usize;
    let mut nlr = 0usize;
    let mut operand1: BTreeMap<u8, [usize; 6]> = BTreeMap::new();
    let mut operand2: BTreeMap<u8, [usize; 3]> = BTreeMap::new();
    let mut lits = HashSet::new();
    let mut call_args: BTreeMap<usize, usize> = BTreeMap::new();
    let mut prims: HashMap<(u8, usize), usize> = HashMap::new();
    let mut instrs = 0usize;
    let mut virtual_sel: HashMap<usize, usize> = HashMap::new();
    let mut static_targets = HashSet::new();
    for m in 0..n {
        let v = p.methods.at(m);
        kinds[(v.kind & 7).min(4) as usize] += 1;
        let size = v.end() - v.entry as usize;
        body_bytes += size;
        sizes.push(size);
        let ins = instructions(p, m);
        instrs += ins.len();
        let mut has_try = false;
        let mut prev: Option<u8> = None;
        for &(off, op) in &ins {
            let bci = v.entry as usize + off;
            let e = ops.entry(op).or_insert((0, 0));
            e.0 += 1;
            e.1 += len_of(op);
            if let Some(q) = prev { *pairs.entry((q, op)).or_insert(0) += 1; }
            prev = Some(op);
            let b = exec_base_op(op);
            if b == TRY { has_try = true; tries += 1; }
            if b == NON_LOCAL_RETURN || b == NON_LOCAL_BRANCH { nlr += 1; }
            let l = len_of(op);
            if l == 2 {
                let x = p.bytecodes[bci + 1] as usize;
                let bucket = if x < 4 { 0 } else if x < 8 { 1 } else if x < 16 { 2 } else if x < 32 { 3 } else if x < 64 { 4 } else { 5 };
                operand1.entry(op).or_insert([0; 6])[bucket] += 1;
            } else if l == 3 {
                let x = u16_at(p, bci + 1);
                let bucket = if x < 16 { 0 } else if x < 256 { 1 } else { 2 };
                operand2.entry(op).or_insert([0; 3])[bucket] += 1;
            }
            if b == LOAD_LITERAL { lits.insert(p.bytecodes[bci + 1] as usize); }
            if b == LOAD_LITERAL_WIDE { lits.insert(u16_at(p, bci + 1)); }
            if b == INVOKE_STATIC || b == INVOKE_STATIC_TAIL {
                let d = u16_at(p, bci + 1);
                let t = p.dispatch.get(d).copied().unwrap_or(-1);
                if t >= 0 && (t as usize) < n {
                    static_targets.insert(t as usize);
                    *call_args.entry(p.methods.at(t as usize).arity as usize).or_insert(0) += 1;
                }
            }
            if b == INVOKE_VIRTUAL {
                *virtual_sel.entry(u16_at(p, bci + 2)).or_insert(0) += 1;
                *call_args.entry(p.bytecodes[bci + 1] as usize + 1).or_insert(0) += 1;
            }
            if b == PRIMITIVE {
                *prims.entry((p.bytecodes[bci + 1], u16_at(p, bci + 2))).or_insert(0) += 1;
            }
        }
        if has_try { try_methods += 1; }
    }
    println!("== static {}", path);
    println!("methods {} (method {}, accessor {}, lambda {}, block {}, other {})", n, kinds[0], kinds[1], kinds[2], kinds[3], kinds[4]);
    println!("bytecodes {} B, bodies {} B, headers+pad {} B ({:.2} B/method)", p.bytecodes.len(), body_bytes,
        p.bytecodes.len() - body_bytes, (p.bytecodes.len() - body_bytes) as f64 / n as f64);
    println!("method table {} B (4 B/method)", n * 4);
    println!("instructions {} ({:.2} B/instruction)", instrs, body_bytes as f64 / instrs as f64);
    let mean = body_bytes as f64 / n as f64;
    let mut s2 = sizes.clone();
    println!("body bytes per method: mean {:.1}, median {}, p90 {}, p99 {}, max {}", mean,
        pct(&mut s2, 0.5), pct(&mut s2, 0.9), pct(&mut s2, 0.99), pct(&mut s2, 1.0));
    println!("max height (program) {}", p.max_height);
    println!("try: {} TRY in {} methods ({:.1} %); non-local return/branch {}", tries, try_methods,
        100.0 * try_methods as f64 / n as f64, nlr);
    println!("literals: {} in table, {} distinct loaded", p.literals.len(), lits.len());
    println!("static call targets (distinct) {}", static_targets.len());
    let cs: Vec<String> = call_args.iter().map(|(a, c)| format!("{}:{}", a, c)).collect();
    println!("static+virtual call arg counts: {}", cs.join(" "));
    println!("virtual call sites {} over {} selectors", virtual_sel.values().sum::<usize>(), virtual_sel.len());
    let mut pv: Vec<_> = prims.iter().collect();
    pv.sort_by(|a, b| b.1.cmp(a.1));
    println!("primitive call sites {} ({} distinct)", prims.values().sum::<usize>(), prims.len());
    println!("-- opcodes (raw): count bytes %count");
    let mut ov: Vec<_> = ops.iter().collect();
    ov.sort_by(|a, b| (b.1).0.cmp(&(a.1).0));
    for (op, (c, by)) in &ov {
        println!("{:>4} {:<26} {:>7} {:>7} {:>5.1}", op, name(**op), c, by, 100.0 * *c as f64 / instrs as f64);
    }
    println!("-- 1-byte operands: <4 <8 <16 <32 <64 >=64");
    for (op, b) in &operand1 {
        println!("{:>4} {:<26} {:?}", op, name(*op), b);
    }
    println!("-- 2-byte operands: <16 <256 >=256");
    for (op, b) in &operand2 {
        println!("{:>4} {:<26} {:?}", op, name(*op), b);
    }
    println!("-- static pairs (top 30)");
    let mut pp: Vec<_> = pairs.iter().collect();
    pp.sort_by(|a, b| b.1.cmp(a.1));
    for ((a, b), c) in pp.iter().take(30) {
        println!("{:>6} {} {}", c, name(*a), name(*b));
    }
}

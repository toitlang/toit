// Copyright (C) 2026 Toit contributors.

//! Dynamic statistics from a `-Xtrace` stream of the checked loop
//! (`[bci] #opcode` lines; with TOIT_V2_TRACE_PROCESS also `pN gX`, the
//! process and its program) on stdin. "OPB name" lines start a segment,
//! "OPB -" ends it (verified/format3-study/README.md). Only lines of the
//! program given as tables are attributed to methods; other programs
//! (the system process) are counted per segment.

use crate::stats::{len_of, name, u16_at};
use std::collections::HashMap;
use std::io::BufRead;
use toit_spec::v2::bytecodes::*;
use toit_spec::v2::vprog::VProgram;

#[derive(Default)]
struct Seg {
    ops: HashMap<u8, u64>,
    pairs: HashMap<(u8, u8), u64>,
    triples: HashMap<(u8, u8, u8), u64>,
    total: u64,
    other_program: u64,
    // Call site -> target (method index, or usize::MAX for "continued inline").
    sites: HashMap<usize, HashMap<usize, u64>>,
    prims: HashMap<(u8, usize), (u64, u64)>,
    methods: HashMap<usize, u64>,
    branches: HashMap<u8, (u64, u64)>,
}

struct Proc {
    prev: Option<(usize, u8)>,
    prev2: Option<u8>,
}

fn method_of(entries: &[(usize, usize, usize)], bci: usize) -> Option<usize> {
    let i = entries.partition_point(|e| e.0 <= bci);
    if i == 0 { return None; }
    let (entry, end, m) = entries[i - 1];
    if bci < end { let _ = entry; Some(m) } else { None }
}

pub fn run(p: &VProgram, top: usize) {
    let n = p.methods.len();
    let mut entries: Vec<(usize, usize, usize)> = (0..n).map(|m| { let v = p.methods.at(m); (v.entry as usize, v.end(), m) }).collect();
    entries.sort();
    let is_entry: std::collections::HashSet<usize> = entries.iter().map(|e| e.0).collect();
    let mut segs: Vec<(String, Seg)> = Vec::new();
    let mut cur: Option<usize> = None;
    let mut procs: HashMap<String, Proc> = HashMap::new();
    // The benchmark's program: the tag of the first traced line inside a
    // segment whose bci decodes as an instruction of the tables' program
    // is not reliable; take the most frequent tag of the first segment.
    let mut prog_tag: Option<String> = None;
    let mut tag_counts: HashMap<String, u64> = HashMap::new();
    let stdin = std::io::stdin();
    let mut lines = 0u64;
    for line in stdin.lock().lines() {
        let line = match line { Ok(l) => l, Err(_) => break };
        if let Some(rest) = line.strip_prefix("OPB ") {
            if rest == "-" { cur = None; } else {
                segs.push((rest.to_string(), Seg::default()));
                cur = Some(segs.len() - 1);
            }
            procs.clear();
            continue;
        }
        if !line.starts_with('[') { continue; }
        let close = match line.find(']') { Some(c) => c, None => continue };
        let bci: usize = match line[1..close].trim().parse() { Ok(b) => b, Err(_) => continue };
        let mut parts = line[close + 1..].split_whitespace();
        let op: u8 = match parts.next().and_then(|s| s.strip_prefix('#')).and_then(|s| s.parse().ok()) { Some(o) => o, None => continue };
        let pid = parts.next().unwrap_or("p0").to_string();
        let tag = parts.next().unwrap_or("g0").to_string();
        lines += 1;
        let Some(si) = cur else { continue };
        if prog_tag.is_none() {
            *tag_counts.entry(tag.clone()).or_insert(0) += 1;
            if tag_counts.values().sum::<u64>() >= 20000 || tag_counts.len() > 1 && tag_counts.values().sum::<u64>() >= 2000 {
                prog_tag = tag_counts.iter().max_by_key(|e| e.1).map(|e| e.0.clone());
            }
        }
        let seg = &mut segs[si].1;
        if let Some(t) = &prog_tag { if *t != tag { seg.other_program += 1; continue; } }
        // Sanity: the opcode must match the tables' program.
        if bci >= p.bytecodes.len() || p.bytecodes[bci] != op { seg.other_program += 1; continue; }
        seg.total += 1;
        *seg.ops.entry(op).or_insert(0) += 1;
        if let Some(m) = method_of(&entries, bci) { *seg.methods.entry(m).or_insert(0) += 1; }
        let pr = procs.entry(pid).or_insert(Proc { prev: None, prev2: None });
        if let Some((pb, pop)) = pr.prev {
            *seg.pairs.entry((pop, op)).or_insert(0) += 1;
            if let Some(pp) = pr.prev2 { *seg.triples.entry((pp, pop, op)).or_insert(0) += 1; }
            let b = exec_base_op(pop);
            let after = pb + len_of(pop);
            if (INVOKE_STATIC..=INVOKE_SIZE).contains(&b) || b == TRY {
                let t = if bci == after { usize::MAX } else if is_entry.contains(&bci) { method_of(&entries, bci).unwrap_or(usize::MAX - 1) } else { usize::MAX - 1 };
                *seg.sites.entry(pb).or_insert_with(HashMap::new).entry(t).or_insert(0) += 1;
            }
            if b == PRIMITIVE {
                let key = (p.bytecodes[pb + 1], u16_at(p, pb + 2));
                let e = seg.prims.entry(key).or_insert((0, 0));
                e.0 += 1;
                if bci == after { e.1 += 1; }
            }
            if (BRANCH_IF_TRUE..=BRANCH_IF_NOT_NULL).contains(&b) || (BRANCH_BACK_IF_TRUE..=BRANCH_BACK_IF_NOT_NULL).contains(&b) {
                let e = seg.branches.entry(b).or_insert((0, 0));
                e.0 += 1;
                if bci != after { e.1 += 1; }
            }
            pr.prev2 = Some(pop);
        }
        pr.prev = Some((bci, op));
    }
    eprintln!("trace lines {}", lines);
    for (sname, s) in &segs {
        report(p, sname, s, top);
    }
}

fn report(p: &VProgram, sname: &str, s: &Seg, top: usize) {
    let t = s.total.max(1) as f64;
    println!("== dynamic {} : {} instructions (other programs {})", sname, s.total, s.other_program);
    let mut ov: Vec<_> = s.ops.iter().collect();
    ov.sort_by(|a, b| b.1.cmp(a.1));
    println!("-- opcodes");
    for (op, c) in ov.iter().take(top) {
        println!("{:>10} {:>5.1} % {:>4} {}", c, 100.0 * **c as f64 / t, op, name(**op));
    }
    // Classes.
    let mut class: HashMap<&str, u64> = HashMap::new();
    for (op, c) in &s.ops {
        let b = exec_base_op(*op);
        let k = match b {
            LOAD_LOCAL | LOAD_LOCAL_WIDE | POP_LOAD_LOCAL | LOAD_LOCAL_0..=LOAD_LOCAL_5 => "load local",
            STORE_LOCAL | STORE_LOCAL_POP => "store local",
            LOAD_OUTER | STORE_OUTER | LOAD_OUTER_BLOCK | LOAD_BLOCK => "outer/block refs",
            LOAD_FIELD | LOAD_FIELD_WIDE | LOAD_FIELD_LOCAL | POP_LOAD_FIELD_LOCAL | STORE_FIELD | STORE_FIELD_WIDE | STORE_FIELD_POP => "field (checked)",
            LOAD_FIELD_THIS | STORE_FIELD_THIS => "field (this)",
            LOAD_LITERAL | LOAD_LITERAL_WIDE | LOAD_NULL | LOAD_SMI_0 | LOAD_SMIS_0 | LOAD_SMI_1 | LOAD_SMI_U8 | LOAD_SMI_U16 | LOAD_SMI_U32 | LOAD_METHOD => "constants",
            LOAD_GLOBAL_VAR..=STORE_GLOBAL_VAR_DYNAMIC => "globals",
            POP | POP_1 => "pop",
            ALLOCATE | ALLOCATE_WIDE => "allocate",
            IS_CLASS..=AS_LOCAL => "type checks",
            INVOKE_STATIC | INVOKE_STATIC_TAIL => "static call",
            INVOKE_BLOCK => "block call",
            INVOKE_LAMBDA_TAIL | INVOKE_INITIALIZER_TAIL => "lambda/initializer",
            INVOKE_VIRTUAL | INVOKE_VIRTUAL_WIDE => "virtual call",
            INVOKE_VIRTUAL_GET | INVOKE_VIRTUAL_SET => "virtual get/set",
            INVOKE_EQ..=INVOKE_SIZE => "operators",
            BRANCH..=BRANCH_BACK_IF_NOT_NULL => "branches",
            PRIMITIVE => "primitive",
            RETURN | RETURN_NULL => "return",
            THROW | NON_LOCAL_RETURN | NON_LOCAL_BRANCH | TRY | UNWIND => "try/unwind/nlr",
            IDENTICAL => "identical",
            LOOP_REPEAT | LOOP_ARRAY | HASH_FIND => "builtins",
            _ => "other",
        };
        *class.entry(k).or_insert(0) += *c;
    }
    let mut cv: Vec<_> = class.iter().collect();
    cv.sort_by(|a, b| b.1.cmp(a.1));
    println!("-- classes");
    for (k, c) in &cv { println!("{:>10} {:>5.1} % {}", c, 100.0 * **c as f64 / t, k); }
    println!("-- pairs");
    let mut pv: Vec<_> = s.pairs.iter().collect();
    pv.sort_by(|a, b| b.1.cmp(a.1));
    for ((a, b), c) in pv.iter().take(top) {
        println!("{:>10} {:>5.1} % {} {}", c, 100.0 * **c as f64 / t, name(*a), name(*b));
    }
    println!("-- triples");
    let mut tv: Vec<_> = s.triples.iter().collect();
    tv.sort_by(|a, b| b.1.cmp(a.1));
    for ((a, b, c3), c) in tv.iter().take(top) {
        println!("{:>10} {:>5.1} % {} {} {}", c, 100.0 * **c as f64 / t, name(*a), name(*b), name(*c3));
    }
    // Call sites by opcode kind: dynamic calls, sites, monomorphic share.
    let mut by: HashMap<&str, (u64, u64, u64, u64, u64)> = HashMap::new(); // calls, sites, mono calls, inline, unknown
    for (site, targets) in &s.sites {
        let op = exec_base_op(p.bytecodes[*site]);
        let k = match op {
            INVOKE_STATIC | INVOKE_STATIC_TAIL => "static",
            INVOKE_VIRTUAL | INVOKE_VIRTUAL_WIDE => "virtual",
            INVOKE_VIRTUAL_GET | INVOKE_VIRTUAL_SET => "virtual get/set",
            INVOKE_BLOCK => "block",
            TRY => "try",
            INVOKE_LAMBDA_TAIL | INVOKE_INITIALIZER_TAIL => "lambda/initializer",
            _ => "operator",
        };
        let calls: u64 = targets.values().sum();
        let e = by.entry(k).or_insert((0, 0, 0, 0, 0));
        e.0 += calls;
        e.1 += 1;
        let real: Vec<_> = targets.iter().filter(|(t, _)| **t < usize::MAX - 1).collect();
        if targets.len() == 1 { e.2 += calls; }
        e.3 += targets.get(&usize::MAX).copied().unwrap_or(0);
        e.4 += targets.get(&(usize::MAX - 1)).copied().unwrap_or(0);
        let _ = real;
    }
    println!("-- call sites: kind calls sites calls-at-single-target-sites inline-continuations other");
    let mut bv: Vec<_> = by.iter().collect();
    bv.sort_by(|a, b| (b.1).0.cmp(&(a.1).0));
    for (k, (c, n, mono, inl, unk)) in &bv {
        println!("{:<20} {:>10} {:>6} {:>10} ({:.1} %) {:>10} {:>8}", k, c, n, mono, 100.0 * *mono as f64 / (*c).max(1) as f64, inl, unk);
    }
    println!("-- primitives: calls returned-to-body(failed) module index");
    let mut pr: Vec<_> = s.prims.iter().collect();
    pr.sort_by(|a, b| (b.1).0.cmp(&(a.1).0));
    for ((m, i), (c, f)) in pr.iter().take(top) {
        println!("{:>10} {:>8} {:>3} {:>4}", c, f, m, i);
    }
    println!("-- conditional branches: taken/executed");
    for (b, (c, tk)) in &s.branches {
        println!("{:<26} {:>10} {:>5.1} %", name(*b), c, 100.0 * *tk as f64 / (*c).max(1) as f64);
    }
    println!("-- hottest methods (instructions)");
    let mut mv: Vec<_> = s.methods.iter().collect();
    mv.sort_by(|a, b| b.1.cmp(a.1));
    for (m, c) in mv.iter().take(15) {
        let v = p.methods.at(**m);
        println!("{:>10} {:>5.1} % m{} entry {} size {} kind {}", c, 100.0 * **c as f64 / t, m, v.entry, v.end() - v.entry as usize, v.kind);
    }
}

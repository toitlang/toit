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

//! Runs the structural verifier of format 2 on a dumped program
//! (`tools/spec_dump.toit`).
//!
//! Usage: toit_spec_verify [--trusted] [--time] [--word-bits 32|64] [--quiet] <dump>
//!
//! Prints the verdict, the reasons for a rejection, and the primitives the
//! program references. Exit code 0 when accepted, 1 when rejected, 2 on a
//! load error.

use std::time::Instant;
use toit_spec::interp::loader;
use toit_spec::v2::check;
use toit_spec::v2::infer;

fn main() {
    let mut trusted = false;
    let mut time = false;
    let mut quiet = false;
    let mut dis: Vec<usize> = Vec::new();
    let mut word_bits = 64u8;
    let mut path = None;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--trusted" => trusted = true,
            "--time" => time = true,
            "--quiet" => quiet = true,
            "--dis" => dis.push(it.next().and_then(|v| v.parse().ok()).expect("--dis METHOD")),
            "--word-bits" => word_bits = it.next().and_then(|v| v.parse().ok()).expect("--word-bits 32|64"),
            _ => path = Some(arg),
        }
    }
    let path = path.unwrap_or_else(|| {
        eprintln!("Usage: toit_spec_verify [--trusted] [--time] [--word-bits 32|64] [--quiet] <dump>");
        std::process::exit(2);
    });
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("cannot read {}: {}", path, e);
        std::process::exit(2);
    });
    let t0 = Instant::now();
    let loaded = loader::load(&text, word_bits).unwrap_or_else(|e| {
        println!("rejected (load): {}", e);
        std::process::exit(2);
    });
    if loaded.format != 2 {
        println!("rejected (load): not a format-2 program");
        std::process::exit(2);
    }
    let t_load = t0.elapsed();
    let mut reasons: Vec<String> = Vec::new();
    // The task primitives the machine completes itself must have the
    // numbers the verifier assumes.
    let tn = loaded.names.primitive(0, toit_spec::v2::verifier::X_PRIM_TASK_NEW);
    let tt = loaded.names.primitive(0, toit_spec::v2::verifier::X_PRIM_TASK_TRANSFER);
    if tn != "core::task_new" || tt != "core::task_transfer" {
        reasons.push(format!("task primitive numbering differs: {} {}", tn, tt));
    }
    // The primitive names of the program must be the VM's (the arities the
    // verifier checks come from the VM's table).
    for (i, (module, names)) in loaded.names.primitives.iter().enumerate() {
        let table = toit_spec::v2::prim_arity::PRIM_TABLE;
        let ok = i < table.len() && table[i].0 == module
            && names.len() == table[i].1.len() && names.iter().zip(table[i].1.iter()).all(|(a, (b, _))| a == b);
        if !ok {
            reasons.push(format!("primitive module {} ({}) differs from the VM's primitive table", i, module));
            break;
        }
    }
    if let Err(e) = toit_spec::v2::heap_check::check_heap(&loaded) {
        reasons.push(format!("program heap: {}", e));
    }
    let p = &loaded.program;
    let t1 = Instant::now();
    let inferred = infer::infer(p, loaded.globals.len(), trusted);
    let t_infer = t1.elapsed();
    let t2 = Instant::now();
    let ok = check::verify(p, &inferred.cert, trusted);
    let t_check = t2.elapsed();
    for (m, off, msg) in inferred.errors.iter().take(20) {
        let name = loaded.names.method_at(p.methods[*m].entry)
            .map(|(_, _, n)| n.to_string()).unwrap_or_default();
        reasons.push(format!("method {} ({}) +{}: {}", m, name, off, msg));
    }
    if !ok && inferred.errors.is_empty() {
        if !check::x_tables_ok(p, &inferred.cert) {
            reasons.push("tables rejected".into());
        } else {
            for m in 0..p.methods.len() {
                if !check::x_method_ok(p, &inferred.cert, m, trusted) {
                    let name = loaded.names.method_at(p.methods[m].entry)
                        .map(|(_, _, n)| n.to_string()).unwrap_or_default();
                    reasons.push(format!("method {} ({}) rejected by the checker: {}", m, name, diagnose(p, &inferred.cert, m, trusted)));
                    if reasons.len() > 20 { break; }
                }
            }
        }
    }
    for &m in &dis {
        disassemble(p, &inferred.cert, m);
    }
    let accepted = ok && reasons.is_empty();
    println!("{}", if accepted { "accepted" } else { "rejected" });
    for r in &reasons {
        println!("  {}", r);
    }
    if !quiet {
        let mut prims: Vec<(u8, u16)> = Vec::new();
        for info in &p.methods {
            if info.entry < info.end && p.bytecodes[info.entry] == toit_spec::v2::bytecodes::PRIMITIVE
                && info.entry + 4 <= info.end {
                let module = p.bytecodes[info.entry + 1];
                let index = p.bytecodes[info.entry + 2] as u16 | (p.bytecodes[info.entry + 3] as u16) << 8;
                prims.push((module, index));
            }
        }
        prims.sort();
        prims.dedup();
        println!("primitives ({}):", prims.len());
        for (module, index) in prims {
            println!("  {}", loaded.names.primitive(module, index));
        }
    }
    if time {
        println!("time: load {:.1} ms, infer {:.1} ms ({} rounds), check {:.1} ms, verify total {:.1} ms",
            t_load.as_secs_f64() * 1e3, t_infer.as_secs_f64() * 1e3, inferred.rounds,
            t_check.as_secs_f64() * 1e3, (t_infer + t_check).as_secs_f64() * 1e3);
    }
    std::process::exit(if accepted { 0 } else { 1 });
}


fn disassemble(p: &toit_spec::types::ExecProgram, c: &check::XCert, m: usize) {
    use toit_spec::v2::bytecodes::{OPCODE_LENGTHS2, OPCODE_NAMES2};
    let info = p.methods[m];
    println!("method {}: arity {} kind {} max_height {} selector {} recv {}..{} block params {:?} ctx {:?}", m, info.arity, info.kind,
        info.max_height, info.selector, info.recv_start, info.recv_end, c.block_params.get(m),
        c.contexts.get(m).and_then(|x| x.as_ref()).map(|x| (x.outer, x.slot, x.kinds.clone())));
    let mut bci = info.entry;
    while bci < info.end {
        let op = p.bytecodes[bci];
        let len = OPCODE_LENGTHS2.get(op as usize).copied().unwrap_or(1) as usize;
        let operands: Vec<String> = (1..len).filter(|i| bci + i < p.bytecodes.len()).map(|i| p.bytecodes[bci + i].to_string()).collect();
        let off = bci - info.entry;
        let map = c.maps.get(m).and_then(|v| v.get(off)).and_then(|x| x.as_ref());
        let extra = if op == 53 || op == 54 {
            let d = p.bytecodes[bci + 1] as usize | (p.bytecodes[bci + 2] as usize) << 8;
            format!(" -> {}", p.dispatch.get(d).copied().unwrap_or(-2))
        } else { String::new() };
        println!("  {:4} {:24} {:16}{} {:?}", off, OPCODE_NAMES2.get(op as usize).copied().unwrap_or("?"), operands.join(" "), extra, map);
        bci += len;
    }
}

fn diagnose(p: &toit_spec::types::ExecProgram, c: &check::XCert, m: usize, trusted: bool) -> String {
    let info = p.methods[m];
    let e = check::x_entry_kinds(p, c, m);
    match c.maps.get(m).and_then(|v| v.get(0)).and_then(|x| x.as_ref()) {
        Some(k) if *k == e => {}
        k => return format!("entry kinds {:?}, map {:?}", e, k),
    }
    for (off, k) in c.maps[m].iter().enumerate() {
        let k = match k { Some(k) => k, None => continue };
        if check::x_instr_ok(p, c, m, off, k, trusted) { continue; }
        let op = p.bytecodes[info.entry + off];
        let name = toit_spec::v2::bytecodes::OPCODE_NAMES2.get(op as usize).copied().unwrap_or("?");
        let what = if !check::x_wf_kinds(p, c, m as i64, k) { "wf_kinds" }
            else if !check::x_ctx_ok(p, c, m as i64, k) { "ctx_ok" }
            else if !check::x_shape_ok(p, c, m, k) { "shape" }
            else if k.len() > info.arity as usize + info.max_height as usize { "max_height" }
            else { "rule or successor" };
        let ctxs: Vec<String> = k.iter().filter_map(|x| match x {
            check::XKind::Method(t) => c.contexts.get(*t as usize).and_then(|y| y.as_ref()).map(|y| format!("ctx({})=({},{},{:?})", t, y.outer, y.slot, y.kinds)),
            _ => None }).collect();
        return format!("+{} {} {} kinds {:?} {}", off, name, what, k, ctxs.join(" "));
    }
    "?".into()
}

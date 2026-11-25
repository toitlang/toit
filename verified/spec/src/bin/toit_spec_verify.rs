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
use toit_spec::v2::check::MapOracle;
use toit_spec::v2::vprog::{self, VProgram};

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
    let ep = &loaded.program;
    let h = vprog::max_height_of(ep);
    let methods = vprog::vmethods_of(ep, h).unwrap_or_else(|| {
        println!("rejected (load): methods with different max heights or bounds past 32 bits");
        std::process::exit(2);
    });
    let p = &vprog::vprogram_of(ep, methods, h);
    if let Err(e) = toit_spec::v2::heap_check::check_heap(p, &loaded.heap) {
        reasons.push(format!("program heap: {}", e));
    }
    let prim_arity: Vec<Vec<u8>> = toit_spec::v2::prim_arity::PRIM_TABLE.iter()
        .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect();
    let t1 = Instant::now();
    let global = infer::infer_global(p, loaded.globals.len() as u64, prim_arity.clone(), trusted);
    let t_infer = t1.elapsed();
    let t2 = Instant::now();
    let (ok, at) = infer::check(p, &global, trusted);
    let t_check = t2.elapsed();
    // The shipped certificate (format/18-shipped-certificate.md): the
    // inference's certificate as the toolchain ships it, checked alone by
    // the proven checker of shipped certificates, as a device checks it.
    let t3 = Instant::now();
    let shipped = toit_spec::v2::encode::encode(p, &global, trusted).map(|(bytes, sizes)| {
        let (ok, at) = infer::ok(toit_spec::v2::cert::verify_shipped(p, &bytes, loaded.globals.len() as u64, &prim_arity, trusted));
        (ok, at, sizes)
    });
    let t_shipped = t3.elapsed();
    match &shipped {
        Err(e) if ok => reasons.push(format!("no shipped certificate: {}", e)),
        Ok((false, at, _)) if ok => reasons.push(format!("the shipped certificate is rejected (method {})", at)),
        _ => {}
    }
    for (m, off, msg) in global.errors.iter().take(20) {
        let name = p.methods.get(*m).and_then(|i| loaded.names.method_at(i.entry as usize))
            .map(|(_, _, n)| n.to_string()).unwrap_or_default();
        reasons.push(format!("method {} ({}) +{}: {}", m, name, off, msg));
    }
    if !ok && global.errors.is_empty() {
        match at {
            None => reasons.push("tables rejected".into()),
            Some(m) => {
                let name = p.methods.get(m).and_then(|i| loaded.names.method_at(i.entry as usize))
                    .map(|(_, _, n)| n.to_string()).unwrap_or_default();
                let (off, why) = infer::diagnose(p, &global, m, trusted);
                reasons.push(format!("method {} ({}) rejected by the checker at {:?}: {}", m, name, off, why));
            }
        }
    }
    for &m in &dis {
        disassemble(p, &global, m, trusted);
    }
    // The loader's contract (verified check, `v2::heap_check::x_loaded_ok`)
    // for the certificate the verdict uses.
    let loaded_ok = ok && toit_spec::v2::heap_check::x_loaded_ok(p, global.g.global_count, &loaded.heap, &loaded.globals);
    if ok && !loaded_ok && reasons.is_empty() {
        reasons.push("program heap or globals violate the loader's contract".into());
    }
    let accepted = ok && loaded_ok && reasons.is_empty();
    println!("{}", if accepted { "accepted" } else { "rejected" });
    for r in &reasons {
        println!("  {}", r);
    }
    if !quiet {
        let mut prims: Vec<(u8, u16)> = Vec::new();
        for info in (0..p.methods.len()).map(|m| p.methods.at(m)) {
            let (entry, end) = (info.entry as usize, info.end());
            if entry < end && p.bytecodes[entry] == toit_spec::v2::bytecodes::PRIMITIVE
                && entry + 4 <= end {
                let module = p.bytecodes[entry + 1];
                let index = p.bytecodes[entry + 2] as u16 | (p.bytecodes[entry + 3] as u16) << 8;
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
            t_load.as_secs_f64() * 1e3, t_infer.as_secs_f64() * 1e3, global.rounds,
            t_check.as_secs_f64() * 1e3, (t_infer + t_check).as_secs_f64() * 1e3);
        if let Ok((_, _, sizes)) = &shipped {
            println!("shipped: certificate {} bytes (maps {} bytes, {} shipped maps, {} recomputed), check {:.1} ms",
                sizes.total, sizes.maps, sizes.shipped_maps, sizes.implicit_maps, t_shipped.as_secs_f64() * 1e3);
        }
    }
    std::process::exit(if accepted { 0 } else { 1 });
}


fn disassemble(p: &VProgram, global: &infer::Global, m: usize, trusted: bool) {
    use toit_spec::v2::bytecodes::{OPCODE_LENGTHS2, OPCODE_NAMES2};
    let Some(info) = p.methods.get(m) else { return };
    let g = &global.g;
    let bp = if info.kind == 3 { 0 } else { g.word(m) };
    let ctx = if info.kind == 3 { g.ctx(m).map(|(o, s, top)| (o, s, g.list(top))) } else { None };
    println!("method {}: arity {} kind {} max_height {} selector {} recv {}..{} block params {:#x} ctx {:?}", m, info.arity, info.kind,
        p.max_height, info.selector, info.recv_start, info.recv_end, bp, ctx);
    let gv = g.view(p.methods);
    let maps = infer::ok(infer::Oracle::new(p, global, trusted).method_maps(p, &gv, m));
    let (entry, end) = (info.entry as usize, info.end());
    let mut bci = entry;
    while bci < end {
        let op = p.bytecodes[bci];
        let len = OPCODE_LENGTHS2.get(op as usize).copied().unwrap_or(1) as usize;
        let operands: Vec<String> = (1..len).filter(|i| bci + i < p.bytecodes.len()).map(|i| p.bytecodes[bci + i].to_string()).collect();
        let off = bci - entry;
        let map = (off < maps.idx.len()).then(|| maps.idx.at(off)).filter(|t| *t != check::NO_MAP).and_then(|t| check::x_chain(&maps.nodes, t).ok());
        let extra = if op == 53 || op == 54 {
            let d = p.bytecodes[bci + 1] as usize | (p.bytecodes[bci + 2] as usize) << 8;
            format!(" -> {}", p.dispatch.get(d).copied().unwrap_or(-2))
        } else { String::new() };
        println!("  {:4} {:24} {:16}{} {:?}", off, OPCODE_NAMES2.get(op as usize).copied().unwrap_or("?"), operands.join(" "), extra, map);
        bci += len;
    }
}

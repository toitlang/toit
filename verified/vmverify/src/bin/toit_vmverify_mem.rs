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

//! Memory and time of the verifier on dumped programs
//! (tools/spec_dump.toit), measured with vmverify's counting allocator.
//!
//! The program is loaded with the reference loader first (in the VM the
//! tables are the VM's own memory, borrowed); the measurement covers what
//! the verification itself allocates: the heap check, the global phase of
//! the inference, its encoded certificate checked by the checker of shipped
//! certificates (largest-maps: 0, the maps are encoded),
//! and `x_loaded_ok`. Prints one line per program.
//!
//! Usage: toit_vmverify_mem [--trusted] [--runs N] <dump>...

use std::time::Instant;
use toit_spec::interp::loader;
// (No oracle any more: the inference's maps reach the checker as the
// encoded certificate.)
use toit_spec::v2::{cert, encode, heap_check, infer, vprog};
use toit_vmverify::counting;

fn main() {
    let mut trusted = false;
    let mut runs = 1;
    let mut paths = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--trusted" => trusted = true,
            "--runs" => runs = it.next().and_then(|v| v.parse().ok()).expect("--runs N"),
            _ => paths.push(a),
        }
    }
    println!("program bytecodes methods largest-method(bytes) global(bytes) largest-maps(bytes) peak(bytes) infer(ms) check(ms) total(ms) verdict cert(bytes) cert-maps(bytes) shipped-maps implicit-maps shipped-peak(bytes) shipped(ms) shipped-verdict");
    for path in paths {
        let text = std::fs::read_to_string(&path).expect("read");
        let loaded = loader::load(&text, 64).expect("load");
        let e = &loaded.program;
        let h = vprog::max_height_of(e);
        let methods = vprog::vmethods_of(e, h).expect("methods");
        let p = &vprog::vprogram_of(e, methods, h);
        let prim_arity: Vec<Vec<u8>> = toit_spec::v2::prim_arity::PRIM_TABLE.iter()
            .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect();
        let largest = (0..p.methods.len()).map(|i| { let m = p.methods.at(i); m.end() - m.entry as usize }).max().unwrap_or(0);
        let mut best: Option<(f64, f64, f64)> = None;
        let mut line = String::new();
        for _ in 0..runs {
            let pa = prim_arity.clone();
            let base = counting::start_peak();
            let t0 = Instant::now();
            let heap_ok = heap_check::check_heap(p, &loaded.heap).is_ok();
            if std::env::var("MEM_DEBUG").is_ok() { eprintln!("heap check peak {}", counting::peak_since(base)); }
            let global = infer::infer_global(p, loaded.globals.len() as u64, pa, trusted);
            let global_bytes = counting::current().saturating_sub(base);
            let peak1 = counting::peak_since(base);
            let base2 = counting::start_peak();
            let t1 = Instant::now();
            let te = Instant::now();
            let ok = match encode::encode(p, &global, trusted) {
                Ok((bytes, _)) => infer::ok(cert::verify_shipped(p, &bytes, global.g.global_count, &global.g.prim_arity, trusted)).0,
                Err(_) => false,
            };
            let encode_ns = te.elapsed().as_nanos() as u64;
            let loaded_ok = heap_check::x_loaded_ok(p, global.g.global_count, &loaded.heap, &loaded.globals);
            let t2 = Instant::now();
            let peak2 = counting::peak_since(base2);
            let peak = peak1.max(base2 - base + peak2);
            if std::env::var("MEM_DEBUG").is_ok() {
                let g = &global.g;
                eprintln!("phase 1 peak {} global {} phase 2 peak above global {}; global phase {:.1} ms, encode and check {:.1} ms", peak1, global_bytes, peak2, (t1 - t0).as_secs_f64() * 1e3, encode_ns as f64 / 1e6);
                eprintln!("  mw {} crec {} sel {} pins {} nodes {} seeds {} rounds {} errors {:?}", g.mw.len(), g.crec.len(),
                    g.sel.len(), g.pins.len(), g.nodes.len(), global.seeds.len(), global.rounds, global.errors);
            }
            let infer_ms = (t1 - t0).as_secs_f64() * 1e3;
            let check_ms = (t2 - t1).as_secs_f64() * 1e3;
            let total = (t2 - t0).as_secs_f64() * 1e3;
            if best.map_or(true, |b| total < b.2) {
                best = Some((infer_ms, check_ms, total));
                line = format!("{} {} {} {} {} {} {} {:.1} {:.1} {:.1} {}",
                    std::path::Path::new(&path).file_name().unwrap().to_string_lossy(),
                    p.bytecodes.len(), p.methods.len(), largest, global_bytes, 0, peak,
                    infer_ms, check_ms, total,
                    if ok && loaded_ok && heap_ok { "accepted" } else { "rejected" });
            }
        }
        // The shipped certificate: produced by the inference, checked alone.
        let global = infer::infer_global(p, loaded.globals.len() as u64, prim_arity.clone(), trusted);
        let shipped = match encode::encode(p, &global, trusted) {
            Err(e) => format!("- - - - - - encode-failed({})", e),
            Ok((bytes, sizes)) => {
                if std::env::var("MEM_DEBUG").is_ok() { eprintln!("certificate sizes: {:?}", sizes); }
                drop(global);
                let mut best: Option<(f64, usize, bool)> = None;
                for _ in 0..runs {
                    let base = counting::start_peak();
                    let t0 = Instant::now();
                    let (ok, _, _) = infer::ok(cert::verify_shipped(p, &bytes, loaded.globals.len() as u64, &prim_arity, trusted));
                    let ms = t0.elapsed().as_secs_f64() * 1e3;
                    let peak = counting::peak_since(base);
                    if best.map_or(true, |b| ms < b.0) { best = Some((ms, peak, ok)); }
                }
                let (ms, peak, ok) = best.unwrap();
                format!("{} {} {} {} {} {:.1} {}", sizes.total, sizes.maps, sizes.shipped_maps, sizes.implicit_maps, peak, ms,
                    if ok { "accepted" } else { "rejected" })
            }
        };
        println!("{} {}", line, shipped);
    }
}

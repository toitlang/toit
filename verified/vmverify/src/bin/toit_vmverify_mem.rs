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
//! the inference, the per-method maps the checker asks for, the checker,
//! and `x_loaded_ok`. Prints one line per program.
//!
//! Usage: toit_vmverify_mem [--trusted] [--runs N] <dump>...

use std::time::Instant;
use toit_spec::interp::loader;
use toit_spec::v2::check::{self, MapOracle, XMaps};
use toit_spec::v2::{heap_check, infer, vprog};
use toit_vmverify::counting;

/// The oracle, recording the largest maps it handed out.
struct Sized<'a> {
    inner: infer::Oracle<'a>,
    max_maps: usize,
    max_method: usize,
    ns: u64,
}

impl<'a> MapOracle for Sized<'a> {
    fn method_maps(&mut self, m: usize) -> XMaps {
        let t = Instant::now();
        let r = self.inner.method_maps(m);
        self.ns += t.elapsed().as_nanos() as u64;
        let bytes = r.idx.capacity() * 4 + r.nodes.capacity() * std::mem::size_of::<check::XNode>();
        if bytes > self.max_maps {
            self.max_maps = bytes;
            self.max_method = m;
        }
        r
    }
}

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
    println!("program bytecodes methods largest-method(bytes) global(bytes) largest-maps(bytes) peak(bytes) infer(ms) check(ms) total(ms) verdict");
    for path in paths {
        let text = std::fs::read_to_string(&path).expect("read");
        let loaded = loader::load(&text, 64).expect("load");
        let e = &loaded.program;
        let h = vprog::max_height_of(e);
        let methods = vprog::vmethods_of(e, h).expect("methods");
        let p = &vprog::vprogram_of(e, &methods, h);
        let prim_arity: Vec<Vec<u8>> = toit_spec::v2::prim_arity::PRIM_TABLE.iter()
            .map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect();
        let largest = p.methods.iter().map(|m| m.end.saturating_sub(m.entry)).max().unwrap_or(0);
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
            let mut o = Sized { inner: infer::Oracle::new(p, &global, trusted), max_maps: 0, max_method: 0, ns: 0 };
            let (ok, _) = check::verify(p, &global.g, &mut o, trusted);
            let loaded_ok = heap_check::x_loaded_ok(p, global.g.global_count, &loaded.heap, &loaded.globals);
            let t2 = Instant::now();
            let peak2 = counting::peak_since(base2);
            let peak = peak1.max(base2 - base + peak2);
            if std::env::var("MEM_DEBUG").is_ok() {
                let g = &global.g;
                eprintln!("phase 1 peak {} global {} phase 2 peak above global {}", peak1, global_bytes, peak2);
                eprintln!("  sel_rep {} ctxs {} ctx kinds {} pins {} seeds {} rounds {} errors {:?}", g.sel_rep.len(), g.ctxs.len(),
                    g.ctxs.iter().map(|c| c.kinds.len()).sum::<usize>(), g.pins.len(), global.seeds.len(), global.rounds, global.errors);
            }
            let infer_ms = (t1 - t0).as_secs_f64() * 1e3 + o.ns as f64 / 1e6;
            let check_ms = (t2 - t1).as_secs_f64() * 1e3 - o.ns as f64 / 1e6;
            let total = (t2 - t0).as_secs_f64() * 1e3;
            if best.map_or(true, |b| total < b.2) {
                best = Some((infer_ms, check_ms, total));
                line = format!("{} {} {} {} {} {} {} {:.1} {:.1} {:.1} {}",
                    std::path::Path::new(&path).file_name().unwrap().to_string_lossy(),
                    p.bytecodes.len(), p.methods.len(), largest, global_bytes, o.max_maps, peak,
                    infer_ms, check_ms, total,
                    if ok && loaded_ok && heap_ok { "accepted" } else { "rejected" });
            }
        }
        println!("{}", line);
    }
}

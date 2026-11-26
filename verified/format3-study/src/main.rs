// Copyright (C) 2026 Toit contributors.

//! f3study: the format-3 study's host tool (README.md).
//!
//!   f3study static TABLES...          static statistics
//!   f3study trace TABLES [TOP]        dynamic statistics of a -Xtrace stream on stdin
//!   f3study cert TABLES...            certificate sizes, maps, heights
//!   f3study verify MODE RUNS TABLES   one checker (shipped | fused | fused-inc), RUNS times;
//!                                     callgrind: --toggle-collect='*measure_*'
//!   f3study cross TABLES MUTANTS      the prototype against verify_shipped on mutated certificates

mod certstats;
mod fused;
mod load;
mod stats;
mod trace;

use std::time::Instant;
use toit_spec::v2::cert;
use toit_spec::v2::encode;
use toit_spec::v2::vprog::VProgram;
use toit_vmverify::counting;

#[inline(never)]
fn measure_shipped(p: &VProgram, c: &[u8], gc: u64, pa: &[Vec<u8>], t: bool) -> bool {
    matches!(cert::verify_shipped(p, c, gc, pa, t), Ok((true, _)))
}

#[inline(never)]
fn measure_fused(p: &VProgram, c: &[u8], gc: u64, pa: &[Vec<u8>], t: bool, inc: bool) -> (bool, fused::FStats) {
    measure_fused_opt(p, c, gc, pa, t, inc, false)
}

#[inline(never)]
fn measure_fused_opt(p: &VProgram, c: &[u8], gc: u64, pa: &[Vec<u8>], t: bool, inc: bool, opt: bool) -> (bool, fused::FStats) {
    fused::verify(p, c, gc, pa, t, inc, opt)
}

#[inline(never)]
fn measure_convert(l: &load::Loaded) -> toit_vmverify::from_vm::Converted<'static> {
    l.reconvert()
}

#[inline(never)]
fn measure_heap(c: &mut toit_vmverify::from_vm::Converted<'static>, trusted: bool) -> bool {
    let gc = c.globals.len() as u64;
    let globals = std::mem::take(&mut c.globals);
    let (mut p, objects) = c.split();
    p.unchecked = trusted;
    let (ok, _, _) = toit_spec::v2::heap_check::x_loaded_ok_stream(&p, objects, gc, &globals);
    ok && objects.complete()
}

fn certificate(l: &load::Loaded, p: &VProgram) -> Vec<u8> {
    encode::certify(p, l.global_count, l.prim_arity.clone(), l.trusted).expect("certify").0
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() { eprintln!("usage: see src/main.rs"); std::process::exit(2); }
    match args[0].as_str() {
        "static" => for path in &args[1..] {
            let l = load::Loaded::load(path);
            stats::run(path, &l.program());
        },
        "trace" => {
            let l = load::Loaded::load(&args[1]);
            let top = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(40);
            trace::run(&l.program(), top);
        }
        "cert" => for path in &args[1..] {
            let l = load::Loaded::load(path);
            let p = l.program();
            certstats::run(path, &p, l.global_count, &l.prim_arity, l.trusted);
        },
        "verify" => {
            let mode = args[1].as_str();
            let runs: usize = args[2].parse().expect("RUNS");
            for path in &args[3..] {
                let l = load::Loaded::load(path);
                let p = l.program();
                let c = certificate(&l, &p);
                let a0 = counting::allocations();
                let base = counting::start_peak();
                let mut ok = false;
                let mut st = fused::FStats::default();
                let t0 = Instant::now();
                for _ in 0..runs {
                    match mode {
                        "shipped" => ok = measure_shipped(&p, &c, l.global_count, &l.prim_arity, l.trusted),
                        "fused" => { let r = measure_fused(&p, &c, l.global_count, &l.prim_arity, l.trusted, false); ok = r.0; st = r.1; }
                        "fused-inc" => { let r = measure_fused(&p, &c, l.global_count, &l.prim_arity, l.trusted, true); ok = r.0; st = r.1; }
                        "fused-opt" => { let r = measure_fused_opt(&p, &c, l.global_count, &l.prim_arity, l.trusted, true, true); ok = r.0; st = r.1; }
                        _ => panic!("mode"),
                    }
                }
                let dt = t0.elapsed().as_secs_f64() * 1e3 / runs as f64;
                let allocs = (counting::allocations() - a0) / runs;
                let peak = counting::peak_since(base);
                println!("{} {} ok {} bytecodes {} cert {} B {:.3} ms/run allocations/run {} peak {} B stats {:?}",
                    mode, path, ok, p.bytecodes.len(), c.len(), dt, allocs, peak, st);
            }
        }
        "cross" => {
            let l = load::Loaded::load(&args[1]);
            let p = l.program();
            let mutants: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(200);
            let c = certificate(&l, &p);
            let base = measure_shipped(&p, &c, l.global_count, &l.prim_arity, l.trusted);
            let f = measure_fused(&p, &c, l.global_count, &l.prim_arity, l.trusted, false).0;
            let fi = measure_fused(&p, &c, l.global_count, &l.prim_arity, l.trusted, true).0;
            println!("unmutated: shipped {} fused {} fused-inc {}", base, f, fi);
            // Deterministic mutations of the certificate (after the header).
            let mut seed: u64 = 0x9e3779b97f4a7c15;
            let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; seed };
            let (mut agree, mut differ, mut accepted) = (0, 0, 0);
            for i in 0..mutants {
                let mut m = c.clone();
                let nmut = 1 + (next() % 3) as usize;
                for _ in 0..nmut {
                    let at = 60 + (next() as usize) % (m.len() - 60);
                    let r = next();
                    match r % 3 {
                        0 => m[at] ^= 1 << (r >> 8) % 8,
                        1 => m[at] = m[at].wrapping_add(1),
                        _ => m[at] = m[at].wrapping_sub(1),
                    }
                }
                let a = measure_shipped(&p, &m, l.global_count, &l.prim_arity, l.trusted);
                let b = measure_fused(&p, &m, l.global_count, &l.prim_arity, l.trusted, false).0;
                let b2 = measure_fused(&p, &m, l.global_count, &l.prim_arity, l.trusted, true).0;
                let b3 = measure_fused_opt(&p, &m, l.global_count, &l.prim_arity, l.trusted, true, true).0;
                if a == b && a == b2 && a == b3 { agree += 1; } else {
                    differ += 1;
                    println!("mutant {}: shipped {} fused {} fused-inc {}", i, a, b, b2);
                }
                if a { accepted += 1; }
            }
            println!("mutants {}: agree {} differ {} (accepted by verify_shipped {})", mutants, agree, differ, accepted);
            // Mutated method bodies (one byte), the original certificate.
            let (mut agree, mut differ, mut accepted) = (0, 0, 0);
            for i in 0..mutants {
                let mut code = p.bytecodes.to_vec();
                let mi = (next() as usize) % p.methods.len();
                let v = p.methods.at(mi);
                let size = v.end() - v.entry as usize;
                if size == 0 { continue; }
                let at = v.entry as usize + (next() as usize) % size;
                let r = next();
                match r % 3 {
                    0 => code[at] ^= 1 << (r >> 8) % 8,
                    1 => code[at] = code[at].wrapping_add(1),
                    _ => code[at] = code[at].wrapping_sub(1),
                }
                let mut q = l.program();
                q.bytecodes = &code;
                let a = measure_shipped(&q, &c, l.global_count, &l.prim_arity, l.trusted);
                let b = measure_fused(&q, &c, l.global_count, &l.prim_arity, l.trusted, false).0;
                let b2 = measure_fused(&q, &c, l.global_count, &l.prim_arity, l.trusted, true).0;
                let b3 = measure_fused_opt(&q, &c, l.global_count, &l.prim_arity, l.trusted, true, true).0;
                if a == b && a == b2 && a == b3 { agree += 1; } else {
                    differ += 1;
                    println!("code mutant {} (method {} byte {} entry {} {} -> {}): shipped {} fused {} fused-inc {}",
                        i, mi, at, v.entry, p.bytecodes[at], code[at], a, b, b2);
                }
                if a { accepted += 1; }
            }
            println!("code mutants {}: agree {} differ {} (accepted by verify_shipped {})", mutants, agree, differ, accepted);
        }
        "phases" => {
            // phases TABLES: the loader conversion and the heap check
            // (callgrind: --toggle-collect='*measure_convert*' etc.).
            let l = load::Loaded::load(&args[1]);
            let a0 = counting::allocations();
            let mut c = measure_convert(&l);
            let a1 = counting::allocations();
            let ok = measure_heap(&mut c, l.trusted);
            let a2 = counting::allocations();
            println!("convert allocations {} heap ok {} allocations {}", a1 - a0, ok, a2 - a1);
        }
        "probe" => {
            // probe TABLES BCI VALUE: one code mutation, the verdicts and
            // the method verify_shipped stopped at.
            let l = load::Loaded::load(&args[1]);
            let p = l.program();
            let at: usize = args[2].parse().unwrap();
            let val: u8 = args[3].parse().unwrap();
            let c = certificate(&l, &p);
            let mut code = p.bytecodes.to_vec();
            code[at] = val;
            let mut q = l.program();
            q.bytecodes = &code;
            let r = cert::verify_shipped(&q, &c, l.global_count, &l.prim_arity, l.trusted);
            let (b, st) = measure_fused(&q, &c, l.global_count, &l.prim_arity, l.trusted, false);
            println!("shipped {:?} fused {} {:?}", r.ok(), b, st);
        }
        _ => { eprintln!("unknown command"); std::process::exit(2); }
    }
}

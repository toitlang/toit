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

//! certdiff: tests and measures the checker of shipped certificates on
//! programs saved as verifier input tables (`toit.run --verify
//! --emit-canonical=X.tables`).
//!
//!   certdiff verify MODE RUNS TABLES...  one checker, RUNS times: instructions
//!                                        (callgrind: --toggle-collect='*measure_*'),
//!                                        allocations, peak heap
//!   certdiff cross TABLES N [SEED]       N certificate mutants and N method-body
//!                                        mutants: the single-pass checker against
//!                                        the two-pass checker (verdicts must agree)
//!
//! MODE: `walk` (cert::verify_shipped, the single-pass checker) or `two-pass`
//! (cert::verify_shipped_two_pass, the reference while it exists).

mod load;

use std::time::Instant;
use toit_spec::v2::cert;
use toit_spec::v2::encode;
use toit_spec::v2::vprog::VProgram;
use toit_vmverify::counting;

/// The verdict: Some(accepted), None for out of memory.
type V = Option<bool>;

#[inline(never)]
fn measure_walk(p: &VProgram, c: &[u8], gc: u64, pa: &[Vec<u8>], t: bool) -> V {
    cert::verify_shipped(p, c, gc, pa, t).ok().map(|r| r.0)
}

#[inline(never)]
fn measure_two_pass(p: &VProgram, c: &[u8], gc: u64, pa: &[Vec<u8>], t: bool) -> V {
    cert::verify_shipped_two_pass(p, c, gc, pa, t).ok().map(|r| r.0)
}

fn certificate(l: &load::Loaded, p: &VProgram) -> Vec<u8> {
    encode::certify(p, l.global_count, l.prim_arity.clone(), l.trusted).expect("certify").0
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn mutate_byte(b: &mut u8, r: u64) {
    match r % 3 {
        0 => *b ^= 1 << ((r >> 8) % 8),
        1 => *b = b.wrapping_add(1),
        _ => *b = b.wrapping_sub(1),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: see src/main.rs");
        std::process::exit(2);
    }
    match args[0].as_str() {
        "verify" => {
            let mode = args[1].as_str();
            let runs: usize = args[2].parse().expect("RUNS");
            for path in &args[3..] {
                let l = load::Loaded::load(path);
                let p = l.program();
                let c = certificate(&l, &p);
                let a0 = counting::allocations();
                let base = counting::start_peak();
                let mut ok = None;
                let t0 = Instant::now();
                for _ in 0..runs {
                    ok = match mode {
                        "walk" => measure_walk(&p, &c, l.global_count, &l.prim_arity, l.trusted),
                        "two-pass" => measure_two_pass(&p, &c, l.global_count, &l.prim_arity, l.trusted),
                        _ => panic!("mode"),
                    };
                }
                let dt = t0.elapsed().as_secs_f64() * 1e3 / runs as f64;
                let allocs = (counting::allocations() - a0) / runs;
                let peak = counting::peak_since(base);
                println!("{} {} ok {:?} bytecodes {} cert {} B {:.3} ms/run allocations/run {} peak {} B",
                    mode, path, ok, p.bytecodes.len(), c.len(), dt, allocs, peak);
            }
        }
        "cross" => {
            let l = load::Loaded::load(&args[1]);
            let p = l.program();
            let mutants: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(200);
            let seed: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0x9e3779b97f4a7c15);
            let c = certificate(&l, &p);
            let a = measure_walk(&p, &c, l.global_count, &l.prim_arity, l.trusted);
            let b = measure_two_pass(&p, &c, l.global_count, &l.prim_arity, l.trusted);
            println!("unmutated: walk {:?} two-pass {:?}", a, b);
            let mut rng = Rng(seed | 1);
            let header = cert::CERT_HEADER_SIZE;
            let (mut agree, mut differ, mut accepted) = (0, 0, 0);
            for i in 0..mutants {
                let mut m = c.clone();
                let nmut = 1 + (rng.next() % 3) as usize;
                for _ in 0..nmut {
                    let at = header + (rng.next() as usize) % (m.len() - header);
                    let r = rng.next();
                    mutate_byte(&mut m[at], r);
                }
                let a = measure_walk(&p, &m, l.global_count, &l.prim_arity, l.trusted);
                let b = measure_two_pass(&p, &m, l.global_count, &l.prim_arity, l.trusted);
                if a == b { agree += 1; } else {
                    differ += 1;
                    println!("certificate mutant {}: walk {:?} two-pass {:?}", i, a, b);
                }
                if a == Some(true) { accepted += 1; }
            }
            println!("certificate mutants {}: agree {} differ {} (accepted {})", mutants, agree, differ, accepted);
            let (mut agree, mut differ, mut accepted) = (0, 0, 0);
            for i in 0..mutants {
                let mut code = p.bytecodes.to_vec();
                let mi = (rng.next() as usize) % p.methods.len();
                let v = p.methods.at(mi);
                let size = v.end() - v.entry as usize;
                if size == 0 { continue; }
                let at = v.entry as usize + (rng.next() as usize) % size;
                let r = rng.next();
                mutate_byte(&mut code[at], r);
                let mut q = l.program();
                q.bytecodes = &code;
                let a = measure_walk(&q, &c, l.global_count, &l.prim_arity, l.trusted);
                let b = measure_two_pass(&q, &c, l.global_count, &l.prim_arity, l.trusted);
                if a == b { agree += 1; } else {
                    differ += 1;
                    println!("code mutant {} (method {} byte {} entry {} {} -> {}): walk {:?} two-pass {:?}",
                        i, mi, at, v.entry, p.bytecodes[at], code[at], a, b);
                }
                if a == Some(true) { accepted += 1; }
            }
            println!("code mutants {}: agree {} differ {} (accepted {})", mutants, agree, differ, accepted);
        }
        _ => {
            eprintln!("unknown command");
            std::process::exit(2);
        }
    }
}

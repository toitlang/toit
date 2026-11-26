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
//!                                        mutants: verdicts (the two-pass checker
//!                                        they were compared with until commit
//!                                        a45b3ded8 is gone; "differ" counts out of
//!                                        memory now)
//!
//!   certdiff policy TABLES              every PRIMITIVE retargeted: to denied or
//!                                        absent primitives of the policy table of
//!                                        TABLES (accepted: completed by the core
//!                                        without a call), to allowed ones of
//!                                        another arity and past the table (rejected)
//!   certdiff header TABLES              certificate headers of another version,
//!                                        policy or method count: rejected, with
//!                                        the header error naming why
//!
//! MODE: `walk` (cert::verify_shipped, the single-pass checker).

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

fn certificate(l: &load::Loaded, p: &VProgram) -> Vec<u8> {
    encode::certify(p, l.global_count, l.prim_arity.clone(), l.trusted).expect("certify").0
}

fn header_error_text(code: u32) -> &'static str {
    toit_vmverify::verify::header_error_text(code)
}

/// The full primitive table (every primitive allowed), from src/primitive.h.
fn full_table() -> Vec<Vec<u8>> {
    toit_spec::v2::prim_arity::PRIM_TABLE.iter().map(|(_, prims)| prims.iter().map(|(_, a)| *a).collect()).collect()
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
            println!("unmutated: walk {:?}", a);
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
                if a.is_none() { differ += 1; println!("certificate mutant {}: out of memory", i); } else { agree += 1; }
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
                if a.is_none() { differ += 1; println!("code mutant {}: out of memory", i); } else { agree += 1; }
                if a == Some(true) { accepted += 1; }
            }
            println!("code mutants {}: agree {} differ {} (accepted {})", mutants, agree, differ, accepted);
        }
        "policy" => {
            // The primitive call sites of the program, retargeted: to every
            // denied or absent primitive of the policy (accepted: the core
            // completes such a PRIMITIVE itself, with PERMISSION_DENIED or
            // PRIMITIVE_LOOKUP_FAILED, and calls nothing), to allowed
            // primitives of another arity and to indices past a module's
            // table (both rejected). The certificate is the unmutated
            // program's (a PRIMITIVE's maps do not depend on its target).
            let l = load::Loaded::load(&args[1]);
            let p = l.program();
            let policy = l.prim_arity.clone();
            use toit_spec::v2::verifier::{X_PRIM_ABSENT, X_PRIM_DENIED};
            let c = certificate(&l, &p);
            println!("unmutated: {:?}", measure_walk(&p, &c, l.global_count, &policy, l.trusted));
            let (mut sites, mut denied_ok, mut denied_bad, mut arity_ok, mut arity_bad, mut range_ok, mut range_bad) = (0, 0, 0, 0, 0, 0, 0);
            let mut run = |at: usize, dm: usize, di: usize| -> V {
                let mut code = p.bytecodes.to_vec();
                code[at + 1] = dm as u8;
                code[at + 2] = di as u8;
                code[at + 3] = (di >> 8) as u8;
                let mut q = l.program();
                q.bytecodes = &code;
                measure_walk(&q, &c, l.global_count, &policy, l.trusted)
            };
            for mi in 0..p.methods.len() {
                let v = p.methods.at(mi);
                let at = v.entry as usize;
                if at + 4 > v.end() || p.bytecodes[at] != toit_spec::v2::bytecodes::PRIMITIVE { continue; }
                let (module, index) = (p.bytecodes[at + 1] as usize, p.bytecodes[at + 2] as usize | (p.bytecodes[at + 3] as usize) << 8);
                let arity = v.arity;
                sites += 1;
                // Never the task primitives (core 115, 116), whose own rules
                // apply on top.
                let task = |dm: usize, di: usize| dm == 0 && (di == 115 || di == 116);
                for (dm, row) in policy.iter().enumerate() {
                    let (mut nd, mut na) = (0, 0);
                    for (di, a) in row.iter().enumerate() {
                        if task(dm, di) || (dm, di) == (module, index) { continue; }
                        if (*a == X_PRIM_DENIED || *a == X_PRIM_ABSENT) && nd < 2 {
                            nd += 1;
                            match run(at, dm, di) {
                                Some(true) => denied_ok += 1,
                                r => { denied_bad += 1; println!("DENIED NOT ACCEPTED: method {} -> ({}, {}): {:?}", mi, dm, di, r); }
                            }
                        } else if *a != X_PRIM_DENIED && *a != X_PRIM_ABSENT && *a != arity && na < 2 {
                            na += 1;
                            match run(at, dm, di) {
                                Some(false) => arity_ok += 1,
                                r => { arity_bad += 1; println!("WRONG ARITY NOT REJECTED: method {} -> ({}, {}): {:?}", mi, dm, di, r); }
                            }
                        }
                    }
                    // Past the module's table.
                    match run(at, dm, row.len()) {
                        Some(false) => range_ok += 1,
                        r => { range_bad += 1; println!("PAST THE TABLE NOT REJECTED: method {} -> ({}, {}): {:?}", mi, dm, row.len(), r); }
                    }
                }
                // Past the modules.
                match run(at, policy.len(), 0) {
                    Some(false) => range_ok += 1,
                    r => { range_bad += 1; println!("PAST THE MODULES NOT REJECTED: method {}: {:?}", mi, r); }
                }
                let _ = index;
            }
            println!("primitive sites {}: denied/absent targets accepted {} (not accepted {}); other-arity targets rejected {} (not rejected {}); \
                      targets past the table rejected {} (not rejected {})",
                sites, denied_ok, denied_bad, arity_ok, arity_bad, range_ok, range_bad);
            if denied_bad + arity_bad + range_bad > 0 { std::process::exit(1); }
        }
        "header" => {
            let l = load::Loaded::load(&args[1]);
            let p = l.program();
            let policy = l.prim_arity.clone();
            let full = full_table();
            let c = certificate(&l, &p);
            let n = p.methods.len();
            let check = |name: &str, bytes: &[u8], table: &[Vec<u8>], want_accept: bool, want_code: u32| -> bool {
                let v = measure_walk(&p, bytes, l.global_count, table, l.trusted);
                let code = cert::x_header_error(bytes, n, table);
                let ok = v == Some(want_accept) && code == want_code;
                println!("[{}] {} accepted {:?} header error {} ({})", if ok { "ok" } else { "MISMATCH" }, name, v, code,
                    header_error_text(code));
                ok
            };
            let set = |at: usize, x: u32| { let mut b = c.clone(); b[at..at + 4].copy_from_slice(&x.to_le_bytes()); b };
            let mut all = true;
            all &= check("unchanged", &c, &policy, true, 0);
            all &= check("full table instead of the policy's", &c, &full, false, cert::HEADER_POLICY);
            all &= check("version 1", &set(4, 1), &policy, false, cert::HEADER_VERSION);
            all &= check("version 3", &set(4, 3), &policy, false, cert::HEADER_VERSION);
            all &= check("policy id + 1", &set(12, cert::policy_id(&policy).wrapping_add(1)), &policy, false, cert::HEADER_POLICY);
            all &= check("full table's policy id", &set(12, cert::policy_id(&full)), &policy, false, cert::HEADER_POLICY);
            all &= check("method count - 1", &set(8, n as u32 - 1), &policy, false, cert::HEADER_METHODS);
            all &= check("magic", &set(0, 0x5452_4355), &policy, false, cert::HEADER_MALFORMED);
            all &= check("truncated header", &c[..cert::CERT_HEADER_SIZE - 1], &policy, false, cert::HEADER_MALFORMED);
            all &= check("section past the end", &set(16 + 8 * 5 + 4, c.len() as u32), &policy, false, cert::HEADER_SECTIONS);
            if !all { std::process::exit(1); }
        }
        _ => {
            eprintln!("unknown command");
            std::process::exit(2);
        }
    }
}

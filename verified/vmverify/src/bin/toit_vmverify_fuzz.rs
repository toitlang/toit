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

//! In-process fuzzing of the launch-time verifier entry point
//! (`toit_vmverify_verify`, the C ABI the VM calls at every untrusted
//! launch) on mutated copies of the exact input the VM hands it: the
//! `toit_v2_program` tables, the program image, the globals and the
//! primitive table, saved with `toit.run --emit-canonical=FILE.tables`
//! (tables.rs).
//!
//! Every mutant is verified; a verifier panic (result code INTERNAL: the
//! FFI catches it) or a call slower than `--max-ms` is a finding, printed
//! with the seed and the mutation, and the mutant is saved with
//! `--save DIR`. The goal is none.
//!
//! Usage: toit_vmverify_fuzz [--seconds N] [--seed S] [--max-ms M] [--save DIR] TABLES...

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use toit_verified_core::ffi::ProgramTables;
use toit_vmverify::ffi::{toit_vmverify_verify, VerifyResult, MESSAGE_SIZE};
use toit_vmverify::tables::Tables;
use toit_vmverify::verify;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

const WORD: usize = std::mem::size_of::<usize>();

/// An interesting value of type width `bits` near `old`.
fn value(r: &mut Rng, old: u64, bits: u32, scale: u64) -> u64 {
    let mask = if bits == 64 { u64::MAX } else { (1u64 << bits) - 1 };
    let v = match r.below(8) {
        0 => 0,
        1 => mask,
        2 => old.wrapping_add(1),
        3 => old.wrapping_sub(1),
        4 => r.next() % scale.max(1),
        5 => scale,
        6 => old ^ (1 << r.below(bits as usize)),
        _ => r.next(),
    };
    v & mask
}

fn word_value(r: &mut Rng, t: &Tables, old: usize) -> usize {
    let start = t.image.as_ptr() as usize;
    match r.below(5) {
        // A smi.
        0 => ((r.below(1 << 20) as isize - (1 << 19)) << 1) as usize,
        // A reference to some word of the image.
        1 => start + r.below(t.image.len()) * WORD + 1,
        // A reference just outside the image or misaligned.
        2 => start + t.image.len() * WORD + 1 + r.below(3) * WORD,
        3 => old ^ (1 << r.below(64)),
        _ => r.next() as usize,
    }
}

/// Applies one mutation; returns its description.
fn mutate(r: &mut Rng, t: &mut Tables) -> String {
    let n = t.methods.len();
    match r.below(16) {
        0 | 1 | 2 => {
            // A bytecode, often near a method entry.
            if t.bytecodes.is_empty() { return "none".into(); }
            let i = if n > 0 && r.chance(50) {
                let m = &t.methods[r.below(n)];
                (m.entry as usize + r.below(8)).min(t.bytecodes.len() - 1)
            } else {
                r.below(t.bytecodes.len())
            };
            let old = t.bytecodes[i];
            t.bytecodes[i] = value(r, old as u64, 8, 101) as u8;
            format!("bytecode {}: {} -> {}", i, old, t.bytecodes[i])
        }
        3 | 4 | 5 => {
            if n == 0 { return "none".into(); }
            let i = r.below(n);
            let other = t.methods[r.below(n)];
            let m = &mut t.methods[i];
            let scale = t.bytecodes.len() as u64;
            let f = r.below(8);
            match f {
                0 => m.entry = if r.chance(30) { other.entry } else { value(r, m.entry as u64, 32, scale) as u32 },
                1 => m.end = if r.chance(30) { other.end } else { value(r, m.end as u64, 32, scale) as u32 },
                2 => m.selector = if r.chance(30) { other.selector } else { value(r, m.selector as u64, 16, 0xffff) as u16 },
                3 => m.aux = value(r, m.aux as u64, 16, 256) as u16,
                4 => m.recv_start = value(r, m.recv_start as u64, 16, t.class_bits.len() as u64) as u16,
                5 => m.recv_end = value(r, m.recv_end as u64, 16, t.class_bits.len() as u64) as u16,
                6 => m.arity = value(r, m.arity as u64, 8, 8) as u8,
                _ => m.kind = value(r, m.kind as u64, 8, 4) as u8,
            }
            format!("method {} field {}", i, f)
        }
        6 | 7 => {
            if t.dispatch.is_empty() { return "none".into(); }
            let i = r.below(t.dispatch.len());
            let old = t.dispatch[i];
            t.dispatch[i] = match r.below(4) {
                0 => -1,
                1 => r.below(n + 2) as i32,
                2 => n as i32 + r.below(8) as i32,
                _ => value(r, old as u64, 32, n as u64) as i32,
            };
            format!("dispatch {}: {} -> {}", i, old, t.dispatch[i])
        }
        8 => {
            let (name, table): (&str, &mut Vec<u16>) = match r.below(3) {
                0 => ("class_bits", &mut t.class_bits),
                1 => ("class_check_ids", &mut t.class_check_ids),
                _ => ("interface_check_offsets", &mut t.interface_check_offsets),
            };
            if table.is_empty() { return "none".into(); }
            let i = r.below(table.len());
            table[i] = value(r, table[i] as u64, 16, 0x10000) as u16;
            format!("{} {}", name, i)
        }
        9 => {
            let (name, table): (&str, &mut Vec<i32>) = if r.chance(50) {
                ("invoke_offsets", &mut t.invoke_offsets)
            } else {
                ("entry_points", &mut t.entry_points)
            };
            let i = r.below(table.len());
            table[i] = value(r, table[i] as u64, 32, 0x10000) as i32;
            format!("{} {}", name, i)
        }
        10 => {
            let i = r.below(t.builtin.len());
            t.builtin[i] = if r.chance(70) { (r.below(t.class_bits.len() + 4)) << 1 } else { r.next() as usize };
            format!("builtin {}", i)
        }
        11 => {
            let which = r.below(3);
            let len = [t.roots.len(), t.literals.len(), t.globals.len()][which];
            if len == 0 { return "none".into(); }
            let i = r.below(len);
            let old = [&t.roots, &t.literals, &t.globals][which][i];
            let v = word_value(r, t, old);
            [&mut t.roots, &mut t.literals, &mut t.globals][which][i] = v;
            format!("{} {}", ["root", "literal", "global"][which], i)
        }
        12 | 13 => {
            if t.image.is_empty() { return "none".into(); }
            let i = r.below(t.image.len());
            let old = t.image[i];
            t.image[i] = word_value(r, t, old);
            format!("image word {}", i)
        }
        14 => {
            // Truncate a table.
            match r.below(6) {
                0 => { let l = r.below(t.methods.len() + 1); t.methods.truncate(l); format!("methods truncated to {}", l) }
                1 => { let l = r.below(t.bytecodes.len() + 1); t.bytecodes.truncate(l); format!("bytecodes truncated to {}", l) }
                2 => { let l = r.below(t.dispatch.len() + 1); t.dispatch.truncate(l); format!("dispatch truncated to {}", l) }
                3 => { let l = r.below(t.class_bits.len() + 1); t.class_bits.truncate(l); format!("class_bits truncated to {}", l) }
                4 => { let l = r.below(t.literals.len() + 1); t.literals.truncate(l); format!("literals truncated to {}", l) }
                _ => { let l = r.below(t.globals.len() + 1); t.globals.truncate(l); format!("globals truncated to {}", l) }
            }
        }
        _ => {
            if r.chance(50) {
                t.global_max_height = value(r, t.global_max_height as u64, 32, 300) as usize;
                format!("max height {}", t.global_max_height)
            } else if !t.prim_arities.is_empty() {
                let i = r.below(t.prim_arities.len());
                t.prim_arities[i] = value(r, t.prim_arities[i] as u64, 8, 8) as u8;
                format!("primitive arity {}", i)
            } else {
                "none".into()
            }
        }
    }
}

fn run(t: &mut Tables) -> (usize, Duration, String, usize) {
    let mut pt: ProgramTables = unsafe { std::mem::zeroed() };
    let input = t.input(&mut pt);
    let mut result = VerifyResult {
        code: 0, method: 0, offset: 0, objects: 0, convert_ns: 0, heap_ns: 0, infer_ns: 0,
        check_ns: 0, peak_bytes: 0, message: [0; MESSAGE_SIZE],
    };
    let t0 = Instant::now();
    unsafe { toit_vmverify_verify(&input, &mut result) };
    let d = t0.elapsed();
    let len = result.message.iter().position(|b| *b == 0).unwrap_or(MESSAGE_SIZE);
    (result.code, d, String::from_utf8_lossy(&result.message[..len]).into_owned(), result.peak_bytes)
}

fn main() {
    let mut seconds = 60u64;
    let mut seed = 1u64;
    let mut max_ms = 2000u128;
    let mut save: Option<String> = None;
    let mut paths = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--seconds" => seconds = it.next().and_then(|v| v.parse().ok()).expect("--seconds N"),
            "--seed" => seed = it.next().and_then(|v| v.parse().ok()).expect("--seed S"),
            "--max-ms" => max_ms = it.next().and_then(|v| v.parse().ok()).expect("--max-ms M"),
            "--save" => save = it.next(),
            _ => paths.push(a),
        }
    }
    let panics: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    {
        let panics = panics.clone();
        std::panic::set_hook(Box::new(move |info| {
            panics.lock().unwrap().push(info.to_string());
        }));
    }
    let mut programs = Vec::new();
    for p in &paths {
        let mut t = Tables::load(p).unwrap_or_else(|e| panic!("{}", e));
        let (code, d, msg, peak) = run(&mut t);
        println!("baseline {}: code {} ({}) {:.1} ms peak {} KB {}", p, code, if code == verify::ACCEPTED { "accepted" } else { "rejected" },
            d.as_secs_f64() * 1e3, peak >> 10, msg);
        programs.push(t);
    }
    let mut r = Rng(seed.max(1).wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
    let start = Instant::now();
    let mut counts = [0usize; 6];
    let mut findings = 0usize;
    let mut iterations = 0usize;
    let mut slowest = Duration::ZERO;
    let mut peak_max = 0usize;
    while start.elapsed().as_secs() < seconds {
        iterations += 1;
        let pi = r.below(programs.len());
        let mut t = programs[pi].duplicate();
        let k = 1 + r.below(4);
        let what: Vec<String> = (0..k).map(|_| mutate(&mut r, &mut t)).collect();
        panics.lock().unwrap().clear();
        let (code, d, msg, peak) = run(&mut t);
        counts[code.min(5)] += 1;
        slowest = slowest.max(d);
        peak_max = peak_max.max(peak);
        let slow = d.as_millis() > max_ms;
        if code == verify::INTERNAL || slow {
            findings += 1;
            let p = panics.lock().unwrap().join(" | ");
            println!("FINDING seed {} iteration {} program {}: {} ({:.0} ms): {} [{}] {}", seed, iterations, paths[pi],
                if slow { "slow" } else { "panic" }, d.as_secs_f64() * 1e3, what.join("; "), msg, p);
            if let Some(dir) = &save {
                let _ = std::fs::create_dir_all(dir);
                let mut pt: ProgramTables = unsafe { std::mem::zeroed() };
                let input = t.input(&mut pt);
                let path = format!("{}/finding-{}-{}.tables", dir, seed, iterations);
                let _ = unsafe { toit_vmverify::tables::save(&input, &path) };
            }
        }
    }
    println!("seed {}: {} mutants in {} s: accepted {}, malformed {}, heap {}, tables {}, method {}, internal {}; findings {}; slowest {:.1} ms; peak {} KB",
        seed, iterations, seconds, counts[0], counts[1], counts[2], counts[3], counts[4], counts[5], findings,
        slowest.as_secs_f64() * 1e3, peak_max >> 10);
    std::process::exit(if findings == 0 { 0 } else { 1 });
}

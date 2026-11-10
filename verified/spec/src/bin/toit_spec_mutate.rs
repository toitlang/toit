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

//! Mutation campaign for the structural verifier of format 2.
//!
//! For each dumped program the original is run once on the reference
//! interpreter to find the instructions it executes. Then single mutations
//! are applied to the bytecodes: a random byte of an executed instruction,
//! an operand of an executed instruction set to a boundary or random value,
//! or a byte of the method header of an executed method. Every mutant is
//! verified; an accepted mutant is run on the interpreter for a bounded
//! number of steps. A mutant that is accepted and reaches a stuck state
//! (or panics the interpreter) is a soundness failure of the verifier.
//!
//! Usage: toit_spec_mutate [--count N] [--seed S] [--max-steps M] [--log FILE] <dump>...

use std::collections::BTreeMap;
use std::io::Write;
use toit_spec::interp::{loader, prims, system, End, Halt, Machine, Step};
use toit_spec::v2::bytecodes::OPCODE_LENGTHS2;
use toit_spec::v2::infer;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

/// Runs a machine like `Machine::run`, recording executed bcis.
fn run(m: &mut Machine, max_steps: u64, coverage: Option<&mut Vec<bool>>) -> End {
    let mut coverage = coverage;
    loop {
        if m.steps >= max_steps {
            return End::StepLimit;
        }
        m.steps += 1;
        if let Some(c) = coverage.as_deref_mut() {
            if m.s.bci < c.len() {
                c[m.s.bci] = true;
            }
        }
        match m.step() {
            Ok(Step::Next) => {}
            Ok(Step::Primitive(module, index)) => {
                if let Err(end) = prims::call(m, module, index) {
                    return end;
                }
            }
            Ok(Step::Halt(Halt::Yield)) => {
                if let Err(end) = system::on_yield(m) {
                    return end;
                }
            }
            Ok(Step::Halt(Halt::Exit(v))) => return End::Exit(v),
            Ok(Step::Halt(Halt::DeepSleep)) => return End::DeepSleep,
            Ok(Step::Halt(Halt::Reset)) => return End::Reset,
            Ok(Step::Halt(Halt::Uncaught(v))) => return End::Uncaught(m.describe(v)),
            Ok(Step::Halt(Halt::TaskReturned)) => return End::TaskReturned,
            Err(stuck) => return End::Stuck(stuck, m.backtrace()),
        }
    }
}

fn end_kind(e: &End) -> String {
    match e {
        End::Exit(_) => "exit".into(),
        End::DeepSleep => "deep-sleep".into(),
        End::Reset => "reset".into(),
        End::Stuck(s, _) => format!("STUCK:{:?}", s),
        End::Unimplemented(_) => "unimplemented-primitive".into(),
        End::Deadlock => "deadlock".into(),
        End::Uncaught(_) => "uncaught".into(),
        End::TaskReturned => "task-returned".into(),
        End::StepLimit => "step-limit".into(),
    }
}

const ARGS: [&str; 3] = ["foo", "bar", "gee"];

fn args() -> Vec<String> {
    ARGS.iter().map(|s| s.to_string()).collect()
}

fn main() {
    let mut count = 10_000usize;
    let mut seed = 1u64;
    let mut max_steps = 200_000u64;
    let mut log: Option<String> = None;
    let mut dumps = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--count" => count = it.next().unwrap().parse().unwrap(),
            "--seed" => seed = it.next().unwrap().parse().unwrap(),
            "--max-steps" => max_steps = it.next().unwrap().parse().unwrap(),
            "--log" => log = it.next(),
            _ => dumps.push(a),
        }
    }
    let mut log = log.map(|p| std::fs::File::create(p).unwrap());
    let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
    let mut totals: BTreeMap<String, usize> = BTreeMap::new();
    let mut ends: BTreeMap<String, usize> = BTreeMap::new();
    let mut findings: Vec<String> = Vec::new();
    let per = count / dumps.len().max(1);
    if std::env::var("MUTATE_PANIC").is_err() { std::panic::set_hook(Box::new(|_| {})); }
    for (di, path) in dumps.iter().enumerate() {
        let n = if di + 1 == dumps.len() { count - per * (dumps.len() - 1) } else { per };
        let text = std::fs::read_to_string(path).unwrap();
        let base = loader::load(&text, 64).unwrap();
        let globals = base.globals.len();
        let global_max_height = base.program.methods.first().map(|m| m.max_height).unwrap_or(0);
        // Coverage of the original run.
        let mut cov = vec![false; base.program.bytecodes.len()];
        let mut m0 = Machine::new(loader::load(&text, 64).unwrap(), args());
        m0.world.echo = false;
        let e0 = run(&mut m0, max_steps, Some(&mut cov));
        let executed: Vec<usize> = (0..cov.len()).filter(|&i| cov[i]).collect();
        let methods: Vec<usize> = base.program.methods.iter().enumerate()
            .filter(|(_, mi)| executed.iter().any(|&b| mi.entry <= b && b < mi.end))
            .map(|(i, _)| i).collect();
        eprintln!("{}: original run {} ({} executed instructions, {} methods); {} mutants",
            path, end_kind(&e0), executed.len(), methods.len(), n);
        for _ in 0..n {
            let mut bytes = base.program.bytecodes.clone();
            let choice = rng.below(10);
            let (kind, at) = if choice < 5 || executed.is_empty() {
                // A random byte of an executed instruction.
                let bci = executed[rng.below(executed.len())];
                let len = OPCODE_LENGTHS2.get(bytes[bci] as usize).copied().unwrap_or(1) as usize;
                let at = bci + rng.below(len);
                let mut v = rng.below(256) as u8;
                if v == bytes[at] { v = v.wrapping_add(1); }
                bytes[at] = v;
                ("byte", at)
            } else if choice < 9 {
                // An operand of an executed instruction.
                let candidates: Vec<usize> = executed.iter().copied()
                    .filter(|&b| OPCODE_LENGTHS2.get(bytes[b] as usize).copied().unwrap_or(1) > 1).collect();
                if candidates.is_empty() { continue; }
                let bci = candidates[rng.below(candidates.len())];
                let len = OPCODE_LENGTHS2[bytes[bci] as usize] as usize;
                let p = &base.program;
                let bounds = [0usize, 1, 2, 0xff, 0x100, 0xffff, p.literals.len(), p.methods.len(),
                    p.dispatch.len(), p.class_bits.len(), globals, p.class_check_ids.len(),
                    p.interface_check_offsets.len()];
                let old = if len >= 3 { bytes[bci + 1] as usize | (bytes[bci + 2] as usize) << 8 } else { bytes[bci + 1] as usize };
                let v = match rng.below(4) {
                    0 => bounds[rng.below(bounds.len())],
                    1 => old.wrapping_add(1),
                    2 => old.wrapping_sub(1),
                    _ => rng.below(0x10000),
                };
                // Wide operands are u16 at bci+1 (the second operand of the
                // three- and four-byte forms gets the byte mutation path).
                if len >= 3 {
                    bytes[bci + 1] = v as u8;
                    bytes[bci + 2] = (v >> 8) as u8;
                } else {
                    bytes[bci + 1] = v as u8;
                }
                ("operand", bci)
            } else {
                // A byte of the header of an executed method.
                if methods.is_empty() { continue; }
                let mi = base.program.methods[methods[rng.below(methods.len())]];
                let header = base.names.method_at(mi.entry).map(|(id, _, _)| id).unwrap_or(mi.entry - 2);
                let at = header + rng.below(mi.entry - header);
                let mut v = rng.below(256) as u8;
                if v == bytes[at] { v = v.wrapping_add(1); }
                bytes[at] = v;
                ("header", at)
            };
            *totals.entry(format!("{} mutants", kind)).or_default() += 1;
            let mut loaded = loader::load(&text, 64).unwrap();
            let table = match loader::method_table_v2(&bytes, global_max_height) {
                Ok(t) => t,
                Err(_) => {
                    *totals.entry("rejected (method table)".into()).or_default() += 1;
                    continue;
                }
            };
            loaded.program.bytecodes = bytes;
            loaded.program.method_start = vec![false; loaded.program.bytecodes.len()];
            loaded.program.methods = table;
            if !infer::verify_exec(&loaded.program, globals as u64, false) {
                *totals.entry("rejected".into()).or_default() += 1;
                continue;
            }
            *totals.entry("accepted".into()).or_default() += 1;
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut m = Machine::new(loaded, args());
                m.world.echo = false;
                let e = run(&mut m, max_steps, None);
                (end_kind(&e), match &e { End::Stuck(_, t) => t.clone(), _ => String::new() })
            }));
            let (ek, trace) = match r {
                Ok(x) => x,
                Err(_) => ("PANIC".to_string(), String::new()),
            };
            *ends.entry(ek.clone()).or_default() += 1;
            if ek.starts_with("STUCK") || ek == "PANIC" {
                let msg = format!("{} {} {} at {}: {} {}", path, kind, at, at, ek, trace.lines().next().unwrap_or(""));
                findings.push(msg.clone());
                if let Some(f) = log.as_mut() { writeln!(f, "{}", msg).unwrap(); }
            }
        }
    }
    println!("mutation campaign: seed {}, max steps {}", seed, max_steps);
    for (k, v) in &totals {
        println!("  {}: {}", k, v);
    }
    println!("  accepted mutants by how the run ended:");
    for (k, v) in &ends {
        println!("    {}: {}", k, v);
    }
    println!("  soundness findings (accepted and stuck or panicked): {}", findings.len());
    for f in findings.iter().take(50) {
        println!("    {}", f);
    }
    std::process::exit(if findings.is_empty() { 0 } else { 1 });
}

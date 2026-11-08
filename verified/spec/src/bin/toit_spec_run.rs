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

//! Runs a program dumped by `tools/spec_dump.toit` on the reference
//! interpreter.
//!
//! Usage: toit-spec-run [--word-bits 32|64] [--trace] [--no-verified]
//!                      [--max-steps N] [--stats] <dump> [-- args...]

#[allow(unused_imports)]
use vstd::prelude::*;

use toit_spec::interp::{loader, End, Machine};

fn main() {
    let mut word_bits = 64u8;
    let mut trace = false;
    let mut use_verified = true;
    let mut stats = false;
    let mut max_steps = u64::MAX;
    let mut path = None;
    let mut program_args = Vec::new();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--word-bits" => word_bits = it.next().and_then(|v| v.parse().ok()).expect("--word-bits 32|64"),
            "--trace" => trace = true,
            "--no-verified" => use_verified = false,
            "--stats" => stats = true,
            "--max-steps" => max_steps = it.next().and_then(|v| v.parse().ok()).expect("--max-steps N"),
            "--" => {
                program_args.extend(it.by_ref());
            }
            _ if path.is_none() => path = Some(arg),
            _ => program_args.push(arg),
        }
    }
    if word_bits != 32 && word_bits != 64 {
        eprintln!("--word-bits must be 32 or 64");
        std::process::exit(2);
    }
    let path = path.unwrap_or_else(|| {
        eprintln!("Usage: toit-spec-run [--word-bits 32|64] [--trace] [--no-verified] [--max-steps N] <dump> [-- args]");
        std::process::exit(2);
    });
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("cannot read {}: {}", path, e);
        std::process::exit(2);
    });
    let loaded = loader::load(&text, word_bits).unwrap_or_else(|e| {
        eprintln!("cannot load {}: {}", path, e);
        std::process::exit(2);
    });
    let mut m = Machine::new(loaded, program_args);
    m.trace = trace;
    m.use_verified = use_verified;
    let end = m.run(max_steps);
    if stats {
        eprintln!("[spec] steps: {}, verified steps: {}, heap objects: {}", m.steps, m.verified_steps, m.s.heap.len());
    }
    let code = match end {
        End::Exit(v) => v as i32,
        End::Stuck(s, trace) => {
            eprintln!("[spec] stuck: {:?} at\n  {}", s, trace);
            3
        }
        End::Unimplemented(name) => {
            eprintln!("[spec] unimplemented primitive {} at\n  {}", name, m.backtrace());
            4
        }
        other => {
            eprintln!("[spec] {:?}", other);
            5
        }
    };
    std::process::exit(code);
}

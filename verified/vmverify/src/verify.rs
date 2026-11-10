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

//! TRUSTED: the verdict. Accepts exactly when the two proven checks of
//! SOUNDNESS.md accept, on the program converted from VM memory:
//!
//! * `check::verify(p, g, oracle, trusted)`, proven to return exactly
//!   `pins_sorted(g) && split_ok(vview(p), g@, ms, trusted)` for the maps
//!   `ms` the oracle gave it; `split_ok` implies `accepts(vview(p),
//!   with_maps(g@, ms), trusted)` (`v2::split::lemma_split_sound`);
//! * `heap_check::x_loaded_ok(p, g.global_count, heap, globals)`, equal to
//!   `loaded_ok` for every certificate with that global count, so for
//!   `with_maps(g@, ms)` as well.
//!
//! So `theorem_soundness_split` (= `theorem_soundness` for that assembled
//! certificate) applies. The global part `g` comes from the untrusted
//! inference, except its trusted fields (`global_count`, `prim_arity`),
//! which are set here from the program's globals and the VM's table.
//! `x_wf_program2` runs first (the inference needs it), and the
//! unverified `check_heap` only gives an early, readable rejection.
//! Everything after the verdict is diagnostics.

use std::time::Instant;
use toit_spec::v2::check::{self, MapOracle, XMaps};
use toit_spec::v2::{heap_check, infer};
use crate::from_vm::Converted;

pub const ACCEPTED: usize = 0;
/// The VM memory could not be converted (from_vm::Malformed).
pub const MALFORMED: usize = 1;
/// The program heap violates the loader contract (`loaded_ok`).
pub const HEAP: usize = 2;
/// The program tables are rejected (`wf_program2`, `tables_ok`).
pub const TABLES: usize = 3;
/// A method is rejected (`method_ok`); method and offset are set.
pub const METHOD: usize = 4;
/// The verifier itself failed (a panic); the program is rejected.
pub const INTERNAL: usize = 5;

pub struct Verdict {
    pub code: usize,
    pub method: isize,
    pub offset: isize,
    pub message: String,
    pub heap_ns: u64,
    /// The inference: the global phase and the per-method maps the checker
    /// asked for.
    pub infer_ns: u64,
    /// The proven checker, without the time of the maps it asked for.
    pub check_ns: u64,
}

impl Verdict {
    fn new(code: usize, message: String) -> Verdict {
        Verdict { code, method: -1, offset: -1, message, heap_ns: 0, infer_ns: 0, check_ns: 0 }
    }
}

fn ns(t: Instant) -> u64 {
    t.elapsed().as_nanos() as u64
}

/// The inference's oracle, timed.
struct Timed<'a> {
    inner: infer::Oracle<'a>,
    ns: u64,
}

impl<'a> MapOracle for Timed<'a> {
    fn method_maps(&mut self, m: usize) -> XMaps {
        let t = Instant::now();
        let r = self.inner.method_maps(m);
        self.ns += ns(t);
        r
    }
}

/// The verdict on a converted program.
pub fn verify(c: &Converted, trusted: bool) -> Verdict {
    let p = &c.program();
    // The inference and x_loaded_ok require well-formed tables.
    if !check::x_wf_program2(p) {
        return Verdict::new(TABLES, "table sizes or method bounds (wf_program2)".into());
    }
    let t = Instant::now();
    if let Err(e) = heap_check::check_heap(p, &c.heap) {
        let mut v = Verdict::new(HEAP, e);
        v.heap_ns = ns(t);
        return v;
    }
    let mut heap_ns = ns(t);
    let t = Instant::now();
    let mut global = infer::infer_global(p, c.globals.len() as u64, c.prim_arity.clone(), trusted);
    let mut infer_ns = ns(t);
    // The trusted fields of the certificate.
    global.g.global_count = c.globals.len() as u64;
    global.g.prim_arity = c.prim_arity.clone();
    let t = Instant::now();
    let mut oracle = Timed { inner: infer::Oracle::new(p, &global, trusted), ns: 0 };
    let (ok, _) = check::verify(p, &global.g, &mut oracle, trusted);
    let at = oracle.inner.last;
    let check_ns = ns(t).saturating_sub(oracle.ns);
    infer_ns += oracle.ns;
    let t = Instant::now();
    let loaded_ok = heap_check::x_loaded_ok(p, global.g.global_count, &c.heap, &c.globals);
    heap_ns += ns(t);
    let mut v = if !ok {
        diagnose(c, &global, at, trusted)
    } else if !loaded_ok {
        Verdict::new(HEAP, "loader contract (loaded_ok)".into())
    } else {
        Verdict::new(ACCEPTED, String::new())
    };
    v.heap_ns = heap_ns;
    v.infer_ns = infer_ns;
    v.check_ns = check_ns;
    v
}

/// Why `check::verify` rejected (called only after it did): `at` is the
/// last method it asked maps for.
fn diagnose(c: &Converted, global: &infer::Global, at: Option<usize>, trusted: bool) -> Verdict {
    let p = &c.program();
    let Some(m) = at else {
        let mut v = Verdict::new(TABLES, "program tables (tables_ok)".into());
        if let Some((m, off, msg)) = global.errors.first() {
            v.message = format!("program tables (tables_ok); inference: method {} +{}: {}", m, off, msg);
        }
        return v;
    };
    let mut v = Verdict::new(METHOD, String::new());
    v.method = m as isize;
    let (off, why) = infer::diagnose(p, global, m, trusted);
    match off {
        Some(off) => {
            v.offset = off as isize;
            v.message = format!("{}: {}", instruction(p, m, off), why);
        }
        None => v.message = why,
    }
    v
}

/// The instruction at `off` in method `m`: its name and operand bytes.
fn instruction(p: &toit_spec::v2::vprog::VProgram, m: usize, off: usize) -> String {
    use toit_spec::v2::bytecodes::{OPCODE_LENGTHS2, OPCODE_NAMES2};
    let Some(info) = p.methods.get(m) else { return "(no method)".into() };
    let end = info.end as usize;
    let at = info.entry as usize + off;
    let Some(&op) = p.bytecodes.get(at).filter(|_| at < end) else { return "(no instruction)".into() };
    let Some(name) = OPCODE_NAMES2.get(op as usize) else { return format!("bad opcode {}", op) };
    let mut text = name.to_string();
    for i in 1..OPCODE_LENGTHS2[op as usize] as usize {
        match p.bytecodes.get(at + i).filter(|_| at + i < end) {
            Some(b) => text.push_str(&format!(" {}", b)),
            None => text.push_str(" (past the end)"),
        }
    }
    text
}

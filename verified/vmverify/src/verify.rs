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
//! * `heap_check::x_loaded_ok_stream(p, objects, global_count, globals)`,
//!   which accepts only if the heap the converted objects form satisfies
//!   `loaded_ok` for every certificate with that global count, so for
//!   `with_maps(g@, ms)` as well. The objects are checked one at a time as
//!   `from_vm` converts them (none is kept); the conversion must also end
//!   without error with every object found converted (`complete`).
//!
//! So `theorem_soundness_split` (= `theorem_soundness` for that assembled
//! certificate) applies. The global part `g` comes from the untrusted
//! inference, except its trusted fields (`global_count`, `prim_arity`),
//! which are set here from the program's globals and the VM's table.
//! `x_wf_program2` runs first (the inference needs it). Everything after
//! the verdict is diagnostics.

use alloc::format;
use alloc::string::{String, ToString};
use toit_spec::v2::check::{self, MapOracle, XMaps};
use crate::clock::Clock;
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

/// The inference's oracle, timed.
struct Timed<'a> {
    inner: infer::Oracle<'a>,
    ns: u64,
}

impl<'a> MapOracle for Timed<'a> {
    fn method_maps(&mut self, m: usize) -> XMaps {
        let t = Clock::start();
        let r = self.inner.method_maps(m);
        self.ns += t.ns();
        r
    }
}

/// The verdict on a converted program.
pub fn verify(c: &mut Converted, trusted: bool) -> Verdict {
    let global_count = c.globals.len() as u64;
    let prim_arity = c.prim_arity.clone();
    let globals = core::mem::take(&mut c.globals);
    let (p, objects) = c.split();
    let p = &p;
    // The inference and the heap check require well-formed tables.
    if !check::x_wf_program2(p) {
        return Verdict::new(TABLES, "table sizes or method bounds (wf_program2)".into());
    }
    // The loader's contract, one object at a time.
    let t = Clock::start();
    let (heap_ok, _) = heap_check::x_loaded_ok_stream(p, objects, global_count, &globals);
    let complete = objects.complete();
    let heap_ns = t.ns();
    if !heap_ok || !complete {
        let message = match &objects.error {
            Some(e) => format!("{} ({})", e.what, e.detail),
            None => format!("loader contract (loaded_ok); {} objects converted", objects.count()),
        };
        let mut v = Verdict::new(if objects.error.is_some() { MALFORMED } else { HEAP }, message);
        v.heap_ns = heap_ns;
        return v;
    }
    objects.release();
    drop(globals);
    let t = Clock::start();
    let mut global = infer::infer_global(p, global_count, prim_arity.clone(), trusted);
    let mut infer_ns = t.ns();
    // The trusted fields of the certificate (x_loaded_ok_stream checked the
    // globals against this count).
    global.g.global_count = global_count;
    global.g.prim_arity = prim_arity;
    let t = Clock::start();
    let mut oracle = Timed { inner: infer::Oracle::new(p, &global, trusted), ns: 0 };
    let (ok, _) = check::verify(p, &global.g, &mut oracle, trusted);
    let at = oracle.inner.last;
    let check_ns = t.ns().saturating_sub(oracle.ns);
    infer_ns += oracle.ns;
    let mut v = if !ok {
        diagnose(p, &global, at, trusted)
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
fn diagnose(p: &toit_spec::v2::vprog::VProgram, global: &infer::Global, at: Option<usize>, trusted: bool) -> Verdict {
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

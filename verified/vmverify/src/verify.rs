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
//! SOUNDNESS.md accept: `check::verify` (equal to `accepts`) and
//! `heap_check::x_loaded_ok` (equal to `loaded_ok`), both on the program
//! converted from VM memory and with a certificate whose trusted fields
//! (`global_count`, `prim_arity`) are set here, not by the untrusted
//! inference. `x_wf_program2` runs first (the inference and
//! `x_loaded_ok` require it), and the unverified `check_heap` only gives
//! an early, readable rejection. Everything after the verdict is
//! diagnostics.

use std::time::Instant;
use toit_spec::interp::loader::Loaded;
use toit_spec::v2::{check, heap_check, infer};

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
    pub infer_ns: u64,
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

/// The verdict on a converted program. `prim_arity` is the VM's primitive
/// table.
pub fn verify(l: &Loaded, prim_arity: Vec<Vec<u8>>, trusted: bool) -> Verdict {
    let p = &l.program;
    // The inference and x_loaded_ok require well-formed tables.
    if !check::x_wf_program2(p) {
        return Verdict::new(TABLES, "table sizes or method bounds (wf_program2)".into());
    }
    let t = Instant::now();
    if let Err(e) = heap_check::check_heap(l) {
        let mut v = Verdict::new(HEAP, e);
        v.heap_ns = ns(t);
        return v;
    }
    let mut heap_ns = ns(t);
    let t = Instant::now();
    let inferred = infer::infer(p, l.globals.len(), trusted);
    let infer_ns = ns(t);
    let mut cert = inferred.cert;
    cert.global_count = l.globals.len() as u64;
    cert.prim_arity = prim_arity;
    let t = Instant::now();
    let ok = check::verify(p, &cert, trusted);
    let check_ns = ns(t);
    let t = Instant::now();
    let loaded_ok = heap_check::x_loaded_ok(p, &cert, &l.heap, &l.globals);
    heap_ns += ns(t);
    let mut v = if !ok {
        diagnose(l, &cert, &inferred.errors, trusted)
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

/// Why `check::verify` rejected (called only after it did).
fn diagnose(l: &Loaded, c: &check::XCert, errors: &[(usize, usize, String)], trusted: bool) -> Verdict {
    let p = &l.program;
    if !check::x_tables_ok(p, c) {
        let mut v = Verdict::new(TABLES, "program tables (tables_ok)".into());
        if let Some((m, off, msg)) = errors.first() {
            v.message = format!("program tables (tables_ok); inference: method {} +{}: {}", m, off, msg);
        }
        return v;
    }
    for m in 0..p.methods.len() {
        if check::x_method_ok(p, c, m, trusted) { continue; }
        let mut v = Verdict::new(METHOD, String::new());
        v.method = m as isize;
        if let Some((_, off, msg)) = errors.iter().find(|e| e.0 == m) {
            v.offset = *off as isize;
            v.message = format!("{}: {}", instruction(l, m, *off), msg);
            return v;
        }
        // The first offset the checker rejects.
        let maps = &c.maps[m];
        for (off, k) in maps.iter().enumerate() {
            let Some(k) = k else { continue };
            if !check::x_instr_ok(p, c, m, off, k, trusted) {
                v.offset = off as isize;
                v.message = format!("{}: rejected by the checker", instruction(l, m, off));
                return v;
            }
        }
        v.message = "entry kinds or certificate shape rejected by the checker".into();
        return v;
    }
    Verdict::new(TABLES, "rejected".into())
}

/// The instruction at `off` in method `m`: its name and operand bytes.
fn instruction(l: &Loaded, m: usize, off: usize) -> String {
    use toit_spec::v2::bytecodes::{OPCODE_LENGTHS2, OPCODE_NAMES2};
    let p = &l.program;
    let info = &p.methods[m];
    let at = info.entry + off;
    let Some(&op) = p.bytecodes.get(at).filter(|_| at < info.end) else { return "(no instruction)".into() };
    let Some(name) = OPCODE_NAMES2.get(op as usize) else { return format!("bad opcode {}", op) };
    let mut text = name.to_string();
    for i in 1..OPCODE_LENGTHS2[op as usize] as usize {
        match p.bytecodes.get(at + i).filter(|_| at + i < info.end) {
            Some(b) => text.push_str(&format!(" {}", b)),
            None => text.push_str(" (past the end)"),
        }
    }
    text
}

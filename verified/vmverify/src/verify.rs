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
//! * `cert::verify_shipped(p, cert, global_count, prim_arity, trusted)`
//!   (with progress reports: `progress::verify_shipped_progress`), proven to
//!   return true only if some certificate `c` with these trusted fields is
//!   accepted (`accepts(vview(p), c, trusted)`): the single-pass checker
//!   `v2::walk` establishes `split_ok(vview(p), g@, ms, trusted)` for ghost
//!   maps `ms`, and `v2::split::lemma_split_sound` gives `accepts` of
//!   `with_maps(g@, ms)`;
//! * `heap_check::x_loaded_ok_stream(p, objects, global_count, globals)`,
//!   which accepts only if the heap the converted objects form satisfies
//!   `loaded_ok` for every certificate with that global count, so for
//!   that `c` as well. The objects are checked one at a time as
//!   `from_vm` converts them (none is kept); the conversion must also end
//!   without error with every object found converted (`complete`).
//!
//! So `theorem_soundness` applies to `c`. The certificate comes from the
//! untrusted toolchain (shipped) or, on hosts, the untrusted inference
//! (encoded and checked the same way), except its trusted fields (`global_count`, `prim_arity`),
//! which are set here from the program's globals and the VM's table.
//! `x_wf_program2` runs first (the inference needs it). Everything after
//! the verdict is diagnostics.
//!
//! A failed allocation anywhere in the conversion, the heap check or the
//! checker rejects the program (OUT_OF_MEMORY); nothing here panics or
//! allocates infallibly on devices (README.md, "No panics on devices").

use alloc::borrow::Cow;
#[cfg(feature = "infer")]
use alloc::format;
#[cfg(feature = "infer")]
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use toit_spec::v2::check;
use toit_spec::v2::vprog::VProgram;
use crate::clock::Clock;
use toit_spec::v2::{cert, heap_check};
#[cfg(feature = "infer")]
use toit_spec::v2::infer;
use crate::from_vm::Converted;
use crate::ffi::VmProgress;
use toit_spec::progress::verify_shipped_progress;

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
/// The shipped certificate is malformed or rejected.
pub const CERTIFICATE: usize = 6;
/// No certificate was shipped and this VM does not infer one.
pub const NO_CERTIFICATE: usize = 7;
/// An allocation of the verifier failed; the program is rejected.
pub const OUT_OF_MEMORY: usize = 8;

/// A diagnostic text: fixed (devices) or formatted (hosts, `text!`).
pub type Text = Cow<'static, str>;

pub struct Verdict {
    pub code: usize,
    pub method: isize,
    pub offset: isize,
    pub message: Text,
    pub heap_ns: u64,
    /// The inference: the global phase and the per-method maps the checker
    /// asked for.
    pub infer_ns: u64,
    /// The proven checker, without the time of the maps it asked for.
    pub check_ns: u64,
}

impl Verdict {
    pub fn new(code: usize, message: Text) -> Verdict {
        Verdict { code, method: -1, offset: -1, message, heap_ns: 0, infer_ns: 0, check_ns: 0 }
    }

    pub fn out_of_memory() -> Verdict {
        Verdict::new(OUT_OF_MEMORY, Cow::Borrowed("out of memory"))
    }
}

/// The verdict on a converted program. With a shipped certificate `cert`
/// (format/18-shipped-certificate.md) the proven
/// `progress::verify_shipped_progress` decides (`cert::verify_shipped` with
/// `progress` told before each method: same postcondition); without one
/// the inference computes the certificate (the `infer` feature, hosts);
/// without both the program is rejected.
pub fn verify(c: &mut Converted, trusted: bool, cert: Option<&[u8]>, progress: VmProgress) -> Verdict {
    let global_count = c.globals.len() as u64;
    // Taken, not copied: the conversion does not need it any more.
    let prim_arity = core::mem::take(&mut c.prim_arity);
    let globals = core::mem::take(&mut c.globals);
    let (mut p, objects) = c.split();
    // The unchecked twins of the field accesses (format note 20) are for
    // trusted programs only.
    p.unchecked = trusted;
    let p = &p;
    // The inference and the heap check require well-formed tables.
    if !check::x_wf_program2(p) {
        return Verdict::new(TABLES, "table sizes or method bounds (wf_program2)".into());
    }
    // The method headers lie inside the bytecodes (format note 21): the
    // core reads them without bounds checks (`table_ok`, part of the
    // loader's contract, which the loader checks too).
    if !toit_spec::v2::vprog::x_table_ok(p.methods.code, p.methods.recs) {
        return Verdict::new(TABLES, "method headers outside the bytecodes (table_ok)".into());
    }
    // The loader's contract, one object at a time.
    let t = Clock::start();
    let (heap_ok, _, bad_string) = heap_check::x_loaded_ok_stream(p, objects, global_count, &globals);
    let complete = objects.complete();
    mem_trace!("heap checked");
    let heap_ns = t.ns();
    if !heap_ok || !complete {
        let mut v = match &objects.error {
            Some(e) if e.oom => Verdict::out_of_memory(),
            Some(e) => Verdict::new(MALFORMED, text!("malformed program memory", "{} ({})", e.what, e.detail)),
            None if bad_string => Verdict::new(HEAP, text!("a string literal isn't valid UTF-8 (loaded_ok)", "a string literal isn't valid UTF-8 (loaded_ok); object {}", objects.count().saturating_sub(1))),
            None => Verdict::new(HEAP, text!("loader contract (loaded_ok)", "loader contract (loaded_ok); {} objects converted", objects.count())),
        };
        v.heap_ns = heap_ns;
        return v;
    }
    objects.release();
    drop(globals);
    mem_trace!("work list released");
    let mut v = match cert {
        Some(cert) => {
            let t = Clock::start();
            // Proven: true only if a certificate with these trusted fields
            // is accepted.
            let verdict = verify_shipped_progress(p, cert, global_count, &prim_arity, trusted, progress);
            mem_trace!("shipped certificate checked");
            let check_ns = t.ns();
            let mut v = match verdict {
                Ok((true, _, _)) => Verdict::new(ACCEPTED, Cow::Borrowed("")),
                Ok((false, at, off)) => diagnose_shipped(p, cert, at, off, global_count, prim_arity, trusted),
                Err(_) => Verdict::out_of_memory(),
            };
            v.check_ns = check_ns;
            v
        }
        None => verify_inferred(p, global_count, prim_arity, trusted),
    };
    v.heap_ns = heap_ns;
    v
}

#[cfg(not(feature = "infer"))]
fn verify_inferred(_p: &VProgram, _global_count: u64, _prim_arity: Vec<Vec<u8>>, _trusted: bool) -> Verdict {
    Verdict::new(NO_CERTIFICATE, "no certificate (this VM does not infer one)".into())
}

#[cfg(feature = "infer")]
fn verify_inferred(p: &VProgram, global_count: u64, prim_arity: Vec<Vec<u8>>, trusted: bool) -> Verdict {
    // The inference allocates infallibly (hosts).
    crate::counting::stop_failing();
    let t = Clock::start();
    // The trusted fields of the certificate (x_loaded_ok_stream checked the
    // globals against this count) are the inference's inputs.
    let global = infer::infer_global(p, global_count, prim_arity, trusted);
    let mut infer_ns = t.ns();
    // The certificate as the toolchain ships it (the encoder computes each
    // method's maps), checked by the proven checker of shipped
    // certificates as a device checks it.
    let t = Clock::start();
    let encoded = toit_spec::v2::encode::encode(p, &global, trusted);
    infer_ns += t.ns();
    let t = Clock::start();
    let verdict = match &encoded {
        Ok((cert, _)) => cert::verify_shipped(p, cert, global.g.global_count, &global.g.prim_arity, trusted),
        Err(_) => Ok((false, p.methods.len(), 0)),
    };
    let check_ns = t.ns();
    let mut v = match verdict {
        Ok((true, _, _)) => Verdict::new(ACCEPTED, Cow::Borrowed("")),
        Ok((false, at, _)) => diagnose(p, &global, at, trusted),
        Err(_) => Verdict::out_of_memory(),
    };
    v.infer_ns = infer_ns;
    v.check_ns = check_ns;
    v
}

/// Why the shipped certificate was rejected (diagnostics only): the method
/// the checker stopped at, and on hosts what the inference says about it.
fn diagnose_shipped(p: &VProgram, cert: &[u8], at: usize, off: usize, global_count: u64, prim_arity: Vec<Vec<u8>>, trusted: bool) -> Verdict {
    let parsed = cert::parse_cert(p, cert, global_count, &prim_arity).is_some();
    if !parsed {
        return Verdict::new(CERTIFICATE, "malformed certificate (header or sections)".into());
    }
    #[cfg(feature = "infer")]
    {
        crate::counting::stop_failing();
        let global = infer::infer_global(p, global_count, prim_arity, trusted);
        if let (false, at2) = infer::check(p, &global, trusted) {
            let mut v = diagnose(p, &global, at2.map(|x| x.0).unwrap_or(p.methods.len()), trusted);
            v.message = format!("{} (shipped certificate rejected at method {})", v.message, at).into();
            return v;
        }
    }
    #[cfg(not(feature = "infer"))]
    let _ = trusted;
    let mut v = Verdict::new(CERTIFICATE, text!("the shipped certificate is rejected", "the shipped certificate is rejected (method {} +{})", at, off));
    if at < p.methods.len() {
        v.method = at as isize;
        v.offset = off as isize;
    }
    v
}

/// Why the checker rejected the inferred certificate (called only after it
/// did): `m` is the method it stopped at (the method count: the tables).
#[cfg(feature = "infer")]
fn diagnose(p: &VProgram, global: &infer::Global, m: usize, trusted: bool) -> Verdict {
    if m >= p.methods.len() {
        let mut v = Verdict::new(TABLES, "program tables (tables_ok)".into());
        if let Some((m, off, msg)) = global.errors.first() {
            v.message = format!("program tables (tables_ok); inference: method {} +{}: {}", m, off, msg).into();
        }
        return v;
    };
    let mut v = Verdict::new(METHOD, Cow::Borrowed(""));
    v.method = m as isize;
    let (off, why) = infer::diagnose(p, global, m, trusted);
    match off {
        Some(off) => {
            v.offset = off as isize;
            v.message = format!("{}: {}", instruction(p, m, off), why).into();
        }
        None => v.message = why.into(),
    }
    v
}

/// The instruction at `off` in method `m`: its name and operand bytes.
#[cfg(feature = "infer")]
fn instruction(p: &VProgram, m: usize, off: usize) -> String {
    use toit_spec::v2::bytecodes::{OPCODE_LENGTHS2, OPCODE_NAMES2};
    let Some(info) = p.methods.get(m) else { return "(no method)".into() };
    let end = info.end();
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

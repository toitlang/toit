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

//! TRUSTED: the C ABI (src/verifier_v2.h). The structs must match
//! `toit_vmverify_input` and `toit_vmverify_result` (checked by
//! verified/layout_check.cc).

use std::ffi::{c_char, CStr};
use std::time::Instant;
use toit_verified_core::ffi::ProgramTables;
use crate::alloc;
use crate::from_vm::{self, PrimitiveArities};
use crate::verify;

/// `toit_vmverify_input`.
#[repr(C)]
pub struct VerifyInput {
    /// The tables as `toit_v2_run` gets them, with the program's initial
    /// globals.
    pub program: *const ProgramTables,
    /// The VM's primitive table: per module the number of primitives, and
    /// all arities concatenated.
    pub prim_counts: *const u32,
    pub prim_module_count: usize,
    pub prim_arities: *const u8,
    pub prim_arities_length: usize,
    /// Non-zero: the trusted rules (HALT 2 and 3 allowed).
    pub trusted: usize,
}

pub const MESSAGE_SIZE: usize = 200;

/// `toit_vmverify_result`.
#[repr(C)]
pub struct VerifyResult {
    pub code: usize,
    /// The rejected method (index into the method table) and the offset of
    /// the rejected instruction from its entry, or -1.
    pub method: isize,
    pub offset: isize,
    /// Program-heap objects reachable from the roots, globals and literals.
    pub objects: usize,
    pub convert_ns: u64,
    pub heap_ns: u64,
    pub infer_ns: u64,
    pub check_ns: u64,
    /// High-water mark of the Rust heap during the call, above its level at
    /// entry (approximate when other threads allocate meanwhile).
    pub peak_bytes: usize,
    /// NUL-terminated reason.
    pub message: [u8; MESSAGE_SIZE],
}

fn set_message(r: &mut VerifyResult, text: &str) {
    let n = text.len().min(MESSAGE_SIZE - 1);
    r.message[..n].copy_from_slice(&text.as_bytes()[..n]);
    r.message[n] = 0;
}

unsafe fn arities<'a>(i: &VerifyInput) -> PrimitiveArities<'a> {
    let counts = if i.prim_module_count == 0 { &[][..] } else { std::slice::from_raw_parts(i.prim_counts, i.prim_module_count) };
    let arities = if i.prim_arities_length == 0 { &[][..] } else { std::slice::from_raw_parts(i.prim_arities, i.prim_arities_length) };
    PrimitiveArities { counts, arities }
}

/// Verifies the program described by `input`. Returns the result code
/// (also in `result`). A panic of the verifier rejects the program
/// (`INTERNAL`).
///
/// # Safety
/// `input` and `result` must be valid; see `from_vm::convert` for the
/// tables.
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_verify(input: *const VerifyInput, result: *mut VerifyResult) -> usize {
    let input = &*input;
    let r = &mut *result;
    r.code = verify::INTERNAL;
    r.method = -1;
    r.offset = -1;
    r.objects = 0;
    r.convert_ns = 0;
    r.heap_ns = 0;
    r.infer_ns = 0;
    r.check_ns = 0;
    r.peak_bytes = 0;
    set_message(r, "verifier failed");
    let base = alloc::start_peak();
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let t = Instant::now();
        let converted = from_vm::convert(&*input.program, &arities(input));
        let convert_ns = t.elapsed().as_nanos() as u64;
        match converted {
            Err(e) => {
                let mut v = verify::Verdict { code: verify::MALFORMED, method: -1, offset: -1,
                    message: format!("{} ({})", e.what, e.detail), heap_ns: 0, infer_ns: 0, check_ns: 0 };
                v.message.truncate(MESSAGE_SIZE - 1);
                (v, 0, convert_ns)
            }
            Ok((loaded, prim_arity)) => {
                let objects = loaded.heap.len();
                (verify::verify(&loaded, prim_arity, input.trusted != 0), objects, convert_ns)
            }
        }
    }));
    r.peak_bytes = alloc::peak_since(base);
    if let Ok((v, objects, convert_ns)) = outcome {
        r.code = v.code;
        r.method = v.method;
        r.offset = v.offset;
        r.objects = objects;
        r.convert_ns = convert_ns;
        r.heap_ns = v.heap_ns;
        r.infer_ns = v.infer_ns;
        r.check_ns = v.check_ns;
        set_message(r, &v.message);
    }
    r.code
}

/// Writes the canonical form (canonical.rs) of the program described by
/// `input` to the file `path`. Returns 0 on success, 1 if the memory could
/// not be converted, 2 if the file could not be written. Test support for
/// tests/differential.py.
///
/// # Safety
/// As `toit_vmverify_verify`; `path` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_canonical(input: *const VerifyInput, path: *const c_char) -> usize {
    let input = &*input;
    let path = match CStr::from_ptr(path).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return 2,
    };
    match from_vm::convert(&*input.program, &arities(input)) {
        Err(e) => {
            eprintln!("cannot convert the program: {} ({})", e.what, e.detail);
            1
        }
        Ok((loaded, prim_arity)) => {
            let text = crate::canonical::canonical(&loaded, &prim_arity);
            if std::fs::write(&path, text).is_ok() { 0 } else { 2 }
        }
    }
}

macro_rules! layout_entries {
    ($($name:expr => $value:expr),* $(,)?) => {
        const LAYOUT: &[(&[u8], usize)] = &[$(($name, $value),)*];
    };
}

layout_entries!(
    b"VMVERIFY_INPUT_SIZE\0" => core::mem::size_of::<VerifyInput>(),
    b"VMVERIFY_INPUT_program\0" => core::mem::offset_of!(VerifyInput, program),
    b"VMVERIFY_INPUT_prim_counts\0" => core::mem::offset_of!(VerifyInput, prim_counts),
    b"VMVERIFY_INPUT_prim_module_count\0" => core::mem::offset_of!(VerifyInput, prim_module_count),
    b"VMVERIFY_INPUT_prim_arities\0" => core::mem::offset_of!(VerifyInput, prim_arities),
    b"VMVERIFY_INPUT_prim_arities_length\0" => core::mem::offset_of!(VerifyInput, prim_arities_length),
    b"VMVERIFY_INPUT_trusted\0" => core::mem::offset_of!(VerifyInput, trusted),
    b"VMVERIFY_RESULT_SIZE\0" => core::mem::size_of::<VerifyResult>(),
    b"VMVERIFY_RESULT_code\0" => core::mem::offset_of!(VerifyResult, code),
    b"VMVERIFY_RESULT_method\0" => core::mem::offset_of!(VerifyResult, method),
    b"VMVERIFY_RESULT_offset\0" => core::mem::offset_of!(VerifyResult, offset),
    b"VMVERIFY_RESULT_objects\0" => core::mem::offset_of!(VerifyResult, objects),
    b"VMVERIFY_RESULT_convert_ns\0" => core::mem::offset_of!(VerifyResult, convert_ns),
    b"VMVERIFY_RESULT_heap_ns\0" => core::mem::offset_of!(VerifyResult, heap_ns),
    b"VMVERIFY_RESULT_infer_ns\0" => core::mem::offset_of!(VerifyResult, infer_ns),
    b"VMVERIFY_RESULT_check_ns\0" => core::mem::offset_of!(VerifyResult, check_ns),
    b"VMVERIFY_RESULT_peak_bytes\0" => core::mem::offset_of!(VerifyResult, peak_bytes),
    b"VMVERIFY_RESULT_message\0" => core::mem::offset_of!(VerifyResult, message),
    b"VMVERIFY_MESSAGE_SIZE\0" => MESSAGE_SIZE,
    b"VMVERIFY_ACCEPTED\0" => verify::ACCEPTED,
    b"VMVERIFY_MALFORMED\0" => verify::MALFORMED,
    b"VMVERIFY_HEAP\0" => verify::HEAP,
    b"VMVERIFY_TABLES\0" => verify::TABLES,
    b"VMVERIFY_METHOD\0" => verify::METHOD,
    b"VMVERIFY_INTERNAL\0" => verify::INTERNAL,
);

/// The number of layout entries (for verified/layout_check.cc).
#[no_mangle]
pub extern "C" fn toit_vmverify_layout_count() -> usize {
    LAYOUT.len()
}

/// Layout entry `i`: its name and value. False if `i` is out of range.
///
/// # Safety
/// `name` and `value` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn toit_vmverify_layout_entry(i: usize, name: *mut *const c_char, value: *mut usize) -> bool {
    match LAYOUT.get(i) {
        Some((n, v)) => {
            *name = n.as_ptr() as *const c_char;
            *value = *v;
            true
        }
        None => false,
    }
}

/// The arity of primitive `index` of `module` in the verifier's generated
/// table (v2::prim_arity::PRIM_TABLE), or -1: compared against the VM's
/// table by the layout check.
#[no_mangle]
pub extern "C" fn toit_vmverify_generated_arity(module: usize, index: usize) -> isize {
    let table = toit_spec::v2::prim_arity::PRIM_TABLE;
    match table.get(module).and_then(|(_, prims)| prims.get(index)) {
        Some((_, a)) => *a as isize,
        None => -1,
    }
}
